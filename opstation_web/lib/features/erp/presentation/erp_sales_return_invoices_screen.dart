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

/// Sales Return Invoice (SRI) — Stage 2 of sales return flow.
/// Created from a confirmed SRN. User sets price + discount per item.
/// "Issue Invoice" → stock added back to inventory + SRN locked.
class ErpSalesReturnInvoicesScreen extends ConsumerStatefulWidget {
  const ErpSalesReturnInvoicesScreen({super.key});
  @override ConsumerState<ErpSalesReturnInvoicesScreen> createState() => _ErpSalesReturnInvoicesScreenState();
}

class _ErpSalesReturnInvoicesScreenState extends ConsumerState<ErpSalesReturnInvoicesScreen> {
  List<Map<String, dynamic>> _invoices = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  Map<String, TextEditingController> _priceCtrl = {};
  Map<String, TextEditingController> _discCtrl  = {};
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';
  String _filter = 'all';

  @override void initState() { super.initState(); _loadList(); }
  @override void dispose() { for (final c in _priceCtrl.values) c.dispose(); for (final c in _discCtrl.values) c.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isVoided => _detail['is_voided'] as bool? ?? false;
  bool get _isDraft  => !_isLocked;
  bool get _canDelete { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canUnlock { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  void _initCtrls() {
    for (final c in _priceCtrl.values) c.dispose();
    for (final c in _discCtrl.values) c.dispose();
    _priceCtrl = {}; _discCtrl = {};
    for (final it in _items) {
      final id = it['id'] as String;
      _priceCtrl[id] = TextEditingController(text: ((it['unit_price'] as num?)?.toStringAsFixed(2) ?? '0.00'));
      _discCtrl[id]  = TextEditingController(text: ((it['discount']   as num?)?.toStringAsFixed(2) ?? '0.00'));
    }
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('sales_return_invoices')
          .select('id,voucher_number,voucher_date,grand_total,is_locked,is_voided,status,customer_id,srn_id,customers(shop_name),sales_returns(voucher_number)')
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
      final inv = await client.from('sales_return_invoices')
          .select('*,customers(shop_name,code,address,contact_person,phone),branches(name),sales_returns(voucher_number)')
          .eq('id', id).single();
      final items = await client.from('sales_return_invoice_items')
          .select('*,products(name,sku),uoms(abbreviation)').eq('invoice_id', id);
      final meta = await VoucherMeta.fetch(orgId: _orgId ?? '', customerId: inv['customer_id'] as String?, createdById: inv['created_by'] as String?);
      setState(() { _detail = Map<String, dynamic>.from(inv); _items = List<Map<String, dynamic>>.from(items); _meta = meta; _detailLoading = false; _initCtrls(); });
    } catch (e) { _showSnack('Detail error: $e'); setState(() => _detailLoading = false); }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': _orgId, 'voucher_id': id, 'voucher_type': 'SRI',
        'action': action, 'details': details, 'performed_by': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    try {
      final srns = await Supabase.instance.client.from('sales_returns')
          .select('id,voucher_number,voucher_date,customer_id,customers(shop_name)')
          .eq('org_id', orgId).eq('branch_id', branchId)
          .eq('is_locked', true).neq('status', 'invoiced')
          .order('voucher_date', ascending: false);
      if ((srns as List).isEmpty) { _showSnack('No confirmed SRNs available. Confirm an SRN first.'); return; }
      final picked = await showDialog<Map<String, dynamic>?>(context: context,
          builder: (_) => _SrnPickerDialog(srns: List<Map<String, dynamic>>.from(srns)));
      if (picked == null) return;
      await _createFromSrn(picked);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _createFromSrn(Map<String, dynamic> srn) async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null || branchId == null) return;
    setState(() => _detailLoading = true);
    try {
      final existing = await Supabase.instance.client.from('sales_return_invoices').select('id,voucher_number').eq('srn_id', srn['id'] as String);
      if ((existing as List).isNotEmpty) { setState(() => _detailLoading = false); _showSnack('SRI ${existing.first['voucher_number']} already exists for this SRN'); return; }
      final srnItems = await Supabase.instance.client.from('sales_return_items').select('*').eq('return_id', srn['id'] as String);
      if ((srnItems as List).isEmpty) { setState(() => _detailLoading = false); _showSnack('SRN has no items'); return; }
      final pids = [for (final si in srnItems) si['product_id'] as String];
      final prods = pids.isEmpty ? <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(
          await Supabase.instance.client.from('products').select('id,selling_price').inFilter('id', pids));
      final priceMap = {for (final p in prods) p['id'] as String: (p['selling_price'] as num?)?.toDouble() ?? 0};
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SRI', 'p_year': year});
      final vNum = 'SRI-$year-${nextNum.toString().padLeft(4, '0')}';
      final invId = 'sri_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('sales_return_invoices').insert({
        'id': invId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': vNum, 'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'srn_id': srn['id'], 'customer_id': srn['customer_id'],
        'subtotal': 0, 'discount_total': 0, 'grand_total': 0,
        'status': 'draft', 'is_locked': false, 'created_by': ref.read(currentUserProvider)?.id,
      });
      for (final si in srnItems) {
        final pid = si['product_id'] as String;
        final price = priceMap[pid] ?? 0;
        final qty = (si['quantity'] as num?)?.toDouble() ?? 0;
        await Supabase.instance.client.from('sales_return_invoice_items').insert({
          'id': 'srii_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'invoice_id': invId, 'srn_item_id': si['id'],
          'product_id': pid, 'uom_id': si['uom_id'],
          'quantity': si['quantity'], 'unit_price': price, 'discount': 0, 'line_total': qty * price,
        });
      }
      await _logAudit(invId, 'created', 'SRI $vNum from SRN ${srn['voucher_number']}');
      _showSnack('$vNum created — enter prices then issue');
      await _loadList(); _loadDetail(invId);
    } catch (e) { setState(() => _detailLoading = false); _showSnack('Failed: $e'); }
  }

