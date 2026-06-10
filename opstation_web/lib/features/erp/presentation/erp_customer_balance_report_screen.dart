// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Customer Balance Report — a route-wise collection sheet.
///
/// Lists every active customer grouped by sales route (via route_stops),
/// showing Credit Limit and the net AR balance at three period-ends (3 months
/// or 3 weeks; rightmost = current). Balances come from
/// rpc_customer_balance_report, which mirrors the aging/ledger math. Print/PDF
/// adds blank "Receipt #" and "Amount Collected" columns for recording
/// collections on the round, gated by the admin toggle org.cbr_collection_columns.
class ErpCustomerBalanceReportScreen extends ConsumerStatefulWidget {
  const ErpCustomerBalanceReportScreen({super.key});
  @override
  ConsumerState<ErpCustomerBalanceReportScreen> createState() =>
      _ErpCustomerBalanceReportScreenState();
}

class _ErpCustomerBalanceReportScreenState
    extends ConsumerState<ErpCustomerBalanceReportScreen> {
  final _fmt = NumberFormat('#,##0');

  DateTime _asOf = DateTime.now();
  String _span = '3M'; // '3M' | '3W'
  String? _routeFilter; // null = all routes
  bool _collectionCols = false; // admin toggle (print)

  List<Map<String, dynamic>> _routes = []; // {id, name}
  bool _loadingMeta = true;

  bool _loading = false;
  bool _loaded = false;
  List<String> _periodLabels = [];
  // Flattened display items: {'type':'header'|'row', ...}
  List<Map<String, dynamic>> _items = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMeta());
  }

  Future<void> _loadMeta() async {
    final orgId = _orgId;
    if (orgId == null) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) _loadMeta();
      return;
    }
    try {
      final client = Supabase.instance.client;
      final routes = await client
          .from('sales_routes')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final cfg = await client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId);
      bool coll = false;
      for (final r in cfg as List) {
        if (r['key'] == 'org.cbr_collection_columns') {
          coll = (r['value'] as String?) == 'true';
        }
      }
      if (mounted) {
        setState(() {
          _routes = List<Map<String, dynamic>>.from(routes);
          _collectionCols = coll;
          _loadingMeta = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMeta = false);
    }
  }

  List<DateTime> _periodEnds() {
    final a = DateTime(_asOf.year, _asOf.month, _asOf.day);
    if (_span == '3W') {
      return [
        a.subtract(const Duration(days: 14)),
        a.subtract(const Duration(days: 7)),
        a,
      ];
    }
    final d2 = DateTime(a.year, a.month, 0); // last day of previous month
    final d1 = DateTime(a.year, a.month - 1, 0); // last day of month before
    return [d1, d2, a];
  }

  List<String> _labelsFor(List<DateTime> ends) {
    if (_span == '3W') {
      return [
        'Wk to ${DateFormat('d MMM').format(ends[0])}',
        'Wk to ${DateFormat('d MMM').format(ends[1])}',
        'Current',
      ];
    }
    return [
      DateFormat('MMM yyyy').format(ends[0]),
      DateFormat('MMM yyyy').format(ends[1]),
      '${DateFormat('MMM yyyy').format(ends[2])} (current)',
    ];
  }

  Future<void> _loadReport() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final ends = _periodEnds();
      final res = await client.rpc('rpc_customer_balance_report', params: {
        'p_org_id': orgId,
        'p_d1': DateFormat('yyyy-MM-dd').format(ends[0]),
        'p_d2': DateFormat('yyyy-MM-dd').format(ends[1]),
        'p_d3': DateFormat('yyyy-MM-dd').format(ends[2]),
        'p_branch_id': null,
      });
      final byId = <String, Map<String, dynamic>>{};
      for (final r in res as List) {
        byId[r['customer_id'] as String] = Map<String, dynamic>.from(r as Map);
      }

      // Route membership.
      final routeIds = _routes.map((r) => r['id'] as String).toList();
      final stops = routeIds.isEmpty
          ? <dynamic>[]
          : await client
              .from('route_stops')
              .select('route_id, customer_id, position')
              .inFilter('route_id', routeIds);
      final byRoute = <String, List<Map<String, dynamic>>>{};
      final assigned = <String>{};
      for (final s in stops as List) {
        final rid = s['route_id'] as String;
        final cid = s['customer_id'] as String?;
        if (cid == null) continue;
        assigned.add(cid);
        (byRoute[rid] ??= []).add({
          'customer_id': cid,
          'position': (s['position'] as num?)?.toInt() ?? 0,
        });
      }

      final routeName = {for (final r in _routes) r['id'] as String: r['name'] as String? ?? '(route)'};

      final items = <Map<String, dynamic>>[];
      void addGroup(String name, List<Map<String, dynamic>> rows) {
        if (rows.isEmpty) return;
        double t1 = 0, t2 = 0, t3 = 0;
        for (final r in rows) {
          t1 += (r['bal1'] as num).toDouble();
          t2 += (r['bal2'] as num).toDouble();
          t3 += (r['bal3'] as num).toDouble();
        }
        items.add({'type': 'header', 'name': name, 'count': rows.length, 't1': t1, 't2': t2, 't3': t3});
        items.addAll(rows.map((r) => {'type': 'row', ...r}));
      }

      final routesToShow = _routeFilter == null
          ? _routes
          : _routes.where((r) => r['id'] == _routeFilter).toList();
      for (final r in routesToShow) {
        final rid = r['id'] as String;
        final stopsForRoute = (byRoute[rid] ?? [])
          ..sort((a, b) => (a['position'] as int).compareTo(b['position'] as int));
        final rows = <Map<String, dynamic>>[];
        for (final st in stopsForRoute) {
          final row = byId[st['customer_id']];
          if (row != null) rows.add(row);
        }
        addGroup(routeName[rid] ?? '(route)', rows);
      }

      // Unassigned customers (only when not filtering to a single route).
      if (_routeFilter == null) {
        final unassigned = byId.entries
            .where((e) => !assigned.contains(e.key))
            .map((e) => e.value)
            .toList()
          ..sort((a, b) =>
              (a['shop_name'] as String? ?? '').compareTo(b['shop_name'] as String? ?? ''));
        addGroup('Unassigned (no route)', unassigned);
      }

      if (mounted) {
        setState(() {
          _items = items;
          _periodLabels = _labelsFor(ends);
          _loaded = true;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Report error: $e')));
      }
    }
  }

  String _money(num v) {
    final d = v.toDouble();
    return d < 0 ? '(${_fmt.format(-d)})' : _fmt.format(d);
  }

  // ── Print / PDF ─────────────────────────────────────────────────────────────
  void _print() {
    if (!_loaded || _items.isEmpty) return;
    final coll = _collectionCols;
    final extraHead = coll
        ? '<th class="rcpt">Receipt #</th><th class="rcpt">Amount Collected</th>'
        : '';
    final extraCell = coll ? '<td class="rcpt"></td><td class="rcpt"></td>' : '';
    final colspanTotal = coll ? 2 : 0;

    final buf = StringBuffer();
    for (final it in _items) {
      if (it['type'] == 'header') {
        buf.write('<tr class="grp"><td colspan="${2 + colspanTotal}"><b>${it['name']}</b> (${it['count']})</td>'
            '<td class="num">${_money(it['t1'] as num)}</td>'
            '<td class="num">${_money(it['t2'] as num)}</td>'
            '<td class="num">${_money(it['t3'] as num)}</td></tr>');
      } else {
        final code = (it['code'] as String?) ?? '';
        final name = (it['shop_name'] as String?) ?? '';
        final disp = code.isNotEmpty ? '$code — $name' : name;
        buf.write('<tr><td>$disp</td>'
            '<td class="num">${_money((it['credit_limit'] as num?) ?? 0)}</td>'
            '<td class="num">${_money((it['bal1'] as num?) ?? 0)}</td>'
            '<td class="num">${_money((it['bal2'] as num?) ?? 0)}</td>'
            '<td class="num">${_money((it['bal3'] as num?) ?? 0)}</td>'
            '$extraCell</tr>');
      }
    }

    final genTime = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    final spanLabel = _span == '3W' ? '3 Weeks' : '3 Months';
    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Customer Balance Report</title>'
        '<style>'
        '@page { margin: 0.5cm; } '
        'body { font-family: Arial, sans-serif; padding: 14px; font-size: 10px; color: #000; } '
        'h1 { font-size: 16px; margin: 0 0 2px 0; } '
        '.info { font-size: 9.5px; color: #444; margin-bottom: 8px; } '
        'table { width: 100%; border-collapse: collapse; } '
        'th, td { padding: 3px 6px; border-bottom: 1px solid #ddd; text-align: left; font-size: 9px; } '
        'th { background: #f0f4ff; font-weight: 700; border-bottom: 1.5px solid #000; } '
        '.num { text-align: right; white-space: nowrap; } '
        '.grp td { background: #eef2ff; font-weight: 700; border-top: 1px solid #99a; } '
        '.rcpt { width: 90px; border-left: 1px dashed #bbb; } '
        '</style></head><body>'
        '<h1>Customer Balance Report</h1>'
        '<div class="info">Span: $spanLabel &nbsp;|&nbsp; As on: ${DateFormat('d MMM yyyy').format(_asOf)} &nbsp;|&nbsp; Generated: $genTime</div>'
        '<table><thead><tr><th>Customer</th><th class="num">Credit Limit</th>'
        '<th class="num">${_periodLabels.isNotEmpty ? _periodLabels[0] : ''}</th>'
        '<th class="num">${_periodLabels.length > 1 ? _periodLabels[1] : ''}</th>'
        '<th class="num">${_periodLabels.length > 2 ? _periodLabels[2] : ''}</th>'
        '$extraHead</tr></thead><tbody>${buf.toString()}</tbody></table>'
        '<div class="no-print" style="margin-top:14px"><button onclick="window.print()">Print</button></div>'
        '</body></html>';
    final blob = html.Blob([doc], 'text/html;charset=utf-8');
    html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
  }

  // ── UI ──────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Row(children: [
            const Text('Customer Balance Report',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Spacer(),
            if (_loaded)
              OutlinedButton.icon(
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print / PDF'),
                  onPressed: _print),
          ]),
        ),
        // Filters
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border)),
          child: _loadingMeta
              ? const Center(
                  child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : Wrap(
                  spacing: 20,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    _field('As On', SizedBox(
                      width: 150,
                      child: InkWell(
                        onTap: () async {
                          final p = await showDatePicker(
                              context: context,
                              initialDate: _asOf,
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100));
                          if (p != null) setState(() => _asOf = p);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 9),
                          decoration: BoxDecoration(
                              border:
                                  Border.all(color: const Color(0xFFBDBDBD)),
                              borderRadius: BorderRadius.circular(6)),
                          child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(DateFormat('dd MMM yyyy').format(_asOf),
                                    style: const TextStyle(fontSize: 13)),
                                const Icon(Icons.calendar_today,
                                    size: 13, color: AppTheme.textSecondary),
                              ]),
                        ),
                      ),
                    )),
                    _field('Span', ToggleButtons(
                      isSelected: [_span == '3M', _span == '3W'],
                      onPressed: (i) =>
                          setState(() => _span = i == 0 ? '3M' : '3W'),
                      borderRadius: BorderRadius.circular(6),
                      constraints:
                          const BoxConstraints(minHeight: 38, minWidth: 86),
                      children: const [Text('3 Months'), Text('3 Weeks')],
                    )),
                    _field('Route', SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        value: _routeFilter,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                            border: OutlineInputBorder()),
                        items: [
                          const DropdownMenuItem(
                              value: null, child: Text('All routes')),
                          ..._routes.map((r) => DropdownMenuItem(
                              value: r['id'] as String,
                              child: Text(r['name'] as String? ?? '(route)',
                                  overflow: TextOverflow.ellipsis))),
                        ],
                        onChanged: (v) => setState(() => _routeFilter = v),
                      ),
                    )),
                    ElevatedButton.icon(
                      icon: _loading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.play_arrow, size: 18),
                      label: const Text('Load Report'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 12)),
                      onPressed: _loading ? null : _loadReport,
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        // Report
        Expanded(
          child: !_loaded
              ? const Center(
                  child: Text('Choose options and Load Report',
                      style: TextStyle(color: AppTheme.textSecondary)))
              : _items.isEmpty
                  ? const Center(
                      child: Text('No customers found',
                          style: TextStyle(color: AppTheme.textSecondary)))
                  : Container(
                      margin: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.border)),
                      child: Column(children: [
                        _tableHeader(),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _items.length,
                            itemBuilder: (_, i) => _buildItem(_items[i]),
                          ),
                        ),
                      ]),
                    ),
        ),
      ]),
    );
  }

  Widget _field(String label, Widget child) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      child,
    ]);
  }

  Widget _tableHeader() {
    const st = TextStyle(
        fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(10))),
      child: Row(children: [
        const Expanded(flex: 3, child: Text('Customer', style: st)),
        const SizedBox(
            width: 110, child: Text('Credit Limit', style: st, textAlign: TextAlign.right)),
        SizedBox(
            width: 110,
            child: Text(_periodLabels.isNotEmpty ? _periodLabels[0] : '',
                style: st, textAlign: TextAlign.right)),
        SizedBox(
            width: 110,
            child: Text(_periodLabels.length > 1 ? _periodLabels[1] : '',
                style: st, textAlign: TextAlign.right)),
        SizedBox(
            width: 120,
            child: Text(_periodLabels.length > 2 ? _periodLabels[2] : '',
                style: st, textAlign: TextAlign.right)),
      ]),
    );
  }

  Widget _buildItem(Map<String, dynamic> it) {
    if (it['type'] == 'header') {
      return Container(
        color: AppTheme.primary.withOpacity(0.06),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Expanded(
              flex: 3,
              child: Text('${it['name']}  (${it['count']})',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.primary))),
          const SizedBox(width: 110),
          _amt(it['t1'] as num, 110, bold: true),
          _amt(it['t2'] as num, 110, bold: true),
          _amt(it['t3'] as num, 120, bold: true),
        ]),
      );
    }
    final code = (it['code'] as String?) ?? '';
    final name = (it['shop_name'] as String?) ?? '';
    final disp = code.isNotEmpty ? '$code — $name' : name;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(children: [
        Expanded(
            flex: 3,
            child: Text(disp,
                style: const TextStyle(fontSize: 12.5),
                overflow: TextOverflow.ellipsis)),
        _amt((it['credit_limit'] as num?) ?? 0, 110, muted: true),
        _amt((it['bal1'] as num?) ?? 0, 110),
        _amt((it['bal2'] as num?) ?? 0, 110),
        _amt((it['bal3'] as num?) ?? 0, 120, bold: true),
      ]),
    );
  }

  Widget _amt(num v, double w, {bool bold = false, bool muted = false}) {
    final neg = v.toDouble() < 0;
    return SizedBox(
      width: w,
      child: Text(_money(v),
          textAlign: TextAlign.right,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              color: muted
                  ? AppTheme.textSecondary
                  : neg
                      ? Colors.green
                      : AppTheme.textPrimary)),
    );
  }
}
