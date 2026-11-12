import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import '../utils/app_link.dart';

/// Shows a Journal Voucher (header + lines) in a modal — used by the ledgers
/// so a JV opens in place like CRV / CPV do (also inside the installed app).
Future<void> showJournalModal(BuildContext context, {required String entryId}) async {
  Map<String, dynamic>? h;
  List<Map<String, dynamic>> lines = [];
  String? err;
  try {
    final db = Supabase.instance.client;
    h = await db.from('journal_entries').select().eq('id', entryId).maybeSingle();
    if (h != null) {
      lines = List<Map<String, dynamic>>.from(await db
          .from('journal_lines')
          .select('account_name, debit, credit, description, line_order')
          .eq('entry_id', entryId)
          .order('line_order'));
    }
  } catch (e) {
    err = e.toString();
  }
  if (!context.mounted) return;
  if (h == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not load: ${err ?? 'not found'}')));
    return;
  }
  final head = h;
  final fmt = NumberFormat('#,##0.##');
  double n(dynamic v) => (v as num?)?.toDouble() ?? double.tryParse('$v') ?? 0;
  final td = lines.fold<double>(0, (s, l) => s + n(l['debit']));
  final tc = lines.fold<double>(0, (s, l) => s + n(l['credit']));
  final date = DateTime.tryParse('${head['entry_date'] ?? ''}');
  final vno = '${head['entry_number'] ?? ''}';
  final isOpening = head['reference_type'] == 'opening_jv' || head['reference_type'] == 'opening_balance';
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 680, maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(vno, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
            ]),
            Text([
              if (date != null) DateFormat('d MMM yyyy').format(date),
              isOpening ? 'Opening Journal' : 'Journal Voucher',
              if (head['is_voided'] == true) 'VOIDED',
            ].join(' · '), style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            if ('${head['description'] ?? ''}'.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('${head['description']}', style: const TextStyle(fontSize: 13)),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
              child: const Row(children: [
                Expanded(flex: 7, child: Text('Account', style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                Expanded(flex: 2, child: Text('Debit', textAlign: TextAlign.right, style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                Expanded(flex: 2, child: Text('Credit', textAlign: TextAlign.right, style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(children: [
                  for (final l in lines)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(flex: 7, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${l['account_name'] ?? ''}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                          if ('${l['description'] ?? ''}'.trim().isNotEmpty)
                            Text('${l['description']}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                        ])),
                        Expanded(flex: 2, child: Text(n(l['debit']) > 0 ? fmt.format(n(l['debit'])) : '-', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5))),
                        Expanded(flex: 2, child: Text(n(l['credit']) > 0 ? fmt.format(n(l['credit'])) : '-', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5))),
                      ]),
                    ),
                ]),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const Expanded(flex: 7, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5))),
                Expanded(flex: 2, child: Text(fmt.format(td), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5))),
                Expanded(flex: 2, child: Text(fmt.format(tc), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5))),
              ]),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 15),
                label: Text(isOpening ? 'Open Opening Journal' : 'Open Journal Voucher'),
                onPressed: () {
                  Navigator.pop(ctx);
                  openAppLink(context, isOpening ? '/financials/opening-journal?id=$vno' : '/financials/journal-vouchers?id=$vno');
                },
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}
