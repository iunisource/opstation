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
import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';

/// Admin Settings (web) → "Salesperson can add shop location":
/// org.field_location_capture (on/off) + org.field_location_capture_scope
/// (missing | any). Read from the server, cached on the phone for offline.
class FieldLocationConfig {
  final bool enabled;
  final bool anyCustomer; // false = only shops with no saved location
  const FieldLocationConfig(this.enabled, this.anyCustomer);
  static const off = FieldLocationConfig(false, false);

  bool allows({required bool hasLocation}) => enabled && (anyCustomer || !hasLocation);
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
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 75,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (file == null) return null; // cancelled
      final shotAt = DateTime.now();
      final bytes = await File(file.path).readAsBytes();
      if (!context.mounted) return null;

      // Usually already good. If not, wait here (auto-continues).
      if (best == null || best!.accuracy > accuracyLimitMeters) {
        final ok = await _waitForFix(context, () => best, accuracyLimitMeters);
        if (ok != true) return null;
      }
      final pos = best!;
      if (!context.mounted) return null;

      final user = ref.read(authControllerProvider).valueOrNull;
      final stamped = PhotoWatermark.addStampStrip(jpegBytes: bytes, lines: [
        '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}   +/- ${pos.accuracy.round()} m',
        PhotoWatermark.formatTs(shotAt),
        '$shopName${shopCode.isEmpty ? '' : '  (#$shopCode)'}',
        if ((user?.name ?? '').isNotEmpty) 'By ${user!.name}',
      ]);

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
      } catch (_) {}
      nav.pop();
      onError('Shop location saved — sent for review.');
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
