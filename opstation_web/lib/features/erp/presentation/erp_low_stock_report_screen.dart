// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../../../core/widgets/responsive.dart';

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
      // All three lookups are independent — fetch them together. Products are
      // filtered SERVER-SIDE to those with a low-stock threshold (the only ones
      // this report can ever show), which cuts the payload from the whole
      // catalogue to a handful of rows and was the main cause of the slow load.
      final results = await Future.wait([
        client.from('branches').select('id, name, is_virtual').eq('org_id', orgId).eq('is_active', true).order('name'),
        client.from('product_taxonomies').select().eq('org_id', orgId).order('name'),
        client.from('products')
            .select('id, name, sku, low_stock_limit, product_main_group, product_group, product_class, product_movement_category, uoms(abbreviation)')
            .eq('org_id', orgId).eq('is_active', true)
            .gt('low_stock_limit', 0)
            .limit(10000),
      ]);
      // Real branches only — processor / off-site (virtual) locations hold
      // stock out for processing and have no low-stock limits of their own.
      final branchList = List<Map<String, dynamic>>.from(results[0] as List)
          .where((b) => b['is_virtual'] != true).toList();
      if (_branchId == null || !branchList.any((b) => b['id'] == _branchId)) {
        _branchId = branchList.isNotEmpty ? branchList.first['id'] as String : null;
      }

      final Map<String, List<Map<String, dynamic>>> grouped = {};
      for (final t in results[1] as List) {
        grouped.putIfAbsent(t['taxonomy_type'] as String, () => []).add(Map<String, dynamic>.from(t));
      }

      final List<Map<String, dynamic>> rows = [];
      if (_branchId != null) {
        final byId = {for (final p in results[2] as List) p['id'] as String: Map<String, dynamic>.from(p)};
        // Only this branch's stock for the threshold products.
        final Map<String, double> qtyById = {};
        if (byId.isNotEmpty) {
          final ids = byId.keys.toList();
          for (var i = 0; i < ids.length; i += 200) {
            final chunk = ids.sublist(i, i + 200 > ids.length ? ids.length : i + 200);
            final stock = await client.from('inventory_stock')
                .select('product_id, quantity')
                .eq('org_id', orgId).eq('branch_id', _branchId!)
                .inFilter('product_id', chunk);
            for (final s in stock as List) {
              final pid = s['product_id'] as String?;
              if (pid == null) continue;
              qtyById[pid] = (qtyById[pid] ?? 0) + ((s['quantity'] as num?)?.toDouble() ?? 0);
            }
          }
        }
        byId.forEach((pid, p) {
          final limit = (p['low_stock_limit'] as num?)?.toDouble() ?? 0;
          if (limit <= 0) return;
          // No stock row at this branch = zero on hand — that IS low stock;
          // the old load silently skipped these products entirely.
          final qty = qtyById[pid] ?? 0;
          if (qty > limit) return; // above threshold — fine
          rows.add({
            'id': pid,
            'name': p['name'], 'sku': p['sku'],
            'main': p['product_main_group'], 'group': p['product_group'],
            'class': p['product_class'], 'mov': p['product_movement_category'],
            'uom': p['uoms']?['abbreviation'] ?? '',
            'qty': qty, 'limit': limit, 'short': (limit - qty),
          });
        });
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
    return _searchSelect(
      label: label, width: 190, value: value, allowAll: true,
      options: [for (final t in items) (t['name'] as String, t['name'] as String)],
      onChanged: onChanged,
    );
  }

  /// A dropdown-looking field that opens a searchable list.
  Widget _searchSelect({
    required String label,
    required double width,
    required String? value,
    required List<(String, String)> options, // (value, label)
    required void Function(String?) onChanged,
    bool allowAll = false,
  }) {
    String shown = allowAll ? 'All' : '—';
    for (final o in options) { if (o.$1 == value) { shown = o.$2; break; } }
    return SizedBox(width: width, child: InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        String q = '';
        final picked = await showDialog<(bool, String?)>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
          final list = options.where((o) => q.isEmpty || o.$2.toLowerCase().contains(q.toLowerCase())).toList();
          return AlertDialog(
            title: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            content: SizedBox(width: 360, height: 420, child: Column(children: [
              TextField(autofocus: true, onChanged: (v) => setD(() => q = v),
                  decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder())),
              const SizedBox(height: 6),
              Expanded(child: ListView(children: [
                if (allowAll && q.isEmpty)
                  ListTile(dense: true, title: const Text('All', style: TextStyle(fontWeight: FontWeight.w600)),
                      selected: value == null, onTap: () => Navigator.pop(ctx, (true, null))),
                for (final o in list)
                  ListTile(dense: true, title: Text(o.$2), selected: o.$1 == value,
                      trailing: o.$1 == value ? const Icon(Icons.check, size: 16) : null,
                      onTap: () => Navigator.pop(ctx, (true, o.$1))),
                if (list.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No match', style: TextStyle(color: AppTheme.textSecondary))),
              ])),
            ])),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
          );
        }));
        if (picked != null && picked.$1) onChanged(picked.$2);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            suffixIcon: const Icon(Icons.arrow_drop_down)),
        child: Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
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
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
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
          _searchSelect(
            label: 'Branch', width: 220, value: _branchId,
            options: [for (final b in _branches) (b['id'] as String, b['name'] as String? ?? '-')],
            onChanged: (v) { if (v == null) return; setState(() => _branchId = v); _load(); },
          ),
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
            : HScrollOnNarrow(minWidth: 1100, child: Container(
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
              ))),
      ]),
    );
  }
}
