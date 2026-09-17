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
  List<Map<String, dynamic>> _branches = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();
  String? _branchFilter;

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
      final branches = await client
          .from('branches')
          .select()
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
        final matchesSearch = q.isEmpty || productName.contains(q) || sku.contains(q);
        final matchesBranch = _branchFilter == null ||
            s['branch_id'] == _branchFilter;
        return matchesSearch && matchesBranch;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Stock Levels',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('${_pivotRows().length} products',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  hintText: 'Search by product name or SKU...',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                value: _branchFilter,
                decoration: const InputDecoration(labelText: 'Branch', isDense: true),
                hint: const Text('All branches'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All branches')),
                  ..._branches.map((w) => DropdownMenuItem(
                      value: w['id'] as String,
                      child: Text(w['name'] as String))),
                ],
                onChanged: (v) {
                  setState(() => _branchFilter = v);
                  _filter();
                },
              ),
            ),
          ]),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(child: _buildPivot()),
        ],
      ),
    );
  }

  // Branches that actually appear in the filtered stock, ordered like _branches.
  List<Map<String, dynamic>> get _displayBranches {
    final ids = <String>{};
    for (final s in _filtered) {
      final b = s['branch_id'] as String?;
      if (b != null) ids.add(b);
    }
    return _branches.where((b) => ids.contains(b['id'])).toList();
  }

  // One row per product; quantity split across branch columns.
  List<_PivotRow> _pivotRows() {
    final map = <String, _PivotRow>{};
    for (final s in _filtered) {
      final pid = s['product_id'] as String? ?? (s['products']?['sku'] as String? ?? '');
      final row = map.putIfAbsent(pid, () => _PivotRow(
            name: s['products']?['name'] as String? ?? '',
            sku: s['products']?['sku'] as String? ?? '-',
            uom: s['uoms']?['abbreviation'] as String? ?? '',
          ));
      final b = s['branch_id'] as String?;
      final qty = (s['quantity'] as num?)?.toDouble() ?? 0;
      if (b != null) row.byBranch[b] = (row.byBranch[b] ?? 0) + qty;
    }
    final rows = map.values.toList();
    for (final r in rows) {
      r.total = r.byBranch.values.fold(0.0, (a, b) => a + b);
    }
    rows.sort((a, b) => b.total.compareTo(a.total));
    return rows;
  }

  String _fmtQty(double? q, String uom) {
    if (q == null || q == 0) return '—';
    final s = q % 1 == 0 ? q.toInt().toString() : q.toStringAsFixed(2);
    return uom.isEmpty ? s : '$s $uom';
  }

  Widget _buildPivot() {
    final cols = _displayBranches;
    final rows = _pivotRows();
    const wProd = 260.0, wSku = 100.0, wBranch = 150.0, wTotal = 160.0;
    final totalW = wProd + wSku + cols.length * wBranch + wTotal;

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
                child: Text('No stock entries yet.\nReceive a purchase order to populate stock.',
                    textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)),
              ))
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: totalW < 600 ? 600 : totalW,
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          child: Row(children: [
                            SizedBox(width: wProd, child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                            SizedBox(width: wSku, child: Text(r.sku, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600))),
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
  final String name;
  final String sku;
  final String uom;
  final Map<String, double> byBranch = {};
  double total = 0;
  _PivotRow({required this.name, required this.sku, required this.uom});
}
