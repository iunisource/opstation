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

/// Sales Return Note (SRN) — Intent only, like SO.
/// Items: Product | UOM | Qty ONLY. No prices, no stock movement.
/// Stock moves when the Sales Return Invoice (SRI) is issued.
class ErpSalesReturnsScreen extends ConsumerStatefulWidget {
  const ErpSalesReturnsScreen({super.key});
  @override ConsumerState<ErpSalesReturnsScreen> createState() => _ErpSalesReturnsScreenState();
}

class _ErpSalesReturnsScreenState extends ConsumerState<ErpSalesReturnsScreen> {
  List<Map<String, dynamic>> _returns = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  List<Map<String, dynamic>> _customers = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';
  String? _addProductId;
  String? _addUomId;
  final _addQtyCtrl = TextEditingController(text: '1');

  @override void initState() { super.initState(); _loadList(); _loadLookups(); }
  @override void dispose() { _addQtyCtrl.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isDraft  => !_isLocked;
  bool get _canDelete { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canUnlock { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadLookups() async {
    final orgId = _orgId; if (orgId == null) return;
    final client = Supabase.instance.client;
    final results = await Future.wait([
      client.from('products').select('id,name,sku,base_uom_id,selling_price').eq('org_id', orgId).eq('is_active', true).order('name').limit(10000),
      client.from('uoms').select().eq('org_id', orgId).order('name'),
    ]);
    final List<Map<String, dynamic>> c = [];
    var off = 0;
    while (true) {
      final p = await client.from('customers').select('id,shop_name,code').eq('org_id', orgId).eq('is_active', true).order('shop_name').range(off, off + 999);
      c.addAll(List<Map<String, dynamic>>.from(p));
      if (p.length < 1000) break;
      off += 1000;
    }
    if (mounted) setState(() { _products = List<Map<String, dynamic>>.from(results[0]); _uoms = List<Map<String, dynamic>>.from(results[1]); _customers = c; });
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('sales_returns')
          .select('id,voucher_number,voucher_date,status,is_locked,customer_id,customers(shop_name)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final r = await q.order('voucher_date', ascending: false).order('voucher_number', ascending: false).limit(2000);
      setState(() { _returns = List<Map<String, dynamic>>.from(r); _listLoading = false; });
    } catch (e) { _showSnack('Load error: $e'); setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final ret = await client.from('sales_returns')
          .select('*,customers(shop_name,code,address,contact_person,phone),branches(name)')
          .eq('id', id).single();
      final items = await client.from('sales_return_items')
          .select('*,products(name,sku),uoms(abbreviation)').eq('return_id', id);
      final meta = await VoucherMeta.fetch(orgId: _orgId ?? '', customerId: ret['customer_id'] as String?, createdById: ret['created_by'] as String?);
      setState(() { _detail = Map<String, dynamic>.from(ret); _items = List<Map<String, dynamic>>.from(items); _meta = meta; _detailLoading = false; });
    } catch (e) { _showSnack('Detail error: $e'); setState(() => _detailLoading = false); }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': _orgId, 'voucher_id': id, 'voucher_type': 'SRN',
        'action': action, 'details': details, 'user_id': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    final picked = await showDialog<Map<String, dynamic>?>(context: context, builder: (_) => _CustomerPickDialog(customers: _customers));
    if (picked == null) return;
    setState(() => _detailLoading = true);
    try {
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SRN', 'p_year': year});
      final vNum = 'SRN-$year-${nextNum.toString().padLeft(4, '0')}';
      final retId = 'sr_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('sales_returns').insert({
        'id': retId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': vNum, 'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'customer_id': picked['id'], 'subtotal': 0, 'discount_total': 0, 'grand_total': 0,
        'status': 'draft', 'is_locked': false, 'created_by': ref.read(currentUserProvider)?.id,
      });
      await _logAudit(retId, 'created', '$vNum created');
      _showSnack('$vNum created — add items, then confirm');
      await _loadList(); _loadDetail(retId);
    } catch (e) { setState(() => _detailLoading = false); _showSnack('Failed: $e'); }
  }

  Future<void> _addItem() async {
    if (_addProductId == null || _addUomId == null) { _showSnack('Select product and UOM'); return; }
    if (_items.any((i) => i['product_id'] == _addProductId)) { _showSnack('Already added'); return; }
    final qty = double.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) { _showSnack('Qty must be > 0'); return; }
    final prod = _products.firstWhere((p) => p['id'] == _addProductId, orElse: () => {});
    final uom  = _uoms.firstWhere((u) => u['id'] == _addUomId, orElse: () => {});
    final itemId = 'sri_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await Supabase.instance.client.from('sales_return_items').insert({
        'id': itemId, 'return_id': _detail['id'],
        'product_id': _addProductId, 'uom_id': _addUomId,
        'quantity': qty, 'unit_price': 0, 'discount': 0, 'line_total': 0,
      });
      setState(() {
        _items.add({'id': itemId, 'return_id': _detail['id'],
          'product_id': _addProductId, 'uom_id': _addUomId, 'quantity': qty,
          'unit_price': 0, 'discount': 0, 'line_total': 0,
          'products': {'name': prod['name'], 'sku': prod['sku']}, 'uoms': {'abbreviation': uom['abbreviation']}});
        _addProductId = null; _addUomId = null; _addQtyCtrl.text = '1';
      });
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _deleteItem(String itemId) async {
    try {
      await Supabase.instance.client.from('sales_return_items').delete().eq('id', itemId);
      setState(() => _items.removeWhere((i) => i['id'] == itemId));
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _confirmReturn() async {
    if (_items.isEmpty) { _showSnack('Add at least one item before confirming'); return; }
    // Check if SRI already exists
    try {
      final existing = await Supabase.instance.client.from('sales_return_invoices').select('id,voucher_number').eq('srn_id', _detail['id'] as String);
      if ((existing as List).isNotEmpty) { _showSnack('Invoice ${existing.first['voucher_number']} already exists. Cannot re-confirm.'); return; }
    } catch (_) {}
    final userId = ref.read(currentUserProvider)?.id;
    try {
      await Supabase.instance.client.from('sales_returns').update({
        'status': 'saved', 'is_locked': true,
        'locked_by': userId, 'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'confirmed', 'SRN confirmed and locked');
      _showSnack('Confirmed — ready to generate Sales Return Invoice');
      _loadDetail(_detail['id'] as String); _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _generateInvoice() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) return;
    if (_items.isEmpty) { _showSnack('No items to invoice'); return; }
    try {
      final existing = await Supabase.instance.client.from('sales_return_invoices').select('id,voucher_number').eq('srn_id', _detail['id'] as String);
      if ((existing as List).isNotEmpty) { _showSnack('Invoice ${existing.first['voucher_number']} already exists'); return; }
    } catch (_) {}
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Generate Sales Return Invoice?'),
      content: const Text('A draft SRI will be created. Set prices and issue it to move stock back.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Generate'))],
    ));
    if (confirm != true) return;
    final srnId = _detail['id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SRI', 'p_year': year});
      final vNum = 'SRI-$year-${nextNum.toString().padLeft(4, '0')}';
      final invId = 'sri_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('sales_return_invoices').insert({
        'id': invId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': vNum, 'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'srn_id': srnId, 'customer_id': _detail['customer_id'],
        'subtotal': 0, 'discount_total': 0, 'grand_total': 0,
        'status': 'draft', 'is_locked': false, 'created_by': userId,
      });
      for (final si in _items) {
        final pid = si['product_id'] as String;
        await Supabase.instance.client.from('sales_return_invoice_items').insert({
          'id': 'srii_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'invoice_id': invId, 'srn_item_id': si['id'],
          'product_id': pid, 'uom_id': si['uom_id'],
          'quantity': si['quantity'], 'unit_price': 0, 'discount': 0, 'line_total': 0,
        });
      }
      await _logAudit(srnId, 'invoiced', 'Draft SRI $vNum created — set prices in Sales Return Invoices tab');
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': orgId, 'voucher_id': invId, 'voucher_type': 'SRI',
        'action': 'created', 'details': 'Generated from SRN ${_detail['voucher_number']}',
        'user_id': userId,
      });
      _showSnack('$vNum created — open Sales Return Invoices to set prices and issue');
      _loadDetail(srnId); _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    if (_isLocked && !_canUnlock) { _showSnack('Only admins can unlock'); return; }
    final newLocked = !_isLocked;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      await Supabase.instance.client.from('sales_returns').update({
        'is_locked': newLocked, 'locked_by': newLocked ? userId : null,
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
    try {
      final invs = await Supabase.instance.client.from('sales_return_invoices').select('id,voucher_number').eq('srn_id', _detail['id'] as String);
      if ((invs as List).isNotEmpty) { _showSnack('Cannot delete: SRI ${invs.first['voucher_number']} exists. Delete the invoice first.'); return; }
    } catch (e) { _showSnack('Check error: $e'); return; }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Sales Return Note?'),
      content: Text('Delete ${_detail['voucher_number']}? Cannot be undone.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      await _logAudit(_detail['id'] as String, 'deleted', 'SRN ${_detail['voucher_number']} deleted');
      await Supabase.instance.client.from('sales_return_items').delete().eq('return_id', _detail['id']);
      await Supabase.instance.client.from('sales_returns').delete().eq('id', _detail['id']);
      _showSnack('Deleted');
      setState(() { _selectedId = null; _detail = {}; _items = []; }); _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final cust = _detail['customers'] as Map?;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Sales Return Note',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null,
      customerOrSupplier: cust?['shop_name'] as String? ?? 'Walk-in',
      customerAddress: cust?['address'] as String?,
      customerContact: cust?['contact_person'] as String?,
      customerPhone: cust?['phone'] as String?,
      salespersonName: _meta.salespersonName,
      lines: _items.map((it) => VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?, uom: it['uoms']?['abbreviation'] as String?,
        qty: (it['quantity'] as num?)?.toDouble() ?? 0,
      )).toList(),
      preparedBy: _meta.preparedBy, footerNote: _meta.footerNote,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) { _selectedId = null; _detail = {}; _items = []; _loadList(); });
    return Container(color: AppTheme.background, child: CollapsibleListPane(
      paneWidth: 360,
      listChild: _buildList(),
      detailChild: _selectedId == null
          ? const Center(child: Text('Select or create a Sales Return Note', style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
          : _buildDetail(),
    ));
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _returns.where((r) => q.isEmpty || (r['voucher_number'] as String? ?? '').toLowerCase().contains(q) || ((r['customers']?['shop_name'] as String?) ?? '').toLowerCase().contains(q)).toList();
    return Container(decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))), child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 12), child: Row(children: [
        const Expanded(child: Text('Sales Return Notes', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32), onPressed: _createNew, tooltip: 'New SRN'),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: TextField(
        decoration: const InputDecoration(hintText: 'Search SRN / customer…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
        onChanged: (v) => setState(() => _search = v))),
      const SizedBox(height: 12),
      Expanded(child: _listLoading ? const Center(child: CircularProgressIndicator())
          : filtered.isEmpty ? const Center(child: Text('No SRNs yet.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = filtered[i]; final sel = r['id'] == _selectedId;
                final locked = r['is_locked'] as bool? ?? false;
                final status = r['status'] as String? ?? 'draft';
                return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.06),
                  title: Row(children: [
                    Expanded(child: Text(r['voucher_number'] as String? ?? '-', style: TextStyle(fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : null))),
                    _SrnBadge(status: locked ? 'confirmed' : status),
                  ]),
                  subtitle: Text(r['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 11)),
                  onTap: () => _loadDetail(r['id'] as String));
              })),
    ]));
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: CircularProgressIndicator());
    final cust = _detail['customers'] as Map?;
    final status = _detail['status'] as String? ?? 'draft';
    final isInvoiced = status == 'invoiced';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Sales Return Note', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ])),
          if (_isDraft) ...[
            ElevatedButton.icon(icon: const Icon(Icons.check, size: 16), label: const Text('Confirm Return'), onPressed: _confirmReturn),
            const SizedBox(width: 8),
          ],
          if (!isInvoiced && (_isDraft || _canUnlock))
            IconButton(icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
                tooltip: _isLocked ? 'Unlock (admin)' : 'Lock', onPressed: _toggleLock),
          if (_isLocked && !isInvoiced) ...[
            ElevatedButton.icon(icon: const Icon(Icons.receipt_long, size: 16), label: const Text('Generate Invoice'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success), onPressed: _generateInvoice),
            const SizedBox(width: 8),
          ],
          IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), onPressed: _print),
          if (_canDelete) IconButton(icon: const Icon(Icons.delete_outline, color: AppTheme.danger), onPressed: _delete),
        ])),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          _SrnChip(label: 'Customer', value: cust?['shop_name'] as String? ?? 'Walk-in'),
          _SrnChip(label: 'Date', value: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
          _SrnChip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
          _SrnChip(label: 'Status', value: _isLocked ? (_detail['status'] == 'invoiced' ? 'invoiced' : 'confirmed') : 'draft'),
          if (_isLocked) const _SrnLockedChip(),
        ]),
        _SrnInfoStrip(
          address: cust?['address'] as String?,
          contact: cust?['contact_person'] as String?,
          phone: cust?['phone'] as String?,
          salesperson: _meta.salespersonName,
          preparedBy: _meta.preparedBy,
        ),
        if (_isDraft) Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: Colors.blue.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.blue.withOpacity(0.25))),
          child: const Row(children: [Icon(Icons.info_outline, size: 15, color: Colors.blue), SizedBox(width: 8),
            Expanded(child: Text('Add items, then Confirm Return. After confirming, generate the Sales Return Invoice to set prices.', style: TextStyle(fontSize: 12, color: Colors.blue)))])),
        const SizedBox(height: 16),
        Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
              child: const Row(children: [
                Expanded(flex: 5, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                SizedBox(width: 44),
              ])),
            const Divider(height: 1),
            if (_items.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('No items — add below', style: TextStyle(color: AppTheme.textSecondary))),
            ..._items.map((it) {
              final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
              return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13)),
                    if (it['products']?['sku'] != null) Text(it['products']!['sku'] as String, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ])),
                  Expanded(flex: 2, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text(qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                  SizedBox(width: 44, child: _isDraft ? IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger), onPressed: () => _deleteItem(it['id'] as String)) : null),
                ]));
            }),
            if (_isDraft) ...[
              const Divider(height: 1),
              Container(color: AppTheme.background, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Expanded(flex: 5, child: DropdownButtonFormField<String>(value: _addProductId, isDense: true, isExpanded: true,
                    decoration: const InputDecoration(hintText: 'Pick product', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                    items: _products.map((p) => DropdownMenuItem<String>(value: p['id'] as String, child: Text('${p['name']}${p['sku'] != null ? " · ${p['sku']}" : ""}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)))).toList(),
                    onChanged: (v) => setState(() { _addProductId = v; final p = _products.firstWhere((x) => x['id'] == v, orElse: () => {}); _addUomId = p['base_uom_id'] as String?; }))),
                  Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: DropdownButtonFormField<String>(value: _addUomId, isDense: true, isExpanded: true,
                      decoration: const InputDecoration(hintText: 'UOM', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
                      items: _uoms.map((u) => DropdownMenuItem<String>(value: u['id'] as String, child: Text(u['abbreviation'] as String? ?? '', style: const TextStyle(fontSize: 12)))).toList(),
                      onChanged: (v) => setState(() => _addUomId = v)))),
                  Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextField(controller: _addQtyCtrl, decoration: const InputDecoration(hintText: 'Qty', isDense: true), textAlign: TextAlign.right,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true), textInputAction: TextInputAction.done, onSubmitted: (_) => _addItem()))),
                  SizedBox(width: 44, child: IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary), tooltip: 'Add', onPressed: _addItem)),
                ])),
            ],
          ])),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerRight, child: Text('${_items.length} item(s)', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        const SizedBox(height: 16),
        _SrnAuditTrail(voucherId: _selectedId ?? ''),
      ]))),
    ]);
  }
}

