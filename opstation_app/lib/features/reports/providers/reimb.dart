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
  if (orgId == null) return null;
  reimbLastError = null;
  // Whatever happens below, the print still gets the rate per km from settings.
  Future<ReimbInfo?> fallback() async {
    final rate = await reimbRateForScreen(orgId);
    return rate == null ? null : ReimbInfo(rate: rate);
  }
  if (lines.isEmpty) return fallback();
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
    if (r is! Map) {
      reimbLastError = 'Reimbursement check returned nothing';
      return fallback();
    }
    final m = Map<String, dynamic>.from(r);
    // Older database without the rate in the reply: take it from settings.
    m['rate'] ??= await reimbRateForScreen(orgId);
    // Admin Settings → "Rate per km on Trip Summaries" switched off → no rate / amount printed.
    if (!await reimbRatePrintOn(orgId)) m['rate'] = null;
    return reimbInfoFrom(m, lines);
  } catch (e) {
    reimbLastError = '$e';
    return fallback();
  }
}

/// Last reimbursement-check error (shown on the web so it can be reported).
String? reimbLastError;

/// Whether the rate per km and amounts are printed on trip summaries (default on).
Future<bool> reimbRatePrintOn(String orgId) async {
  try {
    final r = await Supabase.instance.client.from('app_config').select('value')
        .eq('org_id', orgId).eq('key', 'org.reimb_rate_print').limit(1);
    return !((r as List).isNotEmpty && '${r.first['value']}' == 'false');
  } catch (_) {
    return true;
  }
}

/// Rate per km to show on screens (null = not set, or printing switched off).
Future<double?> reimbRateForScreen(String? orgId) async {
  if (orgId == null) return null;
  try {
    if (!await reimbRatePrintOn(orgId)) return null;
    final r = await Supabase.instance.client.from('app_config').select('value')
        .eq('org_id', orgId).eq('key', 'org.reimb_rate_km').limit(1);
    final v = (r as List).isEmpty ? null : double.tryParse('${r.first['value']}'.trim());
    return v != null && v > 0 ? v : null;
  } catch (_) {
    return null;
  }
}

ReimbInfo reimbInfoFrom(Map<String, dynamic> r, List<Map<String, dynamic>> lines) {
  final base = _reimbInfoCore(r, lines);
  final gen = _generated(r);
  return ReimbInfo(rate: base.rate, stamp: base.stamp, fullyPaid: base.fullyPaid, approvedBy: base.approvedBy,
      paidKm: base.paidKm, generatedDays: gen.$1, generatedNote: gen.$2);
}

/// Dates already generated for reimbursement on other sheets + the note text.
(Set<String>, String?) _generated(Map<String, dynamic> r) {
  final dFmt = DateFormat('d MMM');
  final at = DateFormat('d MMM yyyy, h:mm a');
  final days = <String>{};
  // one line per earlier sheet: "10 Nov — Trip Summary (approved)"
  final bySheet = <String, Map<String, dynamic>>{};
  for (final g in (r['generated'] as List? ?? const [])) {
    final m = Map<String, dynamic>.from(g as Map);
    days.add('${m['day']}'.substring(0, 10));
    final s = bySheet.putIfAbsent('${m['claim']}', () => {...m, 'days': <String>{}});
    (s['days'] as Set<String>).add('${m['day']}'.substring(0, 10));
  }
  final parts = <String>[];
  for (final s in bySheet.values) {
    final ds = (s['days'] as Set<String>).toList()..sort();
    final from = DateTime.tryParse('${s['from'] ?? ''}');
    final to = DateTime.tryParse('${s['to'] ?? ''}');
    final sheet = s['type'] == 'combined_summary'
        ? 'Combined Trip Summary${from != null && to != null ? ' ${dFmt.format(from)}–${dFmt.format(to)}' : ''}'
        : 'Trip Summary';
    final st = '${s['status'] ?? ''}';
    parts.add('${ds.map((d) => dFmt.format(DateTime.parse(d))).join(', ')} — $sheet'
        '${st.isEmpty ? '' : ' ($st)'}');
  }
  final first = DateTime.tryParse('${r['sheet_first_at'] ?? ''}')?.toLocal();
  final count = (r['sheet_count'] as num?)?.toInt() ?? 0;
  final lines = <String>[
    if (count > 1 && first != null) 'This same sheet was generated before (first on ${at.format(first)}; $count times in all).',
    ...parts,
  ];
  return (days, lines.isEmpty ? null : lines.join('\n'));
}

ReimbInfo _reimbInfoCore(Map<String, dynamic> r, List<Map<String, dynamic>> lines) {
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
