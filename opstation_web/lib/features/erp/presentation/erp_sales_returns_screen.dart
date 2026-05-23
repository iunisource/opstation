import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';

class ErpSalesReturnsScreen extends ConsumerStatefulWidget {
  const ErpSalesReturnsScreen({super.key});
  @override
  ConsumerState<ErpSalesReturnsScreen> createState() => _ErpSalesReturnsScreenState();
}

class _ErpSalesReturnsScreenState extends ConsumerState<ErpSalesReturnsScreen> {
  List<Map<String, dynamic>> _returns = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';

  @override
  void initState() { super.initState(); _loadList(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _canDelete {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('sales_returns')
          .select('id, voucher_number, voucher_date, grand_total, status, customers(shop_name), sales_invoices(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final returns = await q.order('voucher_date', ascending: false).order('voucher_number', ascending: false);
      setState(() {
        _returns = List<Map<String, dynamic>>.from(returns);
        _listLoading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[SalesReturns] load list error: $e');
      setState(() => _listLoading = false);
    }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final ret = await client.from('sales_returns')
          .select('*, customers(shop_name, code, address, contact_person, phone), sales_invoices(voucher_number), branches(name)')
          .eq('id', id).single();
      final items = await client.from('sales_return_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('return_id', id);
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: ret['customer_id'] as String?,
        createdById: ret['created_by'] as String?,
      );
      setState(() {
        _detail = Map<String, dynamic>.from(ret);
        _items = List<Map<String, dynamic>>.from(items);
        _meta = meta;
        _detailLoading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[SalesReturns] load detail error: $e');
      setState(() => _detailLoading = false);
    }
  }

  Future<void> _showSnack(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ── Create new return ─────────────────────────────────────────────────────
  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }

    // Pick a source SI from the same branch.
    final invs = await Supabase.instance.client.from('sales_invoices')
        .select('id, voucher_number, voucher_date, grand_total, customer_id, customers(shop_name)')
        .eq('org_id', orgId).eq('branch_id', branchId)
        .order('voucher_date', ascending: false).limit(500);
    if (!mounted) return;
    final List<Map<String, dynamic>> invList = List<Map<String, dynamic>>.from(invs);
    if (invList.isEmpty) { _showSnack('No sales invoices to return against'); return; }

    final si = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _SiPicker(invoices: invList),
    );
    if (si == null) return;

    setState(() => _detailLoading = true);
    try {
      final siItems = await Supabase.instance.client.from('sales_invoice_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('invoice_id', si['id']);
      if (!mounted) return;
      setState(() => _detailLoading = false);

      // Show items selector for return quantities
      final returnLines = await showDialog<List<Map<String, dynamic>>>(
        context: context,
        builder: (_) => _ReturnItemsDialog(sourceItems: List<Map<String, dynamic>>.from(siItems), title: 'Items to Return'),
      );
      if (returnLines == null || returnLines.isEmpty) return;

      // Generate voucher number
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SRV', 'p_year': year});
      final voucherNum = 'SRV-$year-${nextNum.toString().padLeft(4, '0')}';

      // Totals
      double subtotal = 0, discountTotal = 0;
      for (final l in returnLines) {
        final q = (l['quantity'] as num).toDouble();
        final p = (l['unit_price'] as num).toDouble();
        final d = (l['discount'] as num).toDouble();
        subtotal += q * p;
        discountTotal += q * p * (d / 100);
      }
      final grand = subtotal - discountTotal;

      final retId = 'sr_${DateTime.now().millisecondsSinceEpoch}';
      final userId = ref.read(currentUserProvider)?.id;
      await Supabase.instance.client.from('sales_returns').insert({
        'id': retId,
        'org_id': orgId,
        'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'si_id': si['id'],
        'customer_id': si['customer_id'],
        'subtotal': subtotal,
        'discount_total': discountTotal,
        'grand_total': grand,
        'status': 'returned',
        'created_by': userId,
      });

      // Items + stock movements (positive = returned to stock)
      for (final l in returnLines) {
        final qty = (l['quantity'] as num).toDouble();
        final pid = l['product_id'] as String;
        final uomId = l['uom_id'] as String?;
        final price = (l['unit_price'] as num).toDouble();
        final discPct = (l['discount'] as num).toDouble();
        final lineTotal = (qty * price) * (1 - discPct / 100);

        await Supabase.instance.client.from('sales_return_items').insert({
          'id': 'sri_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'return_id': retId,
          'si_item_id': l['si_item_id'],
          'product_id': pid,
          'uom_id': uomId,
          'quantity': qty,
          'unit_price': price,
          'discount': discPct,
          'line_total': lineTotal,
        });

        // Stock: add qty back to inventory_stock for this branch
        final stock = await Supabase.instance.client.from('inventory_stock').select()
            .eq('org_id', orgId).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (stock != null) {
          await Supabase.instance.client.from('inventory_stock').update({
            'quantity': ((stock['quantity'] as num).toDouble()) + qty,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', stock['id']);
        } else {
          await Supabase.instance.client.from('inventory_stock').insert({
            'id': 'is_${DateTime.now().millisecondsSinceEpoch}_${pid.substring(0, 4)}',
            'org_id': orgId, 'product_id': pid, 'branch_id': branchId,
            'quantity': qty,
          });
        }

        await Supabase.instance.client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId, 'uom_id': uomId,
          'quantity': qty, 'movement_type': 'adjustment',
          'reference_id': retId, 'reference_type': 'sales_return',
          'moved_at': DateTime.now().toUtc().toIso8601String(), 'created_by': userId,
        });
      }

      _showSnack('$voucherNum created');
      await _loadList();
      _loadDetail(retId);
    } catch (e) {
      setState(() => _detailLoading = false);
      _showSnack('Failed: $e');
    }
  }

  Future<void> _delete() async {
    if (!_canDelete) return;
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Sales Return?'),
      content: Text('Permanently delete ${_detail['voucher_number']}? Stock will be reversed.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;

    final orgId = _orgId;
    final branchId = _detail['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;

    try {
      // Reverse stock: remove what was returned
      for (final item in _items) {
        final pid = item['product_id'] as String;
        final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
        if (qty <= 0) continue;

        final stock = await Supabase.instance.client.from('inventory_stock').select()
            .eq('org_id', orgId!).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (stock != null) {
          await Supabase.instance.client.from('inventory_stock').update({
            'quantity': ((stock['quantity'] as num).toDouble()) - qty,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', stock['id']);
        }
        await Supabase.instance.client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId, 'uom_id': item['uom_id'],
          'quantity': -qty, 'movement_type': 'adjustment',
          'reference_id': _detail['id'], 'reference_type': 'sales_return_deleted',
          'moved_at': DateTime.now().toUtc().toIso8601String(), 'created_by': userId,
        });
      }

      await Supabase.instance.client.from('sales_return_items').delete().eq('return_id', _detail['id']);
      await Supabase.instance.client.from('sales_returns').delete().eq('id', _detail['id']);

      _showSnack('Deleted');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      await _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final lines = _items.map((it) {
      final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
      final disc = (it['discount'] as num?)?.toDouble() ?? 0;
      final lt = (it['line_total'] as num?)?.toDouble() ?? 0;
      return VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?,
        uom: it['uoms']?['abbreviation'] as String?,
        qty: qty, unitPrice: price, discountPct: disc, lineTotal: lt,
      );
    }).toList();
    final subtotal = (_detail['subtotal'] as num?)?.toDouble() ?? 0;
    final discountTotal = (_detail['discount_total'] as num?)?.toDouble() ?? 0;
    final grand = (_detail['grand_total'] as num?)?.toDouble() ?? 0;
    final date = _detail['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null;
    final createdAt = _detail['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal()) : null;
    final cust = _detail['customers'] as Map?;
    final siVoucher = _detail['sales_invoices']?['voucher_number'] as String?;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Sales Return',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: cust?['shop_name'] as String?,
      customerAddress: cust?['address'] as String?,
      customerContact: cust?['contact_person'] as String?,
      customerPhone: cust?['phone'] as String?,
      salespersonName: _meta.salespersonName,
      lines: lines,
      subtotal: subtotal, discountTotal: discountTotal, grandTotal: grand,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.footerNote,
      relatedRefs: siVoucher != null ? {'Original SI #': siVoucher} : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) {
      _selectedId = null; _detail = {}; _items = []; _loadList();
    });
    return Container(color: AppTheme.background, child: Row(children: [
      _buildList(),
      Expanded(child: _selectedId == null
          ? const Center(child: Text('Select a Sales Return', style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
          : _buildDetail()),
    ]));
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _returns.where((r) {
      if (q.isEmpty) return true;
      return (r['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
             ((r['customers']?['shop_name'] as String?) ?? '').toLowerCase().contains(q) ||
             ((r['sales_invoices']?['voucher_number'] as String?) ?? '').toLowerCase().contains(q);
    }).toList();
    return SizedBox(width: 360, child: Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Row(children: [
            const Expanded(child: Text('Sales Returns', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
            IconButton(
              icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32),
              onPressed: _createNew,
              tooltip: 'New Return',
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search return / SI / customer…',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _listLoading
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? const Center(child: Text('No returns yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = filtered[i];
                        final selected = r['id'] == _selectedId;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          selectedTileColor: AppTheme.primary.withOpacity(0.06),
                          title: Text(r['voucher_number'] as String? ?? '-',
                              style: TextStyle(fontWeight: FontWeight.w700, color: selected ? AppTheme.primary : null)),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('SI: ${r['sales_invoices']?['voucher_number'] ?? '-'}', style: const TextStyle(fontSize: 11)),
                            Text(r['customers']?['shop_name'] as String? ?? '-', style: const TextStyle(fontSize: 11)),
                          ]),
                          trailing: Text(
                            ((r['grand_total'] as num?)?.toStringAsFixed(2)) ?? '0',
                            style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary),
                          ),
                          onTap: () => _loadDetail(r['id'] as String),
                        );
                      },
                    ),
        ),
      ]),
    ));
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: CircularProgressIndicator());
    final si = _detail['sales_invoices']?['voucher_number'] as String?;
    final cust = _detail['customers'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Sales Return', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ])),
          IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), tooltip: 'Print / PDF', onPressed: _print),
          if (_canDelete)
            IconButton(icon: const Icon(Icons.delete_outline, color: AppTheme.danger), tooltip: 'Delete', onPressed: _delete),
        ]),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (si != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                child: Row(children: [
                  const Icon(Icons.link, size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  const Text('Original SI:', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                  const SizedBox(width: 6),
                  Text(si, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  const SizedBox(width: 16),
                  Text(cust?['shop_name'] as String? ?? '-', style: const TextStyle(fontSize: 12)),
                ]),
              ),
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                  child: const Row(children: [
                    Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                    Expanded(flex: 2, child: Text('Price', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('Disc%', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                    Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                  ]),
                ),
                const Divider(height: 1),
                ..._items.map((it) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      Expanded(flex: 4, child: Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('${(it['quantity'] as num?)?.toStringAsFixed(0) ?? '0'}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(flex: 2, child: Text((it['unit_price'] as num?)?.toStringAsFixed(2) ?? '0', textAlign: TextAlign.right)),
                      Expanded(flex: 1, child: Text('${(it['discount'] as num?)?.toStringAsFixed(0) ?? '0'}%', textAlign: TextAlign.right)),
                      Expanded(flex: 2, child: Text((it['line_total'] as num?)?.toStringAsFixed(2) ?? '0',
                          textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                    ]),
                  );
                }),
              ]),
            ),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerRight, child: Container(
              padding: const EdgeInsets.all(12),
              width: 280,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _totalRow('Subtotal', (_detail['subtotal'] as num?)?.toDouble() ?? 0),
                _totalRow('Discount', (_detail['discount_total'] as num?)?.toDouble() ?? 0, color: AppTheme.warning),
                const Divider(height: 8),
                _totalRow('Grand Total', (_detail['grand_total'] as num?)?.toDouble() ?? 0, bold: true),
              ]),
            )),
          ]),
        ),
      ),
    ]);
  }

  Widget _totalRow(String label, double v, {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(color: color ?? AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: bold ? 14 : 12)),
        Text(v.toStringAsFixed(2), style: TextStyle(color: color ?? (bold ? AppTheme.primary : null), fontWeight: bold ? FontWeight.w700 : FontWeight.w600, fontSize: bold ? 15 : 13)),
      ]),
    );
  }
}

