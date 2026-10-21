import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';
import '../services/batch_tracking.dart';

/// Inventory → Batch Tracking. One place for batches (from GRNs and
/// production), unit serials and cartons, plus a trace search: type a serial,
/// carton or batch / GRN number to see where it came from and where it went.
class ErpBatchTrackingScreen extends ConsumerStatefulWidget {
  const ErpBatchTrackingScreen({super.key, this.query});
  final String? query;
  @override
  ConsumerState<ErpBatchTrackingScreen> createState() => _State();
}

class _State extends ConsumerState<ErpBatchTrackingScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  SupabaseClient get _db => Supabase.instance.client;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  bool? _on; // null = checking
  final Map<String, String> _prodName = {};
  final Map<String, String> _branchName = {};

  // Trace
  final _traceCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  bool _tracing = false;
  String? _traceMsg;
  List<Widget> _traceOut = [];

  // Lists
  bool _loading = true;
  List<Map<String, dynamic>> _batches = [];
  List<Map<String, dynamic>> _serials = [];
  List<Map<String, dynamic>> _cartons = [];
  String _search = '';
  bool _withStock = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if ((widget.query ?? '').trim().isNotEmpty) _traceCtrl.text = widget.query!.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _tabs.dispose();
    _traceCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final on = await BatchTracking.isOn(_orgId);
    if (!mounted) return;
    setState(() => _on = on);
    if (!on) return;
    try {
      final b = await _db.from('branches').select('id, name').eq('org_id', _orgId ?? '');
      for (final r in b as List) { _branchName[r['id'] as String] = '${r['name'] ?? ''}'; }
    } catch (_) {}
    await _loadLists();
    if (_traceCtrl.text.trim().isNotEmpty) _trace();
  }

  Future<void> _names(Iterable<Object?> ids) async {
    final need = ids.whereType<String>().where((id) => !_prodName.containsKey(id)).toSet().toList();
    for (var i = 0; i < need.length; i += 200) {
      try {
        final r = await _db.from('products').select('id, name, sku')
            .inFilter('id', need.sublist(i, (i + 200).clamp(0, need.length)));
        for (final p in r as List) {
          final sku = '${p['sku'] ?? ''}'.trim();
          _prodName[p['id'] as String] = '${p['name'] ?? ''}${sku.isEmpty ? '' : '  ($sku)'}';
        }
      } catch (_) {}
    }
  }

  Future<void> _loadLists() async {
    final org = _orgId;
    if (org == null) return;
    setState(() => _loading = true);
    try {
      final res = await Future.wait<dynamic>([
        _db.from('stock_batches')
            .select('id, product_id, branch_id, batch_no, source_type, source_id, source_number, supplier_id, received_on, warranty_until, qty_in, qty_used, status')
            .eq('org_id', org).neq('status', 'void')
            .order('received_on', ascending: false).limit(2000),
        _db.from('product_serials')
            .select('id, serial, product_id, carton_id, source_type, source_id, source_number, branch_id, produced_on, warranty_months, status, dispatched_on')
            .eq('org_id', org).order('created_at', ascending: false).order('serial', ascending: false).limit(2000),
        _db.from('product_cartons')
            .select('id, carton_no, product_id, source_type, source_id, source_number, branch_id, qty, status, created_at')
            .eq('org_id', org).order('created_at', ascending: false).order('carton_no', ascending: false).limit(1000),
      ]);
      final batches = List<Map<String, dynamic>>.from(res[0] as List);
      final serials = List<Map<String, dynamic>>.from(res[1] as List);
      final cartons = List<Map<String, dynamic>>.from(res[2] as List);
      await BatchTracking.attachSuppliers(batches);
      await _names([...batches.map((e) => e['product_id']), ...serials.map((e) => e['product_id']), ...cartons.map((e) => e['product_id'])]);
      final cartonNo = {for (final c in cartons) c['id']: c['carton_no']};
      for (final s in serials) { s['carton_no'] = cartonNo[s['carton_id']]; }
      if (!mounted) return;
      setState(() { _batches = batches; _serials = serials; _cartons = cartons; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(friendlyError('Could not load batch tracking', e));
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  String _p(Object? id) => _prodName['$id'] ?? '-';
  String _src(Map r) {
    switch ('${r['source_type']}') {
      case 'grn': return 'GRN';
      case 'job_run': return 'Job batch';
      case 'production': return 'Production';
      default: return '${r['source_type'] ?? ''}';
    }
  }

  void _openSource(Map r) {
    final t = '${r['source_type']}';
    if (t == 'grn') context.go('/erp/grn?focus=${r['source_id']}');
    if (t == 'production') context.go('/manufacturing/production-voucher?focus=${r['source_id']}');
  }

  Color _warrantyColor(Object? until) {
    final d = DateTime.tryParse('${until ?? ''}');
    if (d == null) return AppTheme.textSecondary;
    final days = d.difference(DateTime.now()).inDays;
    if (days < 0) return AppTheme.danger;
    if (days <= 60) return AppTheme.warning;
    return AppTheme.success;
  }

  // ── Trace ───────────────────────────────────────────────────────────────
  Future<void> _trace([String? q]) async {
    final org = _orgId;
    final text = (q ?? _traceCtrl.text).trim();
    if (org == null || text.isEmpty) return;
    if (q != null) _traceCtrl.text = q;
    _tabs.animateTo(0);
    setState(() { _tracing = true; _traceMsg = null; _traceOut = []; });
    final out = <Widget>[];
    try {
      final safe = text.replaceAll(RegExp(r'\s+'), '%').replaceAll(RegExp(r'[^A-Za-z0-9%./\-]'), '');
      final like = '%$safe%';
      // Serial
      final ser = await _db.from('product_serials').select().eq('org_id', org).ilike('serial', text).limit(5);
      for (final s in ser as List) { out.add(await _serialCard(Map<String, dynamic>.from(s))); }
      // Carton
      final ct = await _db.from('product_cartons').select().eq('org_id', org).ilike('carton_no', text).limit(5);
      for (final c in ct as List) { out.add(await _cartonCard(Map<String, dynamic>.from(c))); }
      // Batch / GRN / production number
      if (out.isEmpty) {
        final b = await _db.from('stock_batches').select().eq('org_id', org)
            .or('batch_no.ilike.$like,source_number.ilike.$like').order('received_on', ascending: false).limit(30);
        final list = List<Map<String, dynamic>>.from(b as List);
        await BatchTracking.attachSuppliers(list);
        for (final x in list) { out.add(await _batchCard(x)); }
      }
      // Partial serial match
      if (out.isEmpty) {
        final ser2 = await _db.from('product_serials').select().eq('org_id', org).ilike('serial', like).limit(10);
        for (final s in ser2 as List) { out.add(await _serialCard(Map<String, dynamic>.from(s))); }
      }
      if (!mounted) return;
      setState(() {
        _tracing = false;
        _traceOut = out;
        _traceMsg = out.isEmpty ? 'Nothing found for "$text". Try a full serial, carton number, batch or GRN number.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _tracing = false; _traceMsg = friendlyError('The search did not work', e); });
    }
  }

  Future<List<Map<String, dynamic>>> _componentsOf(String type, String id) async {
    final a = await _db.from('batch_allocations').select('product_id, qty, manual, batch_id')
        .eq('consumer_type', type).eq('consumer_id', id);
    final rows = List<Map<String, dynamic>>.from(a as List);
    final ids = rows.map((e) => e['batch_id']).whereType<String>().toList();
    final byId = <String, Map<String, dynamic>>{};
    if (ids.isNotEmpty) {
      final b = await _db.from('stock_batches').select().inFilter('id', ids);
      final list = List<Map<String, dynamic>>.from(b as List);
      await BatchTracking.attachSuppliers(list);
      for (final x in list) { byId[x['id'] as String] = x; }
    }
    await _names(rows.map((e) => e['product_id']));
    for (final r in rows) { r['batch'] = byId[r['batch_id']]; }
    return rows;
  }

  Widget _card(IconData icon, String title, String kind, List<Widget> children, {Color? color}) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 18, color: color ?? AppTheme.primary),
        const SizedBox(width: 8),
        Expanded(child: SelectableText(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10)),
          child: Text(kind, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
      ]),
      const SizedBox(height: 10),
      ...children,
    ]),
  );

  Widget _kv(String k, String v, {Color? color, VoidCallback? onTap}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 150, child: Text(k, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
      Expanded(child: InkWell(onTap: onTap, child: Text(v, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600,
          color: color ?? (onTap != null ? AppTheme.primary : null),
          decoration: onTap != null ? TextDecoration.underline : null)))),
    ]),
  );

  Widget _componentsBox(List<Map<String, dynamic>> comps) {
    if (comps.isEmpty) {
      return const Padding(padding: EdgeInsets.only(top: 8),
        child: Text('No tracked components recorded for this production.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)));
    }
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Components used', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        for (final c in comps) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Builder(builder: (_) {
          final b = c['batch'] as Map<String, dynamic>?;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_p(c['product_id'])}  ·  ${BatchTracking.qty(c['qty'] as num?)}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            if (b == null)
              const Text('From older stock (before tracking)', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
            else
              Wrap(spacing: 10, children: [
                InkWell(onTap: () => _trace('${b['batch_no']}'),
                  child: Text('Batch ${b['batch_no']}', style: const TextStyle(fontSize: 11.5, color: AppTheme.primary, decoration: TextDecoration.underline))),
                if (b['source_number'] != null && b['source_number'] != b['batch_no'])
                  Text('${_src(b)} ${b['source_number']}', style: const TextStyle(fontSize: 11.5)),
                if (b['supplier_name'] != null) Text('${b['supplier_name']}', style: const TextStyle(fontSize: 11.5)),
                Text('Received ${BatchTracking.date(b['received_on'])}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                if (b['warranty_until'] != null)
                  Text('Supplier warranty till ${BatchTracking.date(b['warranty_until'])}',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _warrantyColor(b['warranty_until']))),
                if (c['manual'] == true) const Text('picked by hand', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ]),
          ]);
        })),
      ]),
    );
  }

  String _status(String? s) => switch (s) { 'in_stock' => 'In stock', 'dispatched' => 'Dispatched', 'void' => 'Cancelled', _ => s ?? '-' };

  Future<Widget> _serialCard(Map<String, dynamic> s) async {
    await _names([s['product_id']]);
    String? carton;
    if (s['carton_id'] != null) {
      try {
        final c = await _db.from('product_cartons').select('carton_no').eq('id', s['carton_id']).maybeSingle();
        carton = c?['carton_no'] as String?;
      } catch (_) {}
    }
    final comps = await _componentsOf('${s['source_type']}', '${s['source_id']}');
    final months = (s['warranty_months'] as num?)?.toInt() ?? 0;
    final start = DateTime.tryParse('${s['dispatched_on'] ?? ''}');
    final until = (months > 0 && start != null) ? DateTime(start.year, start.month + months, start.day) : null;
    return _card(Icons.confirmation_number_outlined, '${s['serial']}', 'Serial', [
      _kv('Product', _p(s['product_id'])),
      _kv('Status', _status(s['status'] as String?), color: s['status'] == 'void' ? AppTheme.danger : null),
      _kv('Made in', '${_src(s)} ${s['source_number'] ?? ''}', onTap: s['source_type'] == 'production' ? () => _openSource(s) : null),
      _kv('Made on', BatchTracking.date(s['produced_on'])),
      if (s['branch_id'] != null) _kv('Branch', _branchName[s['branch_id']] ?? '-'),
      if (carton != null) _kv('Carton', '$carton', onTap: () => _trace('$carton')),
      _kv('Warranty', months <= 0 ? 'None' : until != null
          ? '$months months · till ${BatchTracking.date(until.toIso8601String())}'
          : '$months months · starts when sold', color: until != null ? _warrantyColor(until.toIso8601String()) : null),
      _componentsBox(comps),
    ], color: s['status'] == 'void' ? AppTheme.danger : null);
  }

  Future<Widget> _cartonCard(Map<String, dynamic> c) async {
    await _names([c['product_id']]);
    final s = await _db.from('product_serials').select('serial, status').eq('carton_id', c['id']).order('serial');
    final serials = List<Map<String, dynamic>>.from(s as List);
    final comps = await _componentsOf('${c['source_type']}', '${c['source_id']}');
    return _card(Icons.inventory_2_outlined, '${c['carton_no']}', 'Carton', [
      _kv('Product', _p(c['product_id'])),
      _kv('Status', _status(c['status'] as String?)),
      _kv('Units', '${c['qty']}'),
      _kv('Made in', '${_src(c)} ${c['source_number'] ?? ''}', onTap: c['source_type'] == 'production' ? () => _openSource(c) : null),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final x in serials) ActionChip(
          visualDensity: VisualDensity.compact,
          label: Text('${x['serial']}', style: TextStyle(fontSize: 11,
              decoration: x['status'] == 'void' ? TextDecoration.lineThrough : null)),
          onPressed: () => _trace('${x['serial']}')),
      ]),
      _componentsBox(comps),
    ]);
  }

  Future<Widget> _batchCard(Map<String, dynamic> b) async {
    await _names([b['product_id']]);
    final a = await _db.from('batch_allocations').select('consumer_type, consumer_id, consumer_number, qty, manual, created_at')
        .eq('batch_id', b['id']).order('created_at');
    final uses = List<Map<String, dynamic>>.from(a as List);
    final left = BatchTracking.remaining(b);
    final void_ = b['status'] == 'void';
    return _card(Icons.qr_code_2_outlined, '${b['batch_no']}', void_ ? 'Batch · cancelled' : 'Batch', [
      _kv('Product', _p(b['product_id'])),
      _kv('From', '${_src(b)} ${b['source_number'] ?? ''}', onTap: (b['source_type'] == 'grn' || b['source_type'] == 'production') ? () => _openSource(b) : null),
      if (b['supplier_name'] != null) _kv('Supplier', '${b['supplier_name']}'),
      _kv('Received', BatchTracking.date(b['received_on'])),
      if (b['branch_id'] != null) _kv('Branch', _branchName[b['branch_id']] ?? '-'),
      _kv('Warranty until', b['warranty_until'] == null ? 'Not set' : BatchTracking.date(b['warranty_until']),
          color: _warrantyColor(b['warranty_until'])),
      _kv('Quantity', 'In ${BatchTracking.qty(b['qty_in'] as num?)}  ·  Used ${BatchTracking.qty(b['qty_used'] as num?)}  ·  Left ${BatchTracking.qty(left)}'),
      const SizedBox(height: 8),
      Text(uses.isEmpty ? 'Not used in production yet.' : 'Used in', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
      for (final u in uses) Padding(padding: const EdgeInsets.only(top: 3), child: Row(children: [
        Expanded(child: Text('${_src({'source_type': u['consumer_type']})} ${u['consumer_number'] ?? ''}${u['manual'] == true ? '  (picked by hand)' : ''}',
            style: const TextStyle(fontSize: 12))),
        Text(BatchTracking.qty(u['qty'] as num?), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        TextButton(onPressed: () => _showMadeFrom(u), child: const Text('Units', style: TextStyle(fontSize: 11.5))),
      ])),
    ], color: void_ ? AppTheme.danger : null);
  }

  Future<void> _showMadeFrom(Map u) async {
    try {
      final s = await _db.from('product_serials').select('serial, status')
          .eq('source_type', u['consumer_type']).eq('source_id', u['consumer_id']).order('serial').limit(5000);
      final list = List<Map<String, dynamic>>.from(s as List);
      if (!mounted) return;
      await showDialog(context: context, builder: (ctx) => AlertDialog(
        title: Text('Units made · ${u['consumer_number'] ?? ''}'),
        content: SizedBox(width: 420, height: 360, child: list.isEmpty
          ? const Center(child: Text('No serial numbers for this production.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView(children: [for (final x in list) ListTile(dense: true,
              title: Text('${x['serial']}'), trailing: Text(_status(x['status'] as String?), style: const TextStyle(fontSize: 11)),
              onTap: () { Navigator.pop(ctx); _trace('${x['serial']}'); })])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ));
    } catch (e) { _snack(friendlyError('Could not load the units', e)); }
  }

  Future<void> _pickUpPastGrns() async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Pick up past GRNs?'),
      content: const Text('Makes batches for tracked products from GRNs received before tracking was switched on (or before the product was marked Batch / Serial). Existing batches are kept as they are.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pick up')),
      ],
    ));
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final n = await _db.rpc('bt_rebuild_grn_batches', params: {'p_org': _orgId});
      _snack('Checked $n GRN${n == 1 ? '' : 's'}');
      await _loadLists();
    } catch (e) {
      _snack(friendlyError('That did not work', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_on == null) return const Center(child: CircularProgressIndicator());
    if (_on == false) {
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.qr_code_2_outlined, size: 40, color: AppTheme.textSecondary),
        SizedBox(height: 10),
        Text('Batch tracking is off', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        SizedBox(height: 4),
        Text('Turn on "Batch & warranty tracking" in ERP Admin Settings → Inventory & Products.',
            textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)),
      ])));
    }
    final narrow = MediaQuery.of(context).size.width < 700;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(color: Colors.white, padding: EdgeInsets.fromLTRB(narrow ? 14 : 24, narrow ? 14 : 20, narrow ? 8 : 24, 8),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Batch Tracking', style: TextStyle(fontSize: narrow ? 18 : 22, fontWeight: FontWeight.w700)),
            if (!narrow) ...[
              const SizedBox(height: 2),
              const Text('Batches, serial numbers and cartons — where each came from and where it went',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ],
          ])),
          if (_busy) const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _loadLists),
          PopupMenuButton<String>(
            onSelected: (v) { if (v == 'grn') _pickUpPastGrns(); },
            itemBuilder: (_) => const [PopupMenuItem(value: 'grn', child: Text('Pick up past GRNs'))],
          ),
        ])),
      Container(color: Colors.white, child: TabBar(
        controller: _tabs, isScrollable: true, tabAlignment: TabAlignment.start,
        labelColor: AppTheme.primary, unselectedLabelColor: AppTheme.textSecondary, indicatorColor: AppTheme.primary,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        tabs: [
          const Tab(text: 'Trace'),
          Tab(text: 'Batches (${_batches.length})'),
          Tab(text: 'Serials (${_serials.length})'),
          Tab(text: 'Cartons (${_cartons.length})'),
        ],
      )),
      const Divider(height: 1),
      Expanded(child: TabBarView(controller: _tabs, children: [
        _traceTab(narrow),
        _listTab(_batchesTable(), stockFilter: true),
        _listTab(_serialsTable()),
        _listTab(_cartonsTable()),
      ])),
    ]);
  }

  Widget _traceTab(bool narrow) => ListView(padding: EdgeInsets.all(narrow ? 12 : 20), children: [
    Row(children: [
      Expanded(child: TextField(
        controller: _traceCtrl,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _trace(),
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), filled: true, fillColor: Colors.white,
            prefixIcon: Icon(Icons.qr_code_scanner, size: 18),
            hintText: 'Scan or type a serial, carton, batch or GRN number'),
      )),
      const SizedBox(width: 8),
      ElevatedButton(onPressed: _tracing ? null : () => _trace(), child: const Text('Find')),
    ]),
    const SizedBox(height: 14),
    if (_tracing) const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator())),
    if (_traceMsg != null) Text(_traceMsg!, style: const TextStyle(color: AppTheme.textSecondary)),
    ..._traceOut,
  ]);

  Widget _listTab(Widget table, {bool stockFilter = false}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 6), child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(width: 320, child: TextField(
        controller: _searchCtrl,
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), filled: true, fillColor: Colors.white,
            prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search number or product'),
        onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
      )),
      if (stockFilter) FilterChip(label: const Text('With stock left'), selected: _withStock,
          onSelected: (v) => setState(() => _withStock = v)),
    ])),
    Expanded(child: _loading ? const Center(child: CircularProgressIndicator()) : table),
  ]);

  bool _match(List<Object?> parts) {
    if (_search.isEmpty) return true;
    return parts.map((e) => '${e ?? ''}').join(' ').toLowerCase().contains(_search);
  }

  Widget _head(List<(String, int, bool)> cols) => Container(
    color: AppTheme.background, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(children: [for (final c in cols) Expanded(flex: c.$2, child: Text(c.$1, textAlign: c.$3 ? TextAlign.right : TextAlign.left,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)))]),
  );

  Widget _table(List<(String, int, bool)> cols, List<List<Widget>> rows, List<VoidCallback> taps) => HScrollOnNarrow(
    minWidth: 900,
    child: Column(children: [
      _head(cols),
      const Divider(height: 1),
      Expanded(child: rows.isEmpty
        ? const Center(child: Text('Nothing here yet', style: TextStyle(color: AppTheme.textSecondary)))
        : ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => InkWell(onTap: taps[i], child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(children: [for (var j = 0; j < cols.length; j++) Expanded(flex: cols[j].$2,
                  child: Align(alignment: cols[j].$3 ? Alignment.centerRight : Alignment.centerLeft, child: rows[i][j]))]),
            )),
          )),
    ]),
  );

  Widget _t(String s, {bool bold = false, Color? color}) => Text(s, overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.w700 : FontWeight.normal, color: color));

  Widget _batchesTable() {
    final list = _batches.where((b) => (!_withStock || BatchTracking.remaining(b) > 0) &&
        _match([b['batch_no'], b['source_number'], _p(b['product_id']), b['supplier_name']])).toList();
    return _table(
      const [('Batch', 3, false), ('Product', 4, false), ('From', 3, false), ('Supplier', 3, false), ('Received', 2, false),
        ('Warranty until', 2, false), ('In', 1, true), ('Used', 1, true), ('Left', 1, true)],
      [for (final b in list) [
        _t('${b['batch_no']}', bold: true),
        _t(_p(b['product_id'])),
        _t('${_src(b)} ${b['source_number'] ?? ''}'),
        _t('${b['supplier_name'] ?? '-'}'),
        _t(BatchTracking.date(b['received_on'])),
        _t(b['warranty_until'] == null ? '-' : BatchTracking.date(b['warranty_until']), bold: true, color: _warrantyColor(b['warranty_until'])),
        _t(BatchTracking.qty(b['qty_in'] as num?)),
        _t(BatchTracking.qty(b['qty_used'] as num?)),
        _t(BatchTracking.qty(BatchTracking.remaining(b)), bold: true),
      ]],
      [for (final b in list) () => _trace('${b['batch_no']}')],
    );
  }

  Widget _serialsTable() {
    final list = _serials.where((s) => _match([s['serial'], s['carton_no'], s['source_number'], _p(s['product_id'])])).toList();
    return _table(
      const [('Serial', 3, false), ('Product', 4, false), ('Carton', 2, false), ('Made in', 3, false), ('Made on', 2, false), ('Status', 2, false)],
      [for (final s in list) [
        _t('${s['serial']}', bold: true),
        _t(_p(s['product_id'])),
        _t('${s['carton_no'] ?? '-'}'),
        _t('${s['source_number'] ?? ''}'),
        _t(BatchTracking.date(s['produced_on'])),
        _t(_status(s['status'] as String?), color: s['status'] == 'void' ? AppTheme.danger : null),
      ]],
      [for (final s in list) () => _trace('${s['serial']}')],
    );
  }

  Widget _cartonsTable() {
    final list = _cartons.where((c) => _match([c['carton_no'], c['source_number'], _p(c['product_id'])])).toList();
    return _table(
      const [('Carton', 2, false), ('Product', 4, false), ('Units', 1, true), ('Made in', 3, false), ('Branch', 2, false), ('Status', 2, false)],
      [for (final c in list) [
        _t('${c['carton_no']}', bold: true),
        _t(_p(c['product_id'])),
        _t('${c['qty']}'),
        _t('${c['source_number'] ?? ''}'),
        _t(_branchName[c['branch_id']] ?? '-'),
        _t(_status(c['status'] as String?), color: c['status'] == 'void' ? AppTheme.danger : null),
      ]],
      [for (final c in list) () => _trace('${c['carton_no']}')],
    );
  }
}
