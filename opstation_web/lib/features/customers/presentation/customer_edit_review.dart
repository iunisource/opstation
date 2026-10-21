import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';

/// Customer edits / field locations waiting for a supervisor
/// (Admin Settings → Supervision for customer edits; Salesperson can add shop
/// location). Shown in Customer 360 → Overview.
class CustomerReviews {
  final List<Map<String, dynamic>> pending;
  final Map<String, String> photoUrls; // photo_path → signed url
  final bool canSupervise;
  final List<(double, double)> visitPoints; // where visits were marked at this shop

  const CustomerReviews(this.pending, this.photoUrls, this.canSupervise, this.visitPoints);
  static const empty = CustomerReviews([], {}, false, []);

  List<Map<String, dynamic>> get location => pending.where((r) => r['kind'] == 'location').toList();
  List<Map<String, dynamic>> get details => pending.where((r) => r['kind'] != 'location').toList();
  bool get any => pending.isNotEmpty;

  static Future<CustomerReviews> load(String customerId, WebUser? user) async {
    final db = Supabase.instance.client;
    final orgId = user?.orgId;
    if (orgId == null) return empty;
    try {
      final rows = List<Map<String, dynamic>>.from(await db.from('customer_edit_reviews').select()
          .eq('customer_id', customerId).eq('status', 'pending').order('changed_at', ascending: false) as List);
      if (rows.isEmpty) return empty;
      final paths = rows.map((r) => r['photo_path']).whereType<String>().where((p) => p.isNotEmpty).toList();
      final urls = <String, String>{};
      if (paths.isNotEmpty) {
        try {
          final r = await db.storage.from('opstation-photos').createSignedUrls(paths, 3600);
          for (final s in r) {
            if (s.signedUrl != null) urls[s.path!] = s.signedUrl!;
          }
        } catch (_) {}
      }
      bool can = user!.role == WebUserRole.admin || user.role == WebUserRole.masterAdmin;
      if (!can) {
        try {
          final c = await db.from('app_config').select('value').eq('org_id', orgId)
              .eq('key', 'org.customer_edit_supervisor_users').maybeSingle();
          can = '${c?['value'] ?? ''}'.split(',').map((e) => e.trim()).contains(user.id);
        } catch (_) {}
      }
      final pts = <(double, double)>[];
      if (rows.any((r) => r['kind'] == 'location')) {
        try {
          final v = await db.from('visits').select('captured_lat, captured_lng')
              .eq('customer_id', customerId).not('captured_lat', 'is', null)
              .order('timestamp', ascending: false).limit(200);
          for (final x in v as List) {
            final la = (x['captured_lat'] as num?)?.toDouble(), lo = (x['captured_lng'] as num?)?.toDouble();
            if (la != null && lo != null) pts.add((la, lo));
          }
        } catch (_) {}
      }
      return CustomerReviews(rows, urls, can, pts);
    } catch (_) {
      return empty;
    }
  }

  static Future<String?> supervise(List<String> ids) async {
    try {
      await Supabase.instance.client.rpc('customer_review_supervise', params: {'p_ids': ids});
      return null;
    } catch (e) {
      return friendlyError('That did not save', e);
    }
  }

  static Future<String?> revert(String id, String? note) async {
    try {
      final r = await Supabase.instance.client.rpc('customer_review_revert', params: {'p_id': id, 'p_note': note});
      return r == 'partly' ? 'Reverted. Some fields were changed again since, so they were left as they are.' : null;
    } catch (e) {
      return friendlyError('That did not save', e);
    }
  }
}

