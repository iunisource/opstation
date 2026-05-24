import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/layout/collapsible_list_pane.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';

/// Sales Return Invoices (SRI) — stage 2 of the sales return flow.
///
/// Consumes a saved SRN, snapshots its items, ADDS stock back to inventory,
/// and produces the financial credit document.
class ErpSalesReturnInvoicesScreen extends ConsumerStatefulWidget {
  const ErpSalesReturnInvoicesScreen({super.key});
  @override
  ConsumerState<ErpSalesReturnInvoicesScreen> createState() => _ErpSalesReturnInvoicesScreenState();
}

class _ErpSalesReturnInvoicesScreenState extends ConsumerState<ErpSalesReturnInvoicesScreen> {
  List<Map<String, dynamic>> _invoices = [];
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
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('sales_return_invoices')
          .select('id, voucher_number, voucher_date, grand_total, status, customer_id, srn_id, customers(shop_name), sales_returns(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final r = await q
          .order('voucher_date', ascending: false)
          .order('voucher_number', ascending: false)
          .limit(2000);
      setState(() { _invoices = List<Map<String, dynamic>>.from(r); _listLoading = false; });
    } catch (e) {
      // ignore: avoid_print
      print('[SRI] loadList error: $e');
      _showSnack('Failed to load list: $e');
      setState(() => _listLoading = false);
    }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final inv = await client.from('sales_return_invoices')
          .select('*, customers(shop_name, code, address, contact_person, phone), branches(name), sales_returns(voucher_number)')
          .eq('id', id).single();
      final items = await client.from('sales_return_invoice_items')
          .select('*, products(name, sku), uoms(abbreviation)')
          .eq('invoice_id', id);
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: inv['customer_id'] as String?,
        createdById: inv['created_by'] as String?,
      );
      setState(() {
        _detail = Map<String, dynamic>.from(inv);
        _items = List<Map<String, dynamic>>.from(items);
        _meta = meta;
        _detailLoading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[SRI] loadDetail error: $e');
      _showSnack('Failed to load detail: $e');
      setState(() => _detailLoading = false);
    }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'id': 'al_${DateTime.now().microsecondsSinceEpoch}',
        'voucher_id': id, 'voucher_type': 'SRI',
        'action': action, 'details': details,
        'user_id': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  // ── Create new SRI from a saved SRN ────────────────────────────────────────
  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }

    // Fetch eligible SRNs: saved & not yet invoiced
    try {
      final srns = await Supabase.instance.client.from('sales_returns')
          .select('id, voucher_number, voucher_date, grand_total, customer_id, customers(shop_name)')
          .eq('org_id', orgId).eq('branch_id', branchId)
          .eq('status', 'saved')
          .order('voucher_date', ascending: false);
      if ((srns as List).isEmpty) {
        _showSnack('No saved SRNs available — save an SRN first');
        return;
      }
      final picked = await showDialog<Map<String, dynamic>?>(context: context,
        builder: (_) => _SrnPickerDialog(srns: List<Map<String, dynamic>>.from(srns)));
      if (picked == null) return;
      await _generateFromSrn(picked);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  /// Public entry — also called from the SRN screen via a direct id.
  Future<void> _generateFromSrn(Map<String, dynamic> srn) async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) return;
    setState(() => _detailLoading = true);
    final userId = ref.read(currentUserProvider)?.id;
    try {
      final srnId = srn['id'] as String;
      // Load source SRN items
      final srnItems = await Supabase.instance.client.from('sales_return_items')
          .select('*').eq('return_id', srnId);
      if ((srnItems as List).isEmpty) {
        setState(() => _detailLoading = false);
        _showSnack('SRN has no items'); return;
      }

      // Voucher #
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SRI', 'p_year': year});
      final voucherNum = 'SRI-$year-${nextNum.toString().padLeft(4, '0')}';
      final invId = 'sri_${DateTime.now().millisecondsSinceEpoch}';

      // Insert invoice header
      await Supabase.instance.client.from('sales_return_invoices').insert({
        'id': invId,
        'org_id': orgId,
        'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'srn_id': srnId,
        'customer_id': srn['customer_id'],
        'subtotal': srn['subtotal'] ?? 0,
        'discount_total': srn['discount_total'] ?? 0,
        'grand_total': srn['grand_total'] ?? 0,
        'status': 'issued',
        'is_locked': true,  // auto-lock since stock has moved
        'locked_by': userId,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'created_by': userId,
      });

      // Copy items + move stock (positive = stock back)
      for (final si in srnItems) {
        final itemId = 'srii_${DateTime.now().microsecondsSinceEpoch}_${(si['product_id'] as String).substring(0, 4)}';
        await Supabase.instance.client.from('sales_return_invoice_items').insert({
          'id': itemId,
          'invoice_id': invId,
          'srn_item_id': si['id'],
          'product_id': si['product_id'],
          'uom_id': si['uom_id'],
          'quantity': si['quantity'],
          'unit_price': si['unit_price'],
          'discount': si['discount'],
          'line_total': si['line_total'],
        });

        // Stock back into inventory
        final qty = (si['quantity'] as num?)?.toDouble() ?? 0;
        if (qty > 0) {
          final stock = await Supabase.instance.client.from('inventory_stock').select()
              .eq('org_id', orgId).eq('product_id', si['product_id']).eq('branch_id', branchId).maybeSingle();
          if (stock == null) {
            await Supabase.instance.client.from('inventory_stock').insert({
              'id': 'is_${DateTime.now().microsecondsSinceEpoch}_${(si['product_id'] as String).substring(0, 4)}',
              'org_id': orgId, 'product_id': si['product_id'], 'branch_id': branchId,
              'quantity': qty,
            });
          } else {
            await Supabase.instance.client.from('inventory_stock').update({
              'quantity': ((stock['quantity'] as num).toDouble()) + qty,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            }).eq('id', stock['id']);
          }

          await Supabase.instance.client.from('inventory_movements').insert({
            'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${(si['product_id'] as String).substring(0, 4)}',
            'org_id': orgId, 'product_id': si['product_id'], 'branch_id': branchId,
            'uom_id': si['uom_id'], 'quantity': qty,
            'movement_type': 'adjustment',
            'reference_id': invId, 'reference_type': 'sales_return_invoice',
            'moved_at': DateTime.now().toUtc().toIso8601String(),
            'created_by': userId,
          });
        }
      }

      // Flip SRN → 'invoiced' and auto-lock
      await Supabase.instance.client.from('sales_returns').update({
        'status': 'invoiced',
        'is_locked': true,
        'locked_by': userId,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', srnId);

      // Audit on both
      await _logAudit(invId, 'created', 'Generated from SRN ${srn['voucher_number']}, stock moved back');
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'id': 'al_${DateTime.now().microsecondsSinceEpoch}',
        'voucher_id': srnId, 'voucher_type': 'SRN',
        'action': 'invoiced', 'details': 'Converted to invoice $voucherNum',
        'user_id': userId,
      });

      _showSnack('$voucherNum created — stock returned to inventory');
      await _loadList();
      _loadDetail(invId);
    } catch (e) {
      setState(() => _detailLoading = false);
      _showSnack('Failed: $e');
    }
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('sales_return_invoices').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, newLocked ? 'locked' : 'unlocked', null);
      _showSnack(newLocked ? 'Locked' : 'Unlocked');
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _delete() async {
    if (!_canDelete) return;
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Sales Return Invoice?'),
      content: Text('Permanently delete ${_detail['voucher_number']}? Stock will be removed (reversal), and the source SRN will be restored to "saved". This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;
    final orgId = _orgId;
    final branchId = _detail['branch_id'] as String?;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      // Reverse stock
      for (final it in _items) {
        final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
        final pid = it['product_id'] as String;
        if (qty <= 0 || branchId == null || orgId == null) continue;
        final stock = await Supabase.instance.client.from('inventory_stock').select()
            .eq('org_id', orgId).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (stock != null) {
          await Supabase.instance.client.from('inventory_stock').update({
            'quantity': ((stock['quantity'] as num).toDouble()) - qty,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', stock['id']);
        }
        await Supabase.instance.client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId,
          'uom_id': it['uom_id'], 'quantity': -qty,
          'movement_type': 'adjustment',
          'reference_id': _detail['id'], 'reference_type': 'sales_return_invoice_deleted',
          'moved_at': DateTime.now().toUtc().toIso8601String(),
          'created_by': userId,
        });
      }

      // Flip SRN back to 'saved' and unlock
      final srnId = _detail['srn_id'] as String?;
      if (srnId != null) {
        await Supabase.instance.client.from('sales_returns').update({
          'status': 'saved',
          'is_locked': false,
          'locked_by': null,
          'locked_at': null,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', srnId);
      }

      await _logAudit(_detail['id'] as String, 'deleted',
          'Invoice ${_detail['voucher_number']} deleted, stock reversed, SRN restored');
      await Supabase.instance.client.from('sales_return_invoice_items').delete().eq('invoice_id', _detail['id']);
      await Supabase.instance.client.from('sales_return_invoices').delete().eq('id', _detail['id']);

      _showSnack('Deleted — stock reversed, SRN restored');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      await _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final lines = _items.map((it) {
      final qty   = (it['quantity'] as num?)?.toDouble() ?? 0;
      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
      final disc  = (it['discount'] as num?)?.toDouble() ?? 0;
      final lt    = (it['line_total'] as num?)?.toDouble() ?? qty * price * (1 - disc / 100);
      return VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?,
        uom: it['uoms']?['abbreviation'] as String?,
        qty: qty, unitPrice: price, discountPct: disc, lineTotal: lt,
      );
    }).toList();
    final cust = _detail['customers'] as Map?;
    final srnVoucher = _detail['sales_returns']?['voucher_number'] as String?;
    final date = _detail['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null;
    final createdAt = _detail['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal()) : null;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Sales Return Invoice',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: cust?['shop_name'] as String? ?? 'Walk-in',
      customerAddress: cust?['address'] as String?,
      customerContact: cust?['contact_person'] as String?,
      customerPhone: cust?['phone'] as String?,
      salespersonName: _meta.salespersonName,
      lines: lines,
      subtotal: (_detail['subtotal'] as num?)?.toDouble() ?? 0,
      discountTotal: (_detail['discount_total'] as num?)?.toDouble() ?? 0,
      grandTotal: (_detail['grand_total'] as num?)?.toDouble() ?? 0,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.footerNote,
      relatedRefs: srnVoucher != null ? {'SRN #': srnVoucher} : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) {
      _selectedId = null; _detail = {}; _items = []; _loadList();
    });
    return Container(
      color: AppTheme.background,
      child: CollapsibleListPane(
        paneWidth: 360,
        listChild: _buildList(),
        detailChild: _selectedId == null
            ? const Center(child: Text('Select or create a Sales Return Invoice',
                style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
            : _buildDetail(),
      ),
    );
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _invoices.where((r) {
      if (q.isEmpty) return true;
      return (r['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
             ((r['customers']?['shop_name'] as String?) ?? '').toLowerCase().contains(q) ||
             ((r['sales_returns']?['voucher_number'] as String?) ?? '').toLowerCase().contains(q);
    }).toList();
    return Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Row(children: [
            const Expanded(child: Text('Sales Return Invoices', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
            IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32),
                onPressed: _createNew, tooltip: 'New SRI from SRN'),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search SRI / SRN / customer…',
                prefixIcon: Icon(Icons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _listLoading ? const Center(child: CircularProgressIndicator())
            : filtered.isEmpty
                ? const Center(child: Text('No invoices yet.', style: TextStyle(color: AppTheme.textSecondary)))
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
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(r['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 11)),
                          if (r['sales_returns']?['voucher_number'] != null)
                            Text('← ${r['sales_returns']['voucher_number']}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                        ]),
                        trailing: Text(((r['grand_total'] as num?)?.toStringAsFixed(2)) ?? '0',
                            style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary)),
                        onTap: () => _loadDetail(r['id'] as String),
                      );
                    },
                  )),
      ]),
    );
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: CircularProgressIndicator());
    final cust = _detail['customers'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header
      Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Sales Return Invoice',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ])),
          IconButton(
            icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline,
                color: _isLocked ? Colors.orange : AppTheme.textSecondary),
            tooltip: _isLocked ? 'Unlock' : 'Lock',
            onPressed: _toggleLock,
          ),
          IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), tooltip: 'Print / PDF', onPressed: _print),
          if (_canDelete)
            IconButton(icon: const Icon(Icons.delete_outline, color: AppTheme.danger), tooltip: 'Delete', onPressed: _delete),
        ]),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 12, runSpacing: 8, children: [
              _Chip(label: 'Customer', value: cust?['shop_name'] as String? ?? 'Walk-in'),
              _Chip(label: 'Date', value: _detail['voucher_date'] != null
                  ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
              _Chip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
              _Chip(label: 'Source SRN', value: _detail['sales_returns']?['voucher_number'] as String? ?? '-'),
              _Chip(label: 'Status', value: (_detail['status'] as String? ?? 'issued')),
            ]),

            const SizedBox(height: 20),

            // Read-only items table
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
                  final qty   = (it['quantity'] as num?)?.toDouble() ?? 0;
                  final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
                  final disc  = (it['discount'] as num?)?.toDouble() ?? 0;
                  final total = (it['line_total'] as num?)?.toDouble() ?? qty * price * (1 - disc / 100);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      Expanded(flex: 4, child: Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text(qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(flex: 2, child: Text(price.toStringAsFixed(2), textAlign: TextAlign.right)),
                      Expanded(flex: 1, child: Text('${disc.toStringAsFixed(disc % 1 == 0 ? 0 : 2)}%', textAlign: TextAlign.right)),
                      Expanded(flex: 2, child: Text(total.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                    ]),
                  );
                }),
              ]),
            ),

            const SizedBox(height: 16),

            // Totals
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

