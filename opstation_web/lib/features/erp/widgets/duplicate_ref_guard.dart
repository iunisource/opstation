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

/// The Duplicate References log entry for the warning the user last saved
/// through — the voucher screen links it to the voucher once it is saved.
String? _pendingEventId;

/// Call after the voucher is saved (only when checkDuplicateRefs returned a note).
Future<void> linkDuplicateRefEvent(String voucherId, String? voucherNumber) async {
  final id = _pendingEventId;
  _pendingEventId = null;
  if (id == null) return;
  try {
    await Supabase.instance.client.rpc('dup_ref_event_set', params: {
      'p_id': id, 'p_voucher_id': voucherId, 'p_voucher_number': voucherNumber,
    });
  } catch (_) {}
}

Future<String?> checkDuplicateRefs(
  BuildContext context, {
  required String orgId,
  required List<String> narrations,
  List<double>? amounts,
  String? voucherType, // 'CRV' | 'CPV' — the other half of a same-day transfer is not a duplicate
  DateTime? date,
  String? excludeVoucherId,
  String? excludeVoucherNumber,
  String? branchId,
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
  // Record it in Financials → Duplicate References (never blocks the voucher).
  String? eventId;
  try {
    eventId = await Supabase.instance.client.rpc('dup_ref_event_log', params: {
      'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': voucherType ?? '',
      'p_voucher_id': excludeVoucherId, 'p_voucher_number': excludeVoucherNumber,
      'p_refs': refs,
      'p_matches': [
        for (final h in hits)
          {
            'ref': h['ref'], 'type': h['voucher_type'], 'id': h['voucher_id'], 'number': h['voucher_number'],
            'date': h['voucher_date'], 'status': h['status'], 'account': h['account_name'],
            'description': h['description'], 'amount': h['amount'],
          },
      ],
    }) as String?;
  } catch (_) {}
  if (!context.mounted) return '';
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
  if (eventId != null) {
    try {
      await Supabase.instance.client.rpc('dup_ref_event_set', params: {
        'p_id': eventId, 'p_outcome': ok == true ? 'saved_anyway' : 'went_back',
      });
    } catch (_) {}
  }
  if (ok != true) return null;
  _acceptedRefs.addAll(refs);
  _pendingEventId = eventId;
  final where = {for (final h in hits) '${h['voucher_number'] ?? h['voucher_type']}'}.join(', ');
  return 'Saved with a reference already used — ${refs.join(', ')} also in $where';
}

/// Same-location guard for customers (SQL 407). Before a location is saved,
/// looks for other active customers at the same coordinates (within ~1 m).
/// Returns true to go ahead (nothing found, or the user chose "Save anyway"),
/// false when the user went back. A failed check never blocks saving.
/// When the user saves anyway, call [markLocationWarned] with the customer id
/// after the save so the Duplicate References entry shows it.
Future<bool> checkDuplicateLocation(
  BuildContext context, {
  required String orgId,
  required double lat,
  required double lng,
  String? excludeCustomerId,
  String? customerLabel,
}) async {
  List<Map<String, dynamic>> hits;
  try {
    hits = List<Map<String, dynamic>>.from(await Supabase.instance.client.rpc('customer_location_duplicates', params: {
      'p_org_id': orgId, 'p_lat': lat, 'p_lng': lng, 'p_exclude_id': excludeCustomerId,
    }) as List);
  } catch (_) {
    return true;
  }
  hits = hits.where((h) => h['is_active'] != false).toList();
  if (hits.isEmpty || !context.mounted) return true;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.wrong_location_outlined, color: Colors.orange),
      title: const Text('Another customer is at this exact location'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)} is already saved for:',
              style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
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
                      Text('${h['code'] ?? ''}  ${h['shop_name'] ?? ''}'.trim(),
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                      if ('${h['address'] ?? ''}'.isNotEmpty)
                        Text('${h['address']}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ]),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Two shops rarely share the exact same point. Check that this is not the same shop entered twice, '
            'or a location copied from another customer. If you know the case, you can save anyway — it will be '
            'listed in Financials → Duplicate References for review.',
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
  if (ok == true) return true;
  // Went back: still record that the warning came up.
  try {
    final id = await Supabase.instance.client.rpc('dup_ref_event_log', params: {
      'p_org_id': orgId, 'p_branch_id': null, 'p_type': 'LOC',
      'p_voucher_id': excludeCustomerId, 'p_voucher_number': customerLabel,
      'p_refs': ['${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}'],
      'p_matches': [
        for (final h in hits)
          {'type': 'CUSTOMER', 'id': h['id'], 'number': h['code'], 'account': h['shop_name'],
           'description': h['address'] ?? '', 'status': h['is_active'] == false ? 'inactive' : 'active'},
      ],
    }) as String?;
    if (id != null) {
      await Supabase.instance.client.rpc('dup_ref_event_set', params: {'p_id': id, 'p_outcome': 'went_back'});
    }
  } catch (_) {}
  return false;
}

/// After a "Save anyway" on a customer location: the server already recorded
/// the match; mark it as knowingly saved.
Future<void> markLocationWarned(String customerId) async {
  try {
    await Supabase.instance.client.rpc('dup_loc_mark_warned', params: {'p_customer_id': customerId});
  } catch (_) {}
}
