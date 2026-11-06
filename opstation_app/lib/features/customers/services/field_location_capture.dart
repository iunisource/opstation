import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/photo/photo_watermark.dart';
import '../../../core/utils/location_check.dart';
import '../../../shared/widgets/accuracy_meter.dart';
import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import '../../auth/models/user_role.dart';
import '../../../core/sync/sync_controller.dart';
import '../../admin_settings/providers/org_settings_controller.dart';

/// Admin Settings (web) → "Salesperson can add shop location":
/// org.field_location_capture (on/off) + org.field_location_capture_scope
/// (missing | any). Read from the server, cached on the phone for offline.
class FieldLocationConfig {
  final bool enabled;
  final bool anyCustomer; // false = only shops with no saved location
  const FieldLocationConfig(this.enabled, this.anyCustomer);
  static const off = FieldLocationConfig(false, false);

  /// [suspect]: the saved location is shared with a different shop (wrong
  /// / copied) — it can be recaptured even when only missing ones are allowed.
  bool allows({required bool hasLocation, bool suspect = false}) =>
      enabled && (anyCustomer || !hasLocation || suspect);
}

final fieldLocationConfigProvider = FutureProvider<FieldLocationConfig>((ref) async {
  final orgId = ref.watch(orgIdProvider);
  final db = ref.watch(appDatabaseProvider);
  if (orgId == null) return FieldLocationConfig.off;
  try {
    final rows = await Supabase.instance.client
        .from('app_config')
        .select('key, value')
        .eq('org_id', orgId)
        .inFilter('key', ['org.field_location_capture', 'org.field_location_capture_scope']);
    String on = 'false', scope = 'missing';
    for (final r in rows as List) {
      final m = Map<String, dynamic>.from(r as Map);
      if (m['key'] == 'org.field_location_capture') on = '${m['value'] ?? 'false'}';
      if (m['key'] == 'org.field_location_capture_scope') scope = '${m['value'] ?? 'missing'}';
    }
    await db.setConfig('org.field_location_capture', on);
    await db.setConfig('org.field_location_capture_scope', scope);
    return FieldLocationConfig(on == 'true', scope == 'any');
  } catch (_) {
    final on = await db.getConfig('org.field_location_capture');
    final scope = await db.getConfig('org.field_location_capture_scope');
    return FieldLocationConfig(on == 'true', scope == 'any');
  }
});

/// One-step shop location capture: GPS starts sharpening the moment the
/// salesperson taps, the camera opens straight away, and by the time the photo
/// is taken the fix is usually good enough. The photo is stamped with the
/// coordinates and saved to the customer — it then waits for a supervisor in
/// Customer 360 (web).
class FieldLocationCapture {
  /// Surveyor: same capture (photo + GPS, stamped, sent for review), with the
  /// org's GPS accuracy limit. Returns true when saved.
  static Future<bool> runForShop(BuildContext context, WidgetRef ref,
      {required String customerId, required String shopName, required String shopCode}) async {
    int limit = 50;
    try {
      limit = (await ref.read(orgSettingsProvider.future)).accuracyWarnMeters;
    } catch (_) {}
    if (!context.mounted) return false;
    final r = await run(context, ref,
        customerId: customerId, shopName: shopName, shopCode: shopCode, accuracyLimitMeters: limit.toDouble());
    return r != null;
  }

  /// Returns the saved (lat, lng), or null if cancelled / failed (the reason is
  /// shown to the user).
  static Future<(double, double)?> run(
    BuildContext context,
    WidgetRef ref, {
    required String customerId,
    required String shopName,
    required String shopCode,
    required double accuracyLimitMeters,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    void say(String m) => messenger.showSnackBar(SnackBar(content: Text(m)));

    // GPS ready?
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        say('Turn on location (GPS) to add the shop location.');
        return null;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        say('Allow location access for the app to add the shop location.');
        return null;
      }
    } catch (_) {
      say('Location is not available on this phone right now.');
      return null;
    }