// ─── SI Picker (source invoice for return) ────────────────────────────────────
class _SiPicker extends StatefulWidget {
  final List<Map<String, dynamic>> invoices;
  const _SiPicker({required this.invoices});
  @override
  State<_SiPicker> createState() => _SiPickerState();
}

class _SiPickerState extends State<_SiPicker> {
  String _q = '';
  Map<String, dynamic>? _selected;
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase().trim();
    final filtered = widget.invoices.where((inv) {
      if (q.isEmpty) return true;
      return (inv['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
             (inv['customers']?['shop_name'] as String? ?? '').toLowerCase().contains(q);
    }).toList();
    return AlertDialog(
      title: const Text('Pick Source Sales Invoice'),
      content: SizedBox(width: 520, height: 460, child: Column(children: [
        TextField(
          decoration: const InputDecoration(hintText: 'Search SI / customer', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
          onChanged: (v) => setState(() => _q = v),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No invoices.', style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final inv = filtered[i];
                    final selected = _selected == inv;
                    return RadioListTile<Map<String, dynamic>>(
                      dense: true,
                      value: inv,
                      groupValue: _selected,
                      selected: selected,
                      title: Text(inv['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${inv['customers']?['shop_name'] ?? '-'} · ${(inv['grand_total'] as num?)?.toStringAsFixed(2) ?? '0'} · ${inv['voucher_date']}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onChanged: (v) => setState(() => _selected = v),
                    );
                  },
                ),
        ),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: _selected == null ? null : () => Navigator.pop(context, _selected), child: const Text('Next')),
      ],
    );
  }
}

// ─── Items Dialog (enter return qty per source item) ──────────────────────────
class _ReturnItemsDialog extends StatefulWidget {
  final List<Map<String, dynamic>> sourceItems;
  final String title;
  const _ReturnItemsDialog({required this.sourceItems, required this.title});
  @override
  State<_ReturnItemsDialog> createState() => _ReturnItemsDialogState();
}

class _ReturnItemsDialogState extends State<_ReturnItemsDialog> {
  late final Map<String, TextEditingController> _qtyCtrl;
  @override
  void initState() {
    super.initState();
    _qtyCtrl = {for (final it in widget.sourceItems) (it['id'] as String): TextEditingController(text: '0')};
  }
  @override
  void dispose() {
    for (final c in _qtyCtrl.values) c.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(width: 640, height: 480, child: ListView.separated(
        itemCount: widget.sourceItems.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final it = widget.sourceItems[i];
          final qty = (it['qty_delivered'] as num?)?.toDouble() ?? (it['quantity'] as num?)?.toDouble() ?? 0;
          final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(children: [
              Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                Text('Invoiced: ${qty.toStringAsFixed(0)}  ·  @ ${price.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ])),
              const SizedBox(width: 12),
              SizedBox(width: 120, child: TextField(
                controller: _qtyCtrl[it['id'] as String],
                decoration: const InputDecoration(labelText: 'Return Qty', isDense: true),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              )),
            ]),
          );
        },
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: () {
          final lines = <Map<String, dynamic>>[];
          for (final it in widget.sourceItems) {
            final txt = _qtyCtrl[it['id'] as String]?.text ?? '0';
            final q = double.tryParse(txt) ?? 0;
            if (q <= 0) continue;
            final originalQty = (it['qty_delivered'] as num?)?.toDouble() ?? (it['quantity'] as num?)?.toDouble() ?? 0;
            if (q > originalQty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${it['products']?['name']}: cannot return more than $originalQty')));
              return;
            }
            lines.add({
              'si_item_id': it['id'],
              'product_id': it['product_id'],
              'uom_id': it['uom_id'],
              'quantity': q,
              'unit_price': it['unit_price'],
              'discount': it['discount'] ?? 0,
            });
          }
          if (lines.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a return qty for at least one line')));
            return;
          }
          Navigator.pop(context, lines);
        }, child: const Text('Create Return')),
      ],
    );
  }
}
