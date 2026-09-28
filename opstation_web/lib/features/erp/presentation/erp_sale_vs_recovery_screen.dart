// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Sale vs Recovery — one row per Salesman × Market (route).
///
/// Figures come from the posted GL per customer (rpc_sale_vs_recovery) and are
/// rolled up to the route's customers (route_stops) and the route's assigned
/// salespeople (route_assignments). A customer on two routes, or a route with
/// two salespeople, appears in each row it belongs to; the grand total counts
/// every customer once.
///
///   Recovery/Sale %        = Recovery ÷ Sale
///   Recovery/Receivable %  = Recovery ÷ (Opening Balance + Sale)
///   Closing Balance        = Opening + Sale − Recovery + Journal Entries
class ErpSaleVsRecoveryScreen extends ConsumerStatefulWidget {
  const ErpSaleVsRecoveryScreen({super.key});
  @override
  ConsumerState<ErpSaleVsRecoveryScreen> createState() => _ErpSaleVsRecoveryScreenState();
}

class _Opt {
  final String id;
  final String label;
  const _Opt(this.id, this.label);
}

class _ErpSaleVsRecoveryScreenState extends ConsumerState<ErpSaleVsRecoveryScreen> {
  static const _unassigned = '__none__';

  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();

  // Filter selections (ids; empty = all).
  final Set<String> _fSales = {};
  final Set<String> _fRoutes = {};
  final Set<String> _fGroups = {};

  // Reference data.
  bool _loadingMeta = true;
  List<_Opt> _salesOpts = [];
  List<_Opt> _routeOpts = [];
  List<_Opt> _groupOpts = [];
  final Map<String, String> _routeName = {};
  final Map<String, String> _userName = {};
  final Map<String, Set<String>> _routeToSales = {}; // route -> user ids
  final Map<String, Set<String>> _routeToCust = {}; // route -> customer ids
  final Map<String, String> _custGroup = {}; // customer -> group_name