    // Start sharpening GPS now, while the camera is open.
    // The first reading a phone gives is often an OLD cached point (from where
    // it was minutes ago) with a good-looking accuracy figure — keeping it put
    // shop pins hundreds of metres off. Only readings taken from now on count.
    // (Judged by when readings ARRIVE, so a wrong phone clock can't break it.)
    final watch = Stopwatch()..start();
    Position? best;
    DateTime? bestAt;
    final sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
    ).listen((p) {
      if (watch.elapsedMilliseconds < 1500) return; // the instant cached reading
      final DateTime? at = p.timestamp;
      // A reading much newer than the kept one replaces it even if its
      // accuracy figure is a little worse — the kept one is out of date.
      final newer = at != null && bestAt != null && at.difference(bestAt!).inSeconds > 20;
      if (best == null || newer || p.accuracy <= best!.accuracy) {
        best = p;
        bestAt = at;
      }
    }, onError: (_) {});

    try {
      late Position pos;
      late Uint8List bytes;
      late DateTime shotAt;
      // Photo → GPS → check screen (health meter). "Capture again" loops.
      while (true) {
        final file = await ImagePicker().pickImage(
          source: ImageSource.camera,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 75,
          preferredCameraDevice: CameraDevice.rear,
        );
        if (file == null) return null; // cancelled
        shotAt = DateTime.now();
        bytes = await File(file.path).readAsBytes();
        if (!context.mounted) return null;

        // Usually already good. If not, wait here (auto-continues).
        if (best == null || best!.accuracy > accuracyLimitMeters) {
          final ok = await _waitForFix(context, () => best, accuracyLimitMeters);
          if (ok != true) return null;
        }
        pos = best!;
        if (!context.mounted) return null;
        // Stamp now, so the check screen shows exactly the photo that is saved.
        final u = ref.read(authControllerProvider).valueOrNull;
        bytes = PhotoWatermark.addStampStrip(jpegBytes: bytes, lines: [
          '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}   +/- ${pos.accuracy.round()} m',
          PhotoWatermark.formatTs(shotAt),
          '$shopName${shopCode.isEmpty ? '' : '  (#$shopCode)'}',
          if ((u?.name ?? '').isNotEmpty) 'By ${u!.name}',
        ]);
        final choice = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          isDismissible: false,
          enableDrag: false,
          builder: (_) => _CaptureCheck(photo: bytes, pos: pos, shopName: shopName),
        );
        if (choice == null || !context.mounted) return null; // cancelled
        if (choice == 'save') break;
        // Capture again: only readings from now on count.
        best = null;
        bestAt = null;
        watch
          ..reset()
          ..start();
      }
      // Another shop already saved at this exact spot? Ask before saving.
      LocFixWarning warn = const LocFixWarning(true, 'en');
      try {
        warn = await ref.read(locFixWarningProvider.future);
      } catch (_) {}
      if (!context.mounted) return null;
      final okSpot = await confirmFreeSpot(context, ref.read(appDatabaseProvider),
          lat: pos.latitude, lng: pos.longitude, customerId: customerId, shopName: shopName, warning: warn);
      if (!okSpot || !context.mounted) return null;

      final stamped = bytes; // stamped above

      return await _save(context, ref,
          customerId: customerId, pos: pos, photo: stamped, onError: say);
    } catch (_) {
      say('Could not add the location. Please try again.');
      return null;
    } finally {
      await sub.cancel();
    }
  }

  static Future<bool?> _waitForFix(
      BuildContext context, Position? Function() best, double limit) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _FixWaitDialog(best: best, limit: limit),
    );
  }

  static Future<(double, double)?> _save(
    BuildContext context,
    WidgetRef ref, {
    required String customerId,
    required Position pos,
    required Uint8List photo,
    required void Function(String) onError,
  }) async {
    final client = Supabase.instance.client;
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 14),
          Expanded(child: Text('Saving shop location…')),
        ]),
      ),
    );
    try {
      // A shop just added on this phone must reach the server first.
      try {
        final db = ref.read(appDatabaseProvider);
        final local = await (db.select(db.customers)..where((c) => c.id.equals(customerId))).getSingleOrNull();
        if (local != null && local.syncStatus == 'pending') {
          await ref.read(syncControllerProvider.notifier).flushPending();
        }
      } catch (_) {}
      final path = 'customer_locations/$customerId/${DateTime.now().millisecondsSinceEpoch}.jpg';
      await client.storage.from('opstation-photos').uploadBinary(
            path,
            photo,
            fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false),
          );
      await client.rpc('customer_capture_location', params: {
        'p_customer': customerId,
        'p_lat': pos.latitude,
        'p_lng': pos.longitude,
        'p_accuracy': double.parse(pos.accuracy.toStringAsFixed(1)),
        'p_mocked': pos.isMocked,
        'p_photo_path': path,
      });
      // Mirror on the phone without queuing a re-upload.
      try {
        final db = ref.read(appDatabaseProvider);
        await (db.update(db.customers)..where((c) => c.id.equals(customerId))).write(
          CustomersCompanion(latitude: Value(pos.latitude), longitude: Value(pos.longitude)),
        );
        await clearSuspect(db, customerId);
        ref.invalidate(suspectLocationIdsProvider);
      } catch (_) {}
      nav.pop();
      // Surveyors' captures go for review only when Admin Settings says so.
      var review = true;
      try {
        final role = ref.read(authControllerProvider).valueOrNull?.role;
        if (role == UserRole.surveyor) {
          review = (await ref.read(appDatabaseProvider).getConfig('org.surveyor_location_supervise')) == 'true';
        }
      } catch (_) {}
      onError(review ? 'Shop location saved — sent for review.' : 'Shop location saved.');
      return (pos.latitude, pos.longitude);
    } on PostgrestException catch (e) {
      nav.pop();
      onError(e.message.isNotEmpty && !e.message.contains('function')
          ? e.message
          : 'Could not save the location. Please try again.');
      return null;
    } catch (e) {
      nav.pop();
      final s = '$e'.toLowerCase();
      onError(s.contains('socket') || s.contains('network') || s.contains('host')
          ? 'No internet. Adding a shop location needs a connection — please try again when online.'
          : 'Could not save the location. Please try again.');
      return null;
    }
  }
}