// ─── SRN picker dialog ────────────────────────────────────────────────────────
class _SrnPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> srns;
  const _SrnPickerDialog({required this.srns});
  @override
  State<_SrnPickerDialog> createState() => _SrnPickerDialogState();
}

class _SrnPickerDialogState extends State<_SrnPickerDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase().trim();
    final filtered = widget.srns.where((s) {
      if (q.isEmpty) return true;
      return (s['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
             ((s['customers']?['shop_name'] as String?) ?? '').toLowerCase().contains(q);
    }).toList();
    return AlertDialog(
      title: Text('Pick a saved SRN  ·  ${widget.srns.length} eligible'),
      content: SizedBox(width: 520, height: 460, child: Column(children: [
        TextField(
          decoration: const InputDecoration(hintText: 'Search SRN # / customer', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
          onChanged: (v) => setState(() => _q = v),
          autofocus: true,
        ),
        const SizedBox(height: 12),
        Expanded(child: filtered.isEmpty
            ? const Center(child: Text('No saved SRNs match.', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = filtered[i];
                  final date = s['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(s['voucher_date'] as String)) : '';
                  return ListTile(
                    dense: true,
                    title: Text(s['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${s['customers']?['shop_name'] ?? "Walk-in"}  ·  $date',
                        style: const TextStyle(fontSize: 11)),
                    trailing: Text(((s['grand_total'] as num?)?.toStringAsFixed(2)) ?? '0',
                        style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary)),
                    onTap: () => Navigator.pop(context, s),
                  );
                },
              )),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  const _Chip({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
      ]),
    );
  }
}