  // Results.
  bool _running = false;
  bool _hasRun = false;
  List<Map<String, dynamic>> _rows = [];
  Map<String, double> _total = {};
  int _sortCol = 0;
  bool _sortAsc = true;
  int _pageSize = 0; // 0 = All
  String _search = '';
  String _userLabel = '';

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMeta());
  }

  Future<List<Map<String, dynamic>>> _all(
      PostgrestFilterBuilder<List<Map<String, dynamic>>> Function() build) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0; from <= 500000; from += 1000) {
      final page = await build().range(from, from + 999);
      out.addAll(page);
      if (page.length < 1000) break;
    }
    return out;
  }

  Future<void> _loadMeta() async {
    final orgId = _orgId;
    if (orgId == null) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) _loadMeta();
      return;
    }
    _userLabel = ref.read(currentUserProvider)?.name ?? '';
    try {
      final c = Supabase.instance.client;
      final routes = List<Map<String, dynamic>>.from(await c
          .from('sales_routes')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name'));
      final rids = [for (final r in routes) r['id'] as String];
      _routeName
        ..clear()
        ..addEntries(routes.map((r) => MapEntry(r['id'] as String, (r['name'] as String?) ?? '(route)')));

      _routeToSales.clear();
      _routeToCust.clear();
      final uids = <String>{};
      for (var i = 0; i < rids.length; i += 150) {
        final chunk = rids.sublist(i, i + 150 > rids.length ? rids.length : i + 150);
        final ra = await c.from('route_assignments').select('user_id, route_id').inFilter('route_id', chunk);
        for (final a in ra as List) {
          final u = a['user_id'] as String?, r = a['route_id'] as String?;
          if (u == null || r == null) continue;
          uids.add(u);
          (_routeToSales[r] ??= {}).add(u);
        }
        final stops = await _all(() => c.from('route_stops').select('route_id, customer_id').inFilter('route_id', chunk));
        for (final s in stops) {
          final cid = s['customer_id'] as String?, r = s['route_id'] as String?;
          if (cid == null || r == null) continue;
          (_routeToCust[r] ??= {}).add(cid);
        }
      }

      _userName.clear();
      if (uids.isNotEmpty) {
        final us = await c.from('users').select('id, name').inFilter('id', uids.toList());
        for (final u in us as List) {
          _userName[u['id'] as String] = (u['name'] as String?)?.trim().isNotEmpty == true
              ? (u['name'] as String).trim()
              : (u['id'] as String);
        }
      }

      final custs = await _all(() => c.from('customers').select('id, group_name').eq('org_id', orgId));
      _custGroup.clear();
      final groups = <String>{};
      for (final r in custs) {
        final g = (r['group_name'] as String?)?.trim() ?? '';
        _custGroup[r['id'] as String] = g;
        if (g.isNotEmpty) groups.add(g);
      }

      if (!mounted) return;
      setState(() {
        _salesOpts = [for (final e in _userName.entries) _Opt(e.key, e.value)]
          ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
        _routeOpts = [for (final r in routes) _Opt(r['id'] as String, _routeName[r['id']]!)];
        _groupOpts = [for (final g in (groups.toList()..sort())) _Opt(g, g)];
        _loadingMeta = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingMeta = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load filters: $e')));
      }
    }
  }

  // ── Run ────────────────────────────────────────────────────────────────
  Future<void> _run() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _running = true);
    try {
      final res = await Supabase.instance.client.rpc('rpc_sale_vs_recovery', params: {
        'p_org': orgId,
        'p_from': DateFormat('yyyy-MM-dd').format(_from),
        'p_to': DateFormat('yyyy-MM-dd').format(_to),
      });
      final fig = <String, Map<String, double>>{};
      for (final r in res as List) {
        double n(String k) => (r[k] as num?)?.toDouble() ?? 0;
        fig[r['customer_id'] as String] = {
          'opening': n('opening'), 'sale': n('sale'), 'recovery': n('recovery'),
          'journal': n('journal'), 'closing': n('closing'),
        };
      }

      bool groupOk(String cid) => _fGroups.isEmpty || _fGroups.contains(_custGroup[cid] ?? '');

      // Build Salesman × Market buckets.
      final buckets = <String, Map<String, dynamic>>{}; // key -> {sp, route, custs}
      void add(String spId, String routeId, Iterable<String> custs) {
        final key = '$spId|$routeId';
        final b = buckets.putIfAbsent(key, () => {
              'sp': spId, 'route': routeId, 'custs': <String>{},
            });
        (b['custs'] as Set<String>).addAll(custs);
      }

      final onAnyRoute = <String>{};
      for (final e in _routeToCust.entries) {
        onAnyRoute.addAll(e.value);
      }
      for (final rid in _routeName.keys) {
        if (_fRoutes.isNotEmpty && !_fRoutes.contains(rid)) continue;
        final custs = (_routeToCust[rid] ?? const <String>{}).where(groupOk).toList();
        final sps = _routeToSales[rid] ?? const <String>{};
        if (sps.isEmpty) {
          if (_fSales.isEmpty) add(_unassigned, rid, custs);
        } else {
          for (final sp in sps) {
            if (_fSales.isNotEmpty && !_fSales.contains(sp)) continue;
            add(sp, rid, custs);
          }
        }
      }
      // Customers with activity but on no route — only when not filtering by
      // salesman / route, so the grand total still ties to the receivables.
      if (_fSales.isEmpty && _fRoutes.isEmpty) {
        final loose = fig.keys.where((cid) => !onAnyRoute.contains(cid) && groupOk(cid));
        add(_unassigned, _unassigned, loose);
      }

      final rows = <Map<String, dynamic>>[];
      final everyone = <String>{};
      for (final b in buckets.values) {
        final custs = b['custs'] as Set<String>;
        final t = _sum(custs, fig);
        final active = t.values.any((v) => v.abs() >= 0.005);
        if (!active) continue;
        everyone.addAll(custs);
        rows.add({
          'salesman': b['sp'] == _unassigned ? 'Unassigned' : (_userName[b['sp']] ?? b['sp']),
          'market': b['route'] == _unassigned ? 'No route' : (_routeName[b['route']] ?? b['route']),
          'customers': custs.where((c) => fig.containsKey(c)).length,
          ...t,
        });
      }
      rows.sort((a, b) {
        final s = (a['salesman'] as String).toLowerCase().compareTo((b['salesman'] as String).toLowerCase());
        return s != 0 ? s : (a['market'] as String).toLowerCase().compareTo((b['market'] as String).toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _total = _sum(everyone, fig);
        _hasRun = true;
        _running = false;
        _sortCol = 0;
        _sortAsc = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().contains('rpc_sale_vs_recovery')
            ? 'Report function missing — run 285_sale_vs_recovery.sql in Supabase.'
            : 'Could not run report: $e'),
      ));
    }
  }

  Map<String, double> _sum(Iterable<String> custs, Map<String, Map<String, double>> fig) {
    final t = {'opening': 0.0, 'sale': 0.0, 'recovery': 0.0, 'journal': 0.0, 'closing': 0.0};
    for (final c in custs) {
      final f = fig[c];
      if (f == null) continue;
      for (final k in t.keys.toList()) {
        t[k] = t[k]! + (f[k] ?? 0);
      }
    }
    return t;
  }

  static double _pct(double num, double den) => den.abs() < 0.005 ? 0 : num / den * 100;
  static double _rsPct(Map r) => _pct((r['recovery'] as double), (r['sale'] as double));
  static double _rrPct(Map r) =>
      _pct((r['recovery'] as double), (r['opening'] as double) + (r['sale'] as double));
  static String _p(double v) => v.abs() < 0.05 ? '0' : '${v.toStringAsFixed(1)}%';

  // ── Visible rows (search + sort) ─────────────────────────────────────
  static const _cols = [
    'Sr #', 'Salesman', 'Market', 'Sale', 'Recovery', 'Recovery/Sale %',
    'Journal Entries', 'Opening Balance', 'Closing Balance', 'Recovery/Receivable %',
  ];

  Object _sortVal(Map<String, dynamic> r, int col, int idx) {
    switch (col) {
      case 1: return (r['salesman'] as String).toLowerCase();
      case 2: return (r['market'] as String).toLowerCase();
      case 3: return r['sale'] as double;
      case 4: return r['recovery'] as double;
      case 5: return _rsPct(r);
      case 6: return r['journal'] as double;
      case 7: return r['opening'] as double;
      case 8: return r['closing'] as double;
      case 9: return _rrPct(r);
      default: return idx;
    }
  }

  List<Map<String, dynamic>> get _visible {
    final list = <Map<String, dynamic>>[];
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      if (_search.isNotEmpty && !matchesQuery('${r['salesman']} ${r['market']}', _search)) continue;
      list.add({...r, '_i': i});
    }
    list.sort((a, b) {
      final va = _sortVal(a, _sortCol, a['_i'] as int);
      final vb = _sortVal(b, _sortCol, b['_i'] as int);
      final c = (va as Comparable).compareTo(vb);
      return _sortAsc ? c : -c;
    });
    return list;
  }

  // ── Export ────────────────────────────────────────────────────────────
  String _filterSummary() {
    String names(Set<String> ids, List<_Opt> opts) {
      if (ids.isEmpty) return 'All';
      final m = {for (final o in opts) o.id: o.label};
      return ids.map((i) => m[i] ?? i).join(', ');
    }
    return '${DateFormat('dd/MM/yyyy').format(_from)} to ${DateFormat('dd/MM/yyyy').format(_to)}'
        '  •  Salesman: ${names(_fSales, _salesOpts)}'
        '  •  Market: ${names(_fRoutes, _routeOpts)}'
        '  •  Customer Group: ${names(_fGroups, _groupOpts)}';
  }

  List<String> _cells(Map<String, dynamic> r, int sr) => [
        '$sr', '${r['salesman']}', '${r['market']}',
        money(r['sale'] as double), money(r['recovery'] as double), _p(_rsPct(r)),
        money(r['journal'] as double), money(r['opening'] as double), money(r['closing'] as double),
        _p(_rrPct(r)),
      ];

  List<String> get _totalCells => [
        '', 'Total', '',
        money(_total['sale']), money(_total['recovery']), _p(_rsPct(_total)),
        money(_total['journal']), money(_total['opening']), money(_total['closing']),
        _p(_rrPct(_total)),
      ];

  void _exportCsv() {
    String q(Object? v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';
    final sb = StringBuffer()..writeln(_cols.map(q).join(','));
    final rows = _visible;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      sb.writeln([
        i + 1, r['salesman'], r['market'],
        (r['sale'] as double).toStringAsFixed(2), (r['recovery'] as double).toStringAsFixed(2),
        _rsPct(r).toStringAsFixed(1), (r['journal'] as double).toStringAsFixed(2),
        (r['opening'] as double).toStringAsFixed(2), (r['closing'] as double).toStringAsFixed(2),
        _rrPct(r).toStringAsFixed(1),
      ].map(q).join(','));
    }
    if (_search.isEmpty) {
      sb.writeln([
        '', 'Total', '',
        _total['sale']!.toStringAsFixed(2), _total['recovery']!.toStringAsFixed(2),
        _rsPct(_total).toStringAsFixed(1), _total['journal']!.toStringAsFixed(2),
        _total['opening']!.toStringAsFixed(2), _total['closing']!.toStringAsFixed(2),
        _rrPct(_total).toStringAsFixed(1),
      ].map(q).join(','));
    }
    final blob = html.Blob(['﻿', sb.toString()], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download',
          'sale_vs_recovery_${DateFormat('yyyyMMdd').format(_from)}_${DateFormat('yyyyMMdd').format(_to)}.csv')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  void _exportPdf() {
    final rows = _visible;
    final b = StringBuffer();
    b.write('<!doctype html><html><head><meta charset="utf-8"><title>Sale vs Recovery</title>');
    b.write('<style>@page{size:A4 landscape;margin:12mm}body{font-family:Arial,Helvetica,sans-serif;margin:18px;color:#1a1a1a}'
        'h1{font-size:18px;margin:0 0 4px}.meta{font-size:12px;color:#555;margin-bottom:12px}'
        'table{border-collapse:collapse;width:100%;font-size:11px}'
        'th,td{border:1px solid #ddd;padding:5px 6px}th{background:#000;color:#fff;text-align:left}'
        'td.num,th.num{text-align:right}tr.total td{font-weight:700;background:#f3f4f6}'
        '.foot{margin-top:14px;font-size:11px;color:#666}'
        '.no-print{margin-bottom:12px}@media print{.no-print{display:none}}</style></head><body>');
    b.write('<div class="no-print"><button onclick="window.print()">&#x1F5A8; Print / Save as PDF</button></div>');
    b.write('<h1>Sale vs Recovery</h1><div class="meta">${_esc(_filterSummary())}</div>');
    b.write('<table><thead><tr>');
    for (var i = 0; i < _cols.length; i++) {
      b.write('<th${i >= 3 ? ' class="num"' : ''}>${_esc(_cols[i])}</th>');
    }
    b.write('</tr></thead><tbody>');
    for (var i = 0; i < rows.length; i++) {
      final c = _cells(rows[i], i + 1);
      b.write('<tr>');
      for (var j = 0; j < c.length; j++) {
        b.write('<td${j >= 3 ? ' class="num"' : ''}>${_esc(c[j])}</td>');
      }
      b.write('</tr>');
    }
    if (_search.isEmpty) {
      final c = _totalCells;
      b.write('<tr class="total">');
      for (var j = 0; j < c.length; j++) {
        b.write('<td${j >= 3 ? ' class="num"' : ''}>${_esc(c[j])}</td>');
      }
      b.write('</tr>');
    }
    b.write('</tbody></table>');
    b.write('<div class="foot">Total counts each customer once (a customer on two markets appears in both rows).'
        ' &nbsp;•&nbsp; Created by ${_esc(_userLabel.isEmpty ? '—' : _userLabel)}'
        ' &nbsp;•&nbsp; ${DateFormat('d MMM yyyy, HH:mm').format(DateTime.now())}</div>');
    b.write('</body></html>');
    final blob = html.Blob([b.toString()], 'text/html;charset=utf-8');
    html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
  }

  // ── UI ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(
              color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Sale vs Recovery', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Text('Sales, recoveries and receivables by salesman and market.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _filterCard(),
              const SizedBox(height: 16),
              if (_hasRun) _resultsCard(),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _labelled(String label, double width, Widget child) => SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          child,
        ]),
      );

  Widget _box(String text, {bool active = false}) => Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Expanded(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    color: active ? AppTheme.primary : AppTheme.textPrimary,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
          ),
          const Icon(Icons.arrow_drop_down, size: 20),
        ]),
      );

  Future<void> _pickDate(bool from) async {
    final d = await showDatePicker(
      context: context,
      initialDate: from ? _from : _to,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      if (from) {
        _from = d;
        if (_to.isBefore(d)) _to = d;
      } else {
        _to = d;
        if (_from.isAfter(d)) _from = d;
      }
    });
  }

  Widget _multi(String label, List<_Opt> opts, Set<String> sel) {
    final m = {for (final o in opts) o.id: o.label};
    final text = opts.isEmpty
        ? (_loadingMeta ? 'Loading…' : 'None defined')
        : sel.isEmpty
            ? 'All'
            : sel.length == 1
                ? (m[sel.first] ?? sel.first)
                : '${sel.length} selected';
    return _labelled(
      label,
      220,
      InkWell(
        onTap: opts.isEmpty ? null : () => _openPicker(label, opts, sel),
        child: _box(text, active: sel.isNotEmpty),
      ),
    );
  }

  Future<void> _openPicker(String title, List<_Opt> opts, Set<String> sel) async {
    final work = Set<String>.from(sel);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        final shown = opts.where((o) => matchesQuery(o.label, ctrl.text)).toList();
        return AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 17)),
          content: SizedBox(
            width: 380,
            height: 440,
            child: Column(children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search…',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setDlg(() {}),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Text(work.isEmpty ? 'All included' : '${work.length} of ${opts.length} selected',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                const Spacer(),
                TextButton(
                    onPressed: work.isEmpty ? null : () => setDlg(() => work.clear()),
                    child: const Text('Clear', style: TextStyle(fontSize: 12))),
                TextButton(
                    onPressed: shown.isEmpty ? null : () => setDlg(() => work.addAll(shown.map((o) => o.id))),
                    child: const Text('Select shown', style: TextStyle(fontSize: 12))),
              ]),
              const Divider(height: 1),
              Expanded(
                child: shown.isEmpty
                    ? const Center(child: Text('No matches', style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final o = shown[i];
                          return CheckboxListTile(
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: work.contains(o.id),
                            title: Text(o.label, style: const TextStyle(fontSize: 13)),
                            onChanged: (v) => setDlg(() => v == true ? work.add(o.id) : work.remove(o.id)),
                          );
                        },
                      ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
          ],
        );
      }),
    );
    if (ok == true && mounted) {
      setState(() {
        sel
          ..clear()
          ..addAll(work);
      });
    }
  }

  Widget _filterCard() {
    final df = DateFormat('dd/MM/yyyy');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Wrap(spacing: 14, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.end, children: [
        _labelled('From', 150, InkWell(onTap: () => _pickDate(true), child: _box(df.format(_from)))),
        _labelled('To', 150, InkWell(onTap: () => _pickDate(false), child: _box(df.format(_to)))),
        _multi('Salesperson', _salesOpts, _fSales),
        _multi('Route / Market', _routeOpts, _fRoutes),
        _multi('Customer Group', _groupOpts, _fGroups),
        SizedBox(
          height: 40,
          child: ElevatedButton.icon(
            icon: _running
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(_running ? 'Running…' : 'Run report'),
            onPressed: (_running || _loadingMeta) ? null : _run,
          ),
        ),
      ]),
    );
  }

  Widget _resultsCard() {
    final vis = _visible;
    final shown = _pageSize == 0 ? vis : vis.take(_pageSize).toList();
    const h = TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13);
    const cell = TextStyle(fontSize: 13);
    const bold = TextStyle(fontSize: 13, fontWeight: FontWeight.w800);

    DataColumn col(int i) => DataColumn(
          numeric: i >= 3,
          label: Text(_cols[i], style: h),
          onSort: (_, __) => setState(() {
            if (_sortCol == i) {
              _sortAsc = !_sortAsc;
            } else {
              _sortCol = i;
              _sortAsc = true;
            }
          }),
        );

    return Container(
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('Show ', style: TextStyle(fontSize: 13)),
              DropdownButton<int>(
                value: _pageSize,
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 10, child: Text('10')),
                  DropdownMenuItem(value: 25, child: Text('25')),
                  DropdownMenuItem(value: 50, child: Text('50')),
                  DropdownMenuItem(value: 100, child: Text('100')),
                  DropdownMenuItem(value: 0, child: Text('All')),
                ],
                onChanged: (v) => setState(() => _pageSize = v ?? 0),
              ),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 220,
                child: TextField(
                  decoration: const InputDecoration(
                      isDense: true, hintText: 'Search', prefixIcon: Icon(Icons.search, size: 18),
                      border: OutlineInputBorder()),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                  onPressed: _rows.isEmpty ? null : _exportCsv,
                  icon: const Icon(Icons.grid_on, size: 16),
                  label: const Text('Excel')),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                  onPressed: _rows.isEmpty ? null : _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                  label: const Text('PDF')),
            ]),
          ],
        ),
        const SizedBox(height: 10),
        if (_rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No activity for these filters.', style: TextStyle(color: AppTheme.textSecondary)),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              sortColumnIndex: _sortCol,
              sortAscending: _sortAsc,
              headingRowColor: MaterialStateProperty.all(Colors.black),
              headingRowHeight: 44,
              dataRowMinHeight: 38,
              dataRowMaxHeight: 52,
              columnSpacing: 22,
              columns: [for (var i = 0; i < _cols.length; i++) col(i)],
              rows: [
                for (var i = 0; i < shown.length; i++)
                  DataRow(cells: [
                    for (final c in _cells(shown[i], i + 1)) DataCell(Text(c, style: cell)),
                  ]),
                if (_search.isEmpty)
                  DataRow(
                    color: MaterialStateProperty.all(AppTheme.background),
                    cells: [for (final c in _totalCells) DataCell(Text(c, style: bold))],
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Showing ${shown.length} of ${vis.length} row(s). '
          'The total counts each customer once, even if they sit on more than one market.',
          style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
        ),
      ]),
    );
  }
}
