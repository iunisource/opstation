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

/// Purchase Invoice (PI) — Stage 3 of purchase flow.
/// Created from a saved GRN. User enters unit cost + discount per line.
/// Auto-locks on "Save Invoice". Only admins can unlock.
/// Marks source GRN as 'invoiced' on save.
class ErpPurchaseInvoicesScreen extends ConsumerStatefulWidget {
  const ErpPurchaseInvoicesScreen({super.key});
  @override
  ConsumerState<ErpPurchaseInvoicesScreen> createState() => _ErpPurchaseInvoicesScreenState();
}

class _ErpPurchaseInvoicesScreenState extends ConsumerState<ErpPurchaseInvoicesScreen> {
  List<Map<String, dynamic>> _invoices = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  Map<String, TextEditingController> _costCtrl = {};
  Map<String, TextEditingController> _discCtrl = {};
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';
  String _filter = 'all';

  @override
  void initState() { super.initState(); _loadList(); }
  @override
  void dispose() { for (final c in _costCtrl.values) c.dispose(); for (final c in _discCtrl.values) c.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isDraft  => !_isLocked;
  bool get _canDelete { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canUnlock { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  void _initCtrls() {
    for (final c in _costCtrl.values) c.dispose();
    for (final c in _discCtrl.values) c.dispose();
    _costCtrl = {}; _discCtrl = {};
    for (final it in _items) {
      final id = it['id'] as String;
      _costCtrl[id] = TextEditingController(text: ((it['unit_cost'] as num?)?.toStringAsFixed(2) ?? '0.00'));
      _discCtrl[id]  = TextEditingController(text: ((it['discount'] as num?)?.toStringAsFixed(2) ?? '0.00'));
    }
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('purchase_invoices')
          .select('id,voucher_number,voucher_date,grand_total,is_locked,supplier_id,grn_id,suppliers(name),purchase_grns(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final r = await q.order('voucher_date', ascending: false).order('voucher_number', ascending: false).limit(2000);
      setState(() { _invoices = List<Map<String, dynamic>>.from(r); _listLoading = false; });
    } catch (e) { _showSnack('Load error: $e'); setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final inv = await client.from('purchase_invoices')
          .select('*,suppliers(*),purchase_grns(voucher_number),purchase_orders(voucher_number),branches(name)')
          .eq('id', id).single();
      final items = await client.from('purchase_invoice_items')
          .select('*,products(name,sku),uoms(abbreviation)').eq('invoice_id', id);
      final meta = await VoucherMeta.fetch(orgId: _orgId ?? '', customerId: null, createdById: inv['created_by'] as String?);
      setState(() {
        _detail = Map<String, dynamic>.from(inv); _items = List<Map<String, dynamic>>.from(items);
        _meta = meta; _detailLoading = false; _initCtrls();
      });
    } catch (e) { _showSnack('Detail error: $e'); setState(() => _detailLoading = false); }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': _orgId, 'voucher_id': id, 'voucher_type': 'PI',
        'action': action, 'details': details, 'user_id': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    try {
      final grns = await Supabase.instance.client.from('purchase_grns')
          .select('id,voucher_number,voucher_date,supplier_id,po_id,suppliers(name),purchase_orders(voucher_number)')
          .eq('org_id', orgId).eq('branch_id', branchId).eq('status', 'saved').eq('is_locked', true)
          .order('voucher_date', ascending: false);
      if ((grns as List).isEmpty) { _showSnack('No confirmed GRNs available. Confirm a GRN first.'); return; }
      final picked = await showDialog<Map<String, dynamic>?>(context: context,
          builder: (_) => _GrnPickerForPiDialog(grns: List<Map<String, dynamic>>.from(grns)));
      if (picked == null) return;
      await _createFromGrn(picked);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _createFromGrn(Map<String, dynamic> grn) async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) return;
    setState(() => _detailLoading = true);
    try {
      // Check not already invoiced
      final existing = await Supabase.instance.client.from('purchase_invoices').select('id,voucher_number').eq('grn_id', grn['id'] as String);
      if ((existing as List).isNotEmpty) { setState(() => _detailLoading = false); _showSnack('PI ${existing.first['voucher_number']} already exists for this GRN'); return; }
      final grnItems = await Supabase.instance.client.from('purchase_grn_items').select('*').eq('grn_id', grn['id'] as String);
      if ((grnItems as List).isEmpty) { setState(() => _detailLoading = false); _showSnack('GRN has no items'); return; }
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'PI', 'p_year': year});
      final vNum = 'PI-$year-${nextNum.toString().padLeft(4, '0')}';
      final piId = 'pi_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('purchase_invoices').insert({
        'id': piId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': vNum, 'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'grn_id': grn['id'], 'po_id': grn['po_id'], 'supplier_id': grn['supplier_id'],
        'subtotal': 0, 'discount_total': 0, 'grand_total': 0,
        'is_locked': false, 'created_by': ref.read(currentUserProvider)?.id,
      });
      for (final item in grnItems) {
        final pid = item['product_id'] as String;
        await Supabase.instance.client.from('purchase_invoice_items').insert({
          'id': 'pii_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'invoice_id': piId, 'product_id': pid, 'uom_id': item['uom_id'],
          'qty_received': item['qty_received'], 'unit_cost': 0, 'discount': 0, 'line_total': 0,
        });
      }
      await _logAudit(piId, 'created', 'PI $vNum from GRN ${grn['voucher_number']}');
      _showSnack('$vNum created — enter costs then save');
      await _loadList(); _loadDetail(piId);
    } catch (e) { setState(() => _detailLoading = false); _showSnack('Failed: $e'); }
  }

  Future<void> _saveItemCost(String itemId) async {
    final cost = double.tryParse(_costCtrl[itemId]?.text ?? '') ?? 0;
    final disc = (double.tryParse(_discCtrl[itemId]?.text ?? '') ?? 0).clamp(0.0, 100.0);
    final qty = (_items.firstWhere((i) => i['id'] == itemId, orElse: () => {})['qty_received'] as num?)?.toDouble() ?? 0;
    final lt = qty * cost * (1 - disc / 100);
    try {
      await Supabase.instance.client.from('purchase_invoice_items').update({'unit_cost': cost, 'discount': disc, 'line_total': lt}).eq('id', itemId);
      setState(() {
        final idx = _items.indexWhere((i) => i['id'] == itemId);
        if (idx >= 0) { _items[idx]['unit_cost'] = cost; _items[idx]['discount'] = disc; _items[idx]['line_total'] = lt; }
      });
      await _recalcTotals();
    } catch (e) { _showSnack('Save error: $e'); }
  }

  Future<void> _recalcTotals() async {
    double subtotal = 0, discount = 0;
    for (final it in _items) {
      final qty  = (it['qty_received'] as num?)?.toDouble() ?? 0;
      final cost = (it['unit_cost']   as num?)?.toDouble() ?? 0;
      final disc = (it['discount']    as num?)?.toDouble() ?? 0;
      subtotal += qty * cost; discount += qty * cost * (disc / 100);
    }
    final grand = subtotal - discount;
    try {
      await Supabase.instance.client.from('purchase_invoices').update({'subtotal': subtotal, 'discount_total': discount, 'grand_total': grand, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', _detail['id']);
      setState(() {
        _detail['subtotal'] = subtotal; _detail['discount_total'] = discount; _detail['grand_total'] = grand;
        final idx = _invoices.indexWhere((r) => r['id'] == _detail['id']);
        if (idx >= 0) _invoices[idx]['grand_total'] = grand;
      });
    } catch (_) {}
  }

  Future<void> _saveInvoice() async {
    if (_items.isEmpty) { _showSnack('No items'); return; }
    for (final it in _items) await _saveItemCost(it['id'] as String);
    // Validate costs > 0
    for (final it in _items) {
      final cost = (it['unit_cost'] as num?)?.toDouble() ?? 0;
      if (cost <= 0) { _showSnack('Unit cost for "${it['products']?['name'] ?? 'item'}" must be > 0'); return; }
    }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Save & Lock Invoice?'),
      content: const Text('The GRN will be marked as invoiced and this invoice will be locked. Only admins can unlock.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Save Invoice'))],
    ));
    if (ok != true) return;
    final userId = ref.read(currentUserProvider)?.id;
    final piId = _detail['id'] as String;
    final grnId = _detail['grn_id'] as String?;
    try {
      await Supabase.instance.client.from('purchase_invoices').update({
        'is_locked': true, 'locked_by': userId, 'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', piId);
      if (grnId != null) {
        await Supabase.instance.client.from('purchase_grns').update({'status': 'invoiced', 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', grnId);
      }
      await _logAudit(piId, 'saved', 'Invoice saved and locked');
      _showSnack('Invoice saved and locked');
      _loadDetail(piId); _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    if (_isLocked && !_canUnlock) { _showSnack('Only admins can unlock'); return; }
    final newLocked = !_isLocked;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      await Supabase.instance.client.from('purchase_invoices').update({
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
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Purchase Invoice?'),
      content: Text('Delete ${_detail['voucher_number']}? The GRN will be restored to saved.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      final grnId = _detail['grn_id'] as String?;
      if (grnId != null) { await Supabase.instance.client.from('purchase_grns').update({'status': 'saved', 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', grnId); }
      await _logAudit(_detail['id'] as String, 'deleted', 'PI ${_detail['voucher_number']} deleted');
      await Supabase.instance.client.from('purchase_invoice_items').delete().eq('invoice_id', _detail['id']);
      await Supabase.instance.client.from('purchase_invoices').delete().eq('id', _detail['id']);
      _showSnack('Deleted — GRN restored');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final sup = _detail['suppliers'] as Map?;
    final refs = <String, String>{};
    if (_detail['purchase_grns']?['voucher_number'] != null) refs['GRN #'] = _detail['purchase_grns']['voucher_number'] as String;
    if (_detail['purchase_orders']?['voucher_number'] != null) refs['PO #'] = _detail['purchase_orders']['voucher_number'] as String;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Purchase Invoice',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null,
      customerOrSupplier: sup?['name'] as String?,
      customerAddress: sup?['address'] as String?,
      customerContact: sup?['contact_person'] as String?,
      customerPhone: (sup?['contact_number'] ?? sup?['phone']) as String?,
      lines: _isDraft ? [] : _items.map((it) { final qty = (it['qty_received'] as num?)?.toDouble() ?? 0; final cost = (it['unit_cost'] as num?)?.toDouble() ?? 0; final disc = (it['discount'] as num?)?.toDouble() ?? 0; final lt = (it['line_total'] as num?)?.toDouble() ?? qty * cost * (1 - disc / 100); return VoucherLine(product: it['products']?['name'] as String? ?? '-', sku: it['products']?['sku'] as String?, uom: it['uoms']?['abbreviation'] as String?, qty: qty, unitPrice: cost, discountPct: disc, lineTotal: lt); }).toList(),
      subtotal: (_detail['subtotal'] as num?)?.toDouble() ?? 0,
      discountTotal: (_detail['discount_total'] as num?)?.toDouble() ?? 0,
      grandTotal: (_detail['grand_total'] as num?)?.toDouble() ?? 0,
      preparedBy: _meta.preparedBy, footerNote: _meta.purchaseFooterNote ?? _meta.footerNote,
      relatedRefs: refs.isNotEmpty ? refs : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) { _selectedId = null; _detail = {}; _items = []; _loadList(); });
    return Container(color: AppTheme.background, child: CollapsibleListPane(
      paneWidth: 360,
      listChild: _buildList(),
      detailChild: _selectedId == null
          ? const Center(child: Text('Select or create a Purchase Invoice', style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
          : _buildDetail(),
    ));
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _invoices.where((r) {
      final matchSearch = q.isEmpty || (r['voucher_number'] as String? ?? '').toLowerCase().contains(q) || ((r['suppliers']?['name'] as String?) ?? '').toLowerCase().contains(q) || ((r['purchase_grns']?['voucher_number'] as String?) ?? '').toLowerCase().contains(q);
      final locked = r['is_locked'] as bool? ?? false;
      final matchFilter = _filter == 'all' || (_filter == 'draft' && !locked) || (_filter == 'saved' && locked);
      return matchSearch && matchFilter;
    }).toList();
    return Container(decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))), child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 12), child: Row(children: [
        const Expanded(child: Text('Purchase Invoices', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32), onPressed: _createNew, tooltip: 'New PI'),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: TextField(
        decoration: const InputDecoration(hintText: 'Search PI / GRN / supplier…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
        onChanged: (v) => setState(() => _search = v))),
      const SizedBox(height: 8),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
        _PiFilterTab(label: 'All',   value: 'all',   current: _filter, onTap: (v) => setState(() => _filter = v)),
        const SizedBox(width: 6),
        _PiFilterTab(label: 'Draft', value: 'draft', current: _filter, onTap: (v) => setState(() => _filter = v)),
        const SizedBox(width: 6),
        _PiFilterTab(label: 'Saved', value: 'saved', current: _filter, onTap: (v) => setState(() => _filter = v)),
      ])),
      const SizedBox(height: 12),
      Expanded(child: _listLoading ? const Center(child: CircularProgressIndicator())
          : filtered.isEmpty ? const Center(child: Text('No invoices yet.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = filtered[i]; final sel = r['id'] == _selectedId;
                final locked = r['is_locked'] as bool? ?? false;
                return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.06),
                  title: Row(children: [
                    Expanded(child: Text(r['voucher_number'] as String? ?? '-', style: TextStyle(fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : null))),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: locked ? AppTheme.success.withOpacity(0.12) : Colors.orange.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                      child: Text(locked ? 'saved' : 'draft', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: locked ? AppTheme.success : Colors.orange))),
                  ]),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(r['suppliers']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 11)),
                    if (r['purchase_grns']?['voucher_number'] != null) Text('← ${r['purchase_grns']['voucher_number']}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ]),
                  trailing: Text(((r['grand_total'] as num?)?.toStringAsFixed(2)) ?? '0.00', style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  onTap: () => _loadDetail(r['id'] as String));
              })),
    ]));
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: CircularProgressIndicator());
    final sup = _detail['suppliers'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Purchase Invoice', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ])),
          if (_isDraft) ...[
            ElevatedButton.icon(icon: const Icon(Icons.save_outlined, size: 16), label: const Text('Save Invoice'), onPressed: _saveInvoice),
            const SizedBox(width: 8),
          ],
          if (!_isDraft || _canUnlock)
            IconButton(icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
                tooltip: _isLocked ? 'Unlock (admin)' : 'Lock', onPressed: _toggleLock),
          IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), onPressed: _print),
          if (_canDelete) IconButton(icon: const Icon(Icons.delete_outline, color: AppTheme.danger), onPressed: _delete),
        ])),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          _PiChip(label: 'Supplier', value: sup?['name'] as String? ?? '-'),
          _PiChip(label: 'Date', value: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
          _PiChip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
          if (_detail['purchase_grns']?['voucher_number'] != null) _PiChip(label: 'GRN #', value: _detail['purchase_grns']['voucher_number'] as String),
          if (_detail['purchase_orders']?['voucher_number'] != null) _PiChip(label: 'PO #', value: _detail['purchase_orders']['voucher_number'] as String),
          _PiChip(label: 'Status', value: _isLocked ? 'saved' : 'draft'),
          if (_isLocked) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.4))), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.lock_outline, size: 12, color: Colors.orange), SizedBox(width: 4), Text('Locked', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w600))])),
        ]),
        if (sup != null) _PiInfoStrip(address: sup['address'] as String?, contact: sup['contact_person'] as String?, phone: (sup['contact_number'] ?? sup['phone']) as String?, ntn: sup['ntn'] as String?, preparedBy: _meta.preparedBy),
        const SizedBox(height: 16),
        if (_isDraft) Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.primary.withOpacity(0.25))),
          child: const Row(children: [Icon(Icons.edit_note, size: 15, color: AppTheme.primary), SizedBox(width: 8), Expanded(child: Text('Enter unit costs and discounts below, then click "Save Invoice" to lock.', style: TextStyle(fontSize: 12, color: AppTheme.primary)))])),
        Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
              child: const Row(children: [
                Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 1, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                Expanded(flex: 2, child: Text('Unit Cost', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                Expanded(flex: 1, child: Text('Disc%', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
              ])),
            const Divider(height: 1),
            if (_items.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('No items', style: TextStyle(color: AppTheme.textSecondary))),
            ..._items.map((it) {
              final id = it['id'] as String;
              final qty  = (it['qty_received'] as num?)?.toDouble() ?? 0;
              final cost = (it['unit_cost']   as num?)?.toDouble() ?? 0;
              final disc = (it['discount']    as num?)?.toDouble() ?? 0;
              final lt   = (it['line_total']  as num?)?.toDouble() ?? qty * cost * (1 - disc / 100);
              return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(children: [
                  Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13)),
                    if (it['products']?['sku'] != null) Text(it['products']!['sku'] as String, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ])),
                  Expanded(flex: 1, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 1, child: Text(qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(flex: 2, child: _isDraft
                      ? TextField(controller: _costCtrl[id], decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)), textAlign: TextAlign.right, keyboardType: const TextInputType.numberWithOptions(decimal: true), onSubmitted: (_) => _saveItemCost(id))
                      : Text(cost.toStringAsFixed(2), textAlign: TextAlign.right)),
                  Expanded(flex: 1, child: _isDraft
                      ? TextField(controller: _discCtrl[id], decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)), textAlign: TextAlign.right, keyboardType: const TextInputType.numberWithOptions(decimal: true), onSubmitted: (_) => _saveItemCost(id))
                      : Text('${disc.toStringAsFixed(0)}%', textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text(lt.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                ]));
            }),
          ])),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerRight, child: Container(padding: const EdgeInsets.all(12), width: 280,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _piTotalRow('Subtotal', (_detail['subtotal'] as num?)?.toDouble() ?? 0),
            _piTotalRow('Discount', (_detail['discount_total'] as num?)?.toDouble() ?? 0, color: AppTheme.warning),
            const Divider(height: 8),
            _piTotalRow('Grand Total', (_detail['grand_total'] as num?)?.toDouble() ?? 0, bold: true),
          ]))),
        const SizedBox(height: 16),
        _PiAuditTrail(voucherId: _selectedId ?? ''),
      ]))),
    ]);
  }

  Widget _piTotalRow(String label, double v, {bool bold = false, Color? color}) => Padding(padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: TextStyle(color: color ?? AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: bold ? 14 : 12)),
      Text(v.toStringAsFixed(2), style: TextStyle(color: color ?? (bold ? AppTheme.primary : null), fontWeight: bold ? FontWeight.w700 : FontWeight.w600, fontSize: bold ? 15 : 13)),
    ]));
}