class _CustomerPickDialog extends StatefulWidget {
  final List<Map<String, dynamic>> customers;
  const _CustomerPickDialog({required this.customers});
  @override State<_CustomerPickDialog> createState() => _CustomerPickDialogState();
}
class _CustomerPickDialogState extends State<_CustomerPickDialog> {
  String _q = '';
  @override Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final filtered = widget.customers.where((c) => q.isEmpty || (c['shop_name'] as String? ?? '').toLowerCase().contains(q) || (c['code'] as String? ?? '').toLowerCase().contains(q)).toList();
    return AlertDialog(
      title: Text('Select Customer  ·  ${widget.customers.length} total'),
      content: SizedBox(width: 480, height: 440, child: Column(children: [
        TextField(decoration: const InputDecoration(hintText: 'Search name / code…', prefixIcon: Icon(Icons.search, size: 18), isDense: true), onChanged: (v) => setState(() => _q = v), autofocus: true),
        const SizedBox(height: 12),
        Container(decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.05), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.primary.withOpacity(0.3))),
          child: ListTile(dense: true, leading: const Icon(Icons.person_outline, color: AppTheme.primary),
            title: const Text('Walk-in', style: TextStyle(fontWeight: FontWeight.w700)),
            onTap: () => Navigator.pop(context, {'id': null, 'shop_name': 'Walk-in'}))),
        const SizedBox(height: 6),
        Expanded(child: filtered.isEmpty ? const Center(child: Text('No customers.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) { final c = filtered[i]; return ListTile(dense: true,
                title: Text(c['shop_name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: c['code'] != null ? Text(c['code'] as String, style: const TextStyle(fontSize: 11)) : null,
                onTap: () => Navigator.pop(context, c)); })),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
    );
  }
}