  Future<void> _saveItemPrice(String itemId) async {
    final price = double.tryParse(_priceCtrl[itemId]?.text ?? '') ?? 0;
    final disc  = (double.tryParse(_discCtrl[itemId]?.text ?? '') ?? 0).clamp(0.0, 100.0);
    final qty   = (_items.firstWhere((i) => i['id'] == itemId, orElse: () => {})['quantity'] as num?)?.toDouble() ?? 0;
    final lt    = qty * price * (1 - disc / 100);
    try {
      await Supabase.instance.client.from('sales_return_invoice_items').update({'unit_price': price, 'discount': disc, 'line_total': lt}).eq('id', itemId);
      setState(() { final idx = _items.indexWhere((i) => i['id'] == itemId); if (idx >= 0) { _items[idx]['unit_price'] = price; _items[idx]['discount'] = disc; _items[idx]['line_total'] = lt; } });
      await _recalcTotals();
    } catch (e) { _showSnack('Save error: $e'); }
  }

  Future<void> _recalcTotals() async {
    double subtotal = 0, discount = 0;
    for (final it in _items) {
      final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
      final disc = (it['discount'] as num?)?.toDouble() ?? 0;
      subtotal += qty * price; discount += qty * price * (disc / 100);
    }
    final grand = subtotal - discount;
    try {
      await Supabase.instance.client.from('sales_return_invoices').update({'subtotal': subtotal, 'discount_total': discount, 'grand_total': grand, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', _detail['id']);
      setState(() { _detail['subtotal'] = subtotal; _detail['discount_total'] = discount; _detail['grand_total'] = grand; final idx = _invoices.indexWhere((r) => r['id'] == _detail['id']); if (idx >= 0) _invoices[idx]['grand_total'] = grand; });
    } catch (_) {}
  }

  Future<void> _issueInvoice() async {
    if (_items.isEmpty) { _showSnack('No items'); return; }
    for (final it in _items) await _saveItemPrice(it['id'] as String);
    for (final it in _items) {
      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
      if (price <= 0) { _showSnack('Unit price for "${it['products']?['name'] ?? 'item'}" must be greater than 0'); return; }
    }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Issue Sales Return Invoice?'),
      content: const Text('The return will be posted to the ledger and the invoice locked. Stock was already returned to inventory when the SRN was confirmed. This cannot be undone.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Issue'))],
    ));
    if (ok != true) return;
    final userId = ref.read(currentUserProvider)?.id;
    final invId = _detail['id'] as String;
    final srnId = _detail['srn_id'] as String?;
    try {
      // Lock SRI — the sri_autopost trigger posts the GL on this update.
      // Stock is NOT moved here; it moved when the SRN was confirmed.
      await Supabase.instance.client.from('sales_return_invoices').update({'status': 'issued', 'is_locked': true, 'locked_by': userId, 'locked_at': DateTime.now().toUtc().toIso8601String(), 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', invId);
      // Flip SRN to invoiced + lock
      if (srnId != null) {
        await Supabase.instance.client.from('sales_returns').update({'status': 'invoiced', 'is_locked': true, 'locked_by': userId, 'locked_at': DateTime.now().toUtc().toIso8601String(), 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', srnId);
      }
      await _logAudit(invId, 'issued', 'Return posted to ledger');
      _showSnack('Invoice issued — return posted to the ledger');
      _loadDetail(invId); _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    if (_isLocked && !_canUnlock) { _showSnack('Only admins can unlock'); return; }
    final newLocked = !_isLocked;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      await Supabase.instance.client.from('sales_return_invoices').update({'is_locked': newLocked, 'locked_by': newLocked ? userId : null, 'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, newLocked ? 'locked' : 'unlocked', null);
      _showSnack(newLocked ? 'Locked' : 'Unlocked');
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _void() async {
    if (!_canDelete) return;
    if (_isVoided) { _showSnack('Already voided'); return; }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Void Sales Return Invoice?'),
      content: Text('Void ${_detail['voucher_number']}?\n\nThe ledger entries will be reversed and the SRN restored so it can be re-invoiced or voided. The record is kept for the audit trail; this cannot be undone.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Void'))],
    ));
    if (ok != true) return;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      // Flip is_voided — the void_sri trigger reverses the GL on this update.
      // Stock is not touched here; it belongs to the SRN.
      await Supabase.instance.client.from('sales_return_invoices').update({
        'is_voided': true, 'voided_at': DateTime.now().toUtc().toIso8601String(), 'voided_by': userId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      final srnId = _detail['srn_id'] as String?;
      if (srnId != null) { await Supabase.instance.client.from('sales_returns').update({'status': 'saved', 'is_locked': true, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', srnId); }
      await _logAudit(_detail['id'] as String, 'voided', 'SRI voided; GL reversed; SRN restored');
      _showSnack('Voided — ledger reversed, SRN restored');
      _loadDetail(_detail['id'] as String); _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final cust = _detail['customers'] as Map?;
    final srnVoucher = _detail['sales_returns']?['voucher_number'] as String?;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Sales Return Invoice',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null,
      customerOrSupplier: cust?['shop_name'] as String? ?? 'Walk-in',
      customerAddress: cust?['address'] as String?,
      customerContact: cust?['contact_person'] as String?,
      customerPhone: cust?['phone'] as String?,
      salespersonName: _meta.salespersonName,
      lines: _items.map((it) { final qty = (it['quantity'] as num?)?.toDouble() ?? 0; final price = (it['unit_price'] as num?)?.toDouble() ?? 0; final disc = (it['discount'] as num?)?.toDouble() ?? 0; final lt = (it['line_total'] as num?)?.toDouble() ?? qty * price * (1 - disc / 100); return VoucherLine(product: it['products']?['name'] as String? ?? '-', sku: it['products']?['sku'] as String?, uom: it['uoms']?['abbreviation'] as String?, qty: qty, unitPrice: price, discountPct: disc, lineTotal: lt); }).toList(),
      subtotal: (_detail['subtotal'] as num?)?.toDouble() ?? 0,
      discountTotal: (_detail['discount_total'] as num?)?.toDouble() ?? 0,
      grandTotal: (_detail['grand_total'] as num?)?.toDouble() ?? 0,
      preparedBy: _meta.preparedBy, footerNote: _meta.footerNote,
      relatedRefs: srnVoucher != null ? {'SRN #': srnVoucher} : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) { _selectedId = null; _detail = {}; _items = []; _loadList(); });
    return Container(color: AppTheme.background, child: CollapsibleListPane(
      paneWidth: 360,
      listChild: _buildList(),
      detailChild: _selectedId == null
          ? const Center(child: Text('Select or create a Sales Return Invoice', style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
          : _buildDetail(),
    ));
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _invoices.where((r) {
      final matchSearch = q.isEmpty || (r['voucher_number'] as String? ?? '').toLowerCase().contains(q) || ((r['customers']?['shop_name'] as String?) ?? '').toLowerCase().contains(q) || ((r['sales_returns']?['voucher_number'] as String?) ?? '').toLowerCase().contains(q);
      final locked = r['is_locked'] as bool? ?? false;
      final matchFilter = _filter == 'all' || (_filter == 'draft' && !locked) || (_filter == 'issued' && locked);
      return matchSearch && matchFilter;
    }).toList();
    return Container(decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))), child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 12), child: Row(children: [
        const Expanded(child: Text('Sales Return Invoices', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32), onPressed: _createNew, tooltip: 'New SRI'),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: TextField(
        decoration: const InputDecoration(hintText: 'Search SRI / SRN / customer…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
        onChanged: (v) => setState(() => _search = v))),
      const SizedBox(height: 8),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
        _SriTab(label: 'All',    value: 'all',    current: _filter, onTap: (v) => setState(() => _filter = v)),
        const SizedBox(width: 6),
        _SriTab(label: 'Draft',  value: 'draft',  current: _filter, onTap: (v) => setState(() => _filter = v)),
        const SizedBox(width: 6),
        _SriTab(label: 'Issued', value: 'issued', current: _filter, onTap: (v) => setState(() => _filter = v)),
      ])),
      const SizedBox(height: 12),
      Expanded(child: _listLoading ? const Center(child: CircularProgressIndicator())
          : filtered.isEmpty ? const Center(child: Text('No invoices yet.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = filtered[i]; final sel = r['id'] == _selectedId;
                final locked = r['is_locked'] as bool? ?? false;
                final voided = r['is_voided'] as bool? ?? false;
                final badgeText = voided ? 'voided' : (locked ? 'issued' : 'draft');
                final badgeColor = voided ? AppTheme.danger : (locked ? AppTheme.success : Colors.orange);
                return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.06),
                  title: Row(children: [
                    Expanded(child: Text(r['voucher_number'] as String? ?? '-', style: TextStyle(fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : null, decoration: voided ? TextDecoration.lineThrough : null))),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: badgeColor.withOpacity(0.12), borderRadius: BorderRadius.circular(4)), child: Text(badgeText, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: badgeColor))),
                  ]),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(r['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 11)),
                    if (r['sales_returns']?['voucher_number'] != null) Text('← ${r['sales_returns']['voucher_number']}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ]),
                  trailing: Text(((r['grand_total'] as num?)?.toStringAsFixed(2)) ?? '0.00', style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  onTap: () => _loadDetail(r['id'] as String));
              })),
    ]));
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: CircularProgressIndicator());
    final cust = _detail['customers'] as Map?;
    final srnVoucher = _detail['sales_returns']?['voucher_number'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Sales Return Invoice', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ])),
          if (!_isVoided && _isDraft) ...[
            ElevatedButton.icon(icon: const Icon(Icons.check_circle_outline, size: 16), label: const Text('Issue Invoice'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success), onPressed: _issueInvoice),
            const SizedBox(width: 8),
          ],
          if (!_isVoided && (!_isDraft || _canUnlock))
            IconButton(icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
                tooltip: _isLocked ? 'Unlock (admin)' : 'Lock', onPressed: _toggleLock),
          IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), onPressed: _print),
          if (_canDelete && !_isVoided) IconButton(icon: const Icon(Icons.block, color: AppTheme.danger), tooltip: 'Void', onPressed: _void),
        ])),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          _SriChip(label: 'Customer', value: cust?['shop_name'] as String? ?? 'Walk-in'),
          _SriChip(label: 'Date', value: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
          _SriChip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
          if (srnVoucher != null) _SriChip(label: 'SRN #', value: srnVoucher),
          _SriChip(label: 'Status', value: _isVoided ? 'voided' : (_isLocked ? 'issued' : 'draft')),
          if (_isLocked) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.4))), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.lock_outline, size: 12, color: Colors.orange), SizedBox(width: 4), Text('Locked', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w600))])),
        ]),
        _SriInfoStrip(address: cust?['address'] as String?, contact: cust?['contact_person'] as String?, phone: cust?['phone'] as String?, salesperson: _meta.salespersonName, preparedBy: _meta.preparedBy),
        if (_isDraft) Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.success.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.success.withOpacity(0.25))),
          child: const Row(children: [Icon(Icons.edit_note, size: 15, color: AppTheme.success), SizedBox(width: 8), Expanded(child: Text('Enter selling prices and discounts, then click "Issue Invoice" to return stock to inventory.', style: TextStyle(fontSize: 12, color: AppTheme.success)))])),
        const SizedBox(height: 16),
        Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
              child: const Row(children: [
                Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 1, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                Expanded(flex: 2, child: Text('Price', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                Expanded(flex: 1, child: Text('Disc%', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
              ])),
            const Divider(height: 1),
            if (_items.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('No items', style: TextStyle(color: AppTheme.textSecondary))),
            ..._items.map((it) {
              final id = it['id'] as String;
              final qty   = (it['quantity']   as num?)?.toDouble() ?? 0;
              final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
              final disc  = (it['discount']   as num?)?.toDouble() ?? 0;
              final lt    = (it['line_total'] as num?)?.toDouble() ?? qty * price * (1 - disc / 100);
              return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(children: [
                  Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13)),
                    if (it['products']?['sku'] != null) Text(it['products']!['sku'] as String, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ])),
                  Expanded(flex: 1, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 1, child: Text(qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(flex: 2, child: _isDraft ? TextField(controller: _priceCtrl[id], decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)), textAlign: TextAlign.right, keyboardType: const TextInputType.numberWithOptions(decimal: true), onSubmitted: (_) => _saveItemPrice(id)) : Text(price.toStringAsFixed(2), textAlign: TextAlign.right)),
                  Expanded(flex: 1, child: _isDraft ? TextField(controller: _discCtrl[id], decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)), textAlign: TextAlign.right, keyboardType: const TextInputType.numberWithOptions(decimal: true), onSubmitted: (_) => _saveItemPrice(id)) : Text('${disc.toStringAsFixed(0)}%', textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text(lt.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                ]));
            }),
          ])),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerRight, child: Container(padding: const EdgeInsets.all(12), width: 280,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _tr('Subtotal', (_detail['subtotal'] as num?)?.toDouble() ?? 0),
            _tr('Discount', (_detail['discount_total'] as num?)?.toDouble() ?? 0, color: AppTheme.warning),
            const Divider(height: 8),
            _tr('Grand Total', (_detail['grand_total'] as num?)?.toDouble() ?? 0, bold: true),
          ]))),
        const SizedBox(height: 16),
        _SriAuditTrail(voucherId: _selectedId ?? ''),
      ]))),
    ]);
  }
  Widget _tr(String label, double v, {bool bold = false, Color? color}) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: TextStyle(color: color ?? AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: bold ? 14 : 12)), Text(v.toStringAsFixed(2), style: TextStyle(color: color ?? (bold ? AppTheme.primary : null), fontWeight: bold ? FontWeight.w700 : FontWeight.w600, fontSize: bold ? 15 : 13))]));
}

