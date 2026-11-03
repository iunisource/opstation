import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/photo/photo_watermark.dart';
import '../../../core/services/device_gps_service.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../../core/sync/sync_controller.dart';
import '../../admin_settings/providers/org_settings_controller.dart';
import '../../auth/providers/auth_controller.dart';
import '../services/survey_audit_service.dart';

/// Auditor: re-check surveyed shops. Each audit is "Matches" or "Issue" with a
/// comment, optional photo and the auditor's location (flagged when outside
/// the shop's area). Data the auditor corrects is saved as new survey rows by
/// the auditor — the surveyor's rows stay, so the history is kept.
class SurveyAuditScreen extends ConsumerStatefulWidget {
  const SurveyAuditScreen({super.key});
  @override
  ConsumerState<SurveyAuditScreen> createState() => _SurveyAuditScreenState();
}

enum _St { notAudited, ok, issue, resurveyed }

String _resultLabel(dynamic r) => switch ('$r') {
      'issue' => 'Issue found',
      'feedback' => 'Feedback',
      _ => 'Matches survey',
    };

class _Shop {
  final CustomersData shop;
  final DateTime lastSurvey;
  _Shop(this.shop, this.lastSurvey);
}

String _stLabel(_St s) => switch (s) {
      _St.notAudited => 'Not audited',
      _St.ok => 'Audited',
      _St.issue => 'Audited',
      _St.resurveyed => 'Re-surveyed since audit',
    };

Color _stColor(_St s) => switch (s) {
      _St.notAudited => const Color(0xFF64748B),
      _St.ok => const Color(0xFF059669),
      _St.issue => const Color(0xFFDC2626),
      _St.resurveyed => const Color(0xFFD97706),
    };

