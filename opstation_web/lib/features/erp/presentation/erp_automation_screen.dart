import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/permissions/access_control.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// ERP ▸ Automation (SQL 324).
///
/// Phase 1 — Inventory replenishment. A rule watches products (by category
/// and/or picked products). The moment stock drops to its threshold, the
/// database creates a DRAFT Purchase Order (bought items) or a DRAFT Job Card
/// (items with an active BOM). Nothing is approved automatically.
class ErpAutomationScreen extends ConsumerStatefulWidget {
  const ErpAutomationScreen({super.key});
  @override
  ConsumerState<ErpAutomationScreen> createState() => _ErpAutomationScreenState();
}

class _ErpAutomationScreenState extends ConsumerState<ErpAutomationScreen> {
  bool _loading = true;
  String? _error;
  String _tab = 'rules';
  String _actFilter = 'all';

  List<Map<String, dynamic>> _rules = [];
  List<Map<String, dynamic>> _runs = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _suppliers = [];
  final Map<String, List<String>> _tax = {'main_group': [], 'group': [], 'sub_group': []};
  final Map<String, Map<String, dynamic>> _pById = {};
  final Set<String> _busy = {};

  SupabaseClient get _c => Supabase.instance.client;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  bool get _canEdit {
    final a = ref.read(accessSyncProvider);
    if (a == null) return false;
    return a.isAdmin || a.canAddDoc('automation') || a.canEditDoc('automation');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  String _err(Object e) => e.toString().contains('automation_') ? 'Run SQL 324 in Supabase first.' : '$e';

  Future<void> _load() async {
    final org = _orgId;
    if (org == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _load(); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Future.wait<dynamic>([
        _c.from('automation_rules').select().eq('org_id', org).order('created_at'),
        _c.from('product_taxonomies').select('taxonomy_type, name').eq('org_id', org).order('name'),
        _c.from('branches').select('id, name, is_virtual').eq('org_id', org).eq('is_active', true).order('name'),
      ]);
      _rules = List<Map<String, dynamic>>.from(res[0] as List);
      for (final k in _tax.keys) { _tax[k]!.clear(); }
      for (final t in res[1] as List) {
        final k = '${t['taxonomy_type']}';
        if (_tax.containsKey(k)) _tax[k]!.add('${t['name']}');
      }
      _branches = List<Map<String, dynamic>>.from(res[2] as List).where((b) => b['is_virtual'] != true).toList();
      // Products and suppliers can exceed one page.
      final prods = <Map<String, dynamic>>[];
      for (var from = 0; ; from += 1000) {
        final rows = List<Map<String, dynamic>>.from(await _c.from('products')
            .select('id, name, sku, product_main_group, product_group, product_sub_group, low_stock_limit, is_active')
            .eq('org_id', org).order('name').range(from, from + 999) as List);
        prods.addAll(rows);
        if (rows.length < 1000) break;
      }
      _products = prods;
      _pById..clear()..addEntries(prods.map((p) => MapEntry('${p['id']}', p)));
      final sups = <Map<String, dynamic>>[];
      for (var from = 0; ; from += 1000) {
        final rows = List<Map<String, dynamic>>.from(await _c.from('suppliers').select('id, name')
            .eq('org_id', org).order('name').range(from, from + 999) as List);
        sups.addAll(rows);
        if (rows.length < 1000) break;
      }
      _suppliers = sups;
      await _loadRuns();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = _err(e); });
    }
  }

  Future<void> _loadRuns() async {
    final org = _orgId;
    if (org == null) return;
    try {
      _runs = List<Map<String, dynamic>>.from(await _c.from('automation_runs').select()
          .eq('org_id', org).order('created_at', ascending: false).limit(400) as List);
    } catch (_) {}
  }

  String _branch(String? id) {
    for (final b in _branches) { if (b['id'] == id) return '${b['name']}'; }
    return id == null ? '—' : id;
  }

  String _supplier(String? id) {
    for (final s in _suppliers) { if (s['id'] == id) return '${s['name']}'; }
    return id == null ? '—' : id;
  }

  String _num(dynamic v) => NumberFormat('#,##0.##').format((v as num?)?.toDouble() ?? double.tryParse('$v') ?? 0);
  List<String> _arr(dynamic v) => v is List ? [for (final x in v) '$x'] : <String>[];

  // ── Actions ────────────────────────────────────────────────────────────
  Future<void> _toggle(Map<String, dynamic> r, bool v) async {
    try {
      await _c.from('automation_rules').update({'is_active': v, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', '${r['id']}');
      setState(() => r['is_active'] = v);
    } catch (e) { _snack(_err(e)); }
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete automation?'),
      content: Text('"${r['name']}" will stop creating drafts. Drafts it already created are kept.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await _c.from('automation_rules').delete().eq('id', '${r['id']}');
      setState(() => _rules.remove(r));
    } catch (e) { _snack(_err(e)); }
  }

  Future<void> _runNow(Map<String, dynamic> r) async {
    final id = '${r['id']}';
    setState(() => _busy.add(id));
    try {
      final res = await _c.rpc('automation_run_rule', params: {'p_rule_id': id});
      final m = res is Map ? res : const {};
      final po = (m['po_lines'] as num?)?.toInt() ?? 0, job = (m['jobs'] as num?)?.toInt() ?? 0;
      _snack(po + job == 0
          ? 'Checked ${m['checked'] ?? 0} — nothing below threshold (or already on order)'
          : 'Checked ${m['checked'] ?? 0} — ${po > 0 ? '$po PO line${po == 1 ? '' : 's'}' : ''}${po > 0 && job > 0 ? ' and ' : ''}${job > 0 ? '$job draft job${job == 1 ? '' : 's'}' : ''} created');
      await _loadRuns();
      final fresh = await _c.from('automation_rules').select().eq('id', id).maybeSingle();
      if (fresh != null) { final i = _rules.indexWhere((x) => x['id'] == id); if (i >= 0) _rules[i] = Map<String, dynamic>.from(fresh); }
    } catch (e) { _snack(_err(e)); }
    if (mounted) setState(() => _busy.remove(id));
  }

  // ── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.of(context).size.width < 760;
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(mobile ? 12 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Automation', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          SegmentedButton<String>(
            segments: [
              const ButtonSegment(value: 'rules', label: Text('Rules'), icon: Icon(Icons.bolt_outlined, size: 16)),
              ButtonSegment(value: 'activity', label: Text('Activity (${_runs.length})'), icon: const Icon(Icons.history, size: 16)),
            ],
            selected: {_tab},
            showSelectedIcon: false,
            onSelectionChanged: (v) { setState(() => _tab = v.first); if (v.first == 'activity') _loadRuns().then((_) { if (mounted) setState(() {}); }); },
          ),
          if (_canEdit && _tab == 'rules')
            ElevatedButton.icon(onPressed: () => _edit(null), icon: const Icon(Icons.add, size: 18), label: const Text('New automation')),
          IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
        const SizedBox(height: 6),
        const Text('Inventory: when stock drops to its threshold, a draft Purchase Order or draft Job Card is created instantly for review.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 14),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                : _tab == 'rules' ? _rulesView() : _activityView()),
      ]),
    );
  }

  String _summary(Map<String, dynamic> r) {
    final what = <String>[
      if (_arr(r['main_groups']).isNotEmpty) 'Main group: ${_arr(r['main_groups']).join(', ')}',
      if (_arr(r['groups']).isNotEmpty) 'Group: ${_arr(r['groups']).join(', ')}',
      if (_arr(r['sub_groups']).isNotEmpty) 'Sub group: ${_arr(r['sub_groups']).join(', ')}',
      if (_arr(r['product_ids']).isNotEmpty) '${_arr(r['product_ids']).length} picked product${_arr(r['product_ids']).length == 1 ? '' : 's'}',
    ];
    return what.isEmpty ? 'No products selected' : what.join('  ·  ');
  }

  String _how(Map<String, dynamic> r) {
    final scope = r['stock_scope'] == 'company'
        ? 'Company total → drafts at ${_branch(r['target_branch_id'] as String?)}'
        : (_arr(r['branch_ids']).isEmpty ? 'Each branch' : 'Branches: ${_arr(r['branch_ids']).map(_branch).join(', ')}');
    final when = r['trigger_mode'] == 'rule_min' ? 'at ≤ ${_num(r['min_qty'])}' : 'at product low-stock limit';
    final qty = switch ('${r['qty_mode']}') {
      'fixed' => 'order ${_num(r['fixed_qty'])}',
      'days_cover' => 'order ${r['cover_days']} days of sales (last ${r['sales_window_days']} days)',
      _ => 'fill up to ${_num(r['max_level'])}',
    };
    final round = ((r['round_to'] as num?) ?? 0) > 0 ? ', in multiples of ${_num(r['round_to'])}' : '';
    final src = switch ('${r['source_mode']}') { 'purchase' => 'always PO', 'produce' => 'always Job', _ => 'Job if BOM, else PO' };
    final sup = r['supplier_mode'] == 'fixed' ? 'supplier ${_supplier(r['supplier_id'] as String?)}'
        : 'last supplier${r['supplier_id'] != null ? ' (else ${_supplier(r['supplier_id'] as String?)})' : ''}';
    return '$scope · $when · $qty$round · $src · $sup';
  }

  Widget _rulesView() {
    if (_rules.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.bolt_outlined, size: 48, color: Color(0xFFCBD5E1)),
        const SizedBox(height: 8),
        const Text('No automations yet.', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Create one to raise draft POs / Job Cards when stock runs low.', style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        if (_canEdit) ElevatedButton.icon(onPressed: () => _edit(null), icon: const Icon(Icons.add, size: 18), label: const Text('New automation')),
      ]));
    }
    return ListView.separated(
      itemCount: _rules.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final r = _rules[i];
        final on = r['is_active'] == true;
        final busy = _busy.contains('${r['id']}');
        final fired = DateTime.tryParse('${r['last_fired_at'] ?? ''}');
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? AppTheme.primary.withValues(alpha: 0.35) : AppTheme.border)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 38, height: 38, alignment: Alignment.center,
                decoration: BoxDecoration(color: (on ? AppTheme.primary : AppTheme.textSecondary).withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.inventory_outlined, color: on ? AppTheme.primary : AppTheme.textSecondary)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text('${r['name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
                const SizedBox(width: 8),
                Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: (on ? AppTheme.success : AppTheme.textSecondary).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                    child: Text(on ? 'Active' : 'Paused', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: on ? AppTheme.success : AppTheme.textSecondary))),
              ]),
              const SizedBox(height: 4),
              Text(_summary(r), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(_how(r), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              if (fired != null) Padding(padding: const EdgeInsets.only(top: 4),
                  child: Text('Last created a draft ${DateFormat('d MMM y, h:mm a').format(fired.toLocal())}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            ])),
            const SizedBox(width: 8),
            Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (_canEdit) Switch(value: on, onChanged: (v) => _toggle(r, v)),
              if (_canEdit) OutlinedButton.icon(
                onPressed: busy || !on ? null : () => _runNow(r),
                icon: busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow, size: 16),
                label: const Text('Run now'),
              ),
              if (_canEdit) IconButton(tooltip: 'Edit', onPressed: () => _edit(r), icon: const Icon(Icons.edit_outlined, size: 18)),
              if (_canEdit) IconButton(tooltip: 'Delete', onPressed: () => _delete(r), icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger)),
            ]),
          ]),
        );
      },
    );
  }

  Widget _activityView() {
    final list = _actFilter == 'all' ? _runs : _runs.where((r) => r['action'] == _actFilter).toList();
    Color col(String a) => a == 'po' ? AppTheme.primary : a == 'job' ? Colors.indigo : a == 'error' ? AppTheme.danger : AppTheme.textSecondary;
    String lbl(String a) => a == 'po' ? 'PO' : a == 'job' ? 'Job' : a == 'error' ? 'Error' : 'Skipped';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 6, children: [
        for (final f in const [('all', 'All'), ('po', 'Draft POs'), ('job', 'Draft jobs'), ('skipped', 'Skipped'), ('error', 'Errors')])
          ChoiceChip(label: Text(f.$2), selected: _actFilter == f.$1, onSelected: (_) => setState(() => _actFilter = f.$1)),
      ]),
      const SizedBox(height: 10),
      Expanded(child: list.isEmpty
          ? const Center(child: Text('Nothing yet.', style: TextStyle(color: AppTheme.textSecondary)))
          : Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                itemBuilder: (_, i) {
                  final r = list[i];
                  final a = '${r['action']}';
                  final p = _pById['${r['product_id']}'];
                  final t = DateTime.tryParse('${r['created_at'] ?? ''}');
                  final doc = r['doc_number'] as String?;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(width: 58, padding: const EdgeInsets.symmetric(vertical: 3), alignment: Alignment.center,
                          decoration: BoxDecoration(color: col(a).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                          child: Text(lbl(a), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: col(a)))),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p == null ? '${r['product_id'] ?? '—'}' : '${p['name']}${(p['sku'] ?? '').toString().isEmpty ? '' : '  ·  ${p['sku']}'}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                        Text([
                          '${r['rule_name'] ?? ''}',
                          _branch(r['branch_id'] as String?),
                          if (r['stock_qty'] != null) 'stock ${_num(r['stock_qty'])}',
                          if (r['on_order'] != null && ((r['on_order'] as num?) ?? 0) > 0) 'on order ${_num(r['on_order'])}',
                          if (r['threshold'] != null) 'threshold ${_num(r['threshold'])}',
                        ].where((x) => x.isNotEmpty).join('  ·  '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                        if ('${r['message'] ?? ''}'.isNotEmpty)
                          Text('${r['message']}', style: TextStyle(fontSize: 11.5, color: a == 'error' ? AppTheme.danger : AppTheme.textPrimary)),
                      ])),
                      const SizedBox(width: 10),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        if (((r['qty'] as num?) ?? 0) > 0) Text('Qty ${_num(r['qty'])}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        if (doc != null)
                          InkWell(
                            onTap: () => context.go(a == 'job' ? '/manufacturing/job-card' : '/erp/purchase?focus=${r['doc_id']}'),
                            child: Text(doc, style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w700, decoration: TextDecoration.underline)),
                          ),
                        if (t != null) Text(DateFormat('d MMM, h:mm a').format(t.toLocal()), style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
                      ]),
                    ]),
                  );
                },
              ),
            )),
    ]);
  }

  // ── Rule editor ────────────────────────────────────────────────────────
  Future<void> _edit(Map<String, dynamic>? r) async {
    final org = _orgId;
    if (org == null) return;
    final name = TextEditingController(text: '${r?['name'] ?? ''}');
    final mains = <String>{..._arr(r?['main_groups'])};
    final groups = <String>{..._arr(r?['groups'])};
    final subs = <String>{..._arr(r?['sub_groups'])};
    final picked = <String>{..._arr(r?['product_ids'])};
    final excluded = <String>{..._arr(r?['exclude_product_ids'])};
    String scope = '${r?['stock_scope'] ?? 'branch'}';
    final branches = <String>{..._arr(r?['branch_ids'])};
    String? target = r?['target_branch_id'] as String?;
    String trig = '${r?['trigger_mode'] ?? 'product_limit'}';
    String qtyMode = '${r?['qty_mode'] ?? 'max_level'}';
    String src = '${r?['source_mode'] ?? 'auto'}';
    String supMode = '${r?['supplier_mode'] ?? 'last'}';
    String? supplier = r?['supplier_id'] as String?;
    bool active = r == null ? true : r['is_active'] == true;
    TextEditingController numCtl(String k, String dflt) {
      final v = r?[k];
      return TextEditingController(text: v == null ? dflt : _num(v).replaceAll(',', ''));
    }
    final minQty = numCtl('min_qty', '0');
    final maxLevel = numCtl('max_level', '0');
    final fixedQty = numCtl('fixed_qty', '0');
    final coverDays = numCtl('cover_days', '30');
    final window = numCtl('sales_window_days', '30');
    final roundTo = numCtl('round_to', '0');
    double d(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '')) ?? 0;

    int matchCount() => _products.where((p) {
          final id = '${p['id']}';
          if (excluded.contains(id) || p['is_active'] == false) return false;
          return picked.contains(id) || mains.contains(p['product_main_group']) || groups.contains(p['product_group']) || subs.contains(p['product_sub_group']);
        }).length;

    final saved = await showDialog<bool>(context: context, barrierDismissible: false, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      Widget section(String n, String title, String sub, List<Widget> children) => Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 22, height: 22, alignment: Alignment.center,
                    decoration: const BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle),
                    child: Text(n, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800))),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              ]),
              Padding(padding: const EdgeInsets.only(left: 30, top: 2, bottom: 10),
                  child: Text(sub, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
              ...children,
            ]),
          );
      Widget numField(String label, TextEditingController c, {String? suffix, double w = 150}) => SizedBox(width: w, child: TextField(
            controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setD(() {}),
            decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true, border: const OutlineInputBorder()),
          ));
      Widget seg(String value, List<(String, String)> opts, void Function(String) on) => SegmentedButton<String>(
            segments: [for (final o in opts) ButtonSegment(value: o.$1, label: Text(o.$2, style: const TextStyle(fontSize: 12.5)))],
            selected: {value},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setD(() => on(v.first)),
          );
      Widget pickChips(String label, String type, Set<String> set) {
        final all = [..._tax[type]!];
        for (final x in set) { if (!all.contains(x)) all.add(x); }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
            const SizedBox(width: 6),
            if (set.isNotEmpty) Text('${set.length} selected', style: const TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton(onPressed: () async {
              final res = await _pickNames(label, all, set);
              if (res != null) setD(() { set..clear()..addAll(res); });
            }, child: Text(set.isEmpty ? 'Choose…' : 'Change…')),
          ]),
          if (set.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, children: [
            for (final x in set) InputChip(label: Text(x, style: const TextStyle(fontSize: 12)), onDeleted: () => setD(() => set.remove(x)), visualDensity: VisualDensity.compact),
          ]),
          const SizedBox(height: 8),
        ]);
      }
      Widget productChips(String label, Set<String> set, {bool danger = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
              const SizedBox(width: 6),
              if (set.isNotEmpty) Text('${set.length}', style: TextStyle(fontSize: 11, color: danger ? AppTheme.danger : AppTheme.primary, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(onPressed: () async {
                final res = await _pickProducts(label, set);
                if (res != null) setD(() { set..clear()..addAll(res); });
              }, child: Text(set.isEmpty ? 'Pick products…' : 'Change…')),
            ]),
            if (set.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, children: [
              for (final id in set.take(30)) InputChip(
                label: Text('${_pById[id]?['name'] ?? id}', style: const TextStyle(fontSize: 12)),
                onDeleted: () => setD(() => set.remove(id)), visualDensity: VisualDensity.compact),
              if (set.length > 30) Chip(label: Text('+${set.length - 30} more', style: const TextStyle(fontSize: 12))),
            ]),
            const SizedBox(height: 8),
          ]);

      final count = matchCount();
      return AlertDialog(
        backgroundColor: AppTheme.background,
        insetPadding: const EdgeInsets.all(16),
        title: Row(children: [
          Expanded(child: Text(r == null ? 'New automation' : 'Edit automation', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          const Text('Active', style: TextStyle(fontSize: 13)),
          Switch(value: active, onChanged: (v) => setD(() => active = v)),
        ]),
        content: SizedBox(width: 700, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Oil filters — keep stocked', border: OutlineInputBorder(), isDense: true)),
          const SizedBox(height: 12),
          section('1', 'Which products', 'Pick categories, individual products, or both. A product matching ANY of them is covered.', [
            pickChips('Main groups', 'main_group', mains),
            pickChips('Groups', 'group', groups),
            pickChips('Sub groups', 'sub_group', subs),
            productChips('Products', picked),
            productChips('Exclude products', excluded, danger: true),
            Text('Covers $count active product${count == 1 ? '' : 's'}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          ]),
          section('2', 'Where to watch stock', 'Each branch on its own, or the company total across branches.', [
            seg(scope, const [('branch', 'Each branch'), ('company', 'Company total')], (v) => scope = v),
            const SizedBox(height: 10),
            Text(scope == 'branch' ? 'Branches to watch (none ticked = all branches)' : 'Branches to add up (none ticked = all branches)',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final b in _branches)
                FilterChip(label: Text('${b['name']}', style: const TextStyle(fontSize: 12.5)), selected: branches.contains(b['id']),
                    onSelected: (v) => setD(() { if (v) { branches.add('${b['id']}'); } else { branches.remove('${b['id']}'); } })),
            ]),
            if (scope == 'company') ...[
              const SizedBox(height: 10),
              SizedBox(width: 320, child: DropdownButtonFormField<String>(
                value: _branches.any((b) => b['id'] == target) ? target : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Create drafts at branch', border: OutlineInputBorder(), isDense: true),
                items: [for (final b in _branches) DropdownMenuItem(value: '${b['id']}', child: Text('${b['name']}'))],
                onChanged: (v) => setD(() => target = v),
              )),
            ] else
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('Drafts are created for the branch whose stock dropped.',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
          ]),
          section('3', 'When to act', 'The moment stock (plus anything already on order) is at or below this level.', [
            seg(trig, const [('product_limit', "Product's low-stock limit"), ('rule_min', 'A level set here')], (v) => trig = v),
            const SizedBox(height: 10),
            numField(trig == 'rule_min' ? 'Act at or below' : 'Fallback if product has no limit', minQty, w: 260),
          ]),
          section('4', 'How much to order', 'Already-on-order quantity is always subtracted.', [
            seg(qtyMode, const [('max_level', 'Fill up to a level'), ('fixed', 'Fixed quantity'), ('days_cover', 'Days of sales')], (v) => qtyMode = v),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, children: [
              if (qtyMode == 'max_level') numField('Fill up to', maxLevel),
              if (qtyMode == 'fixed') numField('Order quantity', fixedQty),
              if (qtyMode == 'days_cover') ...[
                numField('Cover', coverDays, suffix: 'days', w: 130),
                numField('Average of last', window, suffix: 'days', w: 160),
              ],
              numField('Round up to multiple of', roundTo, w: 210),
            ]),
            const SizedBox(height: 6),
            Text(switch (qtyMode) {
              'fixed' => 'Always orders ${_num(d(fixedQty))}${d(roundTo) > 0 ? ', rounded up to a multiple of ${_num(d(roundTo))}' : ''}.',
              'days_cover' => 'Orders (average daily sales × ${_num(d(coverDays))}) − stock − on order.',
              _ => 'Orders ${_num(d(maxLevel))} − stock − on order.',
            }, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ]),
          section('5', 'Make or buy', 'Produced items get a draft Job Card from their active BOM; bought items a draft PO.', [
            seg(src, const [('auto', 'Auto (BOM → Job, else PO)'), ('purchase', 'Always PO'), ('produce', 'Always Job')], (v) => src = v),
          ]),
          if (src != 'produce')
            section('6', 'Supplier for draft POs', 'Drafts for the same branch and supplier are combined into one PO.', [
              seg(supMode, const [('last', 'Last supplier'), ('fixed', 'Always this supplier')], (v) => supMode = v),
              const SizedBox(height: 10),
              SizedBox(width: 380, child: DropdownButtonFormField<String?>(
                value: _suppliers.any((s) => s['id'] == supplier) ? supplier : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: supMode == 'fixed' ? 'Supplier' : 'Fallback supplier (if never purchased)',
                    border: const OutlineInputBorder(), isDense: true),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('— None —')),
                  for (final s in _suppliers) DropdownMenuItem<String?>(value: '${s['id']}', child: Text('${s['name']}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setD(() => supplier = v),
              )),
            ]),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () async {
            String? problem;
            if (name.text.trim().isEmpty) problem = 'Give the automation a name';
            else if (count == 0) problem = 'Pick at least one category or product';
            else if (scope == 'company' && target == null) problem = 'Choose the branch where drafts are created';
            else if (trig == 'rule_min' && d(minQty) <= 0) problem = 'Set the level to act at';
            else if (qtyMode == 'max_level' && d(maxLevel) <= 0) problem = 'Set the level to fill up to';
            else if (qtyMode == 'fixed' && d(fixedQty) <= 0) problem = 'Set the order quantity';
            else if (qtyMode == 'days_cover' && (d(coverDays) <= 0 || d(window) <= 0)) problem = 'Set the days';
            else if (src != 'produce' && supMode == 'fixed' && supplier == null) problem = 'Choose the supplier';
            if (problem != null) { ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(problem))); return; }
            final row = {
              'org_id': org, 'name': name.text.trim(), 'kind': 'low_stock_replenish', 'is_active': active,
              'main_groups': mains.toList(), 'groups': groups.toList(), 'sub_groups': subs.toList(),
              'product_ids': picked.toList(), 'exclude_product_ids': excluded.toList(),
              'stock_scope': scope, 'branch_ids': branches.toList(), 'target_branch_id': scope == 'company' ? target : null,
              'trigger_mode': trig, 'min_qty': d(minQty),
              'qty_mode': qtyMode, 'max_level': d(maxLevel), 'fixed_qty': d(fixedQty),
              'cover_days': d(coverDays).round(), 'sales_window_days': d(window).round(), 'round_to': d(roundTo),
              'source_mode': src, 'supplier_mode': supMode, 'supplier_id': supplier,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            };
            try {
              if (r == null) {
                await _c.from('automation_rules').insert({
                  ...row, 'id': 'auto_${DateTime.now().microsecondsSinceEpoch}',
                  'created_by': ref.read(currentUserProvider)?.id,
                });
              } else {
                await _c.from('automation_rules').update(row).eq('id', '${r['id']}');
              }
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(_err(e))));
            }
          }, child: const Text('Save')),
        ],
      );
    }));
    if (saved == true) {
      _snack(r == null ? 'Automation created — it acts on the next stock drop. Use "Run now" for products already low.' : 'Automation saved');
      await _load();
    }
  }

  Future<Set<String>?> _pickNames(String title, List<String> all, Set<String> current) async {
    final sel = <String>{...current};
    String q = '';
    return showDialog<Set<String>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      final list = all.where((x) => q.isEmpty || matchesQuery(x, q)).toList();
      return AlertDialog(
        title: Text(title),
        content: SizedBox(width: 420, height: 440, child: Column(children: [
          TextField(autofocus: true, onChanged: (v) => setD(() => q = v),
              decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder())),
          const SizedBox(height: 6),
          Expanded(child: list.isEmpty
              ? const Center(child: Text('None — add them in Product Classifications', style: TextStyle(color: AppTheme.textSecondary)))
              : ListView(children: [
                  for (final x in list)
                    CheckboxListTile(dense: true, controlAffinity: ListTileControlAffinity.leading, value: sel.contains(x), title: Text(x),
                        onChanged: (v) => setD(() { if (v == true) { sel.add(x); } else { sel.remove(x); } })),
                ])),
        ])),
        actions: [
          TextButton(onPressed: () => setD(sel.clear), child: const Text('Clear')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, sel), child: Text('Done (${sel.length})')),
        ],
      );
    }));
  }

  Future<Set<String>?> _pickProducts(String title, Set<String> current) async {
    final sel = <String>{...current};
    String q = '';
    return showDialog<Set<String>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      final all = _products.where((p) => p['is_active'] != false &&
          (q.isEmpty || matchesQuery('${p['name'] ?? ''} ${p['sku'] ?? ''} ${p['product_group'] ?? ''}', q))).toList();
      final list = all.take(400).toList();
      return AlertDialog(
        title: Text(title),
        content: SizedBox(width: 520, height: 500, child: Column(children: [
          TextField(autofocus: true, onChanged: (v) => setD(() => q = v),
              decoration: const InputDecoration(hintText: 'Search name, SKU or group…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder())),
          Row(children: [
            Text('${all.length} found${all.length > 400 ? ' (showing 400 — refine search)' : ''}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            const Spacer(),
            TextButton(onPressed: () => setD(() { for (final p in list) { sel.add('${p['id']}'); } }), child: const Text('Tick all shown')),
          ]),
          Expanded(child: ListView(children: [
            for (final p in list)
              CheckboxListTile(
                dense: true, controlAffinity: ListTileControlAffinity.leading,
                value: sel.contains('${p['id']}'),
                title: Text('${p['name']}', style: const TextStyle(fontSize: 13)),
                subtitle: Text([p['sku'], p['product_group'], if (((p['low_stock_limit'] as num?) ?? 0) > 0) 'limit ${_num(p['low_stock_limit'])}']
                    .where((x) => x != null && '$x'.isNotEmpty).join(' · '), style: const TextStyle(fontSize: 11)),
                onChanged: (v) => setD(() { if (v == true) { sel.add('${p['id']}'); } else { sel.remove('${p['id']}'); } }),
              ),
          ])),
        ])),
        actions: [
          TextButton(onPressed: () => setD(sel.clear), child: const Text('Clear')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, sel), child: Text('Done (${sel.length})')),
        ],
      );
    }));
  }
}