class _SrnPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> srns;
  const _SrnPickerDialog({required this.srns});
  @override State<_SrnPickerDialog> createState() => _SrnPickerDialogState();
}
class _SrnPickerDialogState extends State<_SrnPickerDialog> {
  String _q = '';
  @override Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final filtered = widget.srns.where((s) => q.isEmpty || (s['voucher_number'] as String? ?? '').toLowerCase().contains(q) || ((s['customers']?['shop_name'] as String?) ?? '').toLowerCase().contains(q)).toList();
    return AlertDialog(
      title: Text('Pick a confirmed SRN  ·  ${widget.srns.length} eligible'),
      content: SizedBox(width: 520, height: 440, child: Column(children: [
        TextField(decoration: const InputDecoration(hintText: 'Search SRN # / customer', prefixIcon: Icon(Icons.search, size: 18), isDense: true), onChanged: (v) => setState(() => _q = v), autofocus: true),
        const SizedBox(height: 12),
        Expanded(child: filtered.isEmpty ? const Center(child: Text('No eligible SRNs.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) { final s = filtered[i]; return ListTile(dense: true,
                title: Text(s['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(s['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(context, s)); })),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
    );
  }
}

class _SriInfoStrip extends StatelessWidget {
  final String? address, contact, phone, salesperson, preparedBy;
  const _SriInfoStrip({this.address, this.contact, this.phone, this.salesperson, this.preparedBy});
  @override Widget build(BuildContext context) {
    final tiles = <Widget>[
      if (address != null && address!.trim().isNotEmpty) _t(Icons.location_on_outlined, 'Address', address!),
      if (contact != null && contact!.isNotEmpty) _t(Icons.account_circle_outlined, 'Contact', contact!),
      if (phone != null && phone!.isNotEmpty) _t(Icons.phone_outlined, 'Phone', phone!),
      if (salesperson != null && salesperson!.isNotEmpty) _t(Icons.person_pin_outlined, 'Salesperson', salesperson!),
    ];
    if (tiles.isEmpty && (preparedBy == null || preparedBy!.isEmpty)) return const SizedBox.shrink();
    return Container(margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: AppTheme.background, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tiles.isNotEmpty) Wrap(spacing: 24, runSpacing: 8, children: tiles),
        if (preparedBy != null && preparedBy!.isNotEmpty) ...[if (tiles.isNotEmpty) const SizedBox(height: 8), Row(children: [const Icon(Icons.draw_outlined, size: 14, color: AppTheme.textSecondary), const SizedBox(width: 6), Text('Prepared by: $preparedBy', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontStyle: FontStyle.italic))])],
      ]));
  }
  Widget _t(IconData icon, String label, String val) => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 300), child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, size: 16, color: AppTheme.textSecondary), const SizedBox(width: 6), Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)), Text(val, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500))])]));
}