/// Location lifecycle: every location change for a shop (newest first) —
/// who, when, how (field photo / edit), old → new, accuracy, and what the
/// supervisor did. Opened from Customer 360 → Location and the customer form.
Future<void> showLocationLifecycle(BuildContext context, {
  required String customerId,
  required String shopName,
  double? currentLat,
  double? currentLng,
}) async {
  final db = Supabase.instance.client;
  List<Map<String, dynamic>> rows = [];
  final urls = <String, String>{};
  String? error;
  try {
    rows = List<Map<String, dynamic>>.from(await db.from('customer_edit_reviews').select()
        .eq('customer_id', customerId).eq('kind', 'location').order('changed_at', ascending: false).limit(100) as List);
    final paths = rows.map((r) => r['photo_path']).whereType<String>().where((p) => p.isNotEmpty).toList();
    if (paths.isNotEmpty) {
      try {
        final r = await db.storage.from('opstation-photos').createSignedUrls(paths, 3600);
        for (final s in r) {
          if (s.signedUrl != null) urls[s.path!] = s.signedUrl!;
        }
      } catch (_) {}
    }
  } catch (e) {
    error = friendlyError('Could not load the location history', e);
  }
  if (!context.mounted) return;

  String coords(Object? la, Object? lo) {
    final a = (la as num?)?.toDouble(), b = (lo as num?)?.toDouble();
    return a == null || b == null ? 'No location' : '${a.toStringAsFixed(6)}, ${b.toStringAsFixed(6)}';
  }

  Widget statusChip(Map r) {
    final st = '${r['status'] ?? 'pending'}';
    final (Color c, String t) = switch (st) {
      'supervised' => (AppTheme.success, 'Supervised'),
      'reverted' => (AppTheme.danger, 'Reverted'),
      _ => (Colors.amber.shade800, 'Pending review'),
    };
    final d = DateTime.tryParse('${r['reviewed_at'] ?? ''}')?.toLocal();
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
        child: Text(t, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      ),
      if (st != 'pending' && r['reviewed_by_name'] != null)
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(
            '${r['reviewed_by_name']}${d == null ? '' : ' · ${DateFormat('d MMM y').format(d)}'}',
            style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary))),
    ]);
  }

  await showDialog(context: context, builder: (ctx) => AlertDialog(
    title: Text('Location history · $shopName'),
    content: SizedBox(width: 560, child: error != null
        ? Text(error, style: const TextStyle(color: AppTheme.danger))
        : SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.location_on_outlined, size: 16, color: AppTheme.primary),
                const SizedBox(width: 6),
                const Text('Now: ', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                Expanded(child: Text(coords(currentLat, currentLng), style: const TextStyle(fontSize: 12.5))),
              ]),
            ),
            const SizedBox(height: 10),
            if (rows.isEmpty)
              const Text('No location changes recorded yet. Changes are recorded from the day "Supervision for customer edits" or "Salesperson can add shop location" was switched on.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            for (var i = 0; i < rows.length; i++) Builder(builder: (_) {
              final r = rows[i];
              final ch = (r['changes'] as Map?) ?? const {};
              final url = urls['${r['photo_path'] ?? ''}'];
              final acc = (r['accuracy_m'] as num?)?.toDouble();
              final field = r['source'] == 'field_capture';
              return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // timeline rail
                SizedBox(width: 22, child: Column(children: [
                  Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 6),
                      decoration: BoxDecoration(shape: BoxShape.circle,
                          color: i == 0 ? AppTheme.primary : AppTheme.border)),
                  if (i < rows.length - 1) Expanded(child: Container(width: 2, color: AppTheme.border)),
                ])),
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (url != null) ...[
                      InkWell(
                        onTap: () => showDialog(context: ctx, builder: (c2) => Dialog(
                            child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)))),
                        child: ClipRRect(borderRadius: BorderRadius.circular(6),
                            child: Image.network(url, width: 64, height: 64, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const SizedBox(width: 64, height: 64))),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${field ? 'Taken in the field' : 'Edited'} · ${_who(r)}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text('${coords((ch['latitude'] as Map?)?['old'], (ch['longitude'] as Map?)?['old'])}  →  '
                          '${coords(r['captured_lat'] ?? (ch['latitude'] as Map?)?['new'], r['captured_lng'] ?? (ch['longitude'] as Map?)?['new'])}',
                          style: const TextStyle(fontSize: 12)),
                      if (acc != null) Text('GPS ±${acc.round()} m${r['is_mocked'] == true ? '  ·  ⚠ fake GPS reported' : ''}',
                          style: TextStyle(fontSize: 11.5, color: r['is_mocked'] == true ? AppTheme.danger : AppTheme.textSecondary)),
                      if ((r['note'] ?? '').toString().isNotEmpty)
                        Text('Note: ${r['note']}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                    ])),
                    const SizedBox(width: 8),
                    statusChip(r),
                  ]),
                )),
              ]));
            }),
          ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
  ));
}

