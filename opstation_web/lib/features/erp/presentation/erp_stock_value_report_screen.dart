// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/format/money.dart';
import '../../auth/auth_controller.dart';
import '../../intelligence/widgets/searchable_dropdown.dart';

class ErpStockValueReportScreen extends ConsumerStatefulWidget {
  const ErpStockValueReportScreen({super.key});
  @override
  ConsumerState<ErpStockValueReportScreen> createState() => _ErpStockValueReportScreenState();
}

class _ErpStockValueReportScreenState extends ConsumerState<ErpStockValueReportScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];      // valued stock rows for the selection
  List<Map<String, dynamic>> _branches = [];
  Map<String, List<Map<String, dynamic>>> _taxonomies = {};
  // Branch multi-select: empty set = ALL branches; else any 1..N branches.
  Set<String> _selBranches = {};
  String? _fMain, _fGroup, _fClass, _fMov, _fSub;
  bool _hideZero = false;
  String _search = '';
  String _sortKey = '';   // '' = default order; else column key
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    final bid = ref.read(selectedBranchProvider)?['id'] as String?;
    if (bid != null) _selBranches = {bid};
    _load();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isAdmin => ref.read(currentUserProvider)?.role != WebUserRole.erpUser;

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      // Branch visibility: admins see all active branches; other users only the
      // branches they have access to (same scoping as Customer Balance Report).
      List<Map<String, dynamic>> branchList;
      if (_isAdmin) {
        final branches = await client.from('branches').select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
        branchList = List<Map<String, dynamic>>.from(branches);
      } else {
        branchList = List<Map<String, dynamic>>.from(
            ref.read(userBranchesProvider).valueOrNull ?? []);
      }
      // Drop selections that are no longer allowed.
      final allowedIds = branchList.map((b) => b['id'] as String).toSet();
      _selBranches = _selBranches.where(allowedIds.contains).toSet();

      final taxonomies = await client.from('product_taxonomies').select().eq('org_id', orgId).order('name');
      final Map<String, List<Map<String, dynamic>>> grouped = {};
      for (final t in taxonomies as List) {
        grouped.putIfAbsent(t['taxonomy_type'] as String, () => []).add(Map<String, dynamic>.from(t));
      }

      final targets = _selBranches.isEmpty
          ? branchList.map((b) => b['id'] as String).toList()
          : branchList.map((b) => b['id'] as String).where(_selBranches.contains).toList();

      final List<Map<String, dynamic>> rows = [];
      if (targets.isNotEmpty) {
        final products = await client.from('products')
            .select('id, name, sku, cost_price, selling_price, product_main_group, product_group, product_sub_group, product_class, product_movement_category, uoms(abbreviation)')
            .eq('org_id', orgId).eq('is_active', true).limit(5000);
        final byId = {for (final p in products as List) p['id'] as String: Map<String, dynamic>.from(p)};

        // Aggregate across the selected branches: total qty per product, and
        // total VALUE per product (each branch's qty valued at that branch's
        // engine cost). Displayed unit cost = value / qty (weighted average).
        final Map<String, double> qtyMap = {};
        final Map<String, double> valMap = {};
        final Map<String, double> anyCost = {}; // fallback display cost
        for (final bid in targets) {
          final Map<String, double> costMap = {};
          try {
            final costs = await client.rpc('rpc_stock_unit_costs', params: {'p_org': orgId, 'p_branch': bid});
            for (final c in costs as List) {
              final pid = c['product_id'] as String?;
              if (pid != null) {
                final uc = (c['unit_cost'] as num?)?.toDouble() ?? 0;
                costMap[pid] = uc;
                anyCost[pid] = uc;
              }
            }
          } catch (_) { /* RPC unavailable -> fall back to cost_price below */ }
          final stock = await client.from('inventory_stock')
              .select('product_id, quantity').eq('org_id', orgId).eq('branch_id', bid);
          for (final s in stock as List) {
            final pid = s['product_id'] as String?;
            if (pid == null) continue;
            final q = (s['quantity'] as num?)?.toDouble() ?? 0;
            final cost = costMap[pid] ?? (byId[pid]?['cost_price'] as num?)?.toDouble() ?? 0;
            qtyMap[pid] = (qtyMap[pid] ?? 0) + q;
            valMap[pid] = (valMap[pid] ?? 0) + q * cost;
          }
        }
        for (final p in byId.values) {
          final pid = p['id'] as String;
          final qty = qtyMap[pid] ?? 0;
          final value = valMap[pid] ?? 0;
          // Weighted-average cost across branches; fallbacks for zero stock.
          final cost = qty.abs() > 1e-9
              ? value / qty
              : (anyCost[pid] ?? (p['cost_price'] as num?)?.toDouble() ?? 0);
          rows.add({
            'name': p['name'], 'sku': p['sku'],
            'main': p['product_main_group'], 'group': p['product_group'],
            'sub': p['product_sub_group'],
            'class': p['product_class'], 'mov': p['product_movement_category'],
            'uom': p['uoms']?['abbreviation'] ?? '',
            'qty': qty, 'cost': cost,
            'value': value,
          });
        }
        rows.sort((a, b) => (b['value'] as double).compareTo(a['value'] as double));
      }

      setState(() {
        _branches = branchList;
        _taxonomies = grouped;
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load: $e')));
    }
  }

  List<Map<String, dynamic>> get _filtered {
    var out = _rows.where((r) {
      if (_fMain != null && r['main'] != _fMain) return false;
      if (_fGroup != null && r['group'] != _fGroup) return false;
      if (_fSub != null && r['sub'] != _fSub) return false;
      if (_fClass != null && r['class'] != _fClass) return false;
      if (_fMov != null && r['mov'] != _fMov) return false;
      if (_hideZero && (r['qty'] as double) == 0) return false;
      if (_search.trim().isNotEmpty) {
        final q = _search.trim().toLowerCase();
        final name = (r['name'] as String? ?? '').toLowerCase();
        final sku = (r['sku'] as String? ?? '').toLowerCase();
        if (!name.contains(q) && !sku.contains(q)) return false;
      }
      return true;
    }).toList();
    if (_sortKey.isNotEmpty) {
      final dir = _sortAsc ? 1 : -1;
      out.sort((a, b) {
        final av = a[_sortKey]; final bv = b[_sortKey];
        int c;
        if (av is num && bv is num) { c = av.compareTo(bv); }
        else { c = (av?.toString() ?? '').toLowerCase().compareTo((bv?.toString() ?? '').toLowerCase()); }
        return c * dir;
      });
    }
    return out;
  }

  void _toggleSort(String key) {
    setState(() {
      if (_sortKey != key) { _sortKey = key; _sortAsc = true; }
      else if (_sortAsc) { _sortAsc = false; }
      else { _sortKey = ''; _sortAsc = true; }
    });
  }

  double get _totalValue => _filtered.fold(0.0, (s, r) => s + (r['value'] as double));

  String get _branchName {
    if (_selBranches.isEmpty) return _isAdmin ? 'All branches' : 'All my branches';
    final names = [
      for (final b in _branches)
        if (_selBranches.contains(b['id'])) (b['name'] as String? ?? '-')
    ];
    if (names.length == 1) return names.first;
    if (names.length <= 3) return names.join(', ');
    return '${names.length} branches';
  }

  String _money(double v) => money(v);

  Widget _sortHeader(String label, String key, {bool right = false}) {
    final active = _sortKey == key;
    return InkWell(
      onTap: () => _toggleSort(key),
      child: Row(
        mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(child: Text(label, textAlign: right ? TextAlign.right : TextAlign.left,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
          if (active) Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 13, color: AppTheme.textSecondary),
        ],
      ),
    );
  }

  Widget _filterDropdown(String label, String type, String? value, void Function(String?) onChanged) {
    final items = _taxonomies[type] ?? [];
    return SizedBox(width: 190, child: SearchableDropdown(
      label: label,
      value: value,
      allLabel: 'All',
      options: [
        for (final t in items) MapEntry(t['name'] as String?, t['name'] as String),
      ],
      onChanged: onChanged,
    ));
  }

  // Branch multi-select: checkbox dialog with search. Empty selection = All.
  Future<void> _pickBranches() async {
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _BranchMultiSelectDialog(
        branches: _branches,
        selected: Set<String>.from(_selBranches),
        allLabel: _isAdmin ? 'All branches' : 'All my branches',
      ),
    );
    if (picked == null) return; // cancelled
    setState(() => _selBranches = picked);
    _load();
  }

  void _print() {
    final list = _filtered;
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final now = DateTime.now();
    final dateStr = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final filters = <String>[];
    if (_fMain != null) filters.add('Main Group: $_fMain');
    if (_fGroup != null) filters.add('Group: $_fGroup');
    if (_fClass != null) filters.add('Class: $_fClass');
    if (_fMov != null) filters.add('Movement: $_fMov');
    final filterLine = filters.isEmpty ? 'All categories' : filters.join(' &middot; ');

    String esc(Object? v) => (v ?? '').toString().replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final body = list.map((r) {
      final qty = (r['qty'] as double); final cost = (r['cost'] as double); final value = (r['value'] as double);
      return '<tr>'
          '<td>${esc(r['name'])}</td>'
          '<td>${esc(r['sku'])}</td>'
          '<td>${esc(r['main'])}</td>'
          '<td>${esc(r['group'])}</td>'
          '<td>${esc(r['class'])}</td>'
          '<td style="text-align:right">${qty.toStringAsFixed(0)}</td>'
          '<td style="text-align:right">${_money(cost)}</td>'
          '<td style="text-align:right;font-weight:bold">${_money(value)}</td>'
          '</tr>';
    }).join();

    final htmlStr = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Stock Value Report</title>'
        '<style>'
        'body{font-family:Arial,Helvetica,sans-serif;color:#222;margin:24px}'
        'h1{font-size:18px;margin:0 0 2px}'
        '.muted{color:#666;font-size:12px;margin:2px 0}'
        'table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}'
        'th{background:#f4f5f7}'
        'tfoot td{font-weight:bold;background:#fafbfc}'
        '@page{size:landscape}'
        '</style></head><body>'
        '<h1>$orgName &mdash; Stock Value Report</h1>'
        '<div class="muted">Branch: ${esc(_branchName)} &middot; valued at inventory cost (cost layers)</div>'
        '<div class="muted">Filters: $filterLine</div>'
        '<div class="muted">Generated: $dateStr &middot; ${list.length} item(s) on hand</div>'
        '<table><thead><tr>'
        '<th>Product</th><th>SKU</th><th>Main Group</th><th>Group</th><th>Class</th>'
        '<th style="text-align:right">On Hand</th><th style="text-align:right">Unit Cost</th><th style="text-align:right">Stock Value</th>'
        '</tr></thead><tbody>$body</tbody>'
        '<tfoot><tr><td colspan="7" style="text-align:right">Total</td>'
        '<td style="text-align:right">${_money(_totalValue)}</td></tr></tfoot>'
        '</table>'
        '<script>window.onload=function(){window.print();}</script>'
        '</body></html>';

    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 4), () => html.Url.revokeObjectUrl(url));
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Stock Value Report', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          OutlinedButton.icon(onPressed: list.isEmpty ? null : _print, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
        ]),
        const SizedBox(height: 4),
        Text('Value of stock on hand, valued at inventory cost (cost layers). ${list.length} item${list.length == 1 ? '' : 's'}.',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 220, child: InkWell(
            onTap: _pickBranches,
            borderRadius: BorderRadius.circular(4),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Branch', isDense: true, border: OutlineInputBorder(),
                suffixIcon: Icon(Icons.arrow_drop_down),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
              child: Text(_branchName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
          )),
          SizedBox(width: 240, child: TextField(
            decoration: const InputDecoration(
              labelText: 'Search product (name or SKU)', isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            onChanged: (v) => setState(() => _search = v),
          )),
          _filterDropdown('Main Group', 'main_group', _fMain, (v) => setState(() => _fMain = v)),
          _filterDropdown('Group', 'group', _fGroup, (v) => setState(() => _fGroup = v)),
          _filterDropdown('Sub Group', 'sub_group', _fSub, (v) => setState(() => _fSub = v)),
          _filterDropdown('Class', 'class', _fClass, (v) => setState(() => _fClass = v)),
          _filterDropdown('Movement Category', 'movement_category', _fMov, (v) => setState(() => _fMov = v)),
          if (_fMain != null || _fGroup != null || _fSub != null || _fClass != null || _fMov != null)
            TextButton.icon(onPressed: () => setState(() { _fMain = null; _fGroup = null; _fSub = null; _fClass = null; _fMov = null; }),
                icon: const Icon(Icons.clear, size: 16), label: const Text('Clear filters')),
          FilterChip(
            label: const Text('Hide zero-stock'),
            selected: _hideZero,
            onSelected: (v) => setState(() => _hideZero = v),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _summaryCard('Stock Value (cost)', 'Rs. ${_money(_totalValue)}', AppTheme.primary),
        ]),
        const SizedBox(height: 16),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                    child: Row(children: [
                      Expanded(flex: 3, child: _sortHeader('Product', 'name')),
                      Expanded(flex: 2, child: _sortHeader('SKU', 'sku')),
                      Expanded(flex: 2, child: _sortHeader('Group', 'group')),
                      Expanded(flex: 1, child: _sortHeader('On Hand', 'qty', right: true)),
                      Expanded(flex: 2, child: _sortHeader('Unit Cost', 'cost', right: true)),
                      Expanded(flex: 2, child: _sortHeader('Stock Value', 'value', right: true)),
                    ]),
                  ),
                  Expanded(child: list.isEmpty
                      ? const Center(child: Text('No stock on hand for this branch / filter.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = list[i];
                            final qty = (r['qty'] as double); final cost = (r['cost'] as double); final value = (r['value'] as double);
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                              child: Row(children: [
                                Expanded(flex: 3, child: Text(r['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                                Expanded(flex: 2, child: Text(r['sku'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(r['group'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 1, child: Text(qty.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 2, child: Text(_money(cost), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(_money(value), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary))),
                              ]),
                            );
                          },
                        )),
                ]),
              )),
      ]),
    );
  }

  Widget _summaryCard(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.25))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
    ]),
  );
}