class _SriChip extends StatelessWidget { final String label, value; const _SriChip({required this.label, required this.value}); @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)), child: Row(mainAxisSize: MainAxisSize.min, children: [Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)), Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12))])); }
class _SriTab extends StatelessWidget { final String label, value, current; final ValueChanged<String> onTap; const _SriTab({required this.label, required this.value, required this.current, required this.onTap}); @override Widget build(BuildContext context) { final active = value == current; return GestureDetector(onTap: () => onTap(value), child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: active ? AppTheme.primary : AppTheme.background, borderRadius: BorderRadius.circular(12), border: Border.all(color: active ? AppTheme.primary : AppTheme.border)), child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)))); } }

class _SriAuditTrail extends StatelessWidget {
  final String voucherId; const _SriAuditTrail({required this.voucherId});
  @override Widget build(BuildContext context) {
    if (voucherId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<dynamic>>(
      future: Supabase.instance.client.from('voucher_audit_log').select('*, users(name)').eq('voucher_id', voucherId).eq('voucher_type', 'SRI').order('created_at', ascending: false).limit(20),
      builder: (ctx, snap) {
        if (!snap.hasData || (snap.data as List).isEmpty) return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)), child: const Row(children: [Icon(Icons.history, size: 14, color: AppTheme.textSecondary), SizedBox(width: 8), Text('No activity logged yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))]));
        final entries = List<Map<String, dynamic>>.from(snap.data!);
        return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)), const SizedBox(height: 8),
            ...entries.map((e) { final a = e['action'] as String? ?? '-'; final ts = e['created_at'] != null ? DateFormat('d MMM HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : ''; final d = e['details'] as String? ?? ''; Color color; switch (a) { case 'created': color = AppTheme.primary; break; case 'issued': color = AppTheme.success; break; case 'deleted': color = AppTheme.danger; break; case 'locked': color = Colors.orange; break; default: color = AppTheme.textSecondary; } return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.history, size: 13, color: color), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Text(a, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)), const Spacer(), Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]), if (d.isNotEmpty) Text(d, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]))])); }),
          ]));
      });
  }
}
