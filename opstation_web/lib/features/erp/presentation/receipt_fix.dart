import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/format/time_format.dart';

/// Correct the CR# on one collection, or release its slip for re-use
/// (admins / master admins, SQL 479 / 482). Releasing does NOT change the
/// old entry: it keeps its CR# and stays searchable; the slip is only freed
/// for its book holder. [serial] = the slip to release (default: the first
/// number on the entry). Returns true when something changed.
Future<bool> receiptFixDialog(BuildContext context, Map<String, dynamic> visit, {int? serial}) async {
  final newCtl = TextEditingController();
  final reasonCtl = TextEditingController();
  var release = false;
  var checked = false;
  final slip = serial ??
      int.tryParse(RegExp(r'\d+').firstMatch('${visit['receipt_number'] ?? ''}')?.group(0) ?? '');
  String? err;
  var busy = false;
  final at = DateTime.tryParse('${visit['timestamp'] ?? visit['at'] ?? ''}')?.toLocal();
  final shop = '${(visit['customers'] is Map ? (visit['customers'] as Map)['shop_name'] : visit['shop']) ?? ''}';
  final done = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      Future<void> save() async {
        if (reasonCtl.text.trim().isEmpty) {
          setD(() => err = 'Enter the reason.');
          return;
        }
        if (!release && !RegExp(r'\d').hasMatch(newCtl.text)) {
          setD(() => err = 'Enter the correct slip number, or choose Release.');
          return;
        }
        if (release && !checked) {
          setD(() => err = 'Check the physical slip book first, then tick the box.');
          return;
        }
        if (release && slip == null) {
          setD(() => err = 'This entry has no slip number to release.');
          return;
        }
        setD(() { busy = true; err = null; });
        try {
          if (release) {
            await Supabase.instance.client.rpc('receipt_slip_release', params: {
              'p_visit': '${visit['id']}',
              'p_serial': slip,
              'p_reason': reasonCtl.text.trim(),
              'p_verified': checked,
            });
          } else {
            await Supabase.instance.client.rpc('receipt_fix', params: {
              'p_visit': '${visit['id']}',
              'p_new': newCtl.text.trim(),
              'p_reason': reasonCtl.text.trim(),
            });
          }
          if (ctx.mounted) Navigator.pop(ctx, true);
        } catch (e) {
          setD(() { busy = false; err = friendlyError('Could not save', e); });
        }
      }

      return AlertDialog(
        title: Text('CR# ${visit['receipt_number'] ?? ''} — correct or release'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              [
                if ('${visit['user_name'] ?? ''}'.isNotEmpty) '${visit['user_name']}',
                if (at != null) DateFormat(orgTime('d MMM yyyy, h:mm a')).format(at),
                if (shop.isNotEmpty) shop,
                if (visit['amount'] != null) 'Rs ${NumberFormat('#,##0').format(visit['amount'])}',
              ].join(' · '),
              style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            RadioListTile<bool>(
              value: false,
              groupValue: release,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) => setD(() => release = false),
              title: const Text('Correct: I know the real slip number'),
            ),
            if (!release)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 6),
                child: TextField(
                  controller: newCtl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Correct slip number', isDense: true, border: OutlineInputBorder()),
                ),
              ),
            RadioListTile<bool>(
              value: true,
              groupValue: release,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) => setD(() => release = true),
              title: Text('Release slip ${slip ?? ''} for re-use'),
              subtitle: const Text(
                  'This entry is NOT changed — it keeps its CR# and stays searchable. The slip only becomes '
                  'free again for the holder of its book.',
                  style: TextStyle(fontSize: 11.5)),
            ),
            if (release)
              CheckboxListTile(
                value: checked,
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) => setD(() => checked = v == true),
                title: const Text('I have checked the physical slip book', style: TextStyle(fontSize: 13)),
              ),
            const SizedBox(height: 6),
            TextField(
              controller: reasonCtl,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Reason *', hintText: 'e.g. slip from another book, typo', isDense: true, border: OutlineInputBorder()),
            ),
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: busy ? null : save, child: Text(release ? 'Release' : 'Correct')),
        ],
      );
    }),
  );
  if (done == true && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(release ? 'Slip $slip released for re-use — the old entry is unchanged' : 'CR# corrected')));
  }
  return done == true;
}

/// All collections carrying slip [serial] (exact, or within a multi-slip
/// entry); pick one, then correct / release it.
Future<bool> receiptFixForSerial(BuildContext context, String orgId, int serial) async {
  List<Map<String, dynamic>> rows;
  try {
    rows = List<Map<String, dynamic>>.from(await Supabase.instance.client
        .from('visits')
        .select('id, user_name, receipt_number, amount, timestamp, customers(shop_name)')
        .eq('org_id', orgId)
        .gt('amount', 0)
        .ilike('receipt_number', '%$serial%')
        .order('timestamp')
        .limit(50));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(friendlyError('Could not load', e))));
    }
    return false;
  }
  rows = rows.where((v) => RegExp(r'\d+').allMatches('${v['receipt_number'] ?? ''}').any((m) => m.group(0) == '$serial')).toList();
  if (!context.mounted) return false;
  if (rows.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('No collection carries slip $serial.')));
    return false;
  }
  if (rows.length == 1) return receiptFixDialog(context, rows.first, serial: serial);
  final pick = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('Slip $serial is on ${rows.length} collections — which one?'),
      children: [
        for (final v in rows)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, v),
            child: Text(
              [
                '${v['user_name'] ?? ''}',
                if (DateTime.tryParse('${v['timestamp'] ?? ''}') != null)
                  DateFormat(orgTime('d MMM yyyy, h:mm a')).format(DateTime.parse('${v['timestamp']}').toLocal()),
                '${(v['customers'] as Map?)?['shop_name'] ?? ''}',
                'Rs ${NumberFormat('#,##0').format(v['amount'] ?? 0)}',
              ].where((x) => x.isNotEmpty).join(' · '),
            ),
          ),
      ],
    ),
  );
  if (pick == null || !context.mounted) return false;
  return receiptFixDialog(context, pick, serial: serial);
}

/// Releases (SQL 482) for an org: "visitId|serial" → {id, reason, by_name, at}.
Future<Map<String, Map<String, dynamic>>> loadSlipReleases(String orgId) async {
  try {
    final rows = await Supabase.instance.client.from('receipt_slip_releases')
        .select('id, visit_id, serial, reason, by_name, at').eq('org_id', orgId).limit(5000);
    return {for (final r in rows as List) '${r['visit_id']}|${r['serial']}': Map<String, dynamic>.from(r as Map)};
  } catch (_) {
    return {}; // SQL 482 not run yet
  }
}