/// Checkbox multi-select for branches with a search box.
/// Pops with the chosen id set — an EMPTY set means "All".
class _BranchMultiSelectDialog extends StatefulWidget {
  final List<Map<String, dynamic>> branches;
  final Set<String> selected;
  final String allLabel;
  const _BranchMultiSelectDialog({required this.branches, required this.selected, required this.allLabel});
  @override
  State<_BranchMultiSelectDialog> createState() => _BranchMultiSelectDialogState();
}

class _BranchMultiSelectDialogState extends State<_BranchMultiSelectDialog> {
  late Set<String> _sel;
  final _searchCtrl = TextEditingController();

  @override
  void initState() { super.initState(); _sel = Set<String>.from(widget.selected); }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final q = _searchCtrl.text.trim().toLowerCase();
    final matches = q.isEmpty
        ? widget.branches
        : widget.branches.where((b) => (b['name'] as String? ?? '').toLowerCase().contains(q)).toList();
    return AlertDialog(
      title: const Text('Select branches', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _searchCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Search branch...', isDense: true,
              prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(widget.allLabel, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            value: _sel.isEmpty,
            onChanged: (_) => setState(() => _sel.clear()),
          ),
          const Divider(height: 1),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final b in matches)
                    CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(b['name'] as String? ?? '-', style: const TextStyle(fontSize: 13.5)),
                      value: _sel.contains(b['id']),
                      onChanged: (v) => setState(() {
                        if (v == true) { _sel.add(b['id'] as String); }
                        else { _sel.remove(b['id']); }
                      }),
                    ),
                  if (matches.isEmpty)
                    const Padding(padding: EdgeInsets.all(20),
                        child: Text('No matches.', textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: Colors.grey))),
                ],
              ),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _sel),
          child: Text(_sel.isEmpty ? 'Apply (All)' : 'Apply (${_sel.length})'),
        ),
      ],
    );
  }
}