/// After the photo: the photo, the reading and its health — Save or Capture again.
class _CaptureCheck extends StatelessWidget {
  final Uint8List photo;
  final Position pos;
  final String shopName;
  const _CaptureCheck({required this.photo, required this.pos, required this.shopName});

  @override
  Widget build(BuildContext context) {
    final poor = pos.accuracy > 50;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(shopName, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(photo, height: 210, width: double.infinity, fit: BoxFit.cover),
          ),
          const SizedBox(height: 12),
          Text('${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          AccuracyMeter(accuracyMeters: pos.accuracy),
          if (pos.isMocked)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('This phone reports a fake (mock) location.',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.danger)),
            )
          else if (poor)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Accuracy is low. Step out to the shop front or open sky and capture again.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
            ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, 'again'),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Capture again'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, 'save'),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
              ),
            ),
          ]),
          Center(
            child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ),
        ]),
      ),
    );
  }
}

class _FixWaitDialog extends StatefulWidget {
  final Position? Function() best;
  final double limit;
  const _FixWaitDialog({required this.best, required this.limit});

  @override
  State<_FixWaitDialog> createState() => _FixWaitDialogState();
}

class _FixWaitDialogState extends State<_FixWaitDialog> {
  Timer? _t;
  int _secs = 0;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final b = widget.best();
      if (b != null && b.accuracy <= widget.limit) {
        _t?.cancel();
        Navigator.of(context).pop(true);
        return;
      }
      setState(() => _secs++);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.best();
    final acc = b?.accuracy.round();
    return AlertDialog(
      title: const Text('Getting a precise location'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text(acc == null
              ? 'Waiting for GPS…'
              : 'Accuracy ±$acc m (needs ±${widget.limit.round()} m)',
              style: TextStyle(fontWeight: FontWeight.w600,
                  color: acc != null && acc <= widget.limit ? AppColors.success : null))),
        ]),
        if (b != null) ...[
          const SizedBox(height: 10),
          AccuracyMeter(accuracyMeters: b.accuracy),
        ],
        if (_secs > 30) ...[
          const SizedBox(height: 10),
          const Text('Step out to the shop front or open sky — it will continue by itself.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
      ],
    );
  }
}