DateTime? _ts(dynamic v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// Status of a shop: compares its latest audit with its latest survey. A
/// correction saved by the audit carries the audit's own time, so it does not
/// count as a newer survey.
_St _statusFor(List<Map<String, dynamic>> audits, DateTime lastSurvey) {
  // Feedback is a note only — the status comes from the latest Matches / Issue.
  final verdicts = audits.where((x) => x['result'] != 'feedback');
  if (verdicts.isEmpty) return _St.notAudited;
  final a = verdicts.first;
  final at = _ts(a['audited_at']);
  if (at != null && lastSurvey.isAfter(at.add(const Duration(seconds: 2)))) return _St.resurveyed;
  return a['result'] == 'issue' ? _St.issue : _St.ok;
}

class _SurveyAuditScreenState extends ConsumerState<SurveyAuditScreen> {
  bool _loading = true;
  List<_Shop> _shops = [];
  Map<String, List<Map<String, dynamic>>> _audits = {};
  int _pending = 0;
  String _q = '';
  String _filter = 'all'; // all | todo | ok

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  SurveyAuditService get _svc => SurveyAuditService(ref.read(appDatabaseProvider));

  Future<void> _load({bool refresh = false}) async {
    final db = ref.read(appDatabaseProvider);
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    if (refresh && orgId != null) {
      // Latest surveys from the server, and send any audits saved offline.
      try {
        await ref.read(supabasePullServiceProvider).refreshSurveyReference(orgId);
        await ref.read(supabasePullServiceProvider).refreshSurveyHistory(orgId);
      } catch (_) {}
      await _svc.flush();
    }
    final shops = await (db.select(db.customers)..where((c) => c.isActive.equals(true))).get();
    final byId = {
      for (final c in shops)
        if (orgId == null || c.orgId == null || c.orgId == orgId) c.id: c,
    };
    final last = <String, DateTime>{};
    void note(String cid, DateTime at) {
      if (!byId.containsKey(cid)) return;
      final cur = last[cid];
      if (cur == null || at.isAfter(cur)) last[cid] = at;
    }
    for (final a in await db.select(db.placementAudits).get()) {
      note(a.customerId, a.surveyedAt);
    }
    for (final s in await db.select(db.competitorSpottings).get()) {
      note(s.customerId, s.surveyedAt);
    }
    final server = orgId == null ? <Map<String, dynamic>>[] : await _svc.fetchOrg(orgId);
    final queued = await _svc.queued();
    final all = <String, Map<String, dynamic>>{
      for (final a in server) '${a['id']}': a,
      for (final a in queued) '${a['id']}': {...a, '_pending': true},
    };
    final byShop = <String, List<Map<String, dynamic>>>{};
    for (final a in all.values) {
      byShop.putIfAbsent('${a['customer_id']}', () => []).add(a);
    }
    for (final l in byShop.values) {
      l.sort((a, b) => '${b['audited_at']}'.compareTo('${a['audited_at']}'));
    }
    final list = [for (final e in last.entries) _Shop(byId[e.key]!, e.value)]
      ..sort((a, b) => b.lastSurvey.compareTo(a.lastSurvey));
    if (!mounted) return;
    setState(() {
      _shops = list;
      _audits = byShop;
      _pending = queued.length;
      _loading = false;
    });
  }

  _St _st(_Shop s) => _statusFor(_audits[s.shop.id] ?? const [], s.lastSurvey);

  // ── Audit report (PDF) for a date range ──
  Future<void> _export() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: now,
      initialDateRange: DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
      helpText: 'Audit report — date range',
    );
    if (range == null || !mounted) return;
    final from = DateTime(range.start.year, range.start.month, range.start.day);
    final to = DateTime(range.end.year, range.end.month, range.end.day).add(const Duration(days: 1));
    final shops = {for (final s in _shops) s.shop.id: s.shop};
    final rows = <Map<String, dynamic>>[
      for (final l in _audits.values)
        for (final a in l)
          if (_ts(a['audited_at']) != null &&
              !_ts(a['audited_at'])!.isBefore(from) &&
              _ts(a['audited_at'])!.isBefore(to))
            a
    ]..sort((a, b) => '${a['audited_at']}'.compareTo('${b['audited_at']}'));
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No audits in that date range.')));
      return;
    }
    final df = DateFormat('d MMM yyyy');
    final tf = DateFormat('d MMM yyyy, h:mm a');
    String loc(Map<String, dynamic> a) {
      final d = (a['distance_m'] as num?)?.round();
      return switch ('${a['location_status']}') {
        'inside' => 'At shop${d == null ? '' : ' (${d}m)'}',
        'outside' => 'Outside${d == null ? '' : ' (${d}m)'}',
        'no_shop_location' => 'No shop location',
        _ => 'No GPS',
      };
    }
    String corr(Map<String, dynamic> a) {
      final c = a['corrections'];
      if (c is! List || c.isEmpty) return '';
      return [
        for (final x in c)
          if (x is Map) '${x['type'] == 'placement' ? x['product'] : x['category']}: ${x['from'] ?? '-'} -> ${x['to'] ?? '-'}'
      ].join('\n');
    }
    final user = ref.read(authControllerProvider).valueOrNull;
    final ok = rows.where((a) => a['result'] == 'ok').length;
    final issues = rows.where((a) => a['result'] == 'issue').length;
    final fb = rows.where((a) => a['result'] == 'feedback').length;
    final doc = pw.Document();
    const head = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);
    const cell = pw.TextStyle(fontSize: 7.5);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      maxPages: 500,
      build: (_) => [
        pw.Text('Survey audit report', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text('${user?.organizationName ?? ''}  ·  ${df.format(range.start)} to ${df.format(range.end)}  ·  '
            '${rows.length} audits: $ok matches, $issues issues, $fb feedback',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.SizedBox(height: 10),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(1.5),
            1: pw.FlexColumnWidth(2.2),
            2: pw.FlexColumnWidth(1.3),
            3: pw.FlexColumnWidth(1.1),
            4: pw.FlexColumnWidth(1.3),
            5: pw.FlexColumnWidth(2.6),
            6: pw.FlexColumnWidth(2.6),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                for (final h in ['Date', 'Shop', 'Auditor', 'Result', 'Location', 'Comment', 'Corrections'])
                  pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(h, style: head)),
              ],
            ),
            for (final a in rows)
              pw.TableRow(children: [
                for (final v in [
                  _ts(a['audited_at']) == null ? '' : tf.format(_ts(a['audited_at'])!),
                  '${shops[a['customer_id']]?.shopName ?? a['customer_id']}${shops[a['customer_id']] == null ? '' : '\n${shops[a['customer_id']]!.code}'}',
                  '${a['auditor_name'] ?? ''}',
                  _resultLabel(a['result']),
                  loc(a),
                  '${a['comment'] ?? ''}${(a['photo_path'] ?? a['local_photo']) != null ? '\n(photo attached)' : ''}',
                  corr(a),
                ])
                  pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(v, style: cell)),
              ]),
          ],
        ),
      ],
    ));
    final bytes = await doc.save();
    await Printing.sharePdf(
      bytes: bytes,
      filename: 'audit_report_${DateFormat('yyyyMMdd').format(range.start)}_${DateFormat('yyyyMMdd').format(range.end)}.pdf',
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = _shops.where((s) {
      if (q.isNotEmpty &&
          !s.shop.shopName.toLowerCase().contains(q) &&
          !s.shop.code.toLowerCase().contains(q)) {
        return false;
      }
      final st = _st(s);
      return switch (_filter) {
        'todo' => st == _St.notAudited || st == _St.resurveyed,
        'ok' => st == _St.ok || st == _St.issue,
        _ => true,
      };
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Audit surveys'), actions: [
        IconButton(tooltip: 'Export audit report', icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: _export),
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => _load(refresh: true)),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (_pending > 0)
                MaterialBanner(
                  content: Text('$_pending audit${_pending == 1 ? '' : 's'} saved on this phone, waiting for internet.'),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        final left = await _svc.flush();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(left == 0 ? 'All audits sent' : 'Still offline — $left waiting')));
                        _load();
                      },
                      child: const Text('Send now'),
                    ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Wrap(spacing: 8, runSpacing: 6, children: [
                  for (final f in const [('all', 'All'), ('todo', 'To audit'), ('ok', 'Audited')])
                    ChoiceChip(
                      label: Text(f.$2),
                      selected: _filter == f.$1,
                      onSelected: (_) => setState(() => _filter = f.$1),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: const InputDecoration(
                    hintText: 'Search shop by name or code',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _load(refresh: true),
                  child: shown.isEmpty
                      ? ListView(children: const [
                          Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No surveyed shops here.'))),
                        ])
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: shown.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final s = shown[i];
                            final st = _st(s);
                            return ListTile(
                              title: Text(s.shop.shopName),
                              subtitle: Text('${s.shop.code} · surveyed ${DateFormat('d MMM yyyy').format(s.lastSurvey)}'),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _stColor(st).withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(_stLabel(st),
                                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _stColor(st))),
                              ),
                              onTap: () async {
                                final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
                                  builder: (_) => ShopAuditPage(shop: s.shop, audits: _audits[s.shop.id] ?? const []),
                                ));
                                if (saved == true) _load();
                              },
                            );
                          },
                        ),
                ),
              ),
            ]),
    );
  }
}