const _labels = {
  'shop_name': 'Shop name', 'code': 'Code', 'contact_person': 'Contact', 'phone': 'Phone',
  'address': 'Address', 'category': 'Category', 'group_name': 'Group', 'credit_limit': 'Credit limit',
  'monthly_sale_target': 'Monthly target', 'ntn_gst': 'NTN / GST', 'is_active': 'Status',
};

String _show(String field, Object? v) {
  if (v == null || '$v'.trim().isEmpty) return '—';
  if (field == 'is_active') return v == true ? 'Active' : 'Deactivated';
  return '$v';
}

String _who(Map r) {
  final d = DateTime.tryParse('${r['changed_at'] ?? ''}')?.toLocal();
  return '${r['changed_by_name'] ?? 'Someone'}${d == null ? '' : ' · ${DateFormat('d MMM y, h:mm a').format(d)}'}';
}

double _meters(double la1, double lo1, double la2, double lo2) {
  const r = 6371000.0;
  final p1 = la1 * math.pi / 180, p2 = la2 * math.pi / 180;
  final dp = (la2 - la1) * math.pi / 180, dl = (lo2 - lo1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

String _dist(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

Future<String?> _askReason(BuildContext context) async {
  final ctrl = TextEditingController();
  return showDialog<String>(context: context, builder: (ctx) => AlertDialog(
    title: const Text('Revert this change?'),
    content: TextField(controller: ctrl, autofocus: true, maxLines: 2,
        decoration: const InputDecoration(labelText: 'Reason (optional)', border: OutlineInputBorder())),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Revert')),
    ],
  ));
}

Widget _actions(BuildContext context, Map r, bool can, Future<void> Function() onDone, {bool location = false}) {
  if (!can) {
    return const Padding(padding: EdgeInsets.only(top: 6),
        child: Text('Waiting for a supervisor.', style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)));
  }
  return Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Wrap(spacing: 8, runSpacing: 6, children: [
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success, foregroundColor: Colors.white),
        icon: const Icon(Icons.verified_outlined, size: 16),
        label: Text(location ? 'Supervise location' : 'Supervise'),
        onPressed: () async {
          final err = await CustomerReviews.supervise(['${r['id']}']);
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Supervised')));
          await onDone();
        },
      ),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
        icon: const Icon(Icons.undo, size: 16),
        label: const Text('Revert'),
        onPressed: () async {
          final note = await _askReason(context);
          if (note == null) return;
          final msg = await CustomerReviews.revert('${r['id']}', note.isEmpty ? null : note);
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg ?? 'Reverted to the old values')));
          await onDone();
        },
      ),
    ]),
  );
}

/// "Changes to review" card (everything except location).
class PendingCustomerChanges extends StatelessWidget {
  const PendingCustomerChanges({super.key, required this.data, required this.onDone});
  final CustomerReviews data;
  final Future<void> Function() onDone;

  @override
  Widget build(BuildContext context) {
    final list = data.details;
    if (list.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.shade700, width: 1.4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.rate_review_outlined, size: 18, color: Colors.amber.shade800),
          const SizedBox(width: 8),
          Text('Changes to review (${list.length})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        ]),
        for (final r in list) Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_who(r), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            for (final e in ((r['changes'] as Map?) ?? const {}).entries) Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 120, child: Text(_labels[e.key] ?? '${e.key}',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
                Expanded(child: Text.rich(TextSpan(children: [
                  TextSpan(text: _show('${e.key}', (e.value as Map?)?['old']),
                      style: const TextStyle(color: AppTheme.textSecondary, decoration: TextDecoration.lineThrough)),
                  const TextSpan(text: '  →  '),
                  TextSpan(text: _show('${e.key}', (e.value as Map?)?['new']), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]), style: const TextStyle(fontSize: 12.5))),
              ]),
            ),
            _actions(context, r, data.canSupervise, onDone),
          ]),
        ),
      ]),
    );
  }
}

