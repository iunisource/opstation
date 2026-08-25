// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpLowStockReportScreen extends ConsumerStatefulWidget {
  const ErpLowStockReportScreen({super.key});
  @override
  ConsumerState<ErpLowStockReportScreen> createState() => _ErpLowStockReportScreenState();
}

class _ErpLowStockReportScreenState extends ConsumerState<ErpLowStockReportScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];      // low-stock rows for the branch
  List<Map<String, dynamic>> _branches = [];
  Map<String, List<Map<String, dynamic>>> _taxonomies = {};
  String? _branchId;
  String? _fMain, _fGroup, _fClass, _fMov;
  final Set<String> _selected = {}; // product ids selected for a bulk PO

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
            .select('id, name, sku, low_stock_limit, product_main_group, product_group, product_class, product_movement_category, uoms(abbreviation)')
            .eq('org_id', orgId).eq('is_active', true);
        final byId = {for (final p in products as List) p['id'] as String: Map<String, dynamic>.from(p)};
        final stock = await client.from('inventory_stock')
            .select('product_id, quantity').eq('org_id', orgId).eq('branch_id', _branchId!);
        for (final s in stock as List) {
          final pid = s['product_id'] as String?;
          if (pid == null) continue;
          final p = byId[pid];
          if (p == null) continue;
          final limit = (p['low_stock_limit'] as num?)?.toDouble() ?? 0;
          if (limit <= 0) continue;                 // no threshold set
          final qty = (s['quantity'] as num?)?.toDouble() ?? 0;
          if (qty > limit) continue;                // above threshold → fine
          rows.add({
            'id': pid,
            'name': p['name'], 'sku': p['sku'],
            'main': p['product_main_group'], 'group': p['product_group'],
            'class': p['product_class'], 'mov': p['product_movement_category'],
            'uom': p['uoms']?['abbreviation'] ?? '',
            'qty': qty, 'limit': limit, 'short': (limit - qty),
          });
        }
        rows.sort((a, b) => (b['short'] as double).compareTo(a['short'] as double));
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

  String get _branchName => (_branches.firstWhere((b) => b['id'] == _branchId, orElse: () => {})['name'] as String?) ?? '-';

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
      final qty = (r['qty'] as double); final lim = (r['limit'] as double); final sh = (r['short'] as double);
      return '<tr>'
          '<td>${esc(r['name'])}</td>'
          '<td>${esc(r['sku'])}</td>'
          '<td>${esc(r['main'])}</td>'
          '<td>${esc(r['group'])}</td>'
          '<td>${esc(r['class'])}</td>'
          '<td>${esc(r['mov'])}</td>'
          '<td style="text-align:right">${qty.toStringAsFixed(0)}</td>'
          '<td style="text-align:right">${lim.toStringAsFixed(0)}</td>'
          '<td style="text-align:right;color:#c0392b;font-weight:bold">${sh.toStringAsFixed(0)}</td>'
          '<td>${esc(r['uom'])}</td>'
          '</tr>';
    }).join();

    final htmlStr = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Low Stock Report</title>'
        '<style>@page{margin:0}'
        'body{font-family:Arial,Helvetica,sans-serif;color:#222;margin:24px}'
        'h1{font-size:18px;margin:0 0 2px}'
        '.muted{color:#666;font-size:12px;margin:2px 0}'
        'table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}'
        'th{background:#f4f5f7}'
        '@page{size:landscape}'
        '</style></head><body>'
        '<h1>$orgName &mdash; Low Stock Report</h1>'
        '<div class="muted">Branch: ${esc(_branchName)}</div>'
        '<div class="muted">Filters: $filterLine</div>'
        '<div class="muted">Generated: $dateStr &middot; ${list.length} item(s) at or below limit</div>'
        '<table><thead><tr>'
        '<th>Product</th><th>SKU</th><th>Main Group</th><th>Group</th><th>Class</th><th>Movement</th>'
        '<th style="text-align:right">On Hand</th><th style="text-align:right">Limit</th><th style="text-align:right">Short</th><th>UOM</th>'
        '</tr></thead><tbody>$body</tbody></table>'
        '<script>window.onload=function(){window.print();}</script>'
        '</body></html>';

    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 4), () => html.Url.revokeObjectUrl(url));
  }

  // Jump to the Purchase Order screen seeded with this product + shortfall qty
  // and the branch this report is scoped to, so a new PO opens ready to add.
  void _makePo(Map<String, dynamic> r) {
    final pid = r['id'] as String?;
    if (pid == null) return;
    final short = (r['short'] as double?) ?? 0;
    final qty = short > 0 ? short : ((r['limit'] as double?) ?? 1);
    final params = {
      'seedProduct': pid,
      'seedQty': qty % 1 == 0 ? qty.toStringAsFixed(0) : qty.toStringAsFixed(2),
      if (_branchId != null) 'seedBranch': _branchId!,
    };
    final qs = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    context.go('/erp/purchase?$qs');
  }

  // Bulk "Make PO" — seed one PO with every selected shortfall line.
  void _makePoBulk() {
    final chosen = _filtered.where((r) => _selected.contains(r['id'])).toList();
    if (chosen.isEmpty) return;
    final ids = <String>[]; final qtys = <String>[];
    for (final r in chosen) {
      final pid = r['id'] as String?; if (pid == null) continue;
      final short = (r['short'] as double?) ?? 0;
      final q = short > 0 ? short : ((r['limit'] as double?) ?? 1);
      ids.add(pid);
      qtys.add(q % 1 == 0 ? q.toStringAsFixed(0) : q.toStringAsFixed(2));
    }
    final params = {
      'seedProduct': ids.join(','),
      'seedQty': qtys.join(','),
      if (_branchId != null) 'seedBranch': _branchId!,
    };
    final qs = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    context.go('/erp/purchase?$qs');
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Low Stock Report', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (_selected.isNotEmpty) ...[
            ElevatedButton.icon(
              onPressed: _makePoBulk,
              icon: const Icon(Icons.add_shopping_cart, size: 16),
              label: Text('Make PO (${_selected.length})'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            ),
            const SizedBox(width: 10),
          ],
          OutlinedButton.icon(onPressed: list.isEmpty ? null : _print, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
        ]),
        const SizedBox(height: 4),
        Text('Products at or below their low stock limit. ${list.length} item${list.length == 1 ? '' : 's'} shown.',
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
                      SizedBox(width: 40, child: Checkbox(
                        value: list.isNotEmpty && list.every((r) => _selected.contains(r['id'])),
                        tristate: true,
                        onChanged: (v) => setState(() {
                          final allSel = list.every((r) => _selected.contains(r['id']));
                          if (allSel) { _selected.clear(); }
                          else { _selected.addAll(list.map((r) => r['id'] as String)); }
                        }),
                        visualDensity: VisualDensity.compact,
                      )),
                      const Expanded(flex: 3, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Group', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Class', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('On Hand', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('Limit', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('Short', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 108, child: Text('', textAlign: TextAlign.right)),
                    ]),
                  ),
                  Expanded(child: list.isEmpty
                      ? const Center(child: Text('No products are at or below their low stock limit.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = list[i];
                            final qty = (r['qty'] as double); final lim = (r['limit'] as double); final sh = (r['short'] as double);
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                              child: Row(children: [
                                SizedBox(width: 40, child: Checkbox(
                                  value: _selected.contains(r['id']),
                                  onChanged: (v) => setState(() {
                                    if (v == true) { _selected.add(r['id'] as String); }
                                    else { _selected.remove(r['id']); }
                                  }),
                                  visualDensity: VisualDensity.compact,
                                )),
                                Expanded(flex: 3, child: Text(r['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                                Expanded(flex: 2, child: Text(r['sku'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(r['group'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(r['class'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 1, child: Text(qty.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 1, child: Text(lim.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 1, child: Text(sh.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.danger))),
                                SizedBox(width: 108, child: Align(
                                  alignment: Alignment.centerRight,
                                  child: OutlinedButton.icon(
                                    onPressed: () => _makePo(r),
                                    icon: const Icon(Icons.add_shopping_cart, size: 14),
                                    label: const Text('Make PO', style: TextStyle(fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      visualDensity: VisualDensity.compact,
                                      minimumSize: const Size(0, 32)),
                                  ),
                                )),
                              ]),
                            );
                          },
                        )),
                ]),
              )),
      ]),
    );
  }
}