// ── One shop: last survey (editable), audit trail, Matches / Issue ──────────

class _SpotEdit {
  final CompetitorCategoryRow cat;
  final CompetitorSpottingRow? latest;
  final TextEditingController brand;
  final TextEditingController price;
  final TextEditingController specs;
  _SpotEdit(this.cat, this.latest)
      : brand = TextEditingController(text: latest?.brandName ?? ''),
        price = TextEditingController(text: latest?.price?.toString() ?? ''),
        specs = TextEditingController(text: latest?.specs ?? '');

  bool get changed {
    final b = brand.text.trim(), p = price.text.trim(), s = specs.text.trim();
    if (latest == null) return b.isNotEmpty || p.isNotEmpty || s.isNotEmpty;
    return b != latest!.brandName ||
        p != (latest!.price?.toString() ?? '') ||
        s != (latest!.specs ?? '');
  }

  void dispose() {
    brand.dispose();
    price.dispose();
    specs.dispose();
  }
}

/// One shop's audit page. Opened from Audit surveys, and from Surveyed shops
/// (then [audits] is null and the shop's audits are loaded here).
class ShopAuditPage extends ConsumerStatefulWidget {
  final CustomersData shop;
  final List<Map<String, dynamic>>? audits;
  const ShopAuditPage({super.key, required this.shop, this.audits});
  @override
  ConsumerState<ShopAuditPage> createState() => _ShopAuditPageState();
}