class _GrnPickerForPiDialog extends StatefulWidget {
  final List<Map<String, dynamic>> grns;
  const _GrnPickerForPiDialog({required this.grns});
  @override State<_GrnPickerForPiDialog> createState() => _GrnPickerForPiDialogState();
}
class _GrnPickerForPiDialogState extends State<_GrnPickerForPiDialog> {
  String _q = '';
  @override Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final filtered = widget.grns.where((g) => q.isEmpty || (g['voucher_number'] as String? ?? '').toLowerCase().contains(q) || ((g['suppliers']?['name'] as String?) ?? '').toLowerCase().contains(q)).toList();
    return AlertDialog(
      title: Text('Select Confirmed GRN  ·  ${widget.grns.length} available'),
      content: SizedBox(width: 520, height: 440, child: Column(children: [
        TextField(decoration: const InputDecoration(hintText: 'Search GRN # / supplier', prefixIcon: Icon(Icons.search, size: 18), isDense: true), onChanged: (v) => setState(() => _q = v), autofocus: true),
        const SizedBox(height: 12),
        Expanded(child: filtered.isEmpty ? const Center(child: Text('No confirmed GRNs.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) { final g = filtered[i]; return ListTile(dense: true,
                title: Text(g['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g['suppliers']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 11)),
                  if (g['purchase_orders']?['voucher_number'] != null) Text('← ${g['purchase_orders']['voucher_number']}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                ]),
                onTap: () => Navigator.pop(context, g)); })),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
    );
  }
}

class _PiChip extends StatelessWidget { final String label, value; const _PiChip({required this.label, required this.value}); @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)), child: Row(mainAxisSize: MainAxisSize.min, children: [Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)), Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12))])); }
class _PiFilterTab extends StatelessWidget { final String label, value, current; final ValueChanged<String> onTap; const _PiFilterTab({required this.label, required this.value, required this.current, required this.onTap}); @override Widget build(BuildContext context) { final active = value == current; return GestureDetector(onTap: () => onTap(value), child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: active ? AppTheme.primary : AppTheme.background, borderRadius: BorderRadius.circular(12), border: Border.all(color: active ? AppTheme.primary : AppTheme.border)), child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)))); } }

