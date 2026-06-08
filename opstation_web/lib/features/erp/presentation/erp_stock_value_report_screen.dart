// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpStockValueReportScreen extends ConsumerStatefulWidget {
  const ErpStockValueReportScreen({super.key});
  @override
  ConsumerState<ErpStockValueReportScreen> createState() => _ErpStockValueReportScreenState();
}

class _ErpStockValueReportScreenState extends ConsumerState<ErpStockValueReportScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];      // valued stock rows for the branch
  List<Map<String, dynamic>> _branches = [];
  Map<String, List<Map<String, dynamic>>> _taxonomies = {};
  String? _branchId;
  String? _fMain, _fGroup, _fClass, _fMov;

  @override
  void initState() {
    super.initState();
    _branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    _load();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final branches = await client.from('branches').select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
      final branchList = List<Map<String, dynamic>>.from(branches);
      _branchId ??= branchList.isNotEmpty ? branchList.first['id'] as String : null;

      final taxonomies = await client.from('product_taxonomies').select().eq('org_id', orgId).order('name');
      final Map<String, List<Map<String, dynamic>>> grouped = {};
      for (final t in taxonomies as List) {
        grouped.putIfAbsent(t['taxonomy_type'] as String, () => []).add(Map<String, dynamic>.from(t));
      }

      final List<Map<String, dynamic>> rows = [];
      if (_branchId != null) {
        final products = await client.from('products')
            .select('id, name, sku, cost_price, selling_price, product_main_group, product_group, product_class, product_movement_category, uoms(abbreviation)')
            .eq('org_id', orgId).eq('is_active', true);
        final byId = {for (final p in products as List) p['id'] as String: Map<String, dynamic>.from(p)};

        // Engine-costed unit costs from the cost layers (weighted-average of remaining
        // layers, matching current_unit_cost). One RPC call for the whole branch.
        final Map<String, double> costMap = {};
        try {
          final costs = await client.rpc('rpc_stock_unit_costs', params: {'p_org': orgId, 'p_branch': _branchId});
          for (final c in costs as List) {
            final pid = c['product_id'] as String?;
            if (pid != null) costMap[pid] = (c['unit_cost'] as num?)?.toDouble() ?? 0;
          }
        } catch (_) { /* RPC unavailable -> fall back to cost_price below */ }

        final stock = await client.from('inventory_stock')
            .select('product_id, quantity').eq('org_id', orgId).eq('branch_id', _branchId!);
        for (final s in stock as List) {
          final pid = s['product_id'] as String?;
          if (pid == null) continue;
          final p = byId[pid];
          if (p == null) continue;
          final qty = (s['quantity'] as num?)?.toDouble() ?? 0;
          if (qty == 0) continue;                       // only on-hand stock
          // engine cost first; fall back to product cost_price when no remaining layers
          final cost = costMap[pid] ?? (p['cost_price'] as num?)?.toDouble() ?? 0;
          final sell = (p['selling_price'] as num?)?.toDouble() ?? 0;
          rows.add({
            'name': p['name'], 'sku': p['sku'],
            'main': p['product_main_group'], 'group': p['product_group'],
            'class': p['product_class'], 'mov': p['product_movement_category'],
            'uom': p['uoms']?['abbreviation'] ?? '',
            'qty': qty, 'cost': cost, 'sell': sell,
            'value': qty * cost, 'retail': qty * sell,
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

  List<Map<String, dynamic>> get _filtered => _rows.where((r) {
    if (_fMain != null && r['main'] != _fMain) return false;
    if (_fGroup != null && r['group'] != _fGroup) return false;
    if (_fClass != null && r['class'] != _fClass) return false;
    if (_fMov != null && r['mov'] != _fMov) return false;
    return true;
  }).toList();

  double get _totalValue => _filtered.fold(0.0, (s, r) => s + (r['value'] as double));
  double get _totalRetail => _filtered.fold(0.0, (s, r) => s + (r['retail'] as double));

  String get _branchName => (_branches.firstWhere((b) => b['id'] == _branchId, orElse: () => {})['name'] as String?) ?? '-';

  String _money(double v) {
    final s = v.toStringAsFixed(2);
    final parts = s.split('.');
    final intPart = parts[0];
    final neg = intPart.startsWith('-');
    final digits = neg ? intPart.substring(1) : intPart;
    final buf = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return '${neg ? '-' : ''}${buf.toString()}.${parts[1]}';
  }

  Widget _filterDropdown(String label, String type, String? value, void Function(String?) onChanged) {
    final items = _taxonomies[type] ?? [];
    return SizedBox(width: 190, child: DropdownButtonFormField<String?>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('All')),
        ...items.map((t) => DropdownMenuItem<String?>(value: t['name'] as String, child: Text(t['name'] as String, overflow: TextOverflow.ellipsis))),
      ],
      onChanged: onChanged,
    ));
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
      final qty = (r['qty'] as double); final cost = (r['cost'] as double); final value = (r['value'] as double); final retail = (r['retail'] as double);
      return '<tr>'
          '<td>${esc(r['name'])}</td>'
          '<td>${esc(r['sku'])}</td>'
          '<td>${esc(r['main'])}</td>'
          '<td>${esc(r['group'])}</td>'
          '<td>${esc(r['class'])}</td>'
          '<td style="text-align:right">${qty.toStringAsFixed(0)}</td>'
          '<td style="text-align:right">${_money(cost)}</td>'
          '<td style="text-align:right;font-weight:bold">${_money(value)}</td>'
          '<td style="text-align:right">${_money(retail)}</td>'
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
        '<th style="text-align:right">On Hand</th><th style="text-align:right">Unit Cost</th><th style="text-align:right">Stock Value</th><th style="text-align:right">Retail Value</th>'
        '</tr></thead><tbody>$body</tbody>'
        '<tfoot><tr><td colspan="7" style="text-align:right">Total</td>'
        '<td style="text-align:right">${_money(_totalValue)}</td>'
        '<td style="text-align:right">${_money(_totalRetail)}</td></tr></tfoot>'
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
          SizedBox(width: 220, child: DropdownButtonFormField<String>(
            value: _branchId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Branch', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            items: _branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '-', overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) { setState(() => _branchId = v); _load(); },
          )),
          _filterDropdown('Main Group', 'main_group', _fMain, (v) => setState(() => _fMain = v)),
          _filterDropdown('Group', 'group', _fGroup, (v) => setState(() => _fGroup = v)),
          _filterDropdown('Class', 'class', _fClass, (v) => setState(() => _fClass = v)),
          _filterDropdown('Movement Category', 'movement_category', _fMov, (v) => setState(() => _fMov = v)),
          if (_fMain != null || _fGroup != null || _fClass != null || _fMov != null)
            TextButton.icon(onPressed: () => setState(() { _fMain = null; _fGroup = null; _fClass = null; _fMov = null; }),
                icon: const Icon(Icons.clear, size: 16), label: const Text('Clear filters')),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _summaryCard('Stock Value (cost)', 'Rs. ${_money(_totalValue)}', AppTheme.primary),
          const SizedBox(width: 12),
          _summaryCard('Retail Value', 'Rs. ${_money(_totalRetail)}', AppTheme.success),
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
                    child: const Row(children: [
                      Expanded(flex: 3, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Group', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('On Hand', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Unit Cost', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Stock Value', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
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
