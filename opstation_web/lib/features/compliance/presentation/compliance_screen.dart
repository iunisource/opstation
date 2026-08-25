import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' as xls;

import '../../auth/auth_controller.dart';

/// Compliance report — surfaces three classes of anomaly across the
/// last 90 days, scoped to the current user's organization:
///
///   1. No collection in last 3 visits  (verified visits, all amount=0)
///   2. No visit in last 3 routes       (on planned route 3x, never visited)
///   3. Skipped in last 3 routes        (status=skipped on 3 consecutive trips)
///
/// All checks are per-customer. Trip linkage uses
/// visits.trip_id -> trips.id, with sales_route membership inferred
/// from route_stops.
class ComplianceScreen extends ConsumerStatefulWidget {
  const ComplianceScreen({super.key});

  @override
  ConsumerState<ComplianceScreen> createState() => _ComplianceScreenState();
}

class _ComplianceScreenState extends ConsumerState<ComplianceScreen> {
  static const _border = Color(0xFFE5E7EB);
  static const _muted = Color(0xFF6B7280);
  static const _danger = Color(0xFFDC2626);
  static const _success = Color(0xFF059669);
  static const _zebra = Color(0xFFFAFAFA);

  bool _loading = true;
  String? _error;
  List<_AnomalyRow> _noCollection = [];
  List<_AnomalyRow> _noVisit = [];
  List<_AnomalyRow> _skipped = [];

  // Filters
  List<String> _allGroups = [];      // distinct customer group_name values
  List<String> _allSalespeople = []; // distinct salesperson names
  String? _fGroup;                   // null => all groups
  String? _fPerson;                  // null => all salespeople

  bool _matchFilters(_AnomalyRow r) {
    if (_fGroup != null && r.group != _fGroup) return false;
    if (_fPerson != null && !r.salespeople.contains(_fPerson)) return false;
    return true;
  }

  List<_AnomalyRow> get _fNoCollection => _noCollection.where(_matchFilters).toList();
  List<_AnomalyRow> get _fNoVisit => _noVisit.where(_matchFilters).toList();
  List<_AnomalyRow> get _fSkipped => _skipped.where(_matchFilters).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = ref.read(authControllerProvider).valueOrNull;
      final orgId = auth?.orgId;
      if (orgId == null) {
        setState(() {
          _loading = false;
          _error = 'No organization context';
        });
        return;
      }

      final client = Supabase.instance.client;
      final cutoff = DateTime.now().subtract(const Duration(days: 90));
      final cutoffIso = cutoff.toIso8601String();

      // Stage 1: tables that have org_id (customers, users, trips) —
      // fetched in parallel. visits and route_stops have no org_id
      // column, so we scope them in stage 2 via the ids collected here.
      final stage1 = await Future.wait([
        client
            .from('customers')
            .select('id, code, shop_name, group_name')
            .eq('org_id', orgId)
            .eq('is_active', true)
            .limit(10000),
        client
            .from('users')
            .select('id, name')
            .eq('org_id', orgId)
            .limit(5000),
        client
            .from('trips')
            .select('id, route_id, started_at, user_id')
            .eq('org_id', orgId)
            .gte('started_at', cutoffIso)
            .limit(20000),
      ]);
      final customers = (stage1[0] as List).cast<Map<String, dynamic>>();
      final users = (stage1[1] as List).cast<Map<String, dynamic>>();
      final trips = (stage1[2] as List).cast<Map<String, dynamic>>();

