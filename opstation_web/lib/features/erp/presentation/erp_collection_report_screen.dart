// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../auth/auth_controller.dart';

/// Collection Report — executive view of money collected from the market.
///
/// Two sources side by side (rpc_collection_report, SQL 311):
///   Booked — receipts posted to customer accounts (CRV / BRV / PDC / POS).
///   Field  — amounts salespeople recorded on visits in the field app.
/// The gap (field − booked) flags cash reported in the market but not yet
/// booked, or booked without a field record.
///
/// Filters (salesperson, route, customer) combine with AND and apply instantly;
/// "View by" regroups the same data.
class ErpCollectionReportScreen extends ConsumerStatefulWidget {
  const ErpCollectionReportScreen({super.key});
  @override
  ConsumerState<ErpCollectionReportScreen> createState() => _ErpCollectionReportScreenState();
}

class _Opt {
  final String id;
  final String label;
  const _Opt(this.id, this.label);
}

class _Row {
  final bool booked;
  final DateTime d;
  final String cid, cname, uid, rid, mode, ref;
  final double amount;
  _Row(this.booked, this.d, this.cid, this.cname, this.uid, this.rid, this.amount, this.mode, this.ref);
}

class _Group {
  final String key, label;
  String sub = '';
  double booked = 0, field = 0;
  int bookedN = 0, fieldN = 0;
  final Set<String> custs = {};
  final List<_Row> rows = [];
  _Group(this.key, this.label);
  double get gap => field - booked;
}

const _none = '__none__';
const _modes = ['CRV', 'BRV', 'PDC', 'POS', 'Receipt'];
const _modeColors = {
  'CRV': Color(0xFF2F6FED),
  'BRV': Color(0xFF0EA5E9),
  'PDC': Color(0xFF8B5CF6),
  'POS': Color(0xFF14B8A6),
  'Receipt': Color(0xFF94A3B8),
};
const _modeHex = {'CRV': '#2f6fed', 'BRV': '#0ea5e9', 'PDC': '#8b5cf6', 'POS': '#14b8a6', 'Receipt': '#94a3b8'};
const _cBooked = Color(0xFF1E40AF);
const _cField = Color(0xFFF59E0B);

class _ErpCollectionReportScreenState extends ConsumerState<ErpCollectionReportScreen> {
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  bool _loading = false, _loaded = false, _loadingMeta = true;
  List<_Row> _rows = [];

  final Map<String, String> _userName = {};
  final Map<String, String> _routeName = {};
  final Map<String, String> _custName = {};

  final Set<String> _fSales = {}, _fRoutes = {}, _fCusts = {};
  String _view = 'salesperson'; // salesperson | route | customer | combo | date
  String _sort = 'booked'; // booked | field | gap | name
  String _search = '';

