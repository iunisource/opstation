import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';

/// Duplicate reference guard for cash vouchers (CRV / CPV) — SQL 405.
///
/// Reads the receipt / transaction / cheque numbers written in the line
/// narrations ("CR# 4521", "Trx TX-778", "Chq 123456" …) and looks for the same
/// number in any other CRV or CPV of this organisation (voided ones ignored).
/// If found, shows the matching vouchers so the user can review them, and lets
/// them carry on only by choosing "Save anyway".
///
/// Returns null to stop, '' when there was nothing to warn about, or a short
/// note (for the audit trail) when the user knowingly saved anyway.
/// A failed check never blocks saving.
/// References the user already chose to keep this session (so Save → Post on the
/// same voucher doesn't ask twice).
final Set<String> _acceptedRefs = {};

Future<String?> checkDuplicateRefs(
  BuildContext context, {
  required String orgId,
  required List<String> narrations,
  List<double>? amounts,
  String? voucherType, // 'CRV' | 'CPV' — the other half of a same-day transfer is not a duplicate
  DateTime? date,
  String? excludeVoucherId,
}) async {
  final texts = <String>[];
  final amts = <double>[];
  for (var i = 0; i < narrations.length; i++) {
    final t = narrations[i].trim();
    if (!RegExp(r'\d').hasMatch(t)) continue;
    texts.add(t);
    amts.add(amounts != null && i < amounts.length ? amounts[i] : 0);
  }
  if (texts.isEmpty) return '';
  List<Map<String, dynamic>> hits;
  try {
    hits = List<Map<String, dynamic>>.from(await Supabase.instance.client.rpc('voucher_ref_duplicates', params: {
      'p_org_id': orgId, 'p_texts': texts, 'p_exclude_id': excludeVoucherId,
      'p_type': voucherType, 'p_date': date == null ? null : DateFormat('yyyy-MM-dd').format(date),
      'p_amounts': amounts == null ? null : amts,
    }) as List);
  } catch (_) {
    return ''; // the check is a helper; it must never stop a voucher from saving
  }
  if (hits.isEmpty || !context.mounted) return '';

  final refs = {for (final h in hits) '${h['ref']}'}.toList();
  if (refs.every(_acceptedRefs.contains)) return '';
  final df = DateFormat('d MMM yyyy');
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.content_copy_outlined, color: Colors.orange),
      title: const Text('This reference number is already used'),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            refs.length == 1
                ? 'Reference ${refs.first} in this voucher also appears in:'
                : 'References ${refs.join(', ')} in this voucher also appear in:',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              child: Column(children: [
                for (final h in hits)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.withOpacity(0.3)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text('${h['voucher_number'] ?? h['voucher_type']}',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        const SizedBox(width: 8),
                        Text(h['voucher_date'] != null ? df.format(DateTime.parse('${h['voucher_date']}')) : '',
                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        const SizedBox(width: 8),
                        Text('${h['status'] ?? ''}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                        const Spacer(),
                        Text('Rs ${money((h['amount'] as num?) ?? 0)}',
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 3),
                      Text('${h['account_name'] ?? ''}', style: const TextStyle(fontSize: 12.5)),
                      Text('${h['description'] ?? ''}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ]),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Check that this is not the same receipt being entered twice. If you know the case, you can save anyway — it will be noted in the voucher\'s history.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Go back and review')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade700, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Save anyway'),
        ),
      ],
    ),
  );
  if (ok != true) return null;
  _acceptedRefs.addAll(refs);
  final where = {for (final h in hits) '${h['voucher_number'] ?? h['voucher_type']}'}.join(', ');
  return 'Saved with a reference already used — ${refs.join(', ')} also in $where';
}
