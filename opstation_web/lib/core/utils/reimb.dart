import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/reports/pdf/report_pdf_builder.dart' show ReimbInfo;

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
    final allow = await reimbAllowanceForScreen(orgId);
    return rate == null && allow == null ? null : ReimbInfo(rate: rate, allowancePerDay: allow);
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
    m['allowance'] = await reimbAllowanceForScreen(orgId);
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

/// Allowance per day (Admin Settings → "Allowance per day on Trip Summaries";
/// null = not set or switched off → the line is left blank for hand entry).
Future<double?> reimbAllowanceForScreen(String? orgId) async {
  if (orgId == null) return null;
  try {
    final r = await Supabase.instance.client.from('app_config').select('key, value')
        .eq('org_id', orgId).inFilter('key', ['org.reimb_allowance_print', 'org.reimb_allowance_day']);
    final cfg = {for (final x in r as List) '${x['key']}': '${x['value'] ?? ''}'.trim()};
    if (cfg['org.reimb_allowance_print'] == 'false') return null;
    final v = double.tryParse(cfg['org.reimb_allowance_day'] ?? '');
    return v != null && v > 0 ? v : null;
  } catch (_) {
    return null;
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

/// What the PDF prints. Trips on an APPROVED / PAID claim are locked (SQL
/// 473): they are listed but excluded — 0 km, Rs 0 — with the reason.
ReimbInfo reimbInfoFrom(Map<String, dynamic> r, List<Map<String, dynamic>> lines) {
  final rate = (r['rate'] as num?)?.toDouble();
  final ymd = DateFormat('yyyy-MM-dd');
  // Older databases send only "paid".
  final src = (r['excluded'] as List?) ?? (r['paid'] as List?) ?? const [];
  final excl = [for (final e in src) Map<String, dynamic>.from(e as Map)];
  final lockedTrips = {for (final e in excl) '${e['trip']}'};
  var lockedKm = 0.0;
  final lockedDays = <String>{}, openDays = <String>{};
  for (final l in lines) {
    final d = ymd.format(l['day'] as DateTime);
    if (lockedTrips.contains('${l['trip']}')) {
      lockedKm += ((l['km'] as num?) ?? 0).toDouble();
      lockedDays.add(d);
    } else {
      openDays.add(d);
    }
  }
  final gen = _generated(r, lockedTrips);
  final allLocked = lines.isNotEmpty && openDays.isEmpty && lockedDays.isNotEmpty;
  return ReimbInfo(
    rate: rate,
    stamp: excl.isEmpty ? null : _excludedNote(excl, lines),
    fullyPaid: allLocked,
    approvedBy: null, // approved days are excluded; the box above says who approved them
    paidKm: lockedKm,
    excludedDays: lockedDays,
    generatedDays: gen.$1,
    generatedNote: gen.$2,
    allowancePerDay: (r['allowance'] as num?)?.toDouble(),
    unpaidDays: lockedDays.isEmpty ? null : openDays.length,
  );
}

/// "2 – 13 Nov (10 days, 1,075.7 km): Combined Trip Summary, approved by
/// Mian Hamza on 14 Nov · Rs 10,763 · paid 15 Nov" — one line per claim.
String _excludedNote(List<Map<String, dynamic>> excl, List<Map<String, dynamic>> lines) {
  final dFmt = DateFormat('d MMM');
  final kmOf = {for (final l in lines) '${l['trip']}': ((l['km'] as num?) ?? 0).toDouble()};
  final byClaim = <String, List<Map<String, dynamic>>>{};
  for (final e in excl) {
    (byClaim['${e['claim'] ?? ''}'] ??= []).add(e);
  }
  final out = <String>[];
  for (final g in byClaim.values) {
    final days = {for (final e in g) DateTime.parse('${e['day']}'.substring(0, 10))}.toList()..sort();
    final km = g.fold<double>(0, (s, e) => s + (kmOf['${e['trip']}'] ?? ((e['km'] as num?) ?? 0).toDouble()));
    final when = days.length <= 3
        ? days.map(dFmt.format).join(', ')
        : '${dFmt.format(days.first)} - ${dFmt.format(days.last)}';
    final e = g.first;
    final from = DateTime.tryParse('${e['from'] ?? ''}');
    final to = DateTime.tryParse('${e['to'] ?? ''}');
    final sheet = e['type'] == 'combined_summary'
        ? 'Combined Trip Summary${from != null && to != null ? ' ${dFmt.format(from)}-${dFmt.format(to)}' : ''}'
        : e['type'] == 'trip_summary'
            ? 'Trip Summary'
            : 'an earlier claim';
    final at = DateTime.tryParse('${e['at'] ?? ''}')?.toLocal();
    final paidOn = DateTime.tryParse('${e['paid_on'] ?? ''}');
    final amount = (e['amount'] as num?)?.toDouble();
    final parts = <String>[
      [
        sheet,
        if ((e['by'] ?? '') != '') 'approved by ${e['by']}${at != null ? ' on ${dFmt.format(at)}' : ''}'
        else if (e['status'] == 'approved') 'approved',
      ].join(', '),
      if (amount != null && amount > 0) 'Rs ${NumberFormat('#,##0').format(amount)}',
      if ((e['advice'] ?? '') != '') '${e['advice']}',
      if (e['status'] == 'paid' || paidOn != null) 'paid${paidOn != null ? ' ${dFmt.format(paidOn)}' : ''}',
    ];
    out.add('$when (${days.length} day${days.length == 1 ? '' : 's'}, ${km.toStringAsFixed(1)} km): ${parts.join(', ')}');
  }
  return out.join('\n');
}

/// Dates already generated for reimbursement on other sheets + the note text
/// (trips already approved are left out — they are in the excluded note).
(Set<String>, String?) _generated(Map<String, dynamic> r, [Set<String> skipTrips = const {}]) {
  final dFmt = DateFormat('d MMM');
  final at = DateFormat('d MMM yyyy, h:mm a');
  final days = <String>{};
  // one line per earlier sheet: "10 Nov — Trip Summary (pending)"
  final bySheet = <String, Map<String, dynamic>>{};
  for (final g in (r['generated'] as List? ?? const [])) {
    final m = Map<String, dynamic>.from(g as Map);
    if (skipTrips.contains('${m['trip']}')) continue;
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
