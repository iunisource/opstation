// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpStockScreen extends ConsumerStatefulWidget {
  const ErpStockScreen({super.key});
  @override
  ConsumerState<ErpStockScreen> createState() => _ErpStockScreenState();
}

class _ErpStockScreenState extends ConsumerState<ErpStockScreen> {
  List<Map<String, dynamic>> _stock = [];
  List<Map<String, dynamic>> _filtered = [];
  List<Map<String, dynamic>> _branches = []; // all active branches (incl. processors)
  bool _loading = true;
  final _searchCtrl = TextEditingController();
  final Set<String> _selectedBranches = {}; // empty => all branches
  final Set<String> _expandedNames = {}; // productIds whose full name is expanded

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final stock = await client
          .from('inventory_stock')
          .select('*, products(name, sku), branches(name), uoms(abbreviation)')
          .eq('org_id', orgId)
          .order('quantity', ascending: false);
      // All active branches — including processor / off-site (is_virtual) so
      // stock parked at processors is visible here.
      final branches = await client
          .from('branches')
          .select('id, name, is_virtual')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      setState(() {
        _stock = List<Map<String, dynamic>>.from(stock);
        _filtered = _stock;
        _branches = List<Map<String, dynamic>>.from(branches);
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _stock.where((s) {
        final productName = (s['products']?['name'] as String? ?? '').toLowerCase();
        final sku = (s['products']?['sku'] as String? ?? '').toLowerCase();
        return q.isEmpty || productName.contains(q) || sku.contains(q);
      }).toList();
    });
  }

  // Branch columns to display: selected subset, else all branches.
  List<Map<String, dynamic>> get _displayBranches =>
      _selectedBranches.isEmpty ? _branches : _branches.where((b) => _selectedBranches.contains(b['id'])).toList();

  // One row per product; quantities split across branches.
  List<_PivotRow> _pivotRows() {
    final map = <String, _PivotRow>{};
    for (final s in _filtered) {
      final pid = s['product_id'] as String? ?? (s['products']?['sku'] as String? ?? '');
      final row = map.putIfAbsent(pid, () => _PivotRow(
            productId: s['product_id'] as String?,
            name: s['products']?['name'] as String? ?? '',
            sku: s['products']?['sku'] as String? ?? '-',
            uom: s['uoms']?['abbreviation'] as String? ?? '',
          ));
      final b = s['branch_id'] as String?;
      final qty = (s['quantity'] as num?)?.toDouble() ?? 0;
      if (b != null) row.byBranch[b] = (row.byBranch[b] ?? 0) + qty;
    }
    return map.values.toList();
  }

  String _fmtQty(double? q, String uom) {
    if (q == null || q == 0) return '—';
    final s = q % 1 == 0 ? q.toInt().toString() : q.toStringAsFixed(2);
    return uom.isEmpty ? s : '$s $uom';
  }

  void _openLedger(String? productId) {
    if (productId == null) return;
    // GoRouter uses the hash URL strategy, so a new-tab deep link needs '/#/'.
    final origin = html.window.location.origin;
    html.window.open('$origin/#/erp/inventory-ledger?focus=$productId', '_blank');
  }

  void _printStock(List<Map<String, dynamic>> cols, List<_PivotRow> rows) {
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final gen = '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}';
    String esc(Object? v) => (v ?? '').toString().replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final head = StringBuffer('<tr><th>Product</th><th>SKU</th>');
    for (final b in cols) head.write('<th class="r">${esc(b['name'])}</th>');
    head.write('<th class="r">Total</th></tr>');
    final body = StringBuffer();
    for (final r in rows) {
      body.write('<tr><td>${esc(r.name)}</td><td>${esc(r.sku)}</td>');
      for (final b in cols) body.write('<td class="r">${esc(_fmtQty(r.byBranch[b['id']], r.uom))}</td>');
      body.write('<td class="r b">${esc(_fmtQty(r.total, r.uom))}</td></tr>');
    }
    final htmlStr = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Stock Levels</title>'
        '<style>@page{margin:0}body{font-family:Arial,Helvetica,sans-serif;color:#222;margin:24px}'
        'h1{font-size:18px;margin:0 0 2px}.muted{color:#666;font-size:12px;margin:2px 0}'
        'table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}th{background:#f4f5f7}'
        '.r{text-align:right}.b{font-weight:700}</style></head><body>'
        '<h1>${esc(orgName)} &mdash; Stock Levels</h1>'
        '<div class="muted">Generated: $gen &middot; ${rows.length} products</div>'
        '<table><thead>$head</thead><tbody>$body</tbody></table>'
        '<script>window.onload=function(){window.print();}</script></body></html>';
    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 4), () => html.Url.revokeObjectUrl(url));
  }

  @override
  Widget build(BuildContext context) {
    final cols = _displayBranches;
    // Rows with any stock across the displayed branches, richest first.
    final rows = _pivotRows()
        .map((r) {
          r.total = cols.fold<double>(0, (a, b) => a + (r.byBranch[b['id']] ?? 0));
          return r;
        })
        .where((r) => r.total != 0)
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));

    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Stock Levels', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: rows.isEmpty ? null : () => _printStock(cols, rows),
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Print / PDF'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${rows.length} products', style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search by product name or SKU...',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 12),
          // Branch multi-select: "All branches" + one chip per branch.
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Branches:', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            FilterChip(
              label: const Text('All branches'),
              selected: _selectedBranches.isEmpty,
              onSelected: (_) => setState(() => _selectedBranches.clear()),
            ),
            for (final b in _branches)
              FilterChip(
                label: Text(b['name'] as String? ?? '-'),
                selected: _selectedBranches.contains(b['id']),
                onSelected: (sel) => setState(() {
                  final id = b['id'] as String;
                  if (sel) { _selectedBranches.add(id); } else { _selectedBranches.remove(id); }
                }),
              ),
          ]),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(child: _buildPivot(cols, rows)),
        ],
      ),
    );
  }

  Widget _buildPivot(List<Map<String, dynamic>> cols, List<_PivotRow> rows) {
    const wProd = 360.0, wSku = 90.0, wBranch = 150.0, wTotal = 170.0, pad = 20.0;
    final contentW = wProd + wSku + cols.length * wBranch + wTotal;
    final tableW = contentW + pad * 2; // account for the row's horizontal padding

    Widget headerCell(String t, double w, {bool right = false}) => SizedBox(
          width: w,
          child: Text(t,
              textAlign: right ? TextAlign.right : TextAlign.left,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary)),
        );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No stock in the selected branches.',
                    textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)),
              ))
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: tableW < 600 ? 600 : tableW,
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: pad, vertical: 12),
                    decoration: const BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: Row(children: [
                      headerCell('Product', wProd),
                      headerCell('SKU', wSku),
                      for (final b in cols) headerCell(b['name'] as String? ?? '-', wBranch, right: true),
                      headerCell('Total', wTotal, right: true),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = rows[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: pad, vertical: 12),
                          child: Row(children: [
                            SizedBox(
                              width: wProd,
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                // Tap the name to expand/collapse the full text when
                                // it's longer than the column; the icon opens the ledger.
                                Expanded(
                                  child: InkWell(
                                    onTap: () => setState(() {
                                      final k = r.productId ?? r.sku;
                                      if (!_expandedNames.remove(k)) _expandedNames.add(k);
                                    }),
                                    child: Text(r.name,
                                        maxLines: _expandedNames.contains(r.productId ?? r.sku) ? null : 1,
                                        overflow: _expandedNames.contains(r.productId ?? r.sku)
                                            ? TextOverflow.visible : TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary)),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                InkWell(
                                  onTap: () => _openLedger(r.productId),
                                  child: const Padding(
                                    padding: EdgeInsets.only(top: 2),
                                    child: Icon(Icons.open_in_new, size: 13, color: AppTheme.textSecondary),
                                  ),
                                ),
                              ]),
                            ),
                            SizedBox(width: wSku, child: Text(r.sku, style: const TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                            for (final b in cols)
                              SizedBox(
                                width: wBranch,
                                child: Text(_fmtQty(r.byBranch[b['id']], r.uom),
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: (r.byBranch[b['id']] ?? 0) > 0 ? Colors.black87 : AppTheme.textSecondary)),
                              ),
                            SizedBox(
                              width: wTotal,
                              child: Text(_fmtQty(r.total, r.uom),
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: r.total <= 0 ? AppTheme.danger : Colors.black87)),
                            ),
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
}

class _PivotRow {
  final String? productId;
  final String name;
  final String sku;
  final String uom;
  final Map<String, double> byBranch = {};
  double total = 0;
  _PivotRow({required this.productId, required this.name, required this.sku, required this.uom});
}