class _SrnInfoStrip extends StatelessWidget {
  final String? address, contact, phone, salesperson, preparedBy;
  const _SrnInfoStrip({this.address, this.contact, this.phone, this.salesperson, this.preparedBy});
  @override Widget build(BuildContext context) {
    final tiles = <Widget>[
      if (address != null && address!.trim().isNotEmpty) _t(Icons.location_on_outlined, 'Address', address!),
      if (contact != null && contact!.isNotEmpty) _t(Icons.account_circle_outlined, 'Contact', contact!),
      if (phone != null && phone!.isNotEmpty) _t(Icons.phone_outlined, 'Phone', phone!),
      if (salesperson != null && salesperson!.isNotEmpty) _t(Icons.person_pin_outlined, 'Salesperson', salesperson!),
    ];
    if (tiles.isEmpty && (preparedBy == null || preparedBy!.isEmpty)) return const SizedBox.shrink();
    return Container(margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.background, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tiles.isNotEmpty) Wrap(spacing: 24, runSpacing: 8, children: tiles),
        if (preparedBy != null && preparedBy!.isNotEmpty) ...[
          if (tiles.isNotEmpty) const SizedBox(height: 8),
          Row(children: [const Icon(Icons.draw_outlined, size: 14, color: AppTheme.textSecondary), const SizedBox(width: 6),
            Text('Prepared by: $preparedBy', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontStyle: FontStyle.italic))]),
        ],
      ]));
  }
  Widget _t(IconData icon, String label, String val) => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 300),
    child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: AppTheme.textSecondary), const SizedBox(width: 6),
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        Text(val, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
      ]),
    ]));
}

