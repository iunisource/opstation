import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/photo/photo_watermark.dart';
import '../../../core/services/device_gps_service.dart';
import '../../admin_settings/providers/org_settings_controller.dart';
import '../../auth/providers/auth_controller.dart';
import 'survey_audit_service.dart';

/// Auditor feedback on a shop (surveyed or not): comment + optional photo +
/// where the auditor was. Saved on the phone first, sent when online.
///
/// Photos go to the private bucket `survey-feedback` (SQL 447) as
/// `<org>/<id>.jpg`; the record keeps `survey-feedback/<org>/<id>.jpg`.
/// Older audit photos live in `opstation-photos` (`survey-audits/...`).
const feedbackBucket = 'survey-feedback';

/// Admin Settings → "Auditor location tracking" (org.audit_location_tracking).
/// ON (default): the auditor's location is checked against the shop and
/// shown. OFF: no location is taken or shown, in the app or in reports.
final auditLocationOnProvider = FutureProvider<bool>((ref) async {
  final v = (await ref.watch(appDatabaseProvider).getConfig('org.audit_location_tracking'))?.trim() ?? '';
  return v != 'false';
});

/// (bucket, object path) of a stored audit / feedback photo.
(String, String) photoRef(String path) {
  if (path.startsWith('$feedbackBucket/')) return (feedbackBucket, path.substring(feedbackBucket.length + 1));
  return ('opstation-photos', path);
}

double _distance(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Metres between a phone fix and a shop; null when the shop has no location.
double? distanceTo(CustomersData shop, double lat, double lng) {
  final sLat = shop.latitude, sLng = shop.longitude;
  if (sLat == null || sLng == null) return null;
  return _distance(lat, lng, sLat, sLng);
}

/// Where the auditor is, compared with the shop's saved location.
Future<Map<String, dynamic>> locateAtShop(WidgetRef ref, CustomersData shop) async {
  GpsFixResult? res;
  try {
    res = await ref.read(deviceGpsServiceProvider).getFixResult(timeout: const Duration(seconds: 20));
  } catch (_) {}
  if (res == null || !res.ok) return {'location_status': 'no_gps'};
  final fix = res.fix!;
  final out = <String, dynamic>{'lat': fix.lat, 'lng': fix.lng, 'accuracy_m': fix.accuracy};
  final d = distanceTo(shop, fix.lat, fix.lng);
  if (d == null) {
    out['location_status'] = 'no_shop_location';
    return out;
  }
  int radius = 100;
  try {
    radius = (await ref.read(orgSettingsProvider.future)).geofenceRadiusMeters;
  } catch (_) {}
  out['distance_m'] = double.parse(d.toStringAsFixed(1));
  out['location_status'] = d <= radius ? 'inside' : 'outside';
  return out;
}

/// Opens the feedback sheet for [shop] and saves it. True when saved.
Future<bool> giveFeedback(BuildContext context, WidgetRef ref, CustomersData shop) async {
  final messenger = ScaffoldMessenger.of(context);
  final user = ref.read(authControllerProvider).valueOrNull;
  final orgId = user?.organizationId ?? shop.orgId;
  if (user == null || orgId == null) return false;
  bool track = true;
  try {
    track = await ref.read(auditLocationOnProvider.future);
  } catch (_) {}
  // Location runs while the auditor types (only when tracking is on).
  final locF = track ? locateAtShop(ref, shop) : Future.value(<String, dynamic>{});
  final res = await showModalBottomSheet<(String, String?, Map<String, dynamic>)>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FeedbackSheet(shop: shop, location: locF, showLocation: track),
  );
  if (res == null) return false;
  final (comment, photo, loc) = res;
  final now = DateTime.now();
  final ms = now.millisecondsSinceEpoch;
  final db = ref.read(appDatabaseProvider);
  final svc = SurveyAuditService(db);
  await svc.enqueue({
    'id': 'sa_${ms}_${user.id}',
    'org_id': orgId,
    'customer_id': shop.id,
    'auditor_id': user.id,
    'auditor_name': user.name,
    'result': 'feedback',
    'comment': comment,
    'lat': loc['lat'],
    'lng': loc['lng'],
    'accuracy_m': loc['accuracy_m'],
    'distance_m': loc['distance_m'],
    'location_status': loc['location_status'],
    'audited_at': now.toUtc().toIso8601String(),
    if (photo != null) 'local_photo': photo,
  });
  final left = await svc.flush();
  messenger.showSnackBar(SnackBar(
    content: Text(left == 0 ? 'Feedback saved for ${shop.shopName}' : 'Feedback saved on this phone — it will be sent when online'),
  ));
  return true;
}

