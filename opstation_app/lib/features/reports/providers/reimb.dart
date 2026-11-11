import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../pdf/report_pdf_builder.dart' show ReimbInfo;

/// Reimbursement Approvals (SQL 466). Called every time a Trip Summary /
/// Combined Trip Summary is generated: records the claim the first time
/// ([record] = a real issue, not an admin's look) and returns what the PDF
/// prints — rate per km and a FULLY / PARTLY PAID stamp. Never throws.
Future<ReimbInfo?> reimbSubmit({
  required String? orgId,
  required String type,
  required String key,
  required String? claimantId,
  required List<Map<String, dynamic>> lines, // {trip, day: DateTime, km}
  required bool record,
}) async {
  if (orgId == null || lines.isEmpty) return null;
  String ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  try {
    final r = await Supabase.instance.client.rpc('reimb_submit', params: {
      'p_org': orgId,
      'p_type': type,
      'p_key': key,
      'p_claimant': claimantId,
      'p_lines': [
        for (final l in lines) {'trip': '${l['trip']}', 'day': ymd(l['day'] as DateTime), 'km': ((l['km'] as num?) ?? 0).toDouble()},
      ],
      'p_record': record,
    });
    if (r is! Map) return null;
    return reimbInfoFrom(Map<String, dynamic>.from(r), lines);
  } catch (_) {
    return null;
  }
}

ReimbInfo reimbInfoFrom(Map<String, dynamic> r, List<Map<String, dynamic>> lines) {
  final rate = (r['rate'] as num?)?.toDouble();
  final paid = [for (final p in (r['paid'] as List? ?? const [])) Map<String, dynamic>.from(p as Map)];
  final paidTrips = {for (final p in paid) '${p['trip']}'};
  final fmt = DateFormat('d MMM');
  final fmtY = DateFormat('d MMM yyyy');
  final days = <DateTime>{};
  final unpaidDays = <DateTime>{};
  var paidKm = 0.0;
  for (final l in lines) {
    if (paidTrips.contains('${l['trip']}')) paidKm += ((l['km'] as num?) ?? 0).toDouble();
    final d = l['day'] as DateTime;
    final day = DateTime(d.year, d.month, d.day);
    days.add(day);
    if (!paidTrips.contains('${l['trip']}')) unpaidDays.add(day);
  }
  final approvedBy = r['status'] == 'approved' || r['status'] == 'paid' ? r['approved_by'] as String? : null;
  if (r['status'] == 'paid' || (paid.isNotEmpty && unpaidDays.isEmpty)) {
    final String text;
    if (r['status'] == 'paid') {
      text = [
        'FULLY PAID — Rs ${NumberFormat('#,##0').format(r['paid_amount'] ?? 0)}',
        if (r['paid_on'] != null) 'on ${fmtY.format(DateTime.parse('${r['paid_on']}'))}',
        if ((r['paid_method'] ?? '') != '') '${r['paid_method']}',
        if ((r['paid_ref'] ?? '') != '') 'ref ${r['paid_ref']}',
        if (approvedBy != null) 'approved by $approvedBy',
      ].join(' · ');
    } else {
      final on = {for (final p in paid) if (p['paid_on'] != null) fmtY.format(DateTime.parse('${p['paid_on']}'))};
      final refs = {for (final p in paid) if ((p['ref'] ?? '') != '') '${p['ref']}'};
      text = 'FULLY PAID — all ${days.length} day${days.length == 1 ? '' : 's'} already paid'
          '${on.isEmpty ? '' : ' on ${on.join(', ')}'}${refs.isEmpty ? '' : ' (ref ${refs.join(', ')})'}';
    }
    return ReimbInfo(rate: rate, stamp: text, fullyPaid: true, approvedBy: approvedBy);
  }
  if (paid.isNotEmpty) {
    final paidDays = (days.difference(unpaidDays).toList()..sort()).map(fmt.format).join(', ');
    final un = (unpaidDays.toList()..sort()).map(fmt.format).join(', ');
    return ReimbInfo(
      rate: rate,
      paidKm: paidKm,
      stamp: 'PARTLY PAID — ${days.length - unpaidDays.length} of ${days.length} days already paid ($paidDays). Unpaid: $un.',
      approvedBy: approvedBy,
    );
  }
  return ReimbInfo(rate: rate, approvedBy: approvedBy);
}