class _ShopAuditPageState extends ConsumerState<ShopAuditPage> {
  late List<Map<String, dynamic>> _trailList = widget.audits ?? const [];
  bool _loading = true;
  bool _saving = false;
  List<ProductRow> _products = [];
  final Map<String, PlacementAuditRow> _latestP = {};
  final Map<String, bool> _present = {};
  final List<_SpotEdit> _spots = [];
  Map<String, String> _users = {};
  DateTime? _lastSurvey;
  final _df = DateFormat('d MMM yyyy, h:mm a');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final s in _spots) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final cid = widget.shop.id;
    final orgId = widget.shop.orgId;
    final users = {for (final u in await db.select(db.users).get()) u.id: u.name};
    final products = await (db.select(db.products)
          ..where((p) => p.isActive.equals(true))
          ..orderBy([(p) => OrderingTerm.asc(p.position), (p) => OrderingTerm.asc(p.name)]))
        .get();
    final pa = await (db.select(db.placementAudits)
          ..where((a) => a.customerId.equals(cid))
          ..orderBy([(a) => OrderingTerm.desc(a.surveyedAt)]))
        .get();
    final cats = await (db.select(db.competitorCategories)
          ..where((c) => c.isActive.equals(true))
          ..orderBy([(c) => OrderingTerm.asc(c.position), (c) => OrderingTerm.asc(c.name)]))
        .get();
    final cs = await (db.select(db.competitorSpottings)
          ..where((s) => s.customerId.equals(cid))
          ..orderBy([(s) => OrderingTerm.desc(s.surveyedAt)]))
        .get();
    if (widget.audits == null) {
      final svc = SurveyAuditService(db);
      final server = orgId == null ? <Map<String, dynamic>>[] : await svc.fetchShop(orgId, cid);
      final queued = [for (final q in await svc.queued()) if (q['customer_id'] == cid) {...q, '_pending': true}];
      final all = <String, Map<String, dynamic>>{
        for (final a in server) '${a['id']}': a,
        for (final a in queued) '${a['id']}': a,
      };
      _trailList = all.values.toList()
        ..sort((a, b) => '${b['audited_at']}'.compareTo('${a['audited_at']}'));
    }
    DateTime? last;
    for (final a in pa) {
      _latestP.putIfAbsent(a.productId, () => a);
      if (last == null || a.surveyedAt.isAfter(last)) last = a.surveyedAt;
    }
    final byCat = <String, CompetitorSpottingRow>{};
    for (final s in cs) {
      byCat.putIfAbsent(s.categoryId, () => s);
      if (last == null || s.surveyedAt.isAfter(last)) last = s.surveyedAt;
    }
    if (!mounted) return;
    setState(() {
      _users = users;
      _products = [for (final p in products) if (orgId == null || p.orgId == orgId) p];
      for (final p in _products) {
        _present[p.id] = _latestP[p.id]?.isPresent ?? false;
      }
      for (final c in cats) {
        if (orgId != null && c.orgId != orgId) continue;
        _spots.add(_SpotEdit(c, byCat[c.id]));
      }
      _lastSurvey = last;
      _loading = false;
    });
  }

  List<ProductRow> get _changedProducts => [
        for (final p in _products)
          if ((_present[p.id] ?? false) != (_latestP[p.id]?.isPresent ?? false) ||
              (_latestP[p.id] == null && (_present[p.id] ?? false)))
            p
      ];

  bool get _hasChanges => _changedProducts.isNotEmpty || _spots.any((s) => s.changed);

  // ── location ──
  double _distance(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  Future<Map<String, dynamic>> _locate() async {
    final res = await ref.read(deviceGpsServiceProvider).getFixResult(timeout: const Duration(seconds: 20));
    if (!res.ok) return {'location_status': 'no_gps'};
    final fix = res.fix!;
    final out = <String, dynamic>{'lat': fix.lat, 'lng': fix.lng, 'accuracy_m': fix.accuracy};
    final sLat = widget.shop.latitude, sLng = widget.shop.longitude;
    if (sLat == null || sLng == null) {
      out['location_status'] = 'no_shop_location';
      return out;
    }
    int radius = 100;
    try {
      radius = (await ref.read(orgSettingsProvider.future)).geofenceRadiusMeters;
    } catch (_) {}
    final d = _distance(fix.lat, fix.lng, sLat, sLng);
    out['distance_m'] = double.parse(d.toStringAsFixed(1));
    out['location_status'] = d <= radius ? 'inside' : 'outside';
    return out;
  }

  // ── submit ──
  Future<void> _start(String result) async {
    if (result != 'issue' && _hasChanges) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('You changed the survey — save it as "Issue found" with a comment.')));
      return;
    }
    for (final s in _spots) {
      if (s.changed && s.brand.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${s.cat.name}: enter the brand (it can\'t be left empty).')));
        return;
      }
    }
    setState(() => _saving = true);
    final loc = await _locate();
    if (!mounted) return;
    setState(() => _saving = false);
    final sheet = await showModalBottomSheet<(String, String?)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AuditSheet(result: result, location: loc, shopId: widget.shop.id),
    );
    if (sheet == null || !mounted) return;
    await _save(result, sheet.$1, sheet.$2, loc);
  }

  Future<void> _save(String result, String comment, String? localPhoto, Map<String, dynamic> loc) async {
    setState(() => _saving = true);
    try {
      final db = ref.read(appDatabaseProvider);
      final user = ref.read(authControllerProvider).valueOrNull;
      final orgId = user?.organizationId ?? widget.shop.orgId;
      if (user == null || orgId == null) throw Exception('Not signed in');
      final now = DateTime.now();
      final ms = now.millisecondsSinceEpoch;
      final corrections = <Map<String, dynamic>>[];
      await db.transaction(() async {
        var i = 0;
        for (final p in _changedProducts) {
          final id = 'pa_aud_${ms}_$i';
          i++;
          await db.into(db.placementAudits).insert(PlacementAuditsCompanion.insert(
                id: id,
                orgId: orgId,
                customerId: widget.shop.id,
                productId: p.id,
                isPresent: _present[p.id] ?? false,
                surveyedByUserId: Value(user.id),
                surveyedAt: now,
                createdAt: now,
                syncStatus: const Value('pending'),
              ));
          corrections.add({
            'type': 'placement',
            'product_id': p.id,
            'product': p.name,
            'from': _latestP[p.id] == null ? null : (_latestP[p.id]!.isPresent ? 'Displayed' : 'Not displayed'),
            'to': (_present[p.id] ?? false) ? 'Displayed' : 'Not displayed',
            'row_id': id,
          });
        }
        var j = 0;
        for (final s in _spots.where((s) => s.changed)) {
          final id = 'cs_aud_${ms}_$j';
          j++;
          final priceTxt = s.price.text.trim();
          final specsTxt = s.specs.text.trim();
          await db.into(db.competitorSpottings).insert(CompetitorSpottingsCompanion.insert(
                id: id,
                orgId: orgId,
                customerId: widget.shop.id,
                categoryId: s.cat.id,
                brandName: s.brand.text.trim(),
                price: Value(priceTxt.isEmpty ? null : int.tryParse(priceTxt)),
                specs: Value(specsTxt.isEmpty ? null : specsTxt),
                surveyedByUserId: Value(user.id),
                surveyedAt: now,
                createdAt: now,
                syncStatus: const Value('pending'),
              ));
          String fmt(String? b, int? p, String? sp) =>
              [if ((b ?? '').isNotEmpty) b, if (p != null) 'Rs $p', if ((sp ?? '').isNotEmpty) sp].join(' · ');
          corrections.add({
            'type': 'competitor',
            'category_id': s.cat.id,
            'category': s.cat.name,
            'from': s.latest == null ? null : fmt(s.latest!.brandName, s.latest!.price, s.latest!.specs),
            'to': fmt(s.brand.text.trim(), priceTxt.isEmpty ? null : int.tryParse(priceTxt), specsTxt),
            'row_id': id,
          });
        }
      });
      final svc = SurveyAuditService(db);
      await svc.enqueue({
        'id': 'sa_${ms}_${user.id}',
        'org_id': orgId,
        'customer_id': widget.shop.id,
        'auditor_id': user.id,
        'auditor_name': user.name,
        'result': result,
        'comment': comment.isEmpty ? null : comment,
        'lat': loc['lat'],
        'lng': loc['lng'],
        'accuracy_m': loc['accuracy_m'],
        'distance_m': loc['distance_m'],
        'location_status': loc['location_status'],
        'survey_at': _lastSurvey?.toUtc().toIso8601String(),
        'corrections': corrections,
        'audited_at': now.toUtc().toIso8601String(),
        if (localPhoto != null) 'local_photo': localPhoto,
      });
      if (corrections.isNotEmpty) ref.read(syncControllerProvider.notifier).noteNewPendingVisit();
      final left = await svc.flush();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(left == 0
            ? 'Audit saved for ${widget.shop.shopName}'
            : 'Audit saved on this phone — it will be sent when online'),
      ));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save the audit: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── UI ──
  Widget _section(String title, String sub) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          if (sub.isNotEmpty) Text(sub, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
        ]),
      );

  String _locText(Map<String, dynamic> a) {
    final d = (a['distance_m'] as num?)?.round();
    return switch ('${a['location_status']}') {
      'inside' => 'At the shop${d == null ? '' : ' (${d}m)'}',
      'outside' => 'Outside the shop area${d == null ? '' : ' (${d}m away)'}',
      'no_shop_location' => 'Shop has no saved location',
      _ => 'No GPS',
    };
  }

  Widget _trail() {
    final list = _trailList;
    if (list.isEmpty) {
      return const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Not audited yet.'));
    }
    return Column(children: [
      for (final a in list)
        Card(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(
                    a['result'] == 'issue'
                        ? Icons.error_outline
                        : (a['result'] == 'feedback' ? Icons.chat_bubble_outline : Icons.verified_outlined),
                    size: 18,
                    color: a['result'] == 'issue'
                        ? const Color(0xFFDC2626)
                        : (a['result'] == 'feedback' ? const Color(0xFF2563EB) : const Color(0xFF059669))),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_resultLabel(a['result'])} · ${a['auditor_name'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (a['_pending'] == true)
                  const Text('Not sent yet', style: TextStyle(fontSize: 11, color: Color(0xFFD97706))),
              ]),
              const SizedBox(height: 2),
              Text(
                '${_ts(a['audited_at']) == null ? '' : _df.format(_ts(a['audited_at'])!)} · ${_locText(a)}',
                style: TextStyle(fontSize: 12, color: a['location_status'] == 'outside' ? const Color(0xFFD97706) : Theme.of(context).hintColor),
              ),
              if ('${a['comment'] ?? ''}'.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('${a['comment']}'),
              ],
              if (a['corrections'] is List && (a['corrections'] as List).isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final c in (a['corrections'] as List))
                  if (c is Map)
                    Text(
                      '• ${c['type'] == 'placement' ? c['product'] : c['category']}: ${c['from'] ?? '—'} → ${c['to'] ?? '—'}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
              ],
              if ((a['photo_path'] ?? a['local_photo']) != null)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('📷 Photo attached', style: TextStyle(fontSize: 12)),
                ),
            ]),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final pBy = _latestP.values.isEmpty
        ? ''
        : () {
            final l = _latestP.values.reduce((a, b) => a.surveyedAt.isAfter(b.surveyedAt) ? a : b);
            return '${_df.format(l.surveyedAt)}${_users[l.surveyedByUserId] == null ? '' : ' · ${_users[l.surveyedByUserId]}'}';
          }();
    return Scaffold(
      appBar: AppBar(title: Text(widget.shop.shopName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text(
                  'Check the survey below at the shop. Change anything that is wrong — '
                  'the change is saved as your correction and the original stays in the history.',
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
                ),
              ),
              _section('Placement', pBy),
              if (_products.isEmpty)
                const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('No products set up.'))
              else
                for (final p in _products)
                  CheckboxListTile(
                    dense: true,
                    value: _present[p.id] ?? false,
                    title: Text(p.name),
                    subtitle: _latestP[p.id] == null
                        ? const Text('Not in the survey')
                        : ((_present[p.id] ?? false) != _latestP[p.id]!.isPresent
                            ? Text('Survey said: ${_latestP[p.id]!.isPresent ? 'Displayed' : 'Not displayed'}',
                                style: const TextStyle(color: Color(0xFFD97706)))
                            : null),
                    onChanged: (v) => setState(() => _present[p.id] = v ?? false),
                  ),
              const Divider(height: 24),
              _section('Competitor Spotting', ''),
              if (_spots.isEmpty)
                const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('No categories set up.'))
              else
                for (final s in _spots)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        '${s.cat.name}${s.latest == null ? ' · not in the survey' : ' · ${_users[s.latest!.surveyedByUserId] ?? ''}'}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: s.brand,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(labelText: 'Brand', isDense: true, border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: s.price,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(labelText: 'Price', isDense: true, border: OutlineInputBorder()),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      TextField(
                        controller: s.specs,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(labelText: 'Specs', isDense: true, border: OutlineInputBorder()),
                      ),
                      if (s.changed)
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text('Changed — will be saved as your correction',
                              style: TextStyle(fontSize: 12, color: Color(0xFFD97706))),
                        ),
                    ]),
                  ),
              const Divider(height: 24),
              _section('Audit history', '${_trailList.length} audit${_trailList.length == 1 ? '' : 's'}'),
              _trail(),
            ]),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving || _hasChanges ? null : () => _start('ok'),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Matches'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF059669),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving || _hasChanges ? null : () => _start('feedback'),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Feedback'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF2563EB),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : () => _start('issue'),
                      icon: _saving
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.report_outlined),
                      label: Text(_hasChanges ? 'Issue + fix' : 'Issue'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFDC2626),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
    );
  }
}