/// Comment (required) + optional photo. Returns (comment, photo, location).
class FeedbackSheet extends StatefulWidget {
  final CustomersData shop;
  final Future<Map<String, dynamic>> location;
  final bool showLocation;
  const FeedbackSheet({super.key, required this.shop, required this.location, this.showLocation = true});
  @override
  State<FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<FeedbackSheet> {
  final _comment = TextEditingController();
  Map<String, dynamic>? _loc;
  String? _photo;
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    widget.location.then((l) {
      if (mounted) setState(() => _loc = l);
    });
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    setState(() => _busy = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 70,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (file == null) return;
      Uint8List bytes = await File(file.path).readAsBytes();
      final lat = _loc?['lat'] as double?, lng = _loc?['lng'] as double?;
      if (lat != null && lng != null) {
        try {
          bytes = PhotoWatermark.addWatermark(jpegBytes: bytes, latitude: lat, longitude: lng, timestamp: DateTime.now());
        } catch (_) {}
      }
      final dir = await getApplicationDocumentsDirectory();
      final out = File('${dir.path}/survey_feedback_${widget.shop.id}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await out.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() => _photo = out.path);
    } catch (_) {
      if (mounted) setState(() => _err = 'Could not take the photo');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final st = '${_loc?['location_status'] ?? ''}';
    final d = (_loc?['distance_m'] as num?)?.round();
    final (locText, locColor) = _loc == null
        ? ('Finding your location…', hint)
        : switch (st) {
            'inside' => ('At the shop${d == null ? '' : ' (${d} m)'}', const Color(0xFF059669)),
            'outside' => ('Away from the shop${d == null ? '' : ' (${d} m)'}', const Color(0xFFD97706)),
            'no_shop_location' => ('Shop has no saved location', const Color(0xFFD97706)),
            _ => ('Location not available', const Color(0xFFD97706)),
          };
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Feedback', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(widget.shop.shopName, style: TextStyle(fontSize: 12.5, color: hint), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (widget.showLocation) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(st == 'inside' ? Icons.location_on : Icons.location_searching, size: 15, color: locColor),
            const SizedBox(width: 4),
            Text(locText, style: TextStyle(fontSize: 12.5, color: locColor)),
          ]),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _comment,
          maxLines: 4,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'What did you find?',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _takePhoto,
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: Text(_photo == null ? 'Add photo (optional)' : 'Retake photo'),
          ),
          const SizedBox(width: 10),
          if (_photo != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(File(_photo!), width: 44, height: 44, fit: BoxFit.cover),
            ),
          if (_photo != null)
            IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _photo = null)),
        ]),
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_err!, style: const TextStyle(color: Color(0xFFDC2626))),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    final c = _comment.text.trim();
                    if (c.isEmpty) {
                      setState(() => _err = 'Please write your feedback.');
                      return;
                    }
                    setState(() => _busy = true);
                    final loc = _loc ?? await widget.location;
                    if (!context.mounted) return;
                    Navigator.pop(context, (c, _photo, loc));
                  },
            child: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Save feedback')),
          ),
        ),
      ]),
    );
  }
}

/// Opens a stored feedback / audit photo full screen.
Future<void> showFeedbackPhoto(BuildContext context, Map<String, dynamic> a) async {
  final local = '${a['local_photo'] ?? ''}';
  final path = '${a['photo_path'] ?? ''}';
  Widget img;
  if (path.isEmpty && local.isNotEmpty) {
    img = Image.file(File(local), fit: BoxFit.contain);
  } else if (path.isNotEmpty) {
    final (bucket, name) = photoRef(path);
    String url;
    try {
      url = await Supabase.instance.client.storage.from(bucket).createSignedUrl(name, 3600);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo needs internet to open.')));
      }
      return;
    }
    img = Image.network(url, fit: BoxFit.contain,
        loadingBuilder: (c, w, p) => p == null ? w : const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, __, ___) => const Center(child: Text('Could not load the photo', style: TextStyle(color: Colors.white))));
  } else {
    return;
  }
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (ctx) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(children: [
        Positioned.fill(child: InteractiveViewer(child: Center(child: img))),
        Positioned(
          top: 8,
          right: 8,
          child: SafeArea(
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ),
      ]),
    ),
  );
}