class _PiInfoStrip extends StatelessWidget {
  final String? address, contact, phone, ntn, preparedBy;
  const _PiInfoStrip({this.address, this.contact, this.phone, this.ntn, this.preparedBy});
  @override Widget build(BuildContext context) {
    final tiles = <Widget>[
      if (address != null && address!.trim().isNotEmpty) _t(Icons.location_on_outlined, 'Address', address!),
      if (contact != null && contact!.isNotEmpty) _t(Icons.account_circle_outlined, 'Contact', contact!),
      if (phone != null && phone!.isNotEmpty) _t(Icons.phone_outlined, 'Phone', phone!),
      if (ntn != null && ntn!.isNotEmpty) _t(Icons.badge_outlined, 'NTN', ntn!),
    ];
    if (tiles.isEmpty && (preparedBy == null || preparedBy!.isEmpty)) return const SizedBox.shrink();
    return Container(margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.background, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tiles.isNotEmpty) Wrap(spacing: 24, runSpacing: 8, children: tiles),
        if (preparedBy != null && preparedBy!.isNotEmpty) ...[if (tiles.isNotEmpty) const SizedBox(height: 8), Row(children: [const Icon(Icons.draw_outlined, size: 14, color: AppTheme.textSecondary), const SizedBox(width: 6), Text('Prepared by: $preparedBy', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontStyle: FontStyle.italic))])],
      ]));
  }
  Widget _t(IconData icon, String label, String val) => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 300), child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, size: 16, color: AppTheme.textSecondary), const SizedBox(width: 6), Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)), Text(val, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500))])]));
}

