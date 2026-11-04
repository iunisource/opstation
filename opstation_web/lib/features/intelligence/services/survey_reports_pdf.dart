import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/survey_audit_status.dart';

/// Date-range PDF reports for the survey team:
///  • Audit report — every audit (Matches / Issue / Feedback) in the range.
///  • Surveyor report — what each surveyor surveyed in the range and how it
///    held up in audits.
/// Rows an auditor saved as corrections (ids pa_aud_ / cs_aud_) are not
/// counted as surveyor work.
class SurveyReportsPdf {
  static final _c = Supabase.instance.client;
  static final _df = DateFormat('d MMM yyyy');
  static final _tf = DateFormat('d MMM yyyy, h:mm a');

  static Future<List<Map<String, dynamic>>> _paged(
      String table, String cols, String orgId,
      {String? tsCol, DateTime? from, DateTime? to}) async {
    final out = <Map<String, dynamic>>[];
    for (var f = 0;; f += 1000) {
      var q = _c.from(table).select(cols).eq('org_id', orgId);
      if (tsCol != null && from != null) q = q.gte(tsCol, from.toUtc().toIso8601String());
      if (tsCol != null && to != null) q = q.lt(tsCol, to.toUtc().toIso8601String());
      final page = await q.order('id').range(f, f + 999);
      out.addAll(List<Map<String, dynamic>>.from(page));
      if ((page as List).length < 1000) break;
    }
    return out;
  }

  static Future<Map<String, Map<String, dynamic>>> _shops(String orgId) async {
    final rows = await _paged('customers', 'id, shop_name, code', orgId);
    return {for (final r in rows) '${r['id']}': r};
  }

  static Future<Map<String, String>> _users(String orgId) async {
    final rows = await _c.from('users').select('id, name').eq('org_id', orgId);
    return {for (final r in rows) '${r['id']}': '${r['name'] ?? ''}'};
  }