// ── Comment + optional photo ─────────────────────────────────────────────────

class _AuditSheet extends StatefulWidget {
  final String result;
  final Map<String, dynamic> location;
  final String shopId;
  const _AuditSheet({required this.result, required this.location, required this.shopId});
  @override
  State<_AuditSheet> createState() => _AuditSheetState();
}

class _AuditSheetState extends State<_AuditSheet> {
  final _comment = TextEditingController();
  String? _photo;
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    setState(() => _busy = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 70,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (file == null) return;
      Uint8List bytes = await File(file.path).readAsBytes();
      final lat = widget.location['lat'] as double?, lng = widget.location['lng'] as double?;
      if (lat != null && lng != null) {
        try {
          bytes = PhotoWatermark.addWatermark(jpegBytes: bytes, latitude: lat, longitude: lng, timestamp: DateTime.now());
        } catch (_) {}
      }
      final dir = await getApplicationDocumentsDirectory();
      final out = File('${dir.path}/survey_audit_${widget.shopId}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await out.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() => _photo = out.path);
    } catch (e) {
      if (mounted) setState(() => _err = 'Could not take the photo');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final issue = widget.result == 'issue';
    final feedback = widget.result == 'feedback';
    final needComment = issue || feedback;
    final st = '${widget.location['location_status']}';
    final d = (widget.location['distance_m'] as num?)?.round();
    final locText = switch (st) {
      'inside' => 'You are at the shop${d == null ? '' : ' (${d}m)'}',
      'outside' => 'You are outside the shop area${d == null ? '' : ' (${d}m away)'} — the audit will be flagged',
      'no_shop_location' => 'This shop has no saved location — the audit will be flagged',
      _ => 'Could not get your location — the audit will be flagged',
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(issue ? 'Issue found' : (feedback ? 'Feedback' : 'Matches the survey'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Row(children: [
          Icon(st == 'inside' ? Icons.location_on : Icons.wrong_location_outlined,
              size: 16, color: st == 'inside' ? const Color(0xFF059669) : const Color(0xFFD97706)),
          const SizedBox(width: 6),
          Expanded(child: Text(locText, style: const TextStyle(fontSize: 12.5))),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _comment,
          maxLines: 3,
          autofocus: needComment,
          decoration: InputDecoration(
            labelText: needComment ? 'Comment *' : 'Comment (optional)',
            hintText: issue ? 'What was wrong?' : (feedback ? 'Your feedback on this shop' : 'Anything to note'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _takePhoto,
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(_photo == null ? 'Add photo' : 'Retake photo'),
          ),
          const SizedBox(width: 10),
          if (_photo != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(File(_photo!), width: 48, height: 48, fit: BoxFit.cover),
            ),
          if (_photo != null)
            IconButton(
              tooltip: 'Remove photo',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _photo = null),
            ),
        ]),
        if (_err != null) Text(_err!, style: const TextStyle(color: Color(0xFFDC2626))),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy
                ? null
                : () {
                    final c = _comment.text.trim();
                    if (needComment && c.isEmpty) {
                      setState(() => _err = issue ? 'Please add a comment for the issue.' : 'Please write your feedback.');
                      return;
                    }
                    Navigator.pop(context, (c, _photo));
                  },
            child: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Save audit')),
          ),
        ),
      ]),
    );
  }
}