/// Location changes waiting for review — photo, coordinates, accuracy, and how
/// the new pin compares with where visits were actually marked at this shop.
class PendingLocationReview extends StatelessWidget {
  const PendingLocationReview({super.key, required this.data, required this.onDone});
  final CustomerReviews data;
  final Future<void> Function() onDone;

  @override
  Widget build(BuildContext context) {
    final list = data.location;
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final r in list) _one(context, r),
    ]);
  }

  Widget _one(BuildContext context, Map<String, dynamic> r) {
    final ch = (r['changes'] as Map?) ?? const {};
    final nLa = ((ch['latitude'] as Map?)?['new'] as num?)?.toDouble();
    final nLo = ((ch['longitude'] as Map?)?['new'] as num?)?.toDouble();
    final oLa = ((ch['latitude'] as Map?)?['old'] as num?)?.toDouble();
    final oLo = ((ch['longitude'] as Map?)?['old'] as num?)?.toDouble();
    final url = data.photoUrls['${r['photo_path'] ?? ''}'];
    final acc = (r['accuracy_m'] as num?)?.toDouble();
    final mocked = r['is_mocked'] == true;
    final field = r['source'] == 'field_capture';

    // Corroboration: past visit GPS at this shop vs the new pin.
    String? visitsNote; bool visitsFar = false;
    if (nLa != null && nLo != null && data.visitPoints.isNotEmpty) {
      final d = [for (final p in data.visitPoints) _meters(nLa, nLo, p.$1, p.$2)]..sort();
      final within = d.where((m) => m <= 100).length;
      visitsFar = d.first > 300;
      visitsNote = '${d.length} past visit${d.length == 1 ? '' : 's'} marked here: $within within 100 m · closest ${_dist(d.first)}';
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.danger.withOpacity(0.5))),
      child: LayoutBuilder(builder: (context, box) {
        final narrow = box.maxWidth < 560;
        final photo = url == null
            ? Container(
                width: narrow ? double.infinity : 180, height: 130,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8)),
                child: Text(field ? 'Photo not available' : 'Edited — no photo',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : InkWell(
                onTap: () => showDialog(context: context, builder: (ctx) => Dialog(
                    child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)))),
                child: ClipRRect(borderRadius: BorderRadius.circular(8),
                    child: Image.network(url, width: narrow ? double.infinity : 180, height: narrow ? 220 : 130, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(height: 130, child: Center(child: Icon(Icons.broken_image_outlined))))),
              );
        final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
              child: Text(field ? 'Taken in the field' : 'Edited', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.danger)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(_who(r), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 8),
          Text(nLa == null ? 'Location removed' : '${nLa.toStringAsFixed(6)}, ${nLo!.toStringAsFixed(6)}',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
          if (acc != null) Text('GPS accuracy ±${acc.round()} m', style: const TextStyle(fontSize: 12)),
          if (oLa != null && oLo != null)
            Text('Was ${oLa.toStringAsFixed(5)}, ${oLo.toStringAsFixed(5)}'
                '${nLa != null && nLo != null ? '  ·  moved ${_dist(_meters(oLa, oLo, nLa, nLo))}' : ''}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          if (visitsNote != null) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(visitsNote, style: TextStyle(fontSize: 12,
                  color: visitsFar ? AppTheme.danger : AppTheme.success, fontWeight: FontWeight.w600))),
          if (mocked) const Padding(padding: EdgeInsets.only(top: 4),
              child: Text('⚠ The phone reported a fake (mock) GPS location.',
                  style: TextStyle(fontSize: 12, color: AppTheme.danger, fontWeight: FontWeight.w700))),
          if (nLa != null && nLo != null)
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.map_outlined, size: 15),
              label: const Text('Open in Maps'),
              onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=$nLa,$nLo'),
                  mode: LaunchMode.externalApplication),
            ),
          _actions(context, r, data.canSupervise, onDone, location: true),
        ]);
        return narrow
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [photo, const SizedBox(height: 10), info])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [photo, const SizedBox(width: 14), Expanded(child: info)]);
      }),
    );
  }
}