  String get _orgName => ref.read(currentUserProvider)?.orgName ?? '';
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMeta());
  }

  // ── Data ────────────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _all(dynamic Function() build) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0; from <= 500000; from += 1000) {
      final page = List<Map<String, dynamic>>.from(await build().range(from, from + 999));
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
    try {
      final c = Supabase.instance.client;
      final routes = await c.from('sales_routes').select('id, name').eq('org_id', orgId);
      for (final r in routes as List) {
        _routeName[r['id'] as String] = ((r['name'] as String?) ?? '').trim().isEmpty ? '(route)' : (r['name'] as String).trim();
      }
      final users = await c.from('users').select('id, name').eq('org_id', orgId);
      for (final u in users as List) {
        final n = (u['name'] as String?)?.trim() ?? '';
        _userName[u['id'] as String] = n.isEmpty ? (u['id'] as String) : n;
      }
      final custs = await _all(() => c.from('customers').select('id, shop_name').eq('org_id', orgId).order('id'));
      for (final r in custs) {
        final n = (r['shop_name'] as String?)?.trim() ?? '';
        _custName[r['id'] as String] = n.isEmpty ? '(customer)' : n;
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingMeta = false);
    _load();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final df = DateFormat('yyyy-MM-dd');
      final res = await Supabase.instance.client.rpc('rpc_collection_report', params: {
        'p_org': orgId, 'p_from': df.format(_from), 'p_to': df.format(_to),
      });
      final out = <_Row>[];
      for (final r in res as List) {
        final cid = (r['customer_id'] as String?) ?? _none;
        final cname = (r['customer_name'] as String?)?.trim();
        if (cid != _none && cname != null && cname.isNotEmpty) _custName[cid] ??= cname;
        out.add(_Row(
          r['kind'] == 'booked',
          DateTime.parse(r['d'] as String),
          cid,
          (cname == null || cname.isEmpty) ? (_custName[cid] ?? '(customer)') : cname,
          (r['user_id'] as String?) ?? _none,
          (r['route_id'] as String?) ?? _none,
          (r['amount'] as num?)?.toDouble() ?? 0,
          (r['mode'] as String?) ?? '',
          (r['ref'] as String?) ?? '',
        ));
      }
      if (!mounted) return;
      setState(() { _rows = out; _loaded = true; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load collections: $e')));
    }
  }

  // ── Derived ─────────────────────────────────────────────────────────────
  String _uName(String id) => id == _none ? 'Unassigned' : (_userName[id] ?? 'Unknown user');
  String _rName(String id) => id == _none ? 'No route' : (_routeName[id] ?? 'Unknown route');

  List<_Row> get _filtered => _rows.where((r) =>
      (_fSales.isEmpty || _fSales.contains(r.uid)) &&
      (_fRoutes.isEmpty || _fRoutes.contains(r.rid)) &&
      (_fCusts.isEmpty || _fCusts.contains(r.cid))).toList();

  String _viewLabel(String v) => const {
        'salesperson': 'Salesperson',
        'route': 'Route',
        'customer': 'Customer',
        'combo': 'Salesperson & Route',
        'date': 'Date',
      }[v] ?? v;

  List<_Group> _groups(List<_Row> rows) {
    final m = <String, _Group>{};
    final dfl = DateFormat('EEE, d MMM yyyy');
    for (final r in rows) {
      late String key, label;
      switch (_view) {
        case 'route':
          key = r.rid; label = _rName(r.rid);
          break;
        case 'customer':
          key = r.cid; label = r.cname;
          break;
        case 'combo':
          key = '${r.uid}|${r.rid}'; label = '${_uName(r.uid)}  ·  ${_rName(r.rid)}';
          break;
        case 'date':
          key = DateFormat('yyyy-MM-dd').format(r.d); label = dfl.format(r.d);
          break;
        default:
          key = r.uid; label = _uName(r.uid);
      }
      final g = m.putIfAbsent(key, () => _Group(key, label));
      if (_view == 'customer' && g.sub.isEmpty) g.sub = '${_rName(r.rid)} · ${_uName(r.uid)}';
      if (r.booked) { g.booked += r.amount; g.bookedN++; } else { g.field += r.amount; g.fieldN++; }
      if (r.cid != _none) g.custs.add(r.cid);
      g.rows.add(r);
    }
    var list = m.values.toList();
    if (_search.trim().isNotEmpty) {
      list = list.where((g) => matchesQuery('${g.label} ${g.sub}', _search)).toList();
    }
    int cmp(_Group a, _Group b) {
      switch (_sort) {
        case 'name': return a.label.toLowerCase().compareTo(b.label.toLowerCase());
        case 'field': return b.field.compareTo(a.field);
        case 'gap': return b.gap.abs().compareTo(a.gap.abs());
        default: return b.booked.compareTo(a.booked);
      }
    }
    if (_view == 'date') {
      list.sort((a, b) => a.key.compareTo(b.key));
    } else {
      list.sort(cmp);
    }
    return list;
  }

  // ── Range ───────────────────────────────────────────────────────────────
  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  (DateTime, DateTime) _quick(String k) {
    final t = _day(DateTime.now());
    switch (k) {
      case 'yesterday':
        final y = t.subtract(const Duration(days: 1));
        return (y, y);
      case 'week':
        return (t.subtract(Duration(days: t.weekday - 1)), t);
      case 'month':
        return (DateTime(t.year, t.month, 1), t);
      case 'lastmonth':
        return (DateTime(t.year, t.month - 1, 1), DateTime(t.year, t.month, 0));
      case 'year':
        return (DateTime(t.year, 1, 1), t);
      default:
        return (t, t);
    }
  }

  bool _isQuick(String k) {
    final r = _quick(k);
    return _day(_from) == r.$1 && _day(_to) == r.$2;
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (r == null) return;
    setState(() { _from = _day(r.start); _to = _day(r.end); });
    _load();
  }

  String get _periodLabel {
    final f = DateFormat('d MMM yyyy');
    return _day(_from) == _day(_to) ? f.format(_from) : '${f.format(_from)} – ${f.format(_to)}';
  }

  // ── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final groups = _groups(rows);
    return Container(
      color: AppTheme.background,
      child: LayoutBuilder(builder: (context, cons) {
        final narrow = cons.maxWidth < 760;
        final pad = narrow ? 12.0 : 24.0;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header(pad, narrow),
          _filterBar(pad),
          Expanded(
            child: !_loaded
                ? Center(child: _loading
                    ? const CircularProgressIndicator()
                    : const Text('Pick a period to see collections', style: TextStyle(color: AppTheme.textSecondary)))
                : Stack(children: [
                    SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(pad, 8, pad, 32),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _kpis(rows, narrow),
                        const SizedBox(height: 16),
                        if (narrow) ...[
                          _trendCard(rows),
                          const SizedBox(height: 16),
                          _modeCard(rows),
                        ] else
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(flex: 3, child: _trendCard(rows)),
                            const SizedBox(width: 16),
                            Expanded(flex: 2, child: _modeCard(rows)),
                          ]),
                        const SizedBox(height: 16),
                        _tableCard(groups, rows, narrow),
                        const SizedBox(height: 12),
                        const Text(
                          'Booked = receipts posted to customer accounts (CRV, bank, PDC, POS). Field = amounts recorded on '
                          'visits in the field app. Booked collections are credited to the salesperson and route the customer '
                          'belongs to; field collections to the salesperson who logged the visit.',
                          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, height: 1.5),
                        ),
                      ]),
                    ),
                    if (_loading)
                      const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
                  ]),
          ),
        ]);
      }),
    );
  }

  Widget _header(double pad, bool narrow) {
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      const Text('Collection Report', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
      const SizedBox(height: 2),
      Text(_orgName.isEmpty ? 'Collections from the market' : '$_orgName  ·  Collections from the market',
          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
    ]);
    final actions = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      OutlinedButton.icon(
        icon: const Icon(Icons.date_range, size: 16),
        label: Text(_periodLabel, style: const TextStyle(fontSize: 12)),
        onPressed: _loading ? null : _pickRange,
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
      ),
      IconButton(
        tooltip: 'Refresh',
        onPressed: _loading ? null : _load,
        icon: const Icon(Icons.refresh, size: 20),
      ),
      ElevatedButton.icon(
        icon: const Icon(Icons.print_outlined, size: 16),
        label: const Text('Print / PDF'),
        style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary, foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
        onPressed: _loaded && !_loading ? _print : null,
      ),
    ]);
    final chips = Wrap(spacing: 6, runSpacing: 6, children: [
      for (final q in const [
        ('Today', 'today'), ('Yesterday', 'yesterday'), ('This week', 'week'),
        ('This month', 'month'), ('Last month', 'lastmonth'), ('This year', 'year'),
      ])
        _quickChip(q.$1, q.$2),
    ]);
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, narrow ? 14 : 20, pad, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (narrow) ...[title, const SizedBox(height: 10), actions]
        else Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: title), actions]),
        const SizedBox(height: 10),
        chips,
      ]),
    );
  }

  Widget _quickChip(String label, String key) {
    final sel = _isQuick(key);
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
          color: sel ? Colors.white : AppTheme.textPrimary)),
      selected: sel,
      showCheckmark: false,
      selectedColor: AppTheme.primary,
      backgroundColor: Colors.white,
      side: BorderSide(color: sel ? AppTheme.primary : AppTheme.border),
      visualDensity: VisualDensity.compact,
      onSelected: _loading ? null : (_) {
        final r = _quick(key);
        setState(() { _from = r.$1; _to = r.$2; });
        _load();
      },
    );
  }

  // Filter options come from the loaded data plus master lists, so everything
  // that actually has collections is always pickable.
  List<_Opt> _opts(Iterable<String> ids, String Function(String) name) {
    final s = ids.toSet();
    return [for (final id in s) _Opt(id, name(id))]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }

  Widget _filterBar(double pad) {
    final salesOpts = _opts(_rows.map((r) => r.uid), _uName);
    final routeOpts = _opts({..._rows.map((r) => r.rid), ..._routeName.keys}, _rName);
    final custOpts = _opts({..._rows.map((r) => r.cid).where((c) => c != _none), ..._custName.keys},
        (id) => _custName[id] ?? '(customer)');
    final any = _fSales.isNotEmpty || _fRoutes.isNotEmpty || _fCusts.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Icon(Icons.filter_alt_outlined, size: 18, color: AppTheme.textSecondary),
          _filterBtn('Salesperson', Icons.person_outline, salesOpts, _fSales),
          _filterBtn('Route', Icons.alt_route, routeOpts, _fRoutes),
          _filterBtn('Customer', Icons.storefront_outlined, custOpts, _fCusts),
          if (any)
            TextButton.icon(
              onPressed: () => setState(() { _fSales.clear(); _fRoutes.clear(); _fCusts.clear(); }),
              icon: const Icon(Icons.close, size: 14),
              label: const Text('Clear filters', style: TextStyle(fontSize: 12)),
            ),
          Container(width: 1, height: 24, color: AppTheme.border),
          const Text('View by', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          for (final v in const ['salesperson', 'route', 'customer', 'combo', 'date'])
            ChoiceChip(
              label: Text(_viewLabel(v), style: TextStyle(fontSize: 12,
                  color: _view == v ? AppTheme.primaryDark : AppTheme.textPrimary,
                  fontWeight: _view == v ? FontWeight.w700 : FontWeight.w500)),
              selected: _view == v,
              showCheckmark: false,
              selectedColor: AppTheme.primary.withValues(alpha: 0.12),
              backgroundColor: Colors.white,
              side: BorderSide(color: _view == v ? AppTheme.primary : AppTheme.border),
              visualDensity: VisualDensity.compact,
              onSelected: (_) => setState(() => _view = v),
            ),
        ]),
      ),
    );
  }

  Widget _filterBtn(String label, IconData icon, List<_Opt> opts, Set<String> sel) {
    final m = {for (final o in opts) o.id: o.label};
    final text = sel.isEmpty
        ? 'All'
        : sel.length == 1 ? (m[sel.first] ?? '1 selected') : '${sel.length} selected';
    final active = sel.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: (_loadingMeta && opts.isEmpty) ? null : () => _openPicker(label, opts, sel),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary.withValues(alpha: 0.08) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? AppTheme.primary : AppTheme.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: active ? AppTheme.primary : AppTheme.textSecondary),
          const SizedBox(width: 6),
          Text('$label: ', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(text, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: active ? AppTheme.primaryDark : AppTheme.textPrimary)),
          ),
          const Icon(Icons.arrow_drop_down, size: 18, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }

  Future<void> _openPicker(String title, List<_Opt> opts, Set<String> sel) async {
    final work = Set<String>.from(sel);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        final shown = opts.where((o) => matchesQuery(o.label, ctrl.text)).take(400).toList();
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
                    hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
                onChanged: (_) => setDlg(() {}),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Text(work.isEmpty ? 'All included' : '${work.length} selected',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                const Spacer(),
                TextButton(onPressed: work.isEmpty ? null : () => setDlg(() => work.clear()),
                    child: const Text('Clear', style: TextStyle(fontSize: 12))),
                TextButton(onPressed: shown.isEmpty ? null : () => setDlg(() => work.addAll(shown.map((o) => o.id))),
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
                        }),
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
    if (ok == true && mounted) setState(() { sel..clear()..addAll(work); });
  }

  // ── KPIs ────────────────────────────────────────────────────────────────
  Map<String, num> _totals(List<_Row> rows) {
    double b = 0, f = 0;
    final custB = <String>{}, custF = <String>{};
    var nB = 0, nF = 0;
    for (final r in rows) {
      if (r.booked) { b += r.amount; nB++; if (r.cid != _none) custB.add(r.cid); }
      else { f += r.amount; nF++; if (r.cid != _none) custF.add(r.cid); }
    }
    final days = _to.difference(_from).inDays + 1;
    return {
      'booked': b, 'field': f, 'gap': f - b, 'nB': nB, 'nF': nF,
      'custB': custB.length, 'custF': custF.length,
      'avg': custB.isEmpty ? 0 : b / custB.length,
      'perDay': days <= 0 ? 0 : b / days,
    };
  }

  Widget _kpis(List<_Row> rows, bool narrow) {
    final t = _totals(rows);
    final gap = t['gap']!.toDouble();
    final tiles = <Widget>[
      _kpi('Booked collections', money(t['booked']), '${t['nB']} receipts  ·  ${t['custB']} customers',
          Icons.account_balance_wallet_outlined, _cBooked, hero: true),
      _kpi('Field reported', money(t['field']), '${t['nF']} visits  ·  ${t['custF']} customers',
          Icons.directions_walk, _cField),
      _kpi('Gap (field − booked)', gap == 0 ? '0' : (gap > 0 ? '+${money(gap)}' : '(${money(-gap)})'),
          gap > 0.5 ? 'Reported in field, not yet booked' : gap < -0.5 ? 'Booked beyond field records' : 'Fully reconciled',
          Icons.compare_arrows, gap.abs() < 0.5 ? AppTheme.success : (gap > 0 ? AppTheme.danger : AppTheme.textSecondary)),
      _kpi('Avg per paying customer', money(t['avg']), 'Daily average ${money(t['perDay'])}',
          Icons.insights_outlined, const Color(0xFF0F766E)),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth < 560 ? 1 : c.maxWidth < 980 ? 2 : 4;
      final w = (c.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(spacing: 12, runSpacing: 12, children: [for (final tile in tiles) SizedBox(width: w, child: tile)]);
    });
  }

  Widget _kpi(String label, String value, String sub, IconData icon, Color color, {bool hero = false}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: hero ? _cBooked : Colors.white,
        gradient: hero
            ? const LinearGradient(colors: [Color(0xFF1E3A8A), Color(0xFF2F6FED)], begin: Alignment.topLeft, end: Alignment.bottomRight)
            : null,
        borderRadius: BorderRadius.circular(12),
        border: hero ? null : Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: hero ? Colors.white.withValues(alpha: 0.16) : color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: hero ? Colors.white : color),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: TextStyle(fontSize: 10, letterSpacing: 0.6, fontWeight: FontWeight.w700,
              color: hero ? Colors.white70 : AppTheme.textSecondary)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800,
                color: hero ? Colors.white : color, fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 2),
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: hero ? Colors.white70 : AppTheme.textSecondary)),
        ])),
      ]),
    );
  }

  // ── Trend ───────────────────────────────────────────────────────────────
  /// Buckets for the trend chart: daily up to 45 days, else monthly.
  List<(String, double, double)> _trend(List<_Row> rows) {
    final days = _to.difference(_from).inDays + 1;
    final monthly = days > 45;
    final b = <String, double>{}, f = <String, double>{};
    final keys = <String>[];
    if (monthly) {
      var m = DateTime(_from.year, _from.month, 1);
      while (!m.isAfter(_to)) { keys.add(DateFormat('yyyy-MM').format(m)); m = DateTime(m.year, m.month + 1, 1); }
    } else {
      for (var i = 0; i < days; i++) { keys.add(DateFormat('yyyy-MM-dd').format(_from.add(Duration(days: i)))); }
    }
    for (final r in rows) {
      final k = DateFormat(monthly ? 'yyyy-MM' : 'yyyy-MM-dd').format(r.d);
      if (r.booked) { b[k] = (b[k] ?? 0) + r.amount; } else { f[k] = (f[k] ?? 0) + r.amount; }
    }
    return [
      for (final k in keys)
        (monthly ? DateFormat('MMM yy').format(DateTime.parse('$k-01')) : DateFormat('d MMM').format(DateTime.parse(k)),
         b[k] ?? 0, f[k] ?? 0)
    ];
  }

  Widget _card(String title, String? sub, Widget child, {Widget? trailing, bool flush = false}) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                if (sub != null) Text(sub, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ])),
              if (trailing != null) trailing,
            ]),
          ),
          const Divider(height: 1),
          if (flush)
            ClipRRect(borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)), child: child)
          else
            Padding(padding: const EdgeInsets.all(16), child: child),
        ]),
      );

  Widget _legendDot(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 5),
        Text(t, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]);

  Widget _trendCard(List<_Row> rows) {
    final data = _trend(rows);
    final maxV = data.fold<double>(0, (m, e) => math.max(m, math.max(e.$2, e.$3)));
    final monthly = _to.difference(_from).inDays + 1 > 45;
    return _card(
      'Collection trend',
      monthly ? 'Monthly' : 'Daily',
      SizedBox(
        height: 180,
        child: data.isEmpty || maxV <= 0
            ? const Center(child: Text('No collections in this period', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)))
            : LayoutBuilder(builder: (context, c) {
                final n = data.length;
                final slot = (c.maxWidth - 1) / n;
                final barW = math.max(1.5, math.min(14.0, slot * 0.36));
                final labelEvery = math.max(1, (n / math.max(1, c.maxWidth / 56)).ceil());
                return Column(children: [
                  Expanded(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      for (final e in data)
                        SizedBox(
                          width: slot,
                          child: Tooltip(
                            message: '${e.$1}\nBooked ${money(e.$2)}\nField ${money(e.$3)}',
                            child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                              _bar(e.$2 / maxV, barW, _cBooked),
                              SizedBox(width: math.min(2.0, barW / 4)),
                              _bar(e.$3 / maxV, barW, _cField),
                            ]),
                          ),
                        ),
                    ]),
                  ),
                  Container(height: 1, color: AppTheme.border),
                  const SizedBox(height: 4),
                  Row(children: [
                    for (var i = 0; i < n; i++)
                      SizedBox(
                        width: slot,
                        child: i % labelEvery == 0
                            ? Text(data[i].$1, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.clip,
                                style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary))
                            : const SizedBox.shrink(),
                      ),
                  ]),
                ]);
              }),
      ),
      trailing: Wrap(spacing: 12, children: [_legendDot(_cBooked, 'Booked'), _legendDot(_cField, 'Field')]),
    );
  }

  Widget _bar(double frac, double w, Color c) => LayoutBuilder(builder: (context, cons) {
        final h = (cons.maxHeight.isFinite ? cons.maxHeight : 140) * frac.clamp(0.0, 1.0);
        return Container(
          width: w,
          height: frac > 0 ? math.max(2.0, h) : 0.0,
          decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
        );
      });

  // ── Mode mix ────────────────────────────────────────────────────────────
  Map<String, double> _modeTotals(List<_Row> rows) {
    final m = <String, double>{};
    for (final r in rows.where((r) => r.booked)) {
      final k = _modes.contains(r.mode) ? r.mode : 'Receipt';
      m[k] = (m[k] ?? 0) + r.amount;
    }
    return m;
  }

  String _modeLabel(String m) => const {
        'CRV': 'Cash receipts', 'BRV': 'Bank receipts', 'PDC': 'Cheques (PDC)', 'POS': 'POS counter', 'Receipt': 'Other receipts',
      }[m] ?? m;

  Widget _modeCard(List<_Row> rows) {
    final m = _modeTotals(rows);
    final total = m.values.fold<double>(0, (a, b) => a + b);
    return _card(
      'How it was received',
      'Booked collections by mode',
      total <= 0
          ? const SizedBox(height: 180, child: Center(child: Text('No booked receipts', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12))))
          : Column(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 14,
                  child: Row(children: [
                    for (final k in _modes)
                      if ((m[k] ?? 0) > 0)
                        Expanded(flex: math.max(1, ((m[k]! / total) * 1000).round()), child: Container(color: _modeColors[k])),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              for (final k in _modes)
                if ((m[k] ?? 0) != 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: _modeColors[k], borderRadius: BorderRadius.circular(3))),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_modeLabel(k), style: const TextStyle(fontSize: 12.5))),
                      Text(money(m[k]), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                      SizedBox(
                        width: 48,
                        child: Text('${(m[k]! / total * 100).toStringAsFixed(0)}%', textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                      ),
                    ]),
                  ),
            ]),
    );
  }

  // ── Main table ──────────────────────────────────────────────────────────
  Widget _tableCard(List<_Group> groups, List<_Row> rows, bool narrow) {
    final t = _totals(rows);
    final totalB = t['booked']!.toDouble();
    final maxB = groups.fold<double>(0, (m, g) => math.max(m, g.booked));
    final sortCtl = _view == 'date'
        ? null
        : PopupMenuButton<String>(
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'booked', child: Text('Highest booked')),
              PopupMenuItem(value: 'field', child: Text('Highest field')),
              PopupMenuItem(value: 'gap', child: Text('Largest gap')),
              PopupMenuItem(value: 'name', child: Text('Name A–Z')),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.sort, size: 18, color: AppTheme.textSecondary),
                SizedBox(width: 4),
                Text('Sort', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ]),
            ),
          );
    final search = SizedBox(
      width: narrow ? 150 : 220,
      height: 34,
      child: TextField(
        onChanged: (v) => setState(() => _search = v),
        style: const TextStyle(fontSize: 12.5),
        decoration: InputDecoration(
          hintText: 'Search ${_viewLabel(_view).toLowerCase()}…',
          prefixIcon: const Icon(Icons.search, size: 16),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
    const numStyle = TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]);
    const head = TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppTheme.textSecondary, letterSpacing: 0.5);
    final minW = narrow ? 720.0 : 0.0;

    Widget rowW(_Group g, int i) {
      final share = totalB <= 0 ? 0.0 : g.booked / totalB;
      final gap = g.gap;
      return InkWell(
        onTap: () => _drill(g),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: i.isOdd ? const Color(0xFFFAFBFD) : Colors.white,
            border: const Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
          ),
          child: Row(children: [
            SizedBox(width: 30, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            Expanded(
              flex: 5,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(g.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                if (g.sub.isNotEmpty)
                  Text(g.sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ]),
            ),
            Expanded(flex: 2, child: Text(money(g.booked), textAlign: TextAlign.right,
                style: numStyle.copyWith(fontWeight: FontWeight.w700, color: _cBooked))),
            Expanded(flex: 2, child: Text(money(g.field), textAlign: TextAlign.right, style: numStyle)),
            Expanded(flex: 2, child: Text(
                gap.abs() < 0.5 ? '—' : (gap > 0 ? '+${money(gap)}' : '(${money(-gap)})'),
                textAlign: TextAlign.right,
                style: numStyle.copyWith(
                    color: gap.abs() < 0.5 ? AppTheme.textSecondary : (gap > 0 ? AppTheme.danger : AppTheme.textSecondary),
                    fontWeight: gap > 0.5 ? FontWeight.w700 : FontWeight.w400))),
            Expanded(flex: 1, child: Text('${g.custs.length}', textAlign: TextAlign.right, style: numStyle)),
            const SizedBox(width: 16),
            Expanded(
              flex: 3,
              child: Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxB <= 0 ? 0 : g.booked / maxB,
                      minHeight: 7,
                      backgroundColor: const Color(0xFFEFF3F8),
                      valueColor: const AlwaysStoppedAnimation(_cBooked),
                    ),
                  ),
                ),
                SizedBox(width: 44, child: Text('${(share * 100).toStringAsFixed(1)}%', textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
              ]),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, size: 16, color: AppTheme.textSecondary),
          ]),
        ),
      );
    }

    final table = Column(children: [
      Container(
        color: const Color(0xFFF8FAFC),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const SizedBox(width: 30, child: Text('#', style: head)),
          Expanded(flex: 5, child: Text(_viewLabel(_view).toUpperCase(), style: head)),
          const Expanded(flex: 2, child: Text('BOOKED', textAlign: TextAlign.right, style: head)),
          const Expanded(flex: 2, child: Text('FIELD', textAlign: TextAlign.right, style: head)),
          const Expanded(flex: 2, child: Text('GAP', textAlign: TextAlign.right, style: head)),
          const Expanded(flex: 1, child: Text('CUST.', textAlign: TextAlign.right, style: head)),
          const SizedBox(width: 16),
          const Expanded(flex: 3, child: Text('SHARE OF BOOKED', style: head)),
          const SizedBox(width: 22),
        ]),
      ),
      if (groups.isEmpty)
        const Padding(
          padding: EdgeInsets.all(28),
          child: Text('No collections match these filters.', style: TextStyle(color: AppTheme.textSecondary)),
        )
      else
        for (var i = 0; i < groups.length; i++) rowW(groups[i], i),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(color: Color(0xFFEEF2FF), border: Border(top: BorderSide(color: Color(0xFFC7D2FE), width: 1.5))),
        child: Row(children: [
          const SizedBox(width: 30),
          Expanded(flex: 5, child: Text('Total  ·  ${groups.length} ${_viewLabel(_view).toLowerCase()}${groups.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800))),
          Expanded(flex: 2, child: Text(money(totalB), textAlign: TextAlign.right,
              style: numStyle.copyWith(fontWeight: FontWeight.w800, color: _cBooked))),
          Expanded(flex: 2, child: Text(money(t['field']), textAlign: TextAlign.right, style: numStyle.copyWith(fontWeight: FontWeight.w800))),
          Expanded(flex: 2, child: Text(
              t['gap']!.abs() < 0.5 ? '—' : (t['gap']! > 0 ? '+${money(t['gap'])}' : '(${money(-t['gap']!)})'),
              textAlign: TextAlign.right, style: numStyle.copyWith(fontWeight: FontWeight.w800))),
          Expanded(flex: 1, child: Text('${rows.map((r) => r.cid).where((c) => c != _none).toSet().length}',
              textAlign: TextAlign.right, style: numStyle.copyWith(fontWeight: FontWeight.w800))),
          const SizedBox(width: 16),
          const Expanded(flex: 3, child: Text('100%', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
          const SizedBox(width: 22),
        ]),
      ),
    ]);

    return _card(
      'Collections by ${_viewLabel(_view).toLowerCase()}',
      'Tap a row for the receipts behind it',
      Padding(
        padding: const EdgeInsets.all(0),
        child: narrow
            ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: minW, child: table))
            : table,
      ),
      trailing: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [search, if (sortCtl != null) sortCtl]),
      flush: true,
    );
  }

  // ── Drill-down ──────────────────────────────────────────────────────────
  void _drill(_Group g) {
    final rows = [...g.rows]..sort((a, b) {
        final c = a.d.compareTo(b.d);
        return c != 0 ? c : a.cname.compareTo(b.cname);
      });
    final df = DateFormat('d MMM yyyy');
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820, maxHeight: 640),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 8, 6),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  Text('$_periodLabel  ·  Booked ${money(g.booked)}  ·  Field ${money(g.field)}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ])),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                    child: Row(children: [
                      SizedBox(width: 92, child: Text(df.format(r.d), style: const TextStyle(fontSize: 12))),
                      Container(
                        width: 58,
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: (r.booked ? (_modeColors[r.mode] ?? _cBooked) : _cField).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(r.booked ? r.mode : 'Field', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700,
                            color: r.booked ? (_modeColors[r.mode] ?? _cBooked) : const Color(0xFFB45309))),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(r.cname, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        Text('${_uName(r.uid)} · ${_rName(r.rid)}${r.ref.isEmpty ? '' : ' · ${r.ref}'}',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      ])),
                      Text(r.amount < 0 ? '(${money(-r.amount)})' : money(r.amount),
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                              color: r.booked ? _cBooked : const Color(0xFFB45309),
                              fontFeatures: const [FontFeature.tabularFigures()])),
                    ]),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Print ───────────────────────────────────────────────────────────────
  String _esc(String s) => s
      .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  String _filterSummary() {
    String part(String label, Set<String> sel, String Function(String) name) {
      if (sel.isEmpty) return '';
      final names = sel.map(name).toList()..sort();
      final shown = names.length > 4 ? '${names.take(4).join(', ')} +${names.length - 4} more' : names.join(', ');
      return '<span><b>$label:</b> ${_esc(shown)}</span>';
    }
    final parts = [
      part('Salesperson', _fSales, _uName),
      part('Route', _fRoutes, _rName),
      part('Customer', _fCusts, (id) => _custName[id] ?? '(customer)'),
    ].where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? '<span>All salespeople, routes and customers</span>' : parts.join('');
  }

  String _trendSvg(List<_Row> rows) {
    final data = _trend(rows);
    final maxV = data.fold<double>(0, (m, e) => math.max(m, math.max(e.$2, e.$3)));
    if (data.isEmpty || maxV <= 0) return '';
    const w = 700.0, h = 150.0, top = 8.0, bottom = 22.0;
    final slot = w / data.length;
    final bw = math.max(1.2, math.min(12.0, slot * 0.36));
    final every = math.max(1, (data.length / 14).ceil());
    final b = StringBuffer('<svg viewBox="0 0 $w $h" width="100%" height="$h" xmlns="http://www.w3.org/2000/svg">');
    for (var g = 0; g <= 4; g++) {
      final y = top + (h - top - bottom) * g / 4;
      b.write('<line x1="0" x2="$w" y1="$y" y2="$y" stroke="#eef1f6" stroke-width="1"/>');
    }
    for (var i = 0; i < data.length; i++) {
      final e = data[i];
      final cx = slot * i + slot / 2;
      final ch = h - top - bottom;
      final hb = ch * e.$2 / maxV, hf = ch * e.$3 / maxV;
      if (e.$2 > 0) b.write('<rect x="${(cx - bw - 0.5).toStringAsFixed(1)}" y="${(h - bottom - hb).toStringAsFixed(1)}" width="${bw.toStringAsFixed(1)}" height="${hb.toStringAsFixed(1)}" rx="1.5" fill="#1e40af"/>');
      if (e.$3 > 0) b.write('<rect x="${(cx + 0.5).toStringAsFixed(1)}" y="${(h - bottom - hf).toStringAsFixed(1)}" width="${bw.toStringAsFixed(1)}" height="${hf.toStringAsFixed(1)}" rx="1.5" fill="#f59e0b"/>');
      if (i % every == 0) {
        b.write('<text x="${cx.toStringAsFixed(1)}" y="${h - 6}" font-size="8.5" text-anchor="middle" fill="#64748b">${_esc(e.$1)}</text>');
      }
    }
    b.write('<line x1="0" x2="$w" y1="${h - bottom}" y2="${h - bottom}" stroke="#cbd5e1" stroke-width="1"/></svg>');
    return b.toString();
  }

  void _print() {
    final rows = _filtered;
    final groups = _groups(rows);
    final t = _totals(rows);
    final totalB = t['booked']!.toDouble();
    final gap = t['gap']!.toDouble();
    final maxB = groups.fold<double>(0, (m, g) => math.max(m, g.booked));
    final modes = _modeTotals(rows);
    final modeTotal = modes.values.fold<double>(0, (a, b) => a + b);
    final user = ref.read(currentUserProvider);
    final gen = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    String gapTxt(double v) => v.abs() < 0.5 ? '—' : (v > 0 ? '+${money(v)}' : '(${money(-v)})');

    final body = StringBuffer();
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      final share = totalB <= 0 ? 0.0 : g.booked / totalB * 100;
      final barPct = maxB <= 0 ? 0 : (g.booked / maxB * 100);
      body.write('<tr>'
          '<td class="idx">${i + 1}</td>'
          '<td><div class="nm">${_esc(g.label)}</div>${g.sub.isEmpty ? '' : '<div class="sub">${_esc(g.sub)}</div>'}</td>'
          '<td class="num strong">${money(g.booked)}</td>'
          '<td class="num">${money(g.field)}</td>'
          '<td class="num ${g.gap > 0.5 ? 'warn' : 'muted'}">${gapTxt(g.gap)}</td>'
          '<td class="num">${g.custs.length}</td>'
          '<td class="share"><div class="bar"><span style="width:${barPct.toStringAsFixed(1)}%"></span></div>'
          '<em>${share.toStringAsFixed(1)}%</em></td>'
          '</tr>');
    }

    final seg = StringBuffer();
    for (final k in _modes) {
      final v = modes[k] ?? 0;
      if (v <= 0 || modeTotal <= 0) continue;
      seg.write('<span style="width:${(v / modeTotal * 100).toStringAsFixed(2)}%;background:${_modeHex[k]}"></span>');
    }
    final modeHtml = modeTotal > 0
        ? '<div class="stack">$seg</div><table class="mode">${_modeRowsHtml(modes, modeTotal)}</table>'
        : '';

    final doc = '''<!doctype html><html><head><meta charset="utf-8"><title>Collection Report — ${_esc(_periodLabel)}</title>
<style>
@page { size: A4 portrait; margin: 14mm 12mm 16mm; }
* { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-family: -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; color: #0f172a; margin: 0; font-size: 11px; }
.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
.strong { font-weight: 700; }
.muted { color: #94a3b8; }
.warn { color: #b91c1c; font-weight: 700; }
.band { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 3px solid #1e3a8a; padding-bottom: 10px; }
.org { font-size: 11px; letter-spacing: 1.6px; text-transform: uppercase; color: #475569; font-weight: 700; }
h1 { font-size: 24px; margin: 2px 0 0; letter-spacing: -0.4px; color: #1e3a8a; }
.period { text-align: right; }
.period .lbl { font-size: 9px; letter-spacing: 1.2px; text-transform: uppercase; color: #64748b; }
.period .val { font-size: 14px; font-weight: 800; }
.filters { margin: 8px 0 14px; font-size: 10px; color: #475569; display: flex; flex-wrap: wrap; gap: 4px 16px; }
.filters b { color: #0f172a; }
.kpis { display: grid; grid-template-columns: 1.3fr 1fr 1fr 1fr; gap: 8px; margin-bottom: 14px; }
.kpi { border: 1px solid #e2e8f0; border-radius: 8px; padding: 10px 12px; }
.kpi.hero { background: linear-gradient(135deg, #1e3a8a, #2f6fed); color: #fff; border: 0; }
.kpi .l { font-size: 8.5px; letter-spacing: 1px; text-transform: uppercase; font-weight: 700; color: #64748b; }
.kpi.hero .l, .kpi.hero .s { color: rgba(255,255,255,.78); }
.kpi .v { font-size: 18px; font-weight: 800; margin: 3px 0 2px; font-variant-numeric: tabular-nums; }
.kpi .s { font-size: 9px; color: #64748b; }
.row2 { display: grid; grid-template-columns: 1.7fr 1fr; gap: 10px; margin-bottom: 14px; }
.panel { border: 1px solid #e2e8f0; border-radius: 8px; padding: 10px 12px; break-inside: avoid; }
.panel h3 { margin: 0 0 6px; font-size: 11px; letter-spacing: .4px; }
.legend { font-size: 9px; color: #64748b; float: right; }
.legend i, .mode i { display: inline-block; width: 8px; height: 8px; border-radius: 2px; margin: 0 4px 0 10px; vertical-align: middle; }
.mode i { margin-left: 0; }
.stack { display: flex; height: 10px; border-radius: 5px; overflow: hidden; margin: 6px 0 8px; background: #eef1f6; }
.stack span { display: block; height: 100%; }
table { width: 100%; border-collapse: collapse; }
table.mode td { padding: 3px 0; font-size: 10.5px; }
h2 { font-size: 13px; margin: 0 0 6px; color: #1e3a8a; }
table.main thead { display: table-header-group; }
table.main th { font-size: 8.5px; letter-spacing: .8px; text-transform: uppercase; color: #475569; text-align: left;
  border-bottom: 1.5px solid #1e3a8a; padding: 6px 6px; background: #f1f5f9; }
table.main th.num { text-align: right; }
table.main td { padding: 6px 6px; border-bottom: 1px solid #eef1f6; vertical-align: middle; }
table.main tr { break-inside: avoid; }
table.main tbody tr:nth-child(even) td { background: #fafbfd; }
.idx { color: #94a3b8; width: 22px; }
.nm { font-weight: 600; }
.sub { font-size: 9px; color: #64748b; }
.share { width: 120px; }
.share .bar { display: inline-block; width: 78px; height: 6px; background: #eef1f6; border-radius: 3px; vertical-align: middle; overflow: hidden; }
.share .bar span { display: block; height: 100%; background: #1e40af; }
.share em { font-style: normal; font-size: 9px; color: #64748b; margin-left: 6px; }
tfoot td { padding: 8px 6px; font-weight: 800; background: #eef2ff; border-top: 2px solid #1e3a8a; }
.notes { margin-top: 12px; font-size: 9px; color: #64748b; line-height: 1.5; }
.sign { display: flex; justify-content: space-between; gap: 40px; margin-top: 42px; break-inside: avoid; }
.sign div { flex: 1; border-top: 1px solid #94a3b8; padding-top: 4px; font-size: 9.5px; color: #475569; text-align: center; }
.foot { margin-top: 18px; font-size: 8.5px; color: #94a3b8; display: flex; justify-content: space-between; }
</style></head><body>
<div class="band">
  <div><div class="org">${_esc(_orgName)}</div><h1>Collection Report</h1></div>
  <div class="period"><div class="lbl">Period</div><div class="val">${_esc(_periodLabel)}</div></div>
</div>
<div class="filters"><span><b>View:</b> by ${_esc(_viewLabel(_view).toLowerCase())}</span>${_filterSummary()}</div>
<div class="kpis">
  <div class="kpi hero"><div class="l">Booked collections</div><div class="v">Rs ${money(totalB)}</div><div class="s">${t['nB']} receipts · ${t['custB']} customers</div></div>
  <div class="kpi"><div class="l">Field reported</div><div class="v" style="color:#b45309">${money(t['field'])}</div><div class="s">${t['nF']} visits · ${t['custF']} customers</div></div>
  <div class="kpi"><div class="l">Gap (field − booked)</div><div class="v" style="color:${gap > 0.5 ? '#b91c1c' : gap.abs() < 0.5 ? '#047857' : '#475569'}">${gapTxt(gap)}</div>
    <div class="s">${gap > 0.5 ? 'Reported in field, not yet booked' : gap < -0.5 ? 'Booked beyond field records' : 'Fully reconciled'}</div></div>
  <div class="kpi"><div class="l">Avg per paying customer</div><div class="v" style="color:#0f766e">${money(t['avg'])}</div><div class="s">Daily avg ${money(t['perDay'])}</div></div>
</div>
<div class="row2">
  <div class="panel"><h3>Collection trend <span class="legend"><i style="background:#1e40af"></i>Booked<i style="background:#f59e0b"></i>Field</span></h3>${_trendSvg(rows)}</div>
  <div class="panel"><h3>How it was received</h3>${modeTotal > 0 ? modeHtml : '<div class="muted">No booked receipts</div>'}</div>
</div>
<h2>Collections by ${_esc(_viewLabel(_view).toLowerCase())}</h2>
<table class="main">
  <thead><tr><th>#</th><th>${_esc(_viewLabel(_view))}</th><th class="num">Booked</th><th class="num">Field</th><th class="num">Gap</th><th class="num">Cust.</th><th>Share of booked</th></tr></thead>
  <tbody>${groups.isEmpty ? '<tr><td colspan="7" class="muted">No collections match these filters.</td></tr>' : body.toString()}</tbody>
  <tfoot><tr><td></td><td>Total · ${groups.length} ${_esc(_viewLabel(_view).toLowerCase())}${groups.length == 1 ? '' : 's'}</td>
    <td class="num">${money(totalB)}</td><td class="num">${money(t['field'])}</td><td class="num">${gapTxt(gap)}</td>
    <td class="num">${rows.map((r) => r.cid).where((c) => c != _none).toSet().length}</td><td>100%</td></tr></tfoot>
</table>
<div class="notes"><b>Basis.</b> Booked = receipts posted to customer accounts (cash, bank, PDC, POS), net of voids. Field = amounts recorded on visits in the field app.
Booked collections are credited to the salesperson and route each customer belongs to; field collections to the salesperson who logged the visit.
A positive gap means cash was reported in the market but has not been booked yet.</div>
<div class="sign"><div>Prepared by${(user?.name ?? '').trim().isEmpty ? '' : ' — ${_esc(user!.name)}'}</div><div>Reviewed by</div><div>Approved by</div></div>
<div class="foot"><span>Opstation ERP · Collection Report</span><span>Printed $gen</span></div>
</body></html>''';

    try {
      html.document.getElementById('ops-print-frame')?.remove();
      final frame = html.IFrameElement()
        ..id = 'ops-print-frame'
        ..style.position = 'fixed'
        ..style.left = '-9999px'
        ..style.width = '0'
        ..style.height = '0'
        ..style.border = '0';
      frame.srcdoc = doc.replaceFirst('</body>',
          '<script>window.onload=function(){setTimeout(function(){try{window.focus();window.print();}catch(e){}},350);};</script></body>');
      html.document.body!.append(frame);
    } catch (_) {
      final blob = html.Blob([doc], 'text/html;charset=utf-8');
      html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
    }
  }

  String _modeRowsHtml(Map<String, double> modes, double total) {
    final b = StringBuffer();
    for (final k in _modes) {
      final v = modes[k] ?? 0;
      if (v == 0) continue;
      final c = _modeHex[k];
      b.write('<tr><td><i style="background:$c"></i>${_esc(_modeLabel(k))}</td>'
          '<td class="num strong">${money(v)}</td><td class="num muted" style="width:40px">${(v / total * 100).toStringAsFixed(0)}%</td></tr>');
    }
    return b.toString();
  }
}