  static DateTime? _t(dynamic v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

  static String _result(dynamic r) => switch ('$r') {
        'issue' => 'Issue found',
        'feedback' => 'Feedback',
        _ => 'Matches',
      };

  static String _loc(Map<String, dynamic> a) {
    final d = (a['distance_m'] as num?)?.round();
    return switch ('${a['location_status']}') {
      'inside' => 'At shop${d == null ? '' : ' (${d}m)'}',
      'outside' => 'OUTSIDE${d == null ? '' : ' (${d}m)'}',
      'no_shop_location' => 'No shop location',
      _ => 'No GPS',
    };
  }

  static pw.Widget _title(String title, String org, DateTime from, DateTime to, String summary) =>
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(org, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.Text(title, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text('${_df.format(from)} to ${_df.format(to)}  ·  $summary',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.SizedBox(height: 10),
      ]);

  static pw.Widget _table(List<String> head, List<List<String>> rows, Map<int, pw.TableColumnWidth> widths) {
    const h = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);
    const c = pw.TextStyle(fontSize: 7.5);
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      columnWidths: widths,
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [for (final x in head) pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(x, style: h))],
        ),
        for (final r in rows)
          pw.TableRow(children: [
            for (final x in r) pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(x, style: c)),
          ]),
      ],
    );
  }

  // ── Audit report ──────────────────────────────────────────────────────────
  static Future<Uint8List> auditReport({
    required String orgId,
    required String orgName,
    required DateTime from, // first day (local)
    required DateTime to, // last day (local), inclusive
    Set<String>? shopIds, // only these shops (route / salesperson filter)
    String? scope, // e.g. "Route: North" — printed under the title
  }) async {
    if (scope != null) orgName = '$orgName  ·  $scope';
    final end = DateTime(to.year, to.month, to.day).add(const Duration(days: 1));
    final start = DateTime(from.year, from.month, from.day);
    final audits = await _paged('survey_audits', '*', orgId, tsCol: 'audited_at', from: start, to: end);
    if (shopIds != null) audits.removeWhere((a) => !shopIds.contains('${a['customer_id']}'));
    audits.removeWhere((a) => a['hidden_at'] != null); // hidden by an admin
    audits.sort((a, b) => '${a['audited_at']}'.compareTo('${b['audited_at']}'));
    final shops = await _shops(orgId);
    final ok = audits.where((a) => a['result'] == 'ok').length;
    final issue = audits.where((a) => a['result'] == 'issue').length;
    final fb = audits.where((a) => a['result'] == 'feedback').length;
    final outside = audits.where((a) => a['location_status'] != 'inside').length;

    // Per auditor summary
    final byAuditor = <String, List<Map<String, dynamic>>>{};
    for (final a in audits) {
      byAuditor.putIfAbsent('${a['auditor_name'] ?? '-'}', () => []).add(a);
    }

    String corr(Map<String, dynamic> a) {
      final c = a['corrections'];
      if (c is! List || c.isEmpty) return '';
      return [
        for (final x in c)
          if (x is Map) '${x['type'] == 'placement' ? x['product'] : x['category']}: ${x['from'] ?? '-'} -> ${x['to'] ?? '-'}',
        if (fixStatusText(a).isNotEmpty) '(${fixStatusText(a)})',
      ].join('\n');
    }

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      maxPages: 1000,
      build: (_) => [
        _title('Survey Audit Report', orgName, start, to,
            '${audits.length} audits: $ok matches, $issue issues, $fb feedback · $outside flagged location'),
        if (audits.isEmpty)
          pw.Text('No audits in this period.')
        else ...[
          pw.Text('By auditor', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          _table(
            ['Auditor', 'Audits', 'Shops', 'Matches', 'Issues', 'Feedback', 'Corrections', 'Flagged location'],
            [
              for (final e in byAuditor.entries)
                [
                  e.key,
                  '${e.value.length}',
                  '${e.value.map((a) => a['customer_id']).toSet().length}',
                  '${e.value.where((a) => a['result'] == 'ok').length}',
                  '${e.value.where((a) => a['result'] == 'issue').length}',
                  '${e.value.where((a) => a['result'] == 'feedback').length}',
                  '${e.value.fold<int>(0, (s, a) => s + (a['corrections'] is List ? (a['corrections'] as List).length : 0))}',
                  '${e.value.where((a) => a['location_status'] != 'inside').length}',
                ]
            ],
            const {0: pw.FlexColumnWidth(2.4)},
          ),
          pw.SizedBox(height: 14),
          pw.Text('All audits', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          _table(
            ['Date', 'Shop', 'Auditor', 'Result', 'Location', 'Comment', 'Corrections'],
            [
              for (final a in audits)
                [
                  _t(a['audited_at']) == null ? '' : _tf.format(_t(a['audited_at'])!),
                  '${shops[a['customer_id']]?['shop_name'] ?? a['customer_id']}\n${shops[a['customer_id']]?['code'] ?? ''}',
                  '${a['auditor_name'] ?? ''}',
                  _result(a['result']),
                  _loc(a),
                  '${a['comment'] ?? ''}${'${a['photo_path'] ?? ''}'.isNotEmpty ? '\n(photo attached)' : ''}',
                  corr(a),
                ]
            ],
            const {
              0: pw.FlexColumnWidth(1.5),
              1: pw.FlexColumnWidth(2.2),
              2: pw.FlexColumnWidth(1.3),
              3: pw.FlexColumnWidth(1.0),
              4: pw.FlexColumnWidth(1.2),
              5: pw.FlexColumnWidth(2.6),
              6: pw.FlexColumnWidth(2.6),
            },
          ),
        ],
      ],
    ));
    return doc.save();
  }

  // ── Surveyor report ───────────────────────────────────────────────────────
  static Future<Uint8List> surveyorReport({
    required String orgId,
    required String orgName,
    required DateTime from,
    required DateTime to,
    Set<String>? shopIds,
    String? scope,
  }) async {
    if (scope != null) orgName = '$orgName  ·  $scope';
    bool inScope(Map<String, dynamic> r) => shopIds == null || shopIds.contains('${r['customer_id']}');
    final end = DateTime(to.year, to.month, to.day).add(const Duration(days: 1));
    final start = DateTime(from.year, from.month, from.day);
    final results = await Future.wait([
      _paged('placement_audit', 'id, customer_id, product_id, is_present, surveyed_by_user_id, surveyed_at, source, voided_at', orgId,
          tsCol: 'surveyed_at', from: start, to: end),
      _paged('competitor_spotting', 'id, customer_id, category_id, brand_name, surveyed_by_user_id, surveyed_at, source, voided_at', orgId,
          tsCol: 'surveyed_at', from: start, to: end),
    ]);
    final shops = await _shops(orgId);
    final users = await _users(orgId);
    // Auditor corrections and removed (voided) rows are not surveyor work.
    bool fromAudit(Map<String, dynamic> r) =>
        r['source'] == 'audit_fix' ||
        r['voided_at'] != null ||
        '${r['id']}'.startsWith('pa_aud_') ||
        '${r['id']}'.startsWith('cs_aud_');
    final pa = results[0].where((r) => !fromAudit(r) && inScope(r)).toList();
    final cs = results[1].where((r) => !fromAudit(r) && inScope(r)).toList();
    // One survey visit = surveyor + shop + day.
    final visits = <String, _Visit>{};
    String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
    for (final r in pa) {
      final at = _t(r['surveyed_at']);
      if (at == null) continue;
      final uid = '${r['surveyed_by_user_id'] ?? ''}';
      final k = '$uid|${r['customer_id']}|${dayKey(at)}';
      final v = visits.putIfAbsent(k, () => _Visit(uid, '${r['customer_id']}', at));
      v.note(at);
      v.products['${r['product_id']}'] = r['is_present'] == true;
    }
    for (final r in cs) {
      final at = _t(r['surveyed_at']);
      if (at == null) continue;
      final uid = '${r['surveyed_by_user_id'] ?? ''}';
      final k = '$uid|${r['customer_id']}|${dayKey(at)}';
      final v = visits.putIfAbsent(k, () => _Visit(uid, '${r['customer_id']}', at));
      v.note(at);
      v.categories.add('${r['category_id']}');
    }
    // Where the surveyor was when saving (SQL 445). Best reading of the visit
    // wins: at the shop > away from the shop > no location.
    List<Map<String, dynamic>> locs = [];
    try {
      locs = await _paged('survey_locations', 'customer_id, user_id, surveyed_at, distance_m, location_status', orgId,
          tsCol: 'surveyed_at', from: start, to: end);
    } catch (_) {} // not set up yet: column shows "-"
    const rank = {'inside': 3, 'outside': 2, 'no_gps': 1, 'no_shop_location': 1};
    for (final l in locs) {
      final at = _t(l['surveyed_at']);
      if (at == null) continue;
      final v = visits['${l['user_id']}|${l['customer_id']}|${dayKey(at)}'];
      if (v == null) continue;
      final st = '${l['location_status']}';
      if ((rank[st] ?? 0) > (rank[v.location] ?? 0)) {
        v.location = st;
        v.distance = (l['distance_m'] as num?)?.round();
      }
    }
    String locText(_Visit v) => switch (v.location) {
          'inside' => 'Visited',
          'outside' => 'Not visited${v.distance == null ? '' : ' (${v.distance}m away)'}',
          'no_gps' || 'no_shop_location' => 'No location',
          _ => '-',
        };
    bool isNoLoc(_Visit v) => v.location == 'no_gps' || v.location == 'no_shop_location';

    final list = visits.values.toList()..sort((a, b) => a.first.compareTo(b.first));
    final bySurveyor = <String, List<_Visit>>{};
    for (final v in list) {
      bySurveyor.putIfAbsent(v.user, () => []).add(v);
    }
    String name(String uid) => uid.isEmpty ? '(unknown)' : (users[uid] ?? uid);

    final summary = [
      for (final e in bySurveyor.entries)
        () {
          final vs = e.value;
          return [
            name(e.key),
            '${vs.map((v) => dayKey(v.first)).toSet().length}',
            '${vs.length}',
            '${vs.map((v) => v.shop).toSet().length}',
            '${vs.where((v) => v.products.isNotEmpty).length}',
            '${vs.fold<int>(0, (s, v) => s + v.categories.length)}',
            '${vs.where((v) => v.location == 'inside').length}',
            '${vs.where((v) => v.location == 'outside').length}',
            '${vs.where(isNoLoc).length}',
          ];
        }(),
    ]..sort((a, b) => int.parse(b[2]).compareTo(int.parse(a[2])));

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      maxPages: 1000,
      build: (_) => [
        _title('Surveyor Report', orgName, start, to,
            '${list.length} survey visits by ${bySurveyor.length} surveyor${bySurveyor.length == 1 ? '' : 's'} · '
                '${list.map((v) => v.shop).toSet().length} shops'),
        if (list.isEmpty)
          pw.Text('No surveys in this period.')
        else ...[
          pw.Text('By surveyor', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          _table(
            ['Surveyor', 'Days active', 'Survey visits', 'Shops', 'Placement surveys', 'Competitor entries',
              'Visited', 'Not visited', 'No location'],
            summary,
            const {0: pw.FlexColumnWidth(2.4)},
          ),
          pw.SizedBox(height: 4),
          pw.Text(
              'Location: where the surveyor was when saving, compared with the shop\'s saved location. '
              'No location = phone GPS off or the shop has no saved location. "-" = not recorded.',
              style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700)),
          pw.SizedBox(height: 14),
          pw.Text('All survey visits', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          _table(
            ['Date', 'Surveyor', 'Shop', 'Placement (displayed)', 'Competitor categories', 'Location'],
            [
              for (final v in list)
                [
                  _tf.format(v.first),
                  name(v.user),
                  '${shops[v.shop]?['shop_name'] ?? v.shop}\n${shops[v.shop]?['code'] ?? ''}',
                  v.products.isEmpty ? '-' : '${v.products.values.where((x) => x).length} of ${v.products.length}',
                  v.categories.isEmpty ? '-' : '${v.categories.length}',
                  locText(v),
                ]
            ],
            const {
              0: pw.FlexColumnWidth(1.5),
              1: pw.FlexColumnWidth(1.5),
              2: pw.FlexColumnWidth(2.6),
              3: pw.FlexColumnWidth(1.3),
              4: pw.FlexColumnWidth(1.3),
              5: pw.FlexColumnWidth(1.4),
            },
          ),
        ],
      ],
    ));
    return doc.save();
  }
}

class _Visit {
  final String user;
  final String shop;
  DateTime first;
  DateTime last;
  final Map<String, bool> products = {};
  final Set<String> categories = {};
  String? location; // inside | outside | no_gps | no_shop_location (SQL 445)
  int? distance; // metres from the shop when away
  _Visit(this.user, this.shop, DateTime at)
      : first = at,
        last = at;
  void note(DateTime at) {
    if (at.isBefore(first)) first = at;
    if (at.isAfter(last)) last = at;
  }
}