class _PiAuditTrail extends StatelessWidget {
  final String voucherId; const _PiAuditTrail({required this.voucherId});
  @override Widget build(BuildContext context) {
    if (voucherId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<dynamic>>(
      future: Supabase.instance.client.from('voucher_audit_log').select('action,details,user_id,created_at').eq('voucher_id', voucherId).eq('voucher_type', 'PI').order('created_at', ascending: false).limit(20),
      builder: (ctx, snap) {
        if (!snap.hasData || (snap.data as List).isEmpty) return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)), child: const Row(children: [Icon(Icons.history, size: 14, color: AppTheme.textSecondary), SizedBox(width: 8), Text('No activity logged yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))]));
        final entries = List<Map<String, dynamic>>.from(snap.data!);
        return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)), const SizedBox(height: 8),
            ...entries.map((e) { final action = e['action'] as String? ?? '-'; final ts = e['created_at'] != null ? DateFormat('d MMM HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : ''; final details = e['details'] as String? ?? ''; Color color; switch (action) { case 'created': color = AppTheme.primary; break; case 'saved': color = AppTheme.success; break; case 'deleted': color = AppTheme.danger; break; case 'locked': color = Colors.orange; break; default: color = AppTheme.textSecondary; } return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.history, size: 13, color: color), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Text(action, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)), const Spacer(), Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]), if (details.isNotEmpty) Text(details, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]))])); }),
          ]));
      });
  }
}
