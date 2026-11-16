import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';

/// Correct or release the CR# on one collection (admins / master admins,
/// SQL 479). [visit] needs id, receipt_number; shows user_name, timestamp,
/// amount and shop when present. Returns true when it was changed.
Future<bool> receiptFixDialog(BuildContext context, Map<String, dynamic> visit) async {
  final newCtl = TextEditingController();
  final reasonCtl = TextEditingController();
  var release = false;
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
        setD(() { busy = true; err = null; });
        try {
          await Supabase.instance.client.rpc('receipt_fix', params: {
            'p_visit': '${visit['id']}',
            'p_new': release ? null : newCtl.text.trim(),
            'p_reason': reasonCtl.text.trim(),
          });
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
                if (at != null) DateFormat('d MMM yyyy, h:mm a').format(at),
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
              title: const Text('Release: the real slip is not known'),
              subtitle: const Text('The collection keeps its amount; CR# becomes RELEASED and the slip is free again.',
                  style: TextStyle(fontSize: 11.5)),
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
        content: Text(release ? 'CR# released — the slip is free again' : 'CR# corrected')));
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
  if (rows.length == 1) return receiptFixDialog(context, rows.first);
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
                  DateFormat('d MMM yyyy, h:mm a').format(DateTime.parse('${v['timestamp']}').toLocal()),
                '${(v['customers'] as Map?)?['shop_name'] ?? ''}',
                'Rs ${NumberFormat('#,##0').format(v['amount'] ?? 0)}',
              ].where((x) => x.isNotEmpty).join(' · '),
            ),
          ),
      ],
    ),
  );
  if (pick == null || !context.mounted) return false;
  return receiptFixDialog(context, pick);
}