      final customerIds =
          customers.map((c) => c['id'] as String).toList();
      final routeIds = trips
          .map((t) => t['route_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      // Stage 2: derived tables, scoped via the org-scoped ids above.
      // Chunked (batch size 50) because PostgREST caps unbounded selects at
      // 1000 rows and its query string maxes around 8 KB. The batches are fired
      // CONCURRENTLY (not one-after-another as before) so a 1000-customer org
      // loads in a few round-trips of wall time instead of 20+ serial ones.
      const batchSize = 50;
      List<List<String>> chunk(List<String> ids) => [
        for (var i = 0; i < ids.length; i += batchSize)
          ids.sublist(i, (i + batchSize).clamp(0, ids.length)),
      ];

      final visitFutures = [
        for (final slice in chunk(customerIds))
          client
              .from('visits')
              .select('id, customer_id, trip_id, amount, status, timestamp, user_id')
              .inFilter('customer_id', slice)
              .gte('timestamp', cutoffIso)
              .limit(5000),
      ];
      final stopFutures = [
        for (final slice in chunk(routeIds))
          client
              .from('route_stops')
              .select('route_id, customer_id')
              .inFilter('route_id', slice)
              .limit(5000),
      ];

      // Run both sets of batches at once; the browser naturally caps in-flight
      // requests per host, so this stays polite while cutting wall time sharply.
      final stage2 = await Future.wait([
        Future.wait(visitFutures),
        Future.wait(stopFutures),
      ]);
      final visits = <Map<String, dynamic>>[
        for (final b in (stage2[0]))
          ...(b as List).cast<Map<String, dynamic>>(),
      ];
      final routeStops = <Map<String, dynamic>>[
        for (final b in (stage2[1]))
          ...(b as List).cast<Map<String, dynamic>>(),
      ];

      final userNames = <String, String>{
        for (final u in users)
          (u['id'] as String): ((u['name'] as String?) ?? 'Unknown')
      };

      // customer_id -> set of route_ids
      final routesByCustomer = <String, Set<String>>{};
      for (final rs in routeStops) {
        final rid = rs['route_id'] as String?;
        final cid = rs['customer_id'] as String?;
        if (rid != null && cid != null) {
          routesByCustomer.putIfAbsent(cid, () => <String>{}).add(rid);
        }
      }

      // visits indexed by customer (sorted DESC) and by (trip,customer)
      final visitsByCustomer = <String, List<Map<String, dynamic>>>{};
      final visitByTripCust = <String, Map<String, dynamic>>{};
      for (final v in visits) {
        final cid = v['customer_id'] as String?;
        final tid = v['trip_id'] as String?;
        if (cid != null) {
          visitsByCustomer.putIfAbsent(cid, () => []).add(v);
        }
        if (cid != null && tid != null) {
          visitByTripCust['$tid|$cid'] = v;
        }
      }
      for (final list in visitsByCustomer.values) {
        list.sort((a, b) => (b['timestamp'] as String)
            .compareTo(a['timestamp'] as String));
      }

      // last 3 trips per customer (only trips on a route that includes them)
      final tripsByCustomer = <String, List<Map<String, dynamic>>>{};
      for (final c in customers) {
        final cid = c['id'] as String;
        final rids = routesByCustomer[cid] ?? <String>{};
        if (rids.isEmpty) continue;
        final relevant = trips
            .where((t) => rids.contains(t['route_id'] as String?))
            .toList();
        relevant.sort((a, b) => (b['started_at'] as String)
            .compareTo(a['started_at'] as String));
        tripsByCustomer[cid] = relevant.take(3).toList();
      }

      // Apply triggers
      final noCol = <_AnomalyRow>[];
      final noVis = <_AnomalyRow>[];
      final skipped = <_AnomalyRow>[];

      for (final c in customers) {
        final cid = c['id'] as String;
        final code = (c['code'] as String?) ?? '';
        final name = (c['shop_name'] as String?) ?? '(no name)';
        final grp = (c['group_name'] as String?)?.trim() ?? '';

        // Trigger 1
        final verifiedVisits = (visitsByCustomer[cid] ?? const [])
            .where((v) => v['status'] == 'verified')
            .take(3)
            .toList();
        if (verifiedVisits.length == 3) {
          final allZero = verifiedVisits.every((v) {
            final amt = v['amount'];
            return amt == null || (amt is num && amt == 0);
          });
          if (allZero) {
            noCol.add(_AnomalyRow(
              id: cid,
              code: code,
              name: name,
              group: grp,
              dates: verifiedVisits
                  .map((v) => _fmtDate(v['timestamp'] as String))
                  .toList(),
              salespeople: verifiedVisits
                  .map((v) => userNames[v['user_id']] ?? 'Unknown')
                  .toSet()
                  .toList(),
            ));
          }
        }

        // Triggers 2 & 3
        final recent = tripsByCustomer[cid] ?? const [];
        if (recent.length == 3) {
          int verifiedCount = 0;
          int skippedCount = 0;
          for (final t in recent) {
            final tid = t['id'] as String;
            final v = visitByTripCust['$tid|$cid'];
            final s = v?['status'] as String?;
            if (s == 'verified') verifiedCount++;
            if (s == 'skipped') skippedCount++;
          }
          final dates = recent
              .map((t) => _fmtDate(t['started_at'] as String))
              .toList();
          final people = recent
              .map((t) => userNames[t['user_id']] ?? 'Unknown')
              .toSet()
              .toList();
          if (verifiedCount == 0) {
            noVis.add(_AnomalyRow(
                id: cid, code: code, name: name, group: grp, dates: dates, salespeople: people));
          }
          if (skippedCount == 3) {
            skipped.add(_AnomalyRow(
                id: cid, code: code, name: name, group: grp, dates: dates, salespeople: people));
          }
        }
      }

      int byName(_AnomalyRow a, _AnomalyRow b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase());
      noCol.sort(byName);
      noVis.sort(byName);
      skipped.sort(byName);

      // Filter option lists, drawn from the flagged rows so the dropdowns only
      // offer values that actually appear.
      final all = [...noCol, ...noVis, ...skipped];
      final groups = all.map((r) => r.group).where((g) => g.isNotEmpty).toSet().toList()..sort();
      final people = all.expand((r) => r.salespeople).where((p) => p.isNotEmpty).toSet().toList()..sort();

      setState(() {
        _loading = false;
        _noCollection = noCol;
        _noVisit = noVis;
        _skipped = skipped;
        _allGroups = groups;
        _allSalespeople = people;
        if (_fGroup != null && !groups.contains(_fGroup)) _fGroup = null;
        if (_fPerson != null && !people.contains(_fPerson)) _fPerson = null;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  static String _fmtDate(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)}';
    } catch (_) {
      return iso.length >= 10 ? iso.substring(0, 10) : iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Could not load compliance data:\n$_error',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: _danger),
                          ),
                        ),
                      )
                    : _content(),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      color: Colors.white,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
          children: [
            const Text('Compliance',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(width: 12),
            const Text('· Last 90 days',
                style: TextStyle(fontSize: 13, color: _muted)),
            const Spacer(),
            OutlinedButton.icon(
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text('PDF / Print'),
              onPressed: _loading ? null : _generatePdf,
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.grid_on_outlined, size: 16),
              label: const Text('Excel'),
              onPressed: _loading ? null : _exportExcel,
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
              onPressed: _load,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 260, child: _filterDropdown(
            label: 'Customer main group', value: _fGroup, options: _allGroups,
            icon: Icons.folder_open_outlined, onChanged: (v) => setState(() => _fGroup = v))),
          SizedBox(width: 260, child: _filterDropdown(
            label: 'Salesperson', value: _fPerson, options: _allSalespeople,
            icon: Icons.person_outline, onChanged: (v) => setState(() => _fPerson = v))),
          if (_fGroup != null || _fPerson != null)
            TextButton.icon(
              icon: const Icon(Icons.clear, size: 15),
              label: const Text('Clear filters'),
              onPressed: () => setState(() { _fGroup = null; _fPerson = null; })),
        ]),
      ]),
    );
  }

  Widget _filterDropdown({
    required String label,
    required String? value,
    required List<String> options,
    required IconData icon,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String?>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 18),
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('All')),
        ...options.map((o) => DropdownMenuItem<String?>(value: o, child: Text(o, overflow: TextOverflow.ellipsis))),
      ],
      onChanged: onChanged,
    );
  }

  // ── Combined export matrix ────────────────────────────────────────────────
  // One row per flagged customer (union of the three filtered lists). Each KPI
  // column shows the actual dates when the customer is flagged for it, or "—".
  static const _exportHeaders = ['Code', 'Customer', 'Main Group', 'No Collection', 'No Visit', 'Skipped', 'Salesperson'];

  List<List<String>> _matrixRows() {
    final nc = _fNoCollection, nv = _fNoVisit, sk = _fSkipped;
    final ncMap = {for (final r in nc) r.id: r.dates.join(', ')};
    final nvMap = {for (final r in nv) r.id: r.dates.join(', ')};
    final skMap = {for (final r in sk) r.id: r.dates.join(', ')};
    final byId = <String, _AnomalyRow>{};
    final peopleById = <String, Set<String>>{};
    for (final r in [...nc, ...nv, ...sk]) {
      byId[r.id] = r;
      (peopleById[r.id] ??= <String>{}).addAll(r.salespeople);
    }
    final ids = byId.keys.toList()
      ..sort((a, b) => byId[a]!.name.toLowerCase().compareTo(byId[b]!.name.toLowerCase()));
    return [
      for (final id in ids)
        [
          byId[id]!.code,
          byId[id]!.name,
          byId[id]!.group.isEmpty ? '-' : byId[id]!.group,
          ncMap[id] ?? '-',
          nvMap[id] ?? '-',
          skMap[id] ?? '-',
          (peopleById[id]!.toList()..sort()).join(', '),
        ],
    ];
  }

  String get _filterCaption {
    final parts = <String>[];
    if (_fGroup != null) parts.add('Group: $_fGroup');
    if (_fPerson != null) parts.add('Salesperson: $_fPerson');
    return parts.isEmpty ? 'All customers' : parts.join('  ·  ');
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _generatePdf() async {
    final rows = _matrixRows();
    if (rows.isEmpty) { _snack('Nothing to export for the current filters.'); return; }
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final stamp = DateFormat('d MMM y, h:mm a').format(DateTime.now());
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => [
        if (org.isNotEmpty) pw.Text(org, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Compliance Report', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text('Last 90 days  ·  $_filterCaption', style: pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700)),
        pw.Text('Generated: $stamp', style: pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: _exportHeaders,
          data: rows,
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellHeight: 16,
          columnWidths: {
            0: const pw.FixedColumnWidth(60),
            1: const pw.FlexColumnWidth(3),
            2: const pw.FlexColumnWidth(2),
            3: const pw.FlexColumnWidth(2.4),
            4: const pw.FlexColumnWidth(2.4),
            5: const pw.FlexColumnWidth(2.4),
            6: const pw.FlexColumnWidth(2.2),
          },
          cellAlignment: pw.Alignment.centerLeft,
        ),
      ],
    ));
    await Printing.layoutPdf(
      onLayout: (f) async => doc.save(),
      name: 'compliance-${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
    );
  }

  Future<void> _exportExcel() async {
    final rows = _matrixRows();
    if (rows.isEmpty) { _snack('Nothing to export for the current filters.'); return; }
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final stamp = DateFormat('d MMM y, h:mm a').format(DateTime.now());
    final excel = xls.Excel.createExcel();
    const sheetName = 'Compliance';
    final sheet = excel[sheetName];
    final def = excel.getDefaultSheet();
    if (def != null && def != sheetName) excel.delete(def);
    if (org.isNotEmpty) sheet.appendRow([xls.TextCellValue(org)]);
    sheet.appendRow([xls.TextCellValue('Compliance Report')]);
    sheet.appendRow([xls.TextCellValue('Last 90 days  ·  $_filterCaption')]);
    sheet.appendRow([xls.TextCellValue('Generated: $stamp')]);
    sheet.appendRow([xls.TextCellValue('')]);
    sheet.appendRow([for (final h in _exportHeaders) xls.TextCellValue(h)]);
    for (final r in rows) {
      sheet.appendRow([for (final c in r) xls.TextCellValue(c)]);
    }
    excel.save(fileName: 'compliance-${DateFormat('yyyyMMdd').format(DateTime.now())}.xlsx');
  }

  Widget _content() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section(
            title: 'No Collection in Last 3 Visits',
            description:
                'Verified visits with zero amount, three in a row.',
            rows: _fNoCollection,
            empty: 'No anomalies — every customer has had non-zero collection.',
          ),
          const SizedBox(height: 20),
          _section(
            title: 'No Visit in Last 3 Routes',
            description:
                'Customer was on the planned route on three trips, but never verified.',
            rows: _fNoVisit,
            empty: 'No anomalies — every customer is being visited.',
          ),
          const SizedBox(height: 20),
          _section(
            title: 'Skipped in Last 3 Routes',
            description: 'Customer was marked as skipped on three trips in a row.',
            rows: _fSkipped,
            empty: 'No anomalies — no customer has been skipped repeatedly.',
          ),
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    required String description,
    required List<_AnomalyRow> rows,
    required String empty,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: rows.isEmpty
                        ? _success.withOpacity(0.12)
                        : _danger.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    rows.length.toString(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: rows.isEmpty ? _success : _danger,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(description,
                style: const TextStyle(fontSize: 12, color: _muted)),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(empty,
                    style: const TextStyle(color: _muted, fontSize: 13)),
              )
            else
              _table(rows),
          ],
        ),
      ),
    );
  }

  Widget _table(List<_AnomalyRow> rows) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              color: _zebra,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
            ),
            child: Row(
              children: const [
                SizedBox(width: 110, child: Text('Code', style: _hStyle)),
                Expanded(flex: 3, child: Text('Customer', style: _hStyle)),
                Expanded(flex: 3, child: Text('Last 3 Dates', style: _hStyle)),
                Expanded(flex: 2, child: Text('Salesperson', style: _hStyle)),
              ],
            ),
          ),
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: i.isEven ? Colors.white : _zebra,
                border: const Border(top: BorderSide(color: _border)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(rows[i].code,
                        style:
                            const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(rows[i].name,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(rows[i].dates.join(', '),
                        style: const TextStyle(fontSize: 13, color: _muted)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(rows[i].salespeople.join(', '),
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static const _hStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: _muted,
  );
}

class _AnomalyRow {
  final String id;
  final String code;
  final String name;
  final String group;
  final List<String> dates;
  final List<String> salespeople;
  _AnomalyRow({
    required this.id,
    required this.code,
    required this.name,
    required this.group,
    required this.dates,
    required this.salespeople,
  });
}