class _SrnChip extends StatelessWidget { final String label, value; const _SrnChip({required this.label, required this.value}); @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)), child: Row(mainAxisSize: MainAxisSize.min, children: [Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)), Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12))])); }
class _SrnLockedChip extends StatelessWidget { const _SrnLockedChip(); @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.4))), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.lock_outline, size: 12, color: Colors.orange), SizedBox(width: 4), Text('Locked', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w600))])); }
class _SrnBadge extends StatelessWidget {
  final String status; const _SrnBadge({required this.status});
  @override Widget build(BuildContext context) {
    Color bg; Color fg;
    switch (status) { case 'confirmed': bg = AppTheme.primary.withOpacity(0.12); fg = AppTheme.primary; break; case 'invoiced': bg = Colors.purple.withOpacity(0.12); fg = Colors.purple; break; default: bg = Colors.orange.withOpacity(0.12); fg = Colors.orange; }
    return Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)), child: Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg)));
  }
}

class _SrnAuditTrail extends StatelessWidget {
  final String voucherId; const _SrnAuditTrail({required this.voucherId});
  @override Widget build(BuildContext context) {
    if (voucherId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<dynamic>>(
      future: Supabase.instance.client.from('voucher_audit_log').select('action,details,user_id,created_at').eq('voucher_id', voucherId).eq('voucher_type', 'SRN').order('created_at', ascending: false).limit(20),
      builder: (ctx, snap) {
        if (!snap.hasData || (snap.data as List).isEmpty) return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)), child: const Row(children: [Icon(Icons.history, size: 14, color: AppTheme.textSecondary), SizedBox(width: 8), Text('No activity logged yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))]));
        final entries = List<Map<String, dynamic>>.from(snap.data!);
        return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)), const SizedBox(height: 8),
            ...entries.map((e) { final a = e['action'] as String? ?? '-'; final ts = e['created_at'] != null ? DateFormat('d MMM HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : ''; final d = e['details'] as String? ?? ''; Color color; switch (a) { case 'created': color = AppTheme.primary; break; case 'confirmed': case 'invoiced': color = AppTheme.success; break; case 'deleted': color = AppTheme.danger; break; case 'locked': color = Colors.orange; break; default: color = AppTheme.textSecondary; } return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.history, size: 13, color: color), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Text(a, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)), const Spacer(), Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]), if (d.isNotEmpty) Text(d, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]))])); }),
          ]));
      });
  }
}
