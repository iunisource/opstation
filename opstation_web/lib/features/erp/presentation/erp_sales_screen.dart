import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/layout/collapsible_list_pane.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';
import '../../../core/widgets/product_picker.dart';
import '../widgets/voucher_docs_panel.dart';
import '../widgets/voucher_remarks_panel.dart';

// ─── Shared helpers ──────────────────────────────────────────────────────────

/// Timestamp for inventory movements: the VOUCHER's date (so the inventory
/// ledger posts on the date the voucher carries, not the running date),
/// combined with the current local time-of-day so same-day entries keep
/// their true ordering. Falls back to now if the voucher has no date.
String movedAtForVoucher(String? voucherDate) {
  final nowL = DateTime.now();
  final d = voucherDate == null ? null : DateTime.tryParse(voucherDate);
  if (d == null) return nowL.toUtc().toIso8601String();
  return DateTime(d.year, d.month, d.day, nowL.hour, nowL.minute, nowL.second)
      .toUtc()
      .toIso8601String();
}

/// Returns null on success OR when there's nothing meaningful to bank (e.g.
/// legacy numeric-only voucher numbers from before the TYPE-YYYY-NNNN scheme).
/// Returns a human-readable failure reason only for *actual* DB errors so the
/// caller can surface it in a snack.
Future<String?> _bankCancelledVoucherNumber({
  required String? orgId,
  required String? branchId,
  required String voucherNumber,
}) async {
  if (orgId == null || orgId.isEmpty) return 'org missing';
  if (voucherNumber.isEmpty) return null; // nothing to bank
  final parts = voucherNumber.split('-');
  if (parts.length != 3) {
    // Legacy format (e.g. plain "11") — not tracked in voucher_sequences,
    // nothing to reuse against. Skip silently.
    // ignore: avoid_print
    print('[VoucherBank] $voucherNumber is legacy format, skipping');
    return null;
  }
  final year = int.tryParse(parts[1]);
  final number = int.tryParse(parts[2]);
  if (year == null || number == null) {
    // ignore: avoid_print
    print('[VoucherBank] $voucherNumber not numeric, skipping');
    return null;
  }
  try {
    await Supabase.instance.client.from('voucher_cancelled_numbers').insert({
      'id': 'cancel_${DateTime.now().millisecondsSinceEpoch}',
      'org_id': orgId,
      'branch_id': branchId,
      'voucher_type': parts[0],
      'year': year,
      'number': number,
    });
    // ignore: avoid_print
    print('[VoucherBank] $voucherNumber banked for reuse');
    return null;
  } catch (e) {
    // ignore: avoid_print
    print('[VoucherBank] failed to bank $voucherNumber: $e');
    return e.toString().split('\n').first;
  }
}

// ─── Sales Orders (Master-Detail) ────────────────────────────────────────────


// Up to 4 decimals, trailing zeros trimmed, with thousands separators — for
// read-only display of quantities, unit prices and totals on vouchers.
final NumberFormat _num4 = NumberFormat('#,##0.####');
String _n4(num? v) => _num4.format((v ?? 0).toDouble());
// Plain (no grouping) up-to-4-decimal string for editable field values, so the
// text parses straight back with double.tryParse.
String _plain4(num? v) {
  final d = (v ?? 0).toDouble();
  var s = d.toStringAsFixed(4);
  if (s.contains('.')) {
    while (s.endsWith('0')) { s = s.substring(0, s.length - 1); }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}

class ErpSalesScreen extends ConsumerStatefulWidget {
  const ErpSalesScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpSalesScreen> createState() => _ErpSalesScreenState();
}

class _ErpSalesScreenState extends ConsumerState<ErpSalesScreen> {
  List<Map<String, dynamic>> _orders = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _products = [];
  bool _hideGroupsEnabled = false;
  Map<String, Set<String>> _hiddenByBranch = {};
  List<Map<String, dynamic>> _uoms = [];
  List<Map<String, dynamic>> _customers = [];
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  bool _datesEditable = false;
  String _search = '';
  String _statusFilter = 'all';

  // inline add row
  String? _addProductId;
  String? _addUomId;
  final _addQtyCtrl = TextEditingController(text: '1');
  final _addQtyFocus = FocusNode();
  // FOC (free-of-cost) add-row + org toggle
  String? _focProductId;
  String? _focUomId;
  final _focQtyCtrl = TextEditingController(text: '1');
  bool _focEnabled = false;
  // inline edit
  final Map<String, TextEditingController> _qtyControllers = {};
  bool _hasDo = false; // true if any Delivery Order exists against this SO (cascade lock)
  List<String> _doRefs = []; // DO voucher numbers against this SO (for messages)
  String? _linkedDoId; // most recent active DO id, for the jump-to-DO button

  @override
  void initState() { super.initState(); _loadList(); _loadMeta(); if (widget.focusId != null) _loadDetail(widget.focusId!); }

  @override
  void dispose() {
    _addQtyCtrl.dispose();
    _addQtyFocus.dispose();
    _focQtyCtrl.dispose();
    for (final c in _qtyControllers.values) c.dispose();
    super.dispose();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  List<Map<String, dynamic>> get _visibleProducts {
    if (!_hideGroupsEnabled) return _products;
    final bid = ref.read(selectedBranchProvider)?['id'] as String?;
    final hidden = bid == null ? null : _hiddenByBranch[bid];
    if (hidden == null || hidden.isEmpty) return _products;
    return _products.where((p) => !hidden.contains(p['product_main_group'])).toList();
  }

  Future<void> _loadMeta() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final p = await client.from('products').select('id, name, sku, base_uom_id, selling_price, product_main_group').eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      final u = await client.from('uoms').select().eq('org_id', orgId).order('name');
      bool focOn = false;
      try {
        final cfg = await client.from('app_config').select('value')
            .eq('org_id', orgId).eq('key', 'org.foc_enabled').maybeSingle();
        focOn = (cfg?['value'] as String?) == 'true';
      } catch (_) {}
      bool hideOn = false; final Map<String, Set<String>> hiddenBy = {};
      try {
        final hc = await client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.hide_main_groups_by_branch').maybeSingle();
        hideOn = (hc?['value'] as String?) == 'true';
        if (hideOn) {
          final hr = await client.from('branch_hidden_main_groups').select('branch_id, main_group').eq('org_id', orgId);
          for (final r in hr as List) { (hiddenBy[r['branch_id'] as String] ??= <String>{}).add(r['main_group'] as String); }
        }
      } catch (_) {}
      if (mounted) setState(() { _products = List<Map<String,dynamic>>.from(p); _uoms = List<Map<String,dynamic>>.from(u); _focEnabled = focOn; _hideGroupsEnabled = hideOn; _hiddenByBranch = hiddenBy; });
      _ensureCustomers();
    } catch (_) {}
  }

  Future<void>? _customersFuture;
  // Returns immediately if loaded; otherwise awaits the single in-flight load so
  // opening the picker early waits for customers instead of showing an empty list.
  Future<void> _ensureCustomers() {
    if (_customers.isNotEmpty) return Future.value();
    return _customersFuture ??= _loadCustomersNow();
  }
  Future<void> _loadCustomersNow() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final List<Map<String, dynamic>> c = [];
      const pageSize = 1000;
      var offset = 0;
      while (true) {
        final page = await client.from('customers').select('id, shop_name, code')
            .eq('org_id', orgId).eq('is_active', true).order('shop_name')
            .range(offset, offset + pageSize - 1);
        c.addAll(List<Map<String, dynamic>>.from(page));
        if (page.length < pageSize) break;
        offset += pageSize;
      }
      if (mounted) setState(() { _customers = c; });
    } catch (_) {}
    _customersFuture = null;
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    try {
      var q = Supabase.instance.client.from('sales_orders').select('*, customers(shop_name, code)').eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final res = await q.order('created_at', ascending: false);
      setState(() { _orders = List<Map<String,dynamic>>.from(res); _listLoading = false; });
    } catch (_) { setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final order = await client.from('sales_orders').select('*, customers(shop_name, code, address, contact_person, phone), branches(name)').eq('id', id).single();
      final items = await client.from('sales_order_items').select('*, products(name, sku), uoms(name, abbreviation)').eq('sales_order_id', id);
      _qtyControllers.clear();
      for (final item in items as List) {
        _qtyControllers[item['id'] as String] = TextEditingController(text: _plain4((item['quantity'] as num?) ?? 1));
      }
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: order['customer_id'] as String?,
        createdById: order['created_by'] as String?,
      );
      bool datesEd = false;
      try { final cc = await client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.voucher_dates_editable').maybeSingle(); datesEd = (cc?['value'] as String?) == 'true'; } catch (_) {}
      bool hasDo = false;
      List<String> doRefs = [];
      String? linkedDoId;
      try {
        final d = await client.from('delivery_orders').select('id, voucher_number, is_voided, created_at').eq('so_id', id).order('created_at', ascending: false);
        final active = (d as List).where((x) => x['is_voided'] != true).toList();
        doRefs = [for (final x in active) (x['voucher_number'] as String? ?? '').trim()].where((s) => s.isNotEmpty).toList();
        hasDo = active.isNotEmpty;
        if (active.isNotEmpty) linkedDoId = active.first['id'] as String?;
      } catch (_) {}
      setState(() {
        _detail = Map<String,dynamic>.from(order);
        _items = List<Map<String,dynamic>>.from(items);
        _meta = meta;
        _hasDo = hasDo;
        _doRefs = doRefs;
        _linkedDoId = linkedDoId;
        _datesEditable = datesEd;
        _detailLoading = false;
      });
    } catch (_) { setState(() => _detailLoading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _pickDate() async {
    final cur = _detail['voucher_date'] != null ? DateTime.tryParse(_detail['voucher_date'] as String) : null;
    final picked = await showDatePicker(context: context, initialDate: cur ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked == null) return;
    final iso = DateFormat('yyyy-MM-dd').format(picked);
    try {
      await Supabase.instance.client.from('sales_orders').update({'voucher_date': iso}).eq('id', _detail['id']);
      if (mounted) setState(() => _detail['voucher_date'] = iso);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  bool get _isDraft => (_detail['status'] as String? ?? 'draft') == 'draft';
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _canEdit => _isDraft && !_isLocked;
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canEditDate => (_datesEditable || _isAdmin) && !_isLocked;
  // Line items can be added/edited/deleted as long as no Delivery Order exists
  // against this SO (standalone) — even on a confirmed/locked SO, and even for
  // admins once a DO exists they are cascade-locked. Header fields stay on
  // _canEdit (draft only). Whole-SO delete has the same DO guard.
  bool get _canEditLines => !_hasDo && !_isLocked;
  // The customer (party) can be changed as long as no Delivery Order is linked
  // — even on a confirmed/locked SO — instead of forcing delete + recreate.
  bool get _canEditParty => !_hasDo;
  // Human-readable DO reference(s) for cascade-lock messages.
  String get _doMsg => _doRefs.isEmpty
      ? 'a Delivery Order exists against this SO. Delete it first.'
      : 'Delivery Order ${_doRefs.join(', ')} exists against this SO. Delete it first.';
  bool get _canDelete {
    if (_isLocked) return false; // locked/delivered SOs cannot be deleted
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  Future<void> _deleteSO() async {
    // Cascade check: no DO should exist for this SO
    try {
      final dos = await Supabase.instance.client.from('delivery_orders').select('id, voucher_number, is_voided').eq('so_id', _detail['id']);
      final active = (dos as List).where((d) => d['is_voided'] != true).toList();
      if (active.isNotEmpty) {
        final refs = [for (final d in active) (d['voucher_number'] as String? ?? '').trim()].where((s) => s.isNotEmpty).toList();
        _showSnack(refs.isEmpty
            ? 'Cannot delete: ${active.length} Delivery Order(s) exist. Delete them first.'
            : 'Cannot delete: Delivery Order ${refs.join(', ')} exists. Delete it first.');
        return;
      }
    } catch (e) { _showSnack('Failed to check: $e'); return; }

    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Sales Order?'),
      content: Text('Permanently delete ${_detail['voucher_number']}? This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;

    try {
      // Bank voucher number for reuse — surface any failure so it's visible.
      final vNum = _detail['voucher_number'] as String? ?? '';
      final bankErr = await _bankCancelledVoucherNumber(
        orgId: _orgId,
        branchId: _detail['branch_id'] as String?,
        voucherNumber: vNum,
      );
      if (bankErr != null) _showSnack('Bank # failed: $bankErr');
      await _logAudit(_detail['id'] as String, 'SO', 'deleted', 'Voucher $vNum deleted by admin');
      // Any DO still on this SO is voided (active ones were blocked above). A voided
      // DO is a dead delivery but its row still holds the so_id FK, so remove it (and
      // its items / any Sales Invoice raised from it) to free the SO for deletion.
      final doRows = await Supabase.instance.client.from('delivery_orders').select('id').eq('so_id', _detail['id']);
      final doIds = [for (final d in doRows as List) d['id'] as String];
      if (doIds.isNotEmpty) {
        final siRows = await Supabase.instance.client.from('sales_invoices').select('id').inFilter('do_id', doIds);
        final siIds = [for (final si in siRows as List) si['id'] as String];
        if (siIds.isNotEmpty) {
          await Supabase.instance.client.from('sales_invoice_items').delete().inFilter('invoice_id', siIds);
          await Supabase.instance.client.from('sales_invoices').delete().inFilter('id', siIds);
        }
        await Supabase.instance.client.from('delivery_order_items').delete().inFilter('delivery_order_id', doIds);
        await Supabase.instance.client.from('delivery_orders').delete().inFilter('id', doIds);
      }
      await Supabase.instance.client.from('sales_order_items').delete().eq('sales_order_id', _detail['id']);
      await Supabase.instance.client.from('sales_orders').delete().eq('id', _detail['id']);
      _showSnack('Deleted');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      await _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _printSO() async {
    final user = ref.read(currentUserProvider);
    VoucherLine soLine(Map it) => VoucherLine(
      product: it['products']?['name'] as String? ?? '-',
      sku: it['products']?['sku'] as String?,
      uom: it['uoms']?['abbreviation'] as String?,
      qty: (it['quantity'] as num?)?.toDouble() ?? 0,
    );
    final lines = _items.where((it) => it['is_foc'] != true).map(soLine).toList();
    final focLines = _items.where((it) => it['is_foc'] == true).map(soLine).toList();
    final date = _detail['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null;
    final cust = _detail['customers'] as Map?;
    final createdAt = _detail['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal()) : null;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Sales Order',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: cust?['shop_name'] as String? ?? 'Walk-in',
      customerAddress: cust?['address'] as String?,
      customerContact: cust?['contact_person'] as String?,
      customerPhone: cust?['phone'] as String?,
      salespersonName: _meta.salespersonName,
      status: (_detail['status'] as String? ?? '').replaceAll('_', ' '),
      remarks: _detail['remarks'] as String?,
      lines: lines,
      focLines: focLines.isEmpty ? null : focLines,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.soFooter,
    );
  }

  Future<void> _logAudit(String voucherId, String type, String action, String? details) async {
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': orgId, 'voucher_type': type, 'voucher_id': voucherId,
        'action': action, 'details': details, 'performed_by': userId,
      });
    } catch (_) {}
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    final year = DateTime.now().year;
    try {
      final voucherNum = await Supabase.instance.client.rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SO', 'p_year': year});
      final id = 'so_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('sales_orders').insert({
        'id': id, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'status': 'draft', 'is_locked': false,
        'created_by': ref.read(currentUserProvider)?.id,
      });
      await _logAudit(id, 'SO', 'created', 'Sales Order created');
      _showSnack('SO created');
      await _loadList();
      _loadDetail(id);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _saveHeader() async {
    if (_detail.isEmpty) return;
    try {
      await Supabase.instance.client.from('sales_orders').update({
        'customer_id': _detail['customer_id'],
        'remarks': _detail['remarks'],
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      _showSnack('Saved');
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<bool> _addItem() async {
    if (!_canEditLines) { _showSnack('Cannot add: $_doMsg'); return false; }
    if (_addProductId == null || _addUomId == null) { _showSnack('Select product and UOM'); return false; }
    final qty = double.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) { _showSnack('Enter valid qty'); return false; }
    if (_items.any((i) => i['product_id'] == _addProductId && i['is_foc'] != true)) {
      _showSnack('Product already added — edit its quantity instead');
      return false;
    }
    final itemId = 'soi_${DateTime.now().millisecondsSinceEpoch}';
    final prod = _products.firstWhere((p) => p['id'] == _addProductId, orElse: () => {});
    final uom = _uoms.firstWhere((u) => u['id'] == _addUomId, orElse: () => {});
    try {
      await Supabase.instance.client.from('sales_order_items').insert({
        'id': itemId,
        'sales_order_id': _detail['id'],
        'product_id': _addProductId, 'uom_id': _addUomId,
        'quantity': qty, 'unit_price': 0, 'discount': 0, 'qty_delivered': 0,
      });
      _qtyControllers[itemId] = TextEditingController(text: _plain4(qty));
      setState(() {
        _items.add({
          'id': itemId,
          'sales_order_id': _detail['id'],
          'product_id': _addProductId,
          'uom_id': _addUomId,
          'quantity': qty,
          'products': {'name': prod['name'], 'sku': prod['sku']},
          'uoms': {'name': uom['name'], 'abbreviation': uom['abbreviation']},
        });
        _addProductId = null; _addUomId = null; _addQtyCtrl.text = '1';
      });
      return true;
    } catch (e) { _showSnack('Failed: $e'); return false; }
  }

  // Open the product picker (keyboard nav), set product + default UOM, then
  // focus the Qty field. Shared by the "+ Add product" tap and the Enter loop.
  Future<bool> _pickAddProduct() async {
    if (!_canEditLines) { _showSnack('Cannot add: $_doMsg'); return false; }
    final p = await pickProduct(context, _visibleProducts, title: 'Add product');
    if (p == null || p.isEmpty) return false; // × / Esc ends the loop
    setState(() {
      _addProductId = p['id'] as String?;
      _addUomId = p['base_uom_id'] as String?;   // default UOM
      _addQtyCtrl.text = '1';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _addQtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _addQtyCtrl.text.length);
      _addQtyFocus.requestFocus();
    });
    return true;
  }

  // Enter on Qty: add the line, then immediately reopen the picker for the next
  // product. Loop ends when the picker is dismissed (× / Esc).
  Future<void> _addItemAndPickNext() async {
    final ok = await _addItem();
    if (!ok) return;
    // small delay so the list rebuild settles before reopening the modal
    await Future.delayed(const Duration(milliseconds: 50));
    // ignore: use_build_context_synchronously
    if (!mounted) return;
    final more = await _pickAddProduct();
    if (!more) return; // dismissed → loop ends
  }

  // Free-of-Cost items section: same shape as the paid items table, but lines
  // carry no price (zero invoice value) and are consumed at cost downstream.
  Widget _buildFocSection() {
    final focItems = _items.where((it) => it['is_foc'] == true).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.teal.withOpacity(0.45)),
      ),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.teal.withOpacity(0.07),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(children: [
            const Icon(Icons.card_giftcard, size: 16, color: Colors.teal),
            const SizedBox(width: 6),
            const Text('Free of Cost Items', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.teal)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: Colors.teal.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
              child: const Text('No invoice value', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.teal)),
            ),
          ]),
        ),
        const Divider(height: 1),
        // Column header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: const BoxDecoration(color: AppTheme.background),
          child: Row(children: [
            const Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            const Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            const Expanded(flex: 2, child: Text('Qty (free)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            SizedBox(width: _canEditLines ? 40 : 0),
          ]),
        ),
        const Divider(height: 1),
        if (focItems.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Align(alignment: Alignment.centerLeft, child: Text('No free items added.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          ),
        ...focItems.map((item) {
          final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  if (item['products']?['sku'] != null)
                    Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ])),
                Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                Expanded(flex: 2, child: _canEditLines
                    ? SizedBox(height: 32, child: TextField(
                        controller: _qtyControllers[item['id'] as String],
                        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onSubmitted: (v) async {
                          final newQty = double.tryParse(v) ?? qty;
                          await Supabase.instance.client.from('sales_order_items').update({'quantity': newQty}).eq('id', item['id']);
                          _loadDetail(_detail['id'] as String);
                        },
                      ))
                    : Text(_n4(qty), style: const TextStyle(fontWeight: FontWeight.w600))),
                if (_canEditLines) SizedBox(width: 40, child: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.danger),
                  onPressed: () => _deleteItem(item['id'] as String),
                )),
              ]),
            ),
            const Divider(height: 1),
          ]);
        }),
        // Add row
        if (_canEditLines) Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(flex: 4, child: Builder(builder: (ctx) {
              final sel = _focProductId == null ? null : _products.firstWhere((x) => x['id'] == _focProductId, orElse: () => <String, dynamic>{});
              final name = (sel == null || sel.isEmpty) ? null : sel['name'] as String?;
              return InkWell(
                onTap: () async {
                  final p = await pickProduct(ctx, _visibleProducts, title: 'Select free product');
                  if (p != null && p.isNotEmpty) setState(() {
                    _focProductId = p['id'] as String?;
                    _focUomId = p['base_uom_id'] as String?;
                  });
                },
                child: InputDecorator(
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10), border: OutlineInputBorder()),
                  child: Row(children: [
                    Expanded(child: Text(name ?? '+ Add free product', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: name == null ? Colors.teal : Colors.black87))),
                    const Icon(Icons.arrow_drop_down, size: 20, color: AppTheme.textSecondary),
                  ]),
                ),
              );
            })),
            const SizedBox(width: 8),
            Expanded(flex: 1, child: DropdownButtonFormField<String>(
              value: _focUomId,
              decoration: const InputDecoration(hintText: 'UOM', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
              items: _uoms.map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['abbreviation'] as String? ?? '', style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) => setState(() => _focUomId = v),
            )),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: TextField(
              controller: _focQtyCtrl,
              decoration: const InputDecoration(hintText: 'Qty', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onSubmitted: (_) => _addFocItem(),
            )),
            const SizedBox(width: 8),
            const Expanded(flex: 2, child: SizedBox.shrink()),
            SizedBox(width: 40, child: IconButton(
              icon: const Icon(Icons.add_circle, color: Colors.teal, size: 20),
              onPressed: _addFocItem,
              tooltip: 'Add free item',
            )),
          ]),
        ),
      ]),
    );
  }

  Future<void> _addFocItem() async {
    if (!_canEditLines) { _showSnack('Cannot add: $_doMsg'); return; }
    if (_focProductId == null || _focUomId == null) { _showSnack('Select product and UOM'); return; }
    final qty = double.tryParse(_focQtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) { _showSnack('Enter valid qty'); return; }
    if (_items.any((i) => i['product_id'] == _focProductId && i['is_foc'] == true)) {
      _showSnack('Product already added to FOC — edit its quantity instead');
      return;
    }
    final itemId = 'soi_${DateTime.now().millisecondsSinceEpoch}';
    final prod = _products.firstWhere((p) => p['id'] == _focProductId, orElse: () => {});
    final uom = _uoms.firstWhere((u) => u['id'] == _focUomId, orElse: () => {});
    try {
      await Supabase.instance.client.from('sales_order_items').insert({
        'id': itemId,
        'sales_order_id': _detail['id'],
        'product_id': _focProductId, 'uom_id': _focUomId,
        'quantity': qty, 'unit_price': 0, 'discount': 0, 'qty_delivered': 0,
        'is_foc': true,
      });
      _qtyControllers[itemId] = TextEditingController(text: _plain4(qty));
      setState(() {
        _items.add({
          'id': itemId,
          'sales_order_id': _detail['id'],
          'product_id': _focProductId,
          'uom_id': _focUomId,
          'quantity': qty,
          'is_foc': true,
          'products': {'name': prod['name'], 'sku': prod['sku']},
          'uoms': {'name': uom['name'], 'abbreviation': uom['abbreviation']},
        });
        _focProductId = null; _focUomId = null; _focQtyCtrl.text = '1';
      });
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _deleteItem(String itemId) async {
    if (!_canEditLines) { _showSnack('Cannot remove: $_doMsg'); return; }
    try {
      await Supabase.instance.client.from('sales_order_items').delete().eq('id', itemId);
      setState(() {
        _items.removeWhere((i) => i['id'] == itemId);
        _qtyControllers.remove(itemId)?.dispose();
      });
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _confirmOrder() async {
    if (_items.isEmpty) { _showSnack('Add items first'); return; }
    // A confirmed SO flows SO → DO → SI, and the SI posts to AR against
    // customer_id as party_id. A null customer here would produce an invoice
    // with no party to receive against — uncollectable, un-ageable, invisible
    // on any ledger. Drafting without a customer stays allowed; confirming does
    // not. This guards every path into an SO, not just quotation conversion.
    final custId = _detail['customer_id'] as String?;
    if (custId == null || custId.isEmpty) {
      _showSnack('Select a customer before confirming');
      return;
    }
    try {
      await Supabase.instance.client.from('sales_orders').update({
        'status': 'confirmed', 'is_locked': true,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'SO', 'confirmed', '${_items.length} items confirmed');
      _showSnack('Order confirmed');
      await _loadList();
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('sales_orders').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'SO', newLocked ? 'locked' : 'unlocked', null);
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _cancelOrder() async {
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Cancel Order'),
      content: const Text('Are you sure?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('No')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Cancel')),
      ],
    ));
    if (confirm != true) return;
    try {
      // Bank the cancelled voucher number for reuse — surface failures.
      final vNum = _detail['voucher_number'] as String? ?? '';
      final bankErr = await _bankCancelledVoucherNumber(
        orgId: _orgId,
        branchId: _detail['branch_id'] as String?,
        voucherNumber: vNum,
      );
      if (bankErr != null) _showSnack('Bank # failed: $bankErr');
      await Supabase.instance.client.from('sales_orders').update({'status': 'cancelled'}).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'SO', 'cancelled', 'Voucher number $vNum freed for reuse');
      _showSnack('Cancelled');
      await _loadList();
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  List<Map<String, dynamic>> get _filteredOrders {
    return _orders.where((o) {
      final matchStatus = _statusFilter == 'all' || o['status'] == _statusFilter;
      final q = _search.toLowerCase();
      final matchSearch = q.isEmpty ||
          (o['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
          (o['customers']?['shop_name'] as String? ?? '').toLowerCase().contains(q);
      return matchStatus && matchSearch;
    }).toList();
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'confirmed': return Colors.blue;
      case 'partially_delivered': return Colors.orange;
      case 'delivered': return AppTheme.success;
      case 'cancelled': return AppTheme.danger;
      default: return AppTheme.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<String, dynamic>?>(selectedBranchProvider, (prev, next) {
      if (prev?['id'] != next?['id']) {
        setState(() { _selectedId = null; _detail = {}; _items = []; _listLoading = true; });
        _loadList();
      }
    });
    return CollapsibleListPane(
        listChild: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(children: [
                  const Text('Sales Orders', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 24), onPressed: _createNew, tooltip: 'New SO'),
                ]),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(hintText: 'Search voucher or customer...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: DropdownButtonFormField<String>(
                  value: _statusFilter,
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All Status', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'draft', child: Text('Draft', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'confirmed', child: Text('Confirmed', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'partially_delivered', child: Text('Partial', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'delivered', child: Text('Delivered', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'cancelled', child: Text('Cancelled', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
                )),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _listLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredOrders.isEmpty
                      ? const Center(child: Text('No orders', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          itemCount: _filteredOrders.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final o = _filteredOrders[i];
                            final isSelected = o['id'] == _selectedId;
                            final status = o['status'] as String? ?? 'draft';
                            return InkWell(
                              onTap: () => _loadDetail(o['id'] as String),
                              child: Container(
                                color: isSelected ? AppTheme.primary.withOpacity(0.06) : null,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(o['voucher_number'] as String? ?? '-',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: isSelected ? AppTheme.primary : Colors.black87)),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: _statusColor(status).withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                      child: Text(status == 'partially_delivered' ? 'Partial' : status,
                                          style: TextStyle(color: _statusColor(status), fontSize: 10, fontWeight: FontWeight.w600)),
                                    ),
                                  ]),
                                  const SizedBox(height: 2),
                                  Text(o['customers']?['shop_name'] as String? ?? 'Walk-in',
                                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                  Text(o['voucher_date'] != null
                                      ? DateFormat('d MMM yyyy').format(DateTime.parse(o['voucher_date'] as String)) : '',
                                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                ]),
                              ),
                            );
                          }),
            ),
        ]),
        detailChild: _selectedId == null
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.receipt_long_outlined, size: 48, color: AppTheme.border),
                const SizedBox(height: 12),
                const Text('Select a Sales Order or create new', style: TextStyle(color: AppTheme.textSecondary)),
                const SizedBox(height: 16),
                ElevatedButton.icon(onPressed: _createNew, icon: const Icon(Icons.add, size: 16), label: const Text('New Sales Order')),
              ]))
            : _detailLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    final status = _detail['status'] as String? ?? 'draft';
    final voucherNum = _detail['voucher_number'] as String? ?? '-';
    final isLocked = _detail['is_locked'] as bool? ?? false;
    final custId = _detail['customer_id'] as String?;

    return Column(children: [
      // ── Voucher AppBar ─────────────────────────────────────
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(voucherNum, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text('Sales Order', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(width: 16),
          _StatusChip(status: status.replaceAll('_', ' '), color: _statusColor(status)),
          if (isLocked) ...[const SizedBox(width: 8), const _LockedBadge()],
          const Spacer(),
          if (_canEdit) ...[
            ElevatedButton(onPressed: _confirmOrder, child: const Text('Confirm Order')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _cancelOrder, style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger), child: const Text('Cancel')),
            const SizedBox(width: 8),
          ],
          if (_isDraft)
            IconButton(
              icon: Icon(isLocked ? Icons.lock_open : Icons.lock_outline, color: isLocked ? Colors.orange : AppTheme.textSecondary),
              tooltip: isLocked ? 'Unlock' : 'Lock',
              onPressed: _toggleLock,
            ),
          if (!_isDraft && status != 'cancelled')
            IconButton(
              icon: Icon(isLocked ? Icons.lock_open : Icons.lock_outline, color: isLocked ? Colors.orange : AppTheme.textSecondary),
              tooltip: isLocked ? 'Unlock' : 'Lock',
              onPressed: _toggleLock,
            ),
          if (_linkedDoId != null)
            IconButton(
              icon: const Icon(Icons.local_shipping_outlined, color: AppTheme.primary),
              tooltip: 'Go to Delivery Order',
              onPressed: () => context.go('/erp/delivery-orders?focus=$_linkedDoId'),
            ),
          if (_canEditDate)
            IconButton(
              icon: const Icon(Icons.edit_calendar_outlined, color: AppTheme.textSecondary),
              tooltip: 'Edit date',
              onPressed: _pickDate,
            ),
          IconButton(
            icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary),
            tooltip: 'Print / PDF',
            onPressed: _printSO,
          ),
          if (_canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
              tooltip: 'Delete',
              onPressed: _deleteSO,
            ),
        ]),
      ),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── Header Fields ───────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Row(children: [
                  Expanded(child: _InfoRow(label: 'Voucher No.', value: voucherNum)),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'Date', value: _detail['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-')),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(flex: 2, child: _canEditParty
                      ? _CustomerSelect(
                          customers: _customers,
                          selectedId: custId,
                          ensureLoaded: _ensureCustomers,
                          liveCustomers: () => _customers,
                          onChanged: (v) async {
                            setState(() => _detail['customer_id'] = v);
                            try {
                              await Supabase.instance.client.from('sales_orders').update({
                                'customer_id': v, 'updated_at': DateTime.now().toUtc().toIso8601String(),
                              }).eq('id', _detail['id']);
                              await _logAudit(_detail['id'] as String, 'SO', 'customer_changed',
                                  'Customer set to ${_customers.firstWhere((c) => c['id'] == v, orElse: () => {'shop_name': 'Walk-in'})['shop_name']}');
                            } catch (_) {}
                          },
                        )
                      : _InfoRow(label: 'Customer', value: _detail['customers']?['shop_name'] as String? ?? 'Walk-in')),
                  const SizedBox(width: 16),
                  Expanded(child: _canEdit
                      ? TextField(
                          controller: TextEditingController(text: _detail['remarks'] as String? ?? ''),
                          decoration: const InputDecoration(labelText: 'Remarks', isDense: true),
                          onChanged: (v) => _detail['remarks'] = v,
                        )
                      : _InfoRow(label: 'Remarks', value: _detail['remarks'] as String? ?? '-')),
                  if (_canEdit) ...[
                    const SizedBox(width: 12),
                    ElevatedButton(onPressed: _saveHeader, child: const Text('Save')),
                  ],
                ]),
              ]),
            ),

            const SizedBox(height: 16),

            // ── Items Table ─────────────────────────────────────
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                  child: Row(children: [
                    const Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    const Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    const Expanded(flex: 2, child: Text('Qty Ordered', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    SizedBox(width: _canEditLines ? 40 : 0),
                  ]),
                ),
                const Divider(height: 1),
                // Items (paid only — FOC lines render in their own section)
                ..._items.where((it) => it['is_foc'] != true).map((item) {
                  final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
                  return Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          if (item['products']?['sku'] != null)
                            Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ])),
                        Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                        Expanded(flex: 2, child: _canEditLines
                            ? SizedBox(height: 32, child: TextField(
                                controller: _qtyControllers[item['id'] as String],
                                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                onSubmitted: (v) async {
                                  final newQty = double.tryParse(v) ?? qty;
                                  await Supabase.instance.client.from('sales_order_items').update({'quantity': newQty}).eq('id', item['id']);
                                  _loadDetail(_detail['id'] as String);
                                },
                              ))
                            : Text(_n4(qty), style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (_canEditLines) SizedBox(width: 40, child: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.danger),
                          onPressed: () => _deleteItem(item['id'] as String),
                        )),
                      ]),
                    ),
                    const Divider(height: 1),
                  ]);
                }),
                // Total quantity across all ordered lines
                if (_items.where((it) => it['is_foc'] != true).isNotEmpty)
                  Builder(builder: (_) {
                    final totalQty = _items.where((it) => it['is_foc'] != true)
                        .fold<double>(0, (s, it) => s + ((it['quantity'] as num?)?.toDouble() ?? 0));
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: const BoxDecoration(color: AppTheme.background),
                      child: Row(children: [
                        const Expanded(flex: 5, child: Text('Total Quantity', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                        Expanded(flex: 2, child: Text(
                            _n4(totalQty),
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13))),
                        if (_canEditLines) const SizedBox(width: 40),
                      ]),
                    );
                  }),
                // Add row
                if (_canEditLines) Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(flex: 4, child: Builder(builder: (ctx) {
                      final sel = _addProductId == null ? null : _products.firstWhere((x) => x['id'] == _addProductId, orElse: () => <String, dynamic>{});
                      final name = (sel == null || sel.isEmpty) ? null : sel['name'] as String?;
                      return InkWell(
                        onTap: () => _pickAddProduct(),
                        child: InputDecorator(
                          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10), border: OutlineInputBorder()),
                          child: Row(children: [
                            Expanded(child: Text(name ?? '+ Add product', maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, color: name == null ? AppTheme.primary : Colors.black87))),
                            const Icon(Icons.arrow_drop_down, size: 20, color: AppTheme.textSecondary),
                          ]),
                        ),
                      );
                    })),
                    const SizedBox(width: 8),
                    Expanded(flex: 1, child: DropdownButtonFormField<String>(
                      value: _addUomId,
                      decoration: const InputDecoration(hintText: 'UOM', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                      items: _uoms.map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['abbreviation'] as String? ?? '', style: const TextStyle(fontSize: 13)))).toList(),
                      onChanged: (v) => setState(() => _addUomId = v),
                    )),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: TextField(
                      controller: _addQtyCtrl,
                      focusNode: _addQtyFocus,
                      decoration: const InputDecoration(hintText: 'Qty', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addItemAndPickNext(),
                    )),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: const SizedBox.shrink()),
                    SizedBox(width: 40, child: IconButton(
                      icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 20),
                      onPressed: () => _addItem(),
                      tooltip: 'Add item',
                    )),
                  ]),
                ),
              ]),
            ),

            if (_focEnabled) ...[
              const SizedBox(height: 16),
              _buildFocSection(),
            ],

            const SizedBox(height: 16),
            _VoucherInfoStrip(
              salesperson: _meta.salespersonName,
              salespersonDiagnostic: _meta.diagnostic,
              customerAddress: _detail['customers']?['address'] as String?,
              customerContact: _detail['customers']?['contact_person'] as String?,
              customerPhone: _detail['customers']?['phone'] as String?,
              preparedBy: _meta.preparedBy,
              createdAt: _detail['created_at'] != null
                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal())
                  : null,
            ),
            const SizedBox(height: 16),
            _AuditTrailList(voucherId: _detail['id'] as String, voucherType: 'SO'),
          ]),
        ),
      ),
    ]);
  }
}

// ─── Delivery Orders (Master-Detail) ─────────────────────────────────────────

class ErpDeliveryOrdersScreen extends ConsumerStatefulWidget {
  const ErpDeliveryOrdersScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpDeliveryOrdersScreen> createState() => _ErpDeliveryOrdersScreenState();
}

class _ErpDeliveryOrdersScreenState extends ConsumerState<ErpDeliveryOrdersScreen> {
  List<Map<String, dynamic>> _orders = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  Map<String, dynamic> _linkedSo = {};
  Map<String, double> _stockByProduct = {};
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _soItems = [];
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  bool _datesEditable = false;
  String _search = '';
  String _statusFilter = 'all';
  // inline delivery qty
  final Map<String, TextEditingController> _deliverQtyCtrl = {};
  // collect-amount at DO approval (default off = non-collection delivery)
  bool _collectEnabled = false;
  num? _collectAmount;
  String? _linkedSiId; // most recent live SI id, for the jump-to-SI button
  bool _deliveryFlow = true; // org.delivery_flow_enabled (default on)

  @override
  void initState() {
    super.initState();
    _loadList();
    if (widget.focusId != null) _loadDetail(widget.focusId!);
  }

  @override
  void dispose() {
    for (final c in _deliverQtyCtrl.values) c.dispose();
    super.dispose();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    try {
      var q = Supabase.instance.client.from('delivery_orders')
          .select('*, customers(shop_name), sales_orders(voucher_number)').eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final res = await q.order('created_at', ascending: false);
      setState(() { _orders = List<Map<String,dynamic>>.from(res); _listLoading = false; });
    } catch (_) { setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final do_ = await client.from('delivery_orders')
          .select('*, customers(shop_name), sales_orders(voucher_number, customer_id), branches(name)')
          .eq('id', id).single();
      final items = await client.from('delivery_order_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('delivery_order_id', id);
      final soItems = await client.from('sales_order_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('sales_order_id', do_['so_id'] as String);
      // Load SO details
      final so = await client.from('sales_orders')
          .select('*, customers(shop_name, code, address, contact_person, phone), branches(name)').eq('id', do_['so_id'] as String).single();

      // Fetch current branch stock for all SO products
      final productIds = (soItems as List).map((i) => i['product_id'] as String).toSet().toList();
      final stockMap = <String, double>{};
      if (productIds.isNotEmpty) {
        final stocks = await client.from('inventory_stock')
            .select('product_id, quantity')
            .eq('branch_id', do_['branch_id'] as String)
            .inFilter('product_id', productIds.cast<Object>());
        for (final s in stocks as List) {
          stockMap[s['product_id'] as String] = (s['quantity'] as num?)?.toDouble() ?? 0;
        }
      }

      // Build delivery qty controllers for available SO items
      final existingSoItemIds = (items as List).map((i) => i['so_item_id'] as String).toSet();
      _deliverQtyCtrl.clear();
      for (final soItem in soItems) {
        final ordered = (soItem['quantity'] as num?)?.toDouble() ?? 0;
        final delivered = (soItem['qty_delivered'] as num?)?.toDouble() ?? 0;
        final pending = ordered - delivered;
        if (!existingSoItemIds.contains(soItem['id'] as String) && pending > 0) {
          _deliverQtyCtrl[soItem['id'] as String] = TextEditingController(text: _plain4(pending));
        }
      }

      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: so['customer_id'] as String?,
        createdById: do_['created_by'] as String?,
      );

      String? linkedSiId;
      try {
        final sis = await client.from('sales_invoices')
            .select('id, is_voided, created_at').eq('do_id', id).order('created_at', ascending: false);
        final live = (sis as List).where((s) => s['is_voided'] != true).toList();
        if (live.isNotEmpty) linkedSiId = live.first['id'] as String?;
      } catch (_) {}

      setState(() {
        _detail = Map<String,dynamic>.from(do_);
        _items = List<Map<String,dynamic>>.from(items);
        _soItems = List<Map<String,dynamic>>.from(soItems);
        _linkedSo = Map<String,dynamic>.from(so);
        _stockByProduct = stockMap;
        _meta = meta;
        _collectAmount = (do_['collect_amount'] as num?);
        _collectEnabled = _collectAmount != null;
        _linkedSiId = linkedSiId;
        _detailLoading = false;
      });
      // Read the delivery-flow + voucher-date org settings.
      try {
        final cfg = await client.from('app_config').select('key,value')
            .eq('org_id', _orgId ?? '')
            .inFilter('key', ['org.delivery_flow_enabled', 'org.voucher_dates_editable']);
        bool flow = true, datesEd = false;
        for (final r in cfg as List) {
          if (r['key'] == 'org.delivery_flow_enabled') flow = r['value'] != 'false';
          if (r['key'] == 'org.voucher_dates_editable') datesEd = r['value'] == 'true';
        }
        if (mounted) setState(() { _deliveryFlow = flow; _datesEditable = datesEd; });
      } catch (_) {}
    } catch (_) { setState(() => _detailLoading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _pickDate() async {
    final cur = _detail['voucher_date'] != null ? DateTime.tryParse(_detail['voucher_date'] as String) : null;
    final picked = await showDatePicker(context: context, initialDate: cur ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked == null) return;
    final iso = DateFormat('yyyy-MM-dd').format(picked);
    try {
      await Supabase.instance.client.from('delivery_orders').update({'voucher_date': iso}).eq('id', _detail['id']);
      if (mounted) setState(() => _detail['voucher_date'] = iso);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isSaved => (_detail['status'] as String? ?? 'saved') == 'saved';
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canEditDate => (_datesEditable || _isAdmin) && !_isLocked && !(_detail['is_voided'] as bool? ?? false);
  bool get _canDelete {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  Future<void> _deleteDO() async {
    // Cascade check: a non-voided SI for this DO blocks deletion
    try {
      final sis = await Supabase.instance.client.from('sales_invoices').select('id, voucher_number, is_voided').eq('do_id', _detail['id']);
      final active = (sis as List).where((s) => s['is_voided'] != true).toList();
      if (active.isNotEmpty) {
        _showSnack('Cannot void: Sales Invoice ${active.first['voucher_number']} exists. Void it first.');
        return;
      }
    } catch (e) { _showSnack('Failed to check: $e'); return; }

    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Void Delivery Order?'),
      content: Text('Void ${_detail['voucher_number']}? Stock will be added back and the delivery\'s accounting reversed. An audit trail is kept; this cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Keep')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Void')),
      ],
    ));
    if (confirm != true) return;

    final orgId = _orgId;
    final branchId = _detail['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;

    try {
      // Atomic: void_delivery_order flips is_voided (firing the existing GL /
      // cost-layer reversal trigger), restores stock + SO qty_delivered, and
      // recalculates the SO status in ONE transaction. p_moved_at preserves the
      // voucher-date posting. Errors cleanly if already voided or an active SI exists.
      await Supabase.instance.client.rpc('void_delivery_order', params: {
        'p_do_id': _detail['id'],
        'p_user_id': userId,
        'p_moved_at': movedAtForVoucher(_detail['voucher_date'] as String?),
      });

      // Bank voucher number — surface failures.
      final vNum = _detail['voucher_number'] as String? ?? '';
      final bankErr = await _bankCancelledVoucherNumber(
        orgId: orgId,
        branchId: branchId,
        voucherNumber: vNum,
      );
      if (bankErr != null) _showSnack('Bank # failed: $bankErr');

      await _logAudit(_detail['id'] as String, 'DO', 'voided', 'Voucher $vNum voided -- GL & stock reversed');
      _showSnack('Voided — stock and accounting reversed');
      await _loadList();
      await _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Could not void: $e'); }
  }

  Future<void> _markDelivered() async {
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Mark as Delivered?'),
      content: Text('Mark ${_detail['voucher_number']} as delivered (self-pickup or '
          'manual fulfillment — no driver needed)?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mark Delivered')),
      ],
    ));
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('delivery_orders').update({
        'delivered_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _loadDetail(_detail['id'] as String);
      if (mounted) _showSnack('Marked delivered');
    } catch (e) {
      if (mounted) _showSnack('Could not mark delivered: $e');
    }
  }

  Future<void> _printDO() async {
    final user = ref.read(currentUserProvider);
    VoucherLine doLine(Map it) => VoucherLine(
      product: it['products']?['name'] as String? ?? '-',
      sku: it['products']?['sku'] as String?,
      uom: it['uoms']?['abbreviation'] as String?,
      qty: (it['qty_delivered'] as num?)?.toDouble() ?? 0,
    );
    final lines = _items.where((it) => it['is_foc'] != true).map(doLine).toList();
    final focLines = _items.where((it) => it['is_foc'] == true).map(doLine).toList();
    final date = _detail['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null;
    final cust = _linkedSo['customers'] as Map?;
    final createdAt = _detail['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal()) : null;
    final soVoucher = _linkedSo['voucher_number'] as String?;
    final pdfRefs = <String, String>{
      if (soVoucher != null) 'SO #': soVoucher,
      if ((_detail['collect_amount'] as num?) != null)
        'Collect': 'Rs. ${(_detail['collect_amount'] as num).toStringAsFixed(0)}',
    };
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Delivery Order',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: cust?['shop_name'] as String? ?? 'Walk-in',
      customerAddress: cust?['address'] as String?,
      customerContact: cust?['contact_person'] as String?,
      customerPhone: cust?['phone'] as String?,
      salespersonName: _meta.salespersonName,
      status: (_detail['status'] as String? ?? '').replaceAll('_', ' '),
      lines: lines,
      focLines: focLines.isEmpty ? null : focLines,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.doFooter,
      relatedRefs: pdfRefs.isEmpty ? null : pdfRefs,
      watermark: (_detail['is_voided'] == true) ? 'VOIDED' : null,
    );
  }

  /// Returns true to proceed with DO creation, false if the user cancels at the
  /// credit-limit / overdue-aging alert. Reuses the Customer Aging RPCs so the
  /// figures match the Customer Aging screen exactly. Controlled by the
  /// org-level toggles in Admin Settings (app_config).
  Future<bool> _passesCreditAndAgingCheck(
      BuildContext dctx, String orgId, String? customerId, String customerName) async {
    if (customerId == null) return true; // walk-in / no customer
    final client = Supabase.instance.client;

    // 1) Read the org toggles.
    bool creditOn = false, agingOn = false;
    int agingDays = 0;
    try {
      final cfg = await client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId);
      final map = {
        for (final r in cfg as List)
          r['key'] as String: (r['value'] as String? ?? '')
      };
      creditOn = map['org.credit_limit_alert'] == 'true';
      agingOn = map['org.aging_alert'] == 'true';
      agingDays = int.tryParse(map['org.aging_alert_days'] ?? '') ?? 0;
    } catch (_) {}
    if (!creditOn && !agingOn) return true;

    final fmt = NumberFormat('#,##0');
    final asOf = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final params = {'p_org_id': orgId, 'p_as_of': asOf};
    final issues = <_CreditIssue>[];

    // 2) Credit limit: outstanding (GL-true 1210 balance) vs customers.credit_limit.
    if (creditOn) {
      double creditLimit = 0;
      try {
        final c = await client
            .from('customers')
            .select('credit_limit')
            .eq('id', customerId)
            .maybeSingle();
        creditLimit = (c?['credit_limit'] as num?)?.toDouble() ?? 0;
      } catch (_) {}
      if (creditLimit > 0) {
        double balance = 0;
        try {
          final agg = await client.rpc('rpc_customer_aging', params: params) as List;
          for (final a in agg) {
            if ((a as Map)['customer_id'] == customerId) {
              balance = (a['total'] as num?)?.toDouble() ?? 0;
              break;
            }
          }
        } catch (_) {}
        if (balance > creditLimit) {
          issues.add(_CreditIssue(
            'Credit limit exceeded',
            'Limit ${fmt.format(creditLimit)}  •  Outstanding ${fmt.format(balance)}  •  '
                'Over by ${fmt.format(balance - creditLimit)}',
          ));
        }
      }
    }

    // 3) Aging: any open invoice aged at/beyond the threshold.
    if (agingOn && agingDays > 0) {
      double agedAmt = 0;
      int agedCount = 0, oldest = 0;
      try {
        final det = await client.rpc('rpc_customer_aging_detail', params: params) as List;
        for (final d in det) {
          final m = d as Map;
          if (m['customer_id'] != customerId) continue;
          final age = (m['age_days'] as num?)?.toInt() ?? 0;
          final amt = (m['open_amt'] as num?)?.toDouble() ?? 0;
          if (age >= agingDays && amt > 0) {
            agedAmt += amt;
            agedCount++;
            if (age > oldest) oldest = age;
          }
        }
      } catch (_) {}
      if (agedCount > 0) {
        issues.add(_CreditIssue(
          'Overdue aging',
          '$agedCount invoice(s) totaling ${fmt.format(agedAmt)} aged $agingDays+ days  •  '
              'oldest $oldest days',
        ));
      }
    }

    if (issues.isEmpty) return true;
    if (!dctx.mounted) return false;

    // 4) Overridable alert.
    final proceed = await showDialog<bool>(
      context: dctx,
      barrierDismissible: false,
      builder: (adCtx) => AlertDialog(
        title: Row(children: const [
          Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
          SizedBox(width: 10),
          Text('Credit / Aging Alert'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(customerName,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 12),
            for (final iss in issues) ...[
              Text(iss.title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AppTheme.danger)),
              const SizedBox(height: 2),
              Text(iss.detail,
                  style: const TextStyle(
                      fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35)),
              const SizedBox(height: 12),
            ],
            const Text('Create this Delivery Order anyway?',
                style: TextStyle(fontSize: 12.5)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(adCtx, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.of(adCtx, rootNavigator: true).pop(true),
              child: const Text('Proceed anyway')),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    // Load confirmed SOs
    final sos = await Supabase.instance.client.from('sales_orders')
        .select('id, voucher_number, customer_id, customers(shop_name)').eq('org_id', orgId)
        .eq('branch_id', branchId).inFilter('status', ['confirmed', 'partially_delivered']);
    if (!mounted) return;
    if ((sos as List).isEmpty) { _showSnack('No confirmed Sales Orders available'); return; }
    String? soId;
    String soSearch = '';
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) {
          final filteredSos = (sos as List).where((s) {
            if (soSearch.isEmpty) return true;
            final q = soSearch.toLowerCase();
            return (s['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
                (s['customers']?['shop_name'] as String? ?? '').toLowerCase().contains(q);
          }).toList();
          return AlertDialog(
            title: const Text('New Delivery Order'),
            contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            content: SizedBox(
              width: 520,
              height: 420,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Sales Order *', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search by SO number or customer...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                  onChanged: (v) => setS(() => soSearch = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filteredSos.isEmpty
                      ? const Center(child: Text('No matching Sales Orders', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: filteredSos.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final s = filteredSos[i];
                            final selected = s['id'] == soId;
                            return InkWell(
                              onTap: () => setS(() => soId = s['id'] as String),
                              child: Container(
                                color: selected ? AppTheme.primary.withOpacity(0.08) : null,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                child: Row(children: [
                                  Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                      size: 16, color: selected ? AppTheme.primary : AppTheme.textSecondary),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(s['voucher_number'] as String? ?? '-',
                                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: selected ? AppTheme.primary : Colors.black87)),
                                      Text(s['customers']?['shop_name'] as String? ?? 'Walk-in',
                                          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                                    ]),
                                  ),
                                ]),
                              ),
                            );
                          },
                        ),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: soId == null ? null : () async {
                  final year = DateTime.now().year;
                  try {
                    final so = sos.firstWhere((s) => s['id'] == soId);
                    final custName = (so['customers']?['shop_name'] as String?) ?? 'this customer';
                    final ok = await _passesCreditAndAgingCheck(
                        ctx, orgId, so['customer_id'] as String?, custName);
                    if (!ok) return; // user cancelled at the credit/aging alert
                    if (!ctx.mounted) return;
                    final voucherNum = await Supabase.instance.client.rpc('next_voucher_number',
                        params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'DO', 'p_year': year});
                    final id = 'do_${DateTime.now().millisecondsSinceEpoch}';
                    await Supabase.instance.client.from('delivery_orders').insert({
                      'id': id, 'org_id': orgId, 'branch_id': branchId,
                      'voucher_number': voucherNum,
                      'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                      'so_id': soId, 'customer_id': so['customer_id'],
                      'remarks': so['remarks'],
                      'status': 'saved', 'is_locked': false,
                      'created_by': ref.read(currentUserProvider)?.id,
                    });
                    if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                    await _loadList();
                  _loadDetail(id);
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: const Text('Create'),
            ),
          ],
        );
        },
      ),
    );
  }

  Future<void> _logAudit(String voucherId, String type, String action, String? details) async {
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': orgId, 'voucher_type': type, 'voucher_id': voucherId,
        'action': action, 'details': details, 'performed_by': userId,
      });
    } catch (_) {}
  }

  Widget _collectToggle() {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('Collect', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      Switch(
        value: _collectEnabled,
        onChanged: (v) async {
          if (v) {
            final amt = await _promptCollectAmount();
            if (amt != null && amt > 0) {
              setState(() { _collectEnabled = true; _collectAmount = amt; });
            }
          } else {
            setState(() { _collectEnabled = false; _collectAmount = null; });
          }
        },
      ),
      if (_collectEnabled && _collectAmount != null)
        InkWell(
          onTap: () async {
            final amt = await _promptCollectAmount();
            if (amt != null && amt > 0) setState(() => _collectAmount = amt);
          },
          child: Text('Rs. ${_collectAmount!.toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ),
    ]);
  }

  Future<num?> _promptCollectAmount() async {
    final ctrl = TextEditingController(text: _collectAmount?.toStringAsFixed(0) ?? '');
    return showDialog<num>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Amount to collect'),
      content: TextField(
        controller: ctrl, autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Amount (Rs.)', prefixText: 'Rs. '),
        onSubmitted: (_) => Navigator.pop(ctx, num.tryParse(ctrl.text.trim())),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, num.tryParse(ctrl.text.trim())), child: const Text('Set')),
      ],
    ));
  }

  Future<void> _saveDeliveryOrder() async {
    // Persist collect amount BEFORE _saveDelivery() — save_delivery_order locks
    // the DO as its idempotency claim, and a locked DO can't change other
    // columns (locked-DO rule), so this must happen while it's still unlocked.
    try {
      await Supabase.instance.client.from('delivery_orders').update({
        'collect_amount': _collectEnabled ? _collectAmount : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
    } catch (_) {}
    await _saveDelivery(); // posts lines + locks atomically via the DB function
    try { await _logAudit(_detail['id'] as String, 'DO', 'saved', 'Delivery Order saved'); } catch (_) {}
    // Reload so the collect-amount chip and lock state reflect what was saved.
    // (Invoice is NOT auto-created — use the explicit "Create Invoice" button.)
    await _loadDetail(_detail['id'] as String);
  }

  Future<void> _saveDelivery() async {
    if (_deliverQtyCtrl.isEmpty) { _showSnack('No items to save'); return; }
    final orgId = _orgId;
    final branchId = _detail['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;

    for (final entry in _deliverQtyCtrl.entries) {
      final soItemId = entry.key;
      final deliverQty = double.tryParse(entry.value.text.trim()) ?? 0;
      if (deliverQty <= 0) continue;
      final soItem = _soItems.firstWhere((i) => i['id'] == soItemId, orElse: () => {});
      if (soItem.isEmpty) continue;
      final ordered = (soItem['quantity'] as num?)?.toDouble() ?? 0;
      final alreadyDelivered = (soItem['qty_delivered'] as num?)?.toDouble() ?? 0;
      final pending = ordered - alreadyDelivered;
      if (deliverQty > pending) { _showSnack('${soItem['products']?['name']}: qty exceeds pending (${_n4(pending)})'); return; }
      // Check stock
      final stock = await Supabase.instance.client.from('inventory_stock').select('quantity')
          .eq('org_id', orgId!).eq('product_id', soItem['product_id'] as String)
          .eq('branch_id', branchId).maybeSingle();
      final available = (stock?['quantity'] as num?)?.toDouble() ?? 0;
      if (deliverQty > available) { _showSnack('${soItem['products']?['name']}: insufficient stock (${_n4(available)} available)'); return; }
    }

    // Build the delivery lines from the validated controllers.
    final lines = <Map<String, dynamic>>[];
    for (final entry in _deliverQtyCtrl.entries) {
      final soItemId = entry.key;
      final deliverQty = double.tryParse(entry.value.text.trim()) ?? 0;
      if (deliverQty <= 0) continue;
      final soItem = _soItems.firstWhere((i) => i['id'] == soItemId, orElse: () => {});
      if (soItem.isEmpty) continue;
      final ordered = (soItem['quantity'] as num?)?.toDouble() ?? 0;
      final stock = await Supabase.instance.client.from('inventory_stock').select('quantity')
          .eq('org_id', orgId!).eq('product_id', soItem['product_id'] as String)
          .eq('branch_id', branchId).maybeSingle();
      lines.add({
        'so_item_id': soItemId,
        'product_id': soItem['product_id'],
        'uom_id': soItem['uom_id'],
        'qty_ordered': ordered,
        'qty_available': (stock?['quantity'] as num?)?.toDouble() ?? 0,
        'qty_delivered': deliverQty,
        'is_foc': soItem['is_foc'] == true,
      });
    }
    if (lines.isEmpty) { _showSnack('No items to save'); return; }
    try {
      // Atomic + idempotent: the DB function locks the DO (its claim guard),
      // inserts the lines, posts movements + stock, and updates SO progress and
      // status in ONE transaction. p_moved_at carries the voucher-date posting
      // (movedAtForVoucher) so the ledger date is preserved. Double-click errors cleanly.
      await Supabase.instance.client.rpc('save_delivery_order', params: {
        'p_do_id': _detail['id'],
        'p_user_id': userId,
        'p_lines': lines,
        'p_moved_at': movedAtForVoucher(_detail['voucher_date'] as String?),
      });
      _showSnack('Delivery saved — stock deducted');
      await _loadList();
      await _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _createInvoice({bool auto = false}) async {
    if (_items.isEmpty) { if (!auto) _showSnack('No items to invoice'); return; }
    // A DO may legitimately carry more than one invoice. But the auto path
    // (right after a DO save) must never silently create a second one — that
    // was the accidental-duplicate source. The manual button asks first.
    try {
      final existing = await Supabase.instance.client.from('sales_invoices')
          .select('voucher_number, is_voided').eq('do_id', _detail['id']);
      final live = (existing as List).where((s) => (s['is_voided'] as bool? ?? false) == false).toList();
      if (live.isNotEmpty) {
        if (auto) return; // first invoice already exists — don't auto-duplicate
        final nums = live.map((s) => s['voucher_number']).join(', ');
        final again = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('Invoice already exists'),
          content: Text('This delivery order already has: $nums.\n\nCreate another invoice for it?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create Another')),
          ],
        ));
        if (again != true) return;
      }
    } catch (_) {}
    final orgId = _orgId; final branchId = _detail['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    final year = DateTime.now().year;
    try {
      final voucherNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'SI', 'p_year': year});
      final siId = 'si_${DateTime.now().millisecondsSinceEpoch}';
      double subtotal = 0;
      final Map<String, double> priceMap = {};
      for (final item in _items) {
        final pid = item['product_id'] as String;
        final prod = await Supabase.instance.client.from('products').select('selling_price').eq('id', pid).single();
        priceMap[pid] = (prod['selling_price'] as num?)?.toDouble() ?? 0;
      }
      final siItems = _items.asMap().entries.map((e) {
        final i = e.key; final item = e.value;
        final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
        final isFoc = item['is_foc'] == true;
        final price = isFoc ? 0.0 : (priceMap[item['product_id'] as String] ?? 0);
        final lineTotal = isFoc ? 0.0 : qty * price;
        subtotal += lineTotal;
        return {'id': 'sii_${DateTime.now().millisecondsSinceEpoch}_$i', 'product_id': item['product_id'],
            'uom_id': item['uom_id'], 'qty_delivered': qty, 'unit_price': price, 'discount': 0.0, 'line_total': lineTotal,
            'is_foc': isFoc};
      }).toList();
      await Supabase.instance.client.from('sales_invoices').insert({
        'id': siId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': voucherNum, 'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'so_id': _detail['so_id'], 'do_id': _detail['id'], 'customer_id': _detail['customer_id'],
        'subtotal': subtotal, 'discount_total': 0, 'grand_total': subtotal,
        'remarks': _detail['remarks'],
        'is_locked': false, 'created_by': userId,
      });
      for (int i = 0; i < siItems.length; i++) {
        await Supabase.instance.client.from('sales_invoice_items').insert({...siItems[i], 'invoice_id': siId});
      }
      // Update DO status based on SO fulfillment
      await Supabase.instance.client.from('delivery_orders').update({
        'status': 'invoiced',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'DO', 'invoiced', 'Invoice $voucherNum created');
      // Log creation on the SI itself
      try {
        await Supabase.instance.client.from('voucher_audit_log').insert({
          'org_id': orgId, 'voucher_type': 'SI', 'voucher_id': siId,
          'action': 'created', 'details': 'Created from DO ${_detail['voucher_number']}',
          'performed_by': userId,
        });
      } catch (_) {}
      _showSnack('Invoice $voucherNum created');
      await _loadList();
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('delivery_orders').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'DO', newLocked ? 'locked' : 'unlocked', null);
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  List<Map<String, dynamic>> get _filteredOrders => _orders.where((o) {
    final matchStatus = _statusFilter == 'all' || o['status'] == _statusFilter;
    final q = _search.toLowerCase();
    final matchSearch = q.isEmpty ||
        (o['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
        (o['sales_orders']?['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
        (o['customers']?['shop_name'] as String? ?? '').toLowerCase().contains(q);
    return matchStatus && matchSearch;
  }).toList();

  Color _statusColor(String s) {
    if (s == 'invoiced') return AppTheme.success;
    if (s == 'cancelled') return AppTheme.danger;
    return Colors.blue;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<String, dynamic>?>(selectedBranchProvider, (prev, next) {
      if (prev?['id'] != next?['id']) {
        setState(() { _selectedId = null; _detail = {}; _items = []; _soItems = []; _linkedSo = {}; _listLoading = true; });
        _loadList();
      }
    });
    return CollapsibleListPane(
        listChild: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(children: [
                  const Text('Delivery Orders', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 24), onPressed: _createNew, tooltip: 'New DO'),
                ]),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(hintText: 'Search DO/SO/customer...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: DropdownButtonFormField<String>(
                  value: _statusFilter,
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'saved', child: Text('Saved', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'partially_delivered', child: Text('Partial', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'invoiced', child: Text('Invoiced', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(value: 'cancelled', child: Text('Cancelled', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
                )),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _listLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredOrders.isEmpty
                      ? const Center(child: Text('No DOs', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          itemCount: _filteredOrders.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final o = _filteredOrders[i];
                            final isSelected = o['id'] == _selectedId;
                            final status = o['status'] as String? ?? 'saved';
                            return InkWell(
                              onTap: () => _loadDetail(o['id'] as String),
                              child: Container(
                                color: isSelected ? AppTheme.primary.withOpacity(0.06) : null,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(o['voucher_number'] as String? ?? '-',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: isSelected ? AppTheme.primary : Colors.black87)),
                                    const Spacer(),
                                    if (o['is_voided'] == true)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                        child: const Text('Voided', style: TextStyle(color: AppTheme.danger, fontSize: 10, fontWeight: FontWeight.w700)),
                                      )
                                    else
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(color: _statusColor(status).withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                        child: Text(status, style: TextStyle(color: _statusColor(status), fontSize: 10, fontWeight: FontWeight.w600)),
                                      ),
                                  ]),
                                  Text('SO: ${o['sales_orders']?['voucher_number'] ?? '-'}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                  Text(o['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                ]),
                              ),
                            );
                          }),
            ),
          ]),
        detailChild: _selectedId == null
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.local_shipping_outlined, size: 48, color: AppTheme.border),
                const SizedBox(height: 12),
                const Text('Select a Delivery Order or create new', style: TextStyle(color: AppTheme.textSecondary)),
                const SizedBox(height: 16),
                ElevatedButton.icon(onPressed: _createNew, icon: const Icon(Icons.add, size: 16), label: const Text('New Delivery Order')),
              ]))
            : _detailLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    final status = _detail['status'] as String? ?? 'saved';
    final isInvoiced = status == 'invoiced';
    final isVoided = _detail['is_voided'] == true;
    final pendingSoItems = _soItems.where((i) {
      final ordered = (i['quantity'] as num?)?.toDouble() ?? 0;
      final delivered = (i['qty_delivered'] as num?)?.toDouble() ?? 0;
      final existingSoItemIds = _items.map((di) => di['so_item_id'] as String).toSet();
      return !existingSoItemIds.contains(i['id'] as String) && delivered < ordered;
    }).toList();

    return Column(children: [
      // AppBar
      Container(
        padding: EdgeInsets.symmetric(horizontal: MediaQuery.of(context).size.width < 700 ? 14 : 24, vertical: 12),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Builder(builder: (context) {
          final mobile = MediaQuery.of(context).size.width < 700;
          final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Text('Delivery Order', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]);
          final statusChildren = <Widget>[
            if (_deliveryFlow) ...[
              _StatusChip(status: status == 'invoiced' ? 'Invoiced' : 'Invoice Pending', color: status == 'invoiced' ? AppTheme.success : Colors.orange),
              if (_detail['delivered_at'] != null) const _StatusChip(status: 'Delivered', color: AppTheme.success),
            ] else
              _StatusChip(status: status, color: status == 'invoiced' ? AppTheme.success : Colors.blue),
            if (_isLocked) const _LockedBadge(),
            if ((_detail['collect_amount'] as num?) != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: AppTheme.success.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                child: Text('Collect: Rs. ${(_detail['collect_amount'] as num).toStringAsFixed(0)}',
                    style: const TextStyle(color: AppTheme.success, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            if (isVoided)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                child: const Text('Voided', style: TextStyle(color: AppTheme.danger, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
          ];
          final actionChildren = <Widget>[
            if (!isVoided && !_isLocked && _isSaved && pendingSoItems.isNotEmpty) ...[
              _collectToggle(),
              ElevatedButton(onPressed: _saveDeliveryOrder, child: const Text('Approve Delivery Order')),
            ],
            if (!isVoided && !isInvoiced && _items.isNotEmpty)
              ElevatedButton(
                onPressed: _createInvoice,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
                child: const Text('Create Invoice'),
              ),
            if (_canEditDate)
              IconButton(icon: const Icon(Icons.edit_calendar_outlined, color: AppTheme.textSecondary), tooltip: 'Edit date', onPressed: _pickDate),
            if (!isVoided && !isInvoiced)
              IconButton(icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
                  tooltip: _isLocked ? 'Unlock' : 'Lock', onPressed: _toggleLock),
            if (_linkedSiId != null)
              IconButton(icon: const Icon(Icons.receipt_long_outlined, color: AppTheme.primary), tooltip: 'Go to Sales Invoice',
                  onPressed: () => context.go('/erp/sales-invoices?focus=$_linkedSiId')),
            if (_deliveryFlow && !isVoided && _detail['delivered_at'] == null)
              IconButton(icon: const Icon(Icons.check_circle_outline, color: AppTheme.success), tooltip: 'Mark Delivered (self-pickup / manual)', onPressed: _markDelivered),
            IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), tooltip: 'Print / PDF', onPressed: _printDO),
            if (_canDelete && !isVoided)
              IconButton(icon: const Icon(Icons.block, color: AppTheme.danger), tooltip: 'Void', onPressed: _deleteDO),
          ];
          if (mobile) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              titleBlock,
              if (statusChildren.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: statusChildren),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actionChildren),
            ]);
          }
          return Row(children: [
            titleBlock,
            const SizedBox(width: 12),
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: statusChildren),
            const Spacer(),
            Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actionChildren),
          ]);
        }),
      ),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Linked SO info
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.04),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.primary.withOpacity(0.2)),
              ),
              child: Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.link, size: 16, color: AppTheme.primary),
                  const SizedBox(width: 8),
                  const Text('Sales Order: ', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                  Text(_linkedSo['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary)),
                ]),
                Text(_linkedSo['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                if (_linkedSo['voucher_date'] != null)
                  Text(DateFormat('d MMM yyyy').format(DateTime.parse(_linkedSo['voucher_date'] as String)),
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                _StatusChip(
                  status: (_linkedSo['status'] as String? ?? '').replaceAll('_', ' '),
                  color: _statusColor(_linkedSo['status'] as String? ?? ''),
                ),
              ]),
            ),

            const SizedBox(height: 12),

            // DO header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Row(children: [
                Expanded(child: _InfoRow(label: 'DO No.', value: _detail['voucher_number'] as String? ?? '-')),
                const SizedBox(width: 16),
                Expanded(child: _InfoRow(label: 'Date', value: _detail['voucher_date'] != null
                    ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-')),
                const SizedBox(width: 16),
                Expanded(child: _InfoRow(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-')),
              ]),
            ),

            const SizedBox(height: 16),

            // Delivered items
            if (_items.isNotEmpty) ...[
              const Text('Delivered Items', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('SO Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Available', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Delivered', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    ]),
                  ),
                  const Divider(height: 1),
                  ..._items.map((item) => Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          if (item['products']?['sku'] != null) Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ])),
                        Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                        Expanded(flex: 2, child: Text(item['qty_ordered'] != null ? _n4(item['qty_ordered'] as num) : '-', style: const TextStyle(fontWeight: FontWeight.w600))),
                        Expanded(flex: 2, child: Text(item['qty_available'] != null ? _n4(item['qty_available'] as num) : '-',
                            style: TextStyle(color: ((item['qty_available'] as num?)?.toDouble() ?? 0) > 0 ? AppTheme.success : AppTheme.danger, fontWeight: FontWeight.w600))),
                        Expanded(flex: 2, child: Text(item['qty_delivered'] != null ? _n4(item['qty_delivered'] as num) : '-',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                      ]),
                    ),
                    const Divider(height: 1),
                  ])),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(color: AppTheme.background),
                    child: Row(children: [
                      const Expanded(flex: 9, child: Text('Total Delivered', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                      Expanded(flex: 2, child: Builder(builder: (_) {
                        final t = _items.fold<double>(0, (s, it) => s + ((it['qty_delivered'] as num?)?.toDouble() ?? 0));
                        return Text(_n4(t),
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: AppTheme.primary));
                      })),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            // Pending SO items for delivery entry
            if (!_isLocked && _isSaved && pendingSoItems.isNotEmpty) ...[
              Row(children: [
                const Text('Add Delivery from SO', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                  child: Text('${pendingSoItems.length} pending', style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.withOpacity(0.3))),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.05), borderRadius: const BorderRadius.vertical(top: Radius.circular(8))),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Pending', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Available', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Deliver Qty *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.primary))),
                    ]),
                  ),
                  const Divider(height: 1),
                  ...pendingSoItems.map((item) {
                    final ordered = (item['quantity'] as num?)?.toDouble() ?? 0;
                    final delivered = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
                    final pending = ordered - delivered;
                    final available = _stockByProduct[item['product_id'] as String] ?? 0;
                    final ctrl = _deliverQtyCtrl[item['id'] as String];
                    return Column(children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(children: [
                          Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            if (item['products']?['sku'] != null) Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                          ])),
                          Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                          Expanded(flex: 2, child: Text(_n4(pending), style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w600))),
                          Expanded(flex: 2, child: Text(_n4(available),
                              style: TextStyle(color: available >= pending ? AppTheme.success : AppTheme.danger, fontWeight: FontWeight.w600))),
                          Expanded(flex: 2, child: ctrl != null ? SizedBox(height: 32, child: TextField(
                            controller: ctrl,
                            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            onChanged: (_) => setState(() {}),
                          )) : const SizedBox.shrink()),
                        ]),
                      ),
                      const Divider(height: 1),
                    ]);
                  }),
                  // Realtime total of quantities being entered
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.06)),
                    child: Row(children: [
                      const Expanded(flex: 9, child: Text('Total to Deliver', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                      Expanded(flex: 2, child: Builder(builder: (_) {
                        double t = 0;
                        for (final it in pendingSoItems) {
                          t += double.tryParse(_deliverQtyCtrl[it['id'] as String]?.text ?? '') ?? 0;
                        }
                        return Text(_n4(t),
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: AppTheme.primary));
                      })),
                    ]),
                  ),
                ]),
              ),
            ],

            const SizedBox(height: 16),
            _VoucherInfoStrip(
              salesperson: _meta.salespersonName,
              salespersonDiagnostic: _meta.diagnostic,
              customerAddress: _linkedSo['customers']?['address'] as String?,
              customerContact: _linkedSo['customers']?['contact_person'] as String?,
              customerPhone: _linkedSo['customers']?['phone'] as String?,
              preparedBy: _meta.preparedBy,
              createdAt: _detail['created_at'] != null
                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal())
                  : null,
            ),
            const SizedBox(height: 16),
            _AuditTrailList(voucherId: _detail['id'] as String, voucherType: 'DO'),
          ]),
        ),
      ),
    ]);
  }
}

// ─── Sales Invoices (Master-Detail) ──────────────────────────────────────────

class ErpSalesInvoicesScreen extends ConsumerStatefulWidget {
  const ErpSalesInvoicesScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpSalesInvoicesScreen> createState() => _ErpSalesInvoicesScreenState();
}

class _ErpSalesInvoicesScreenState extends ConsumerState<ErpSalesInvoicesScreen> {
  List<Map<String, dynamic>> _invoices = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  bool _datesEditable = false;
  bool _reviewFlow = false; // org.doc_review_flow_si: support docs + admin review
  String _search = '';
  String _siStatusFilter = 'all'; // all | draft | under_review | rejected | posted | voided
  final Map<String, TextEditingController> _discountCtrl = {};
  final Map<String, TextEditingController> _priceCtrl = {};
  bool _priceEditable = false; // org.si_price_editable
  final TextEditingController _remarksCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadList();
    if (widget.focusId != null) _loadDetail(widget.focusId!);
  }

  @override
  void dispose() {
    for (final c in _discountCtrl.values) c.dispose();
    for (final c in _priceCtrl.values) c.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    try {
      var q = Supabase.instance.client.from('sales_invoices')
          .select('*, customers(shop_name), sales_orders(voucher_number), delivery_orders(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final res = await q.order('created_at', ascending: false);
      bool reviewFlow = _reviewFlow;
      try { final c = await Supabase.instance.client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.doc_review_flow_si').maybeSingle(); reviewFlow = (c?['value'] as String?) == 'true'; } catch (_) {}
      setState(() { _invoices = List<Map<String,dynamic>>.from(res); _reviewFlow = reviewFlow; _listLoading = false; });
    } catch (_) { setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final inv = await client.from('sales_invoices')
          .select('*, customers(shop_name, code, address, contact_person, phone), sales_orders(voucher_number, remarks, customer_id, customers(shop_name, code, address, contact_person, phone)), delivery_orders(voucher_number), branches(name)')
          .eq('id', id).single();
      final items = await client.from('sales_invoice_items')
          .select('*, products(name, sku), uoms(abbreviation)').eq('invoice_id', id);
      _discountCtrl.clear();
      _priceCtrl.clear();
      for (final item in items as List) {
        _discountCtrl[item['id'] as String] = TextEditingController(text: _plain4(item['discount'] as num?));
        _priceCtrl[item['id'] as String] = TextEditingController(text: _plain4(item['unit_price'] as num?));
      }
      // Resolve customer id (direct on SI or via SO)
      final custId = (inv['customer_id'] as String?) ?? (inv['sales_orders']?['customer_id'] as String?);
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: custId,
        createdById: inv['created_by'] as String?,
      );
      bool datesEd = false;
      try { final cc = await client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.voucher_dates_editable').maybeSingle(); datesEd = (cc?['value'] as String?) == 'true'; } catch (_) {}
      bool reviewFlow = _reviewFlow;
      try { final rc = await client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.doc_review_flow_si').maybeSingle(); reviewFlow = (rc?['value'] as String?) == 'true'; } catch (_) {}
      bool priceEditable = _priceEditable;
      try { final pc = await client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.si_price_editable').maybeSingle(); priceEditable = (pc?['value'] as String?) == 'true'; } catch (_) {}
      setState(() {
        _reviewFlow = reviewFlow;
        _priceEditable = priceEditable;
        _detail = Map<String,dynamic>.from(inv);
        _items = List<Map<String,dynamic>>.from(items);
        _meta = meta;
        final siRemarks = (inv['remarks'] as String?)?.trim() ?? '';
        final soRemarks = (inv['sales_orders']?['remarks'] as String?)?.trim() ?? '';
        _remarksCtrl.text = siRemarks.isNotEmpty ? siRemarks : soRemarks;
        _datesEditable = datesEd;
        _detailLoading = false;
      });
    } catch (_) { setState(() => _detailLoading = false); }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _pickDate() async {
    final cur = _detail['voucher_date'] != null ? DateTime.tryParse(_detail['voucher_date'] as String) : null;
    final picked = await showDatePicker(context: context, initialDate: cur ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked == null) return;
    final iso = DateFormat('yyyy-MM-dd').format(picked);
    try {
      await Supabase.instance.client.from('sales_invoices').update({'voucher_date': iso}).eq('id', _detail['id']);
      if (mounted) setState(() => _detail['voucher_date'] = iso);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  bool get _isLocked => _detail['is_locked'] as bool? ?? true;
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canEditDate => (_datesEditable || _isAdmin) && !_isLocked && !(_detail['is_voided'] as bool? ?? false);
  bool get _canDelete {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  String? get _reviewStatus => _detail['review_status'] as String?;
  bool get _isPendingReview => _reviewStatus == 'pending';
  bool get _isRejected => _reviewStatus == 'rejected';

  // Derives the list/badge status from booleans + review_status.
  String _siStatus(Map inv) {
    if (inv['is_voided'] == true) return 'voided';
    if (inv['is_locked'] == true) return 'posted';
    if (_reviewFlow) {
      final rs = inv['review_status'] as String?;
      if (rs == 'pending') return 'under_review';
      if (rs == 'rejected') return 'rejected';
    }
    return 'draft';
  }

  Future<void> _cancelSI() async {
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Cancel / Void Sales Invoice?'),
      content: Text('Void ${_detail['voucher_number']}? Its accounting entries will be reversed, stock movements undone, and the Delivery Order released for re-invoicing. An audit trail is kept; this cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Keep')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Void')),
      ],
    ));
    if (confirm != true) return;

    try {
      final vNum = _detail['voucher_number'] as String? ?? '';
      // 1) void the invoice -> DB trigger reverses GL and restores stock
      await Supabase.instance.client.from('sales_invoices').update({
        'is_voided': true,
        'voided_at': DateTime.now().toUtc().toIso8601String(),
        'voided_by': ref.read(currentUserProvider)?.id,
      }).eq('id', _detail['id']);

      // 2) release the DO so it can be invoiced again
      final doId = _detail['do_id'] as String?;
      if (doId != null) {
        await Supabase.instance.client.from('delivery_orders').update({
          'status': 'saved',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', doId);
      }

      await _logAudit(_detail['id'] as String, 'cancelled', 'Voucher $vNum voided -- GL & stock reversed, DO released');
      _showSnack('Voided -- accounting reversed, DO available again');
      await _loadList();
      _loadDetail(_detail['id'] as String);
    } catch (e) {
      _showSnack('Could not void: $e');
    }
  }

  Future<void> _saveRemarks() async {
    try {
      await Supabase.instance.client.from('sales_invoices').update({
        'remarks': _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
      }).eq('id', _detail['id']);
      _detail['remarks'] = _remarksCtrl.text.trim();
      if (mounted) _showSnack('Remarks saved');
    } catch (e) {
      if (mounted) _showSnack('Could not save remarks: $e');
    }
  }

  Future<void> _printSI() async {
    final user = ref.read(currentUserProvider);
    final lines = _items.where((it) => it['is_foc'] != true).map((it) {
      final qty = (it['qty_delivered'] as num?)?.toDouble() ?? 0;
      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
      final discPct = (double.tryParse(_discountCtrl[it['id'] as String]?.text ?? '0') ?? 0).clamp(0.0, 100.0);
      final lineTotal = (qty * price) * (1 - discPct / 100);
      return VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?,
        uom: it['uoms']?['abbreviation'] as String?,
        qty: qty,
        unitPrice: price,
        discountPct: discPct,
        lineTotal: lineTotal,
      );
    }).toList();
    final focLines = _items.where((it) => it['is_foc'] == true).map((it) => VoucherLine(
      product: it['products']?['name'] as String? ?? '-',
      sku: it['products']?['sku'] as String?,
      uom: it['uoms']?['abbreviation'] as String?,
      qty: (it['qty_delivered'] as num?)?.toDouble() ?? 0,
    )).toList();

    double subtotal = 0, discountTotal = 0;
    for (final l in lines) {
      subtotal += l.qty * (l.unitPrice ?? 0);
      discountTotal += l.qty * (l.unitPrice ?? 0) * ((l.discountPct ?? 0) / 100);
    }

    final date = _detail['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null;
    // Customer details may be direct on the invoice or nested via the SO.
    final cust = (_detail['customers'] as Map?) ?? (_detail['sales_orders']?['customers'] as Map?);
    final createdAt = _detail['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal()) : null;
    final soVoucher = _detail['sales_orders']?['voucher_number'] as String?;
    final doVoucher = _detail['delivery_orders']?['voucher_number'] as String?;
    final refs = <String, String>{};
    if (soVoucher != null) refs['SO #'] = soVoucher;
    if (doVoucher != null) refs['DO #'] = doVoucher;

    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Sales Invoice',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: cust?['shop_name'] as String? ?? 'Walk-in',
      customerAddress: cust?['address'] as String?,
      customerContact: cust?['contact_person'] as String?,
      customerPhone: cust?['phone'] as String?,
      salespersonName: _meta.salespersonName,
      remarks: _detail['remarks'] as String?,
      lines: lines,
      focLines: focLines.isEmpty ? null : focLines,
      subtotal: subtotal,
      discountTotal: discountTotal,
      grandTotal: subtotal - discountTotal,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.siFooter,
      relatedRefs: refs.isNotEmpty ? refs : null,
      watermark: (_detail['is_voided'] == true) ? 'VOIDED' : null,
      approvedBy: _detail['reviewed_by_name'] as String?,
      approvedAt: _detail['reviewed_at'] != null
          ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['reviewed_at'] as String).toLocal()) : null,
      approvedSignatureUrl: _detail['reviewer_signature_url'] as String?,
      stampUrl: _detail['review_stamp_url'] as String?,
    );
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('sales_invoices').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, newLocked ? 'locked' : 'unlocked', null);
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _logAudit(String voucherId, String action, String? details) async {
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': orgId, 'voucher_type': 'SI', 'voucher_id': voucherId,
        'action': action, 'details': details, 'performed_by': userId,
      });
    } catch (_) {}
  }

  // Persists each line's discount/line_total and returns (subtotal, discountTotal).
  // Effective unit price: the edited value when SI prices are editable
  // (org.si_price_editable) and the invoice is unlocked and the line isn't FOC;
  // otherwise the stored unit price.
  double _siPrice(Map<String, dynamic> item) {
    if (_priceEditable && !_isLocked && item['is_foc'] != true) {
      return double.tryParse(_priceCtrl[item['id'] as String]?.text ?? '') ??
          (item['unit_price'] as num?)?.toDouble() ?? 0;
    }
    return (item['unit_price'] as num?)?.toDouble() ?? 0;
  }

  Future<(double, double)> _writeItemDiscounts() async {
    double subtotal = 0, discountTotal = 0;
    for (final item in _items) {
      final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
      final price = _siPrice(item);
      final discPct = (double.tryParse(_discountCtrl[item['id'] as String]?.text ?? '0') ?? 0).clamp(0.0, 100.0);
      final discAmt = qty * price * discPct / 100;
      final lineTotal = (qty * price) - discAmt;
      subtotal += qty * price;
      discountTotal += discAmt;
      await Supabase.instance.client.from('sales_invoice_items').update({'unit_price': price, 'discount': discPct, 'line_total': lineTotal}).eq('id', item['id']);
    }
    return (subtotal, discountTotal);
  }

  // Direct save + lock (used when the review flow is OFF). Locking fires the
  // COGS/GL post trigger (si_cogs_autopost).
  Future<void> _saveDiscounts() async {
    try {
      final (subtotal, discountTotal) = await _writeItemDiscounts();
      await Supabase.instance.client.from('sales_invoices').update({
        'subtotal': subtotal, 'discount_total': discountTotal, 'grand_total': subtotal - discountTotal,
        'is_locked': true,
        'locked_by': ref.read(currentUserProvider)?.id,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'saved',
          'Discount: ${money(discountTotal)} · Total: ${money(subtotal - discountTotal)}');
      _showSnack('Saved & locked');
      await _loadList();
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // Review flow: save the invoice's numbers but do NOT lock (so nothing posts),
  // and park it as pending for an admin to review.
  Future<void> _sendForReview() async {
    try {
      final (subtotal, discountTotal) = await _writeItemDiscounts();
      await Supabase.instance.client.from('sales_invoices').update({
        'subtotal': subtotal, 'discount_total': discountTotal, 'grand_total': subtotal - discountTotal,
        'review_status': 'pending',
        'remarks': _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      setState(() => _detail['review_status'] = 'pending');
      await _logAudit(_detail['id'] as String, 'sent_for_review', 'Sales Invoice sent for admin review');
      _showSnack('Sent for review — an admin will approve and post it');
      await _loadList();
      _loadDetail(_detail['id'] as String);
      ref.invalidate(siReviewPendingProvider);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // Review flow: admin approves a pending invoice, which locks (posts) it and
  // records the reviewer + snapshots their signature and the org stamp.
  Future<void> _approveAndPost() async {
    if (!_isAdmin) { _showSnack('Only admins can approve'); return; }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Approve & post invoice?'),
      content: const Text('This posts the invoice (locks it and books COGS to the ledger) and records you as the reviewer. This cannot be undone by non-admins.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Approve & Post'))],
    ));
    if (ok != true) return;
    try {
      final userId = ref.read(currentUserProvider)?.id;
      final now = DateTime.now().toUtc().toIso8601String();
      final (subtotal, discountTotal) = await _writeItemDiscounts();
      final upd = <String, dynamic>{
        'subtotal': subtotal, 'discount_total': discountTotal, 'grand_total': subtotal - discountTotal,
        'is_locked': true, 'locked_by': userId, 'locked_at': now,
        'review_status': 'approved', 'reviewed_by': userId,
        'reviewed_by_name': ref.read(currentUserProvider)?.name, 'reviewed_at': now,
      };
      final c = Supabase.instance.client;
      try { final u = await c.from('users').select('signature_url').eq('id', userId ?? '').maybeSingle();
        if (u?['signature_url'] != null) upd['reviewer_signature_url'] = u!['signature_url']; } catch (_) {}
      try { final s = await c.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.stamp_url').maybeSingle();
        if (s?['value'] != null) upd['review_stamp_url'] = s!['value']; } catch (_) {}
      await c.from('sales_invoices').update(upd).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'approved', 'Reviewed & posted');
      _showSnack('Approved & posted');
      await _loadList();
      _loadDetail(_detail['id'] as String);
      ref.invalidate(siReviewPendingProvider);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // Review flow: admin rejects a pending invoice back to the creator with a reason.
  Future<void> _reject() async {
    if (!_isAdmin) { _showSnack('Only admins can reject'); return; }
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Reject invoice?'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('The creator will see it as Rejected and can edit and resend it.', style: TextStyle(fontSize: 12.5)),
        const SizedBox(height: 10),
        TextField(controller: reasonCtrl, minLines: 2, maxLines: 4, autofocus: true,
          decoration: const InputDecoration(labelText: 'Reason (optional)', border: OutlineInputBorder())),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Reject')),
      ],
    ));
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('sales_invoices').update({
        'review_status': 'rejected',
        'review_reason': reason.isEmpty ? null : reason,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      setState(() { _detail['review_status'] = 'rejected'; _detail['review_reason'] = reason.isEmpty ? null : reason; });
      await _logAudit(_detail['id'] as String, 'rejected', reason.isEmpty ? 'Invoice rejected' : 'Rejected: $reason');
      _showSnack('Invoice rejected');
      await _loadList();
      _loadDetail(_detail['id'] as String);
      ref.invalidate(siReviewPendingProvider);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  int _siStatusCount(String st) {
    if (st == 'all') return _invoices.length;
    return _invoices.where((i) => _siStatus(i) == st).length;
  }

  Widget _siListBadge(Map inv) {
    final st = _siStatus(inv);
    late final Color color; late final IconData icon; late final String label;
    switch (st) {
      case 'voided':       color = AppTheme.danger;  icon = Icons.block;             label = 'Voided'; break;
      case 'posted':       color = AppTheme.success;  icon = Icons.check_circle;      label = 'Processed'; break;
      case 'under_review': color = Colors.blue;       icon = Icons.hourglass_top;     label = 'Under Review'; break;
      case 'rejected':     color = AppTheme.danger;   icon = Icons.cancel_outlined;   label = 'Rejected'; break;
      default:             color = Colors.orange;     icon = Icons.pending_outlined;  label = 'Pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _siFilterChip(String value, String label) {
    final active = _siStatusFilter == value;
    final count = _siStatusCount(value);
    return GestureDetector(
      onTap: () => setState(() => _siStatusFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? AppTheme.primary : AppTheme.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)),
          const SizedBox(width: 5),
          Text('$count', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: active ? Colors.white70 : AppTheme.textSecondary)),
        ]),
      ),
    );
  }

  List<Map<String, dynamic>> get _filteredInvoices => _invoices.where((i) {
    // Status filter (derived from is_voided / is_locked / review_status)
    if (_siStatusFilter != 'all' && _siStatus(i) != _siStatusFilter) return false;
    final q = _search.toLowerCase();
    return q.isEmpty ||
        (i['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
        (i['sales_orders']?['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
        (i['customers']?['shop_name'] as String? ?? '').toLowerCase().contains(q);
  }).toList();

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<String, dynamic>?>(selectedBranchProvider, (prev, next) {
      if (prev?['id'] != next?['id']) {
        setState(() { _selectedId = null; _detail = {}; _items = []; _listLoading = true; });
        _loadList();
      }
    });
    return CollapsibleListPane(
        listChild: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                const Align(alignment: Alignment.centerLeft, child: Text('Sales Invoices', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(hintText: 'Search SI/SO/customer...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 8),
                // Status filter chips
                SizedBox(
                  height: 30,
                  child: ListView(scrollDirection: Axis.horizontal, children: [
                    _siFilterChip('all', 'All'),
                    const SizedBox(width: 6),
                    _siFilterChip('draft', 'Draft'),
                    if (_reviewFlow) ...[
                      const SizedBox(width: 6),
                      _siFilterChip('under_review', 'Under Review'),
                      const SizedBox(width: 6),
                      _siFilterChip('rejected', 'Rejected'),
                    ],
                    const SizedBox(width: 6),
                    _siFilterChip('posted', 'Posted'),
                    const SizedBox(width: 6),
                    _siFilterChip('voided', 'Voided'),
                  ]),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _listLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredInvoices.isEmpty
                      ? const Center(child: Text('No invoices', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          itemCount: _filteredInvoices.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final inv = _filteredInvoices[i];
                            final isSelected = inv['id'] == _selectedId;
                            return InkWell(
                              onTap: () => _loadDetail(inv['id'] as String),
                              child: Container(
                                color: isSelected ? AppTheme.primary.withOpacity(0.06) : null,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(inv['voucher_number'] as String? ?? '-',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: isSelected ? AppTheme.primary : Colors.black87)),
                                    const Spacer(),
                                    _siListBadge(inv),
                                  ]),
                                  Text('SO: ${inv['sales_orders']?['voucher_number'] ?? '-'} · DO: ${inv['delivery_orders']?['voucher_number'] ?? '-'}',
                                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                  Text(inv['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                  Text('Total: ${_n4(inv['grand_total'] as num?)}',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                                ]),
                              ),
                            );
                          }),
            ),
          ]),
        detailChild: _selectedId == null
            ? const Center(child: Text('Select a Sales Invoice', style: TextStyle(color: AppTheme.textSecondary)))
            : _detailLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    double subtotal = 0, discountTotal = 0;
    for (final item in _items) {
      final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
      final price = _siPrice(item);
      final discPct = (double.tryParse(_discountCtrl[item['id'] as String]?.text ?? '0') ?? 0).clamp(0.0, 100.0);
      subtotal += qty * price;
      discountTotal += qty * price * discPct / 100;
    }
    final grandTotal = subtotal - discountTotal;

    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Text('Sales Invoice', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(width: 12),
          if (_isLocked) const _LockedBadge(),
          const Spacer(),
          if (!_isLocked && !(_detail['is_voided'] as bool? ?? false)) ...[
            if (!_reviewFlow) ...[
              ElevatedButton(onPressed: _saveDiscounts, child: const Text('Save')),
              const SizedBox(width: 8),
            ],
            if (_reviewFlow && !_isPendingReview) ...[
              ElevatedButton.icon(icon: const Icon(Icons.send_outlined, size: 16), label: const Text('Send for Review'), onPressed: _sendForReview),
              const SizedBox(width: 8),
            ],
            if (_reviewFlow && _isPendingReview && _isAdmin) ...[
              OutlinedButton.icon(icon: const Icon(Icons.cancel_outlined, size: 16), label: const Text('Reject'),
                  style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger, side: const BorderSide(color: AppTheme.danger)), onPressed: _reject),
              const SizedBox(width: 8),
              ElevatedButton.icon(icon: const Icon(Icons.verified_outlined, size: 16), label: const Text('Approve & Post'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success), onPressed: _approveAndPost),
              const SizedBox(width: 8),
            ],
            if (_reviewFlow && _isPendingReview && !_isAdmin) ...[
              Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.4))),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.hourglass_top, size: 12, color: Colors.orange), SizedBox(width: 4), Text('Pending review', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w600))])),
              const SizedBox(width: 8),
            ],
          ],
          if (_canEditDate)
            IconButton(
              icon: const Icon(Icons.edit_calendar_outlined, color: AppTheme.textSecondary),
              tooltip: 'Edit date',
              onPressed: _pickDate,
            ),
          // Hide the manual lock toggle while an unlocked invoice is under the
          // review flow — posting must go through Approve. Unlock stays available.
          if (_isLocked || !_reviewFlow)
            IconButton(
              icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
              tooltip: _isLocked ? 'Unlock' : 'Lock',
              onPressed: _toggleLock,
            ),
          IconButton(
            icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary),
            tooltip: 'Print / PDF',
            onPressed: _printSI,
          ),
          if (_canDelete && !(_detail['is_voided'] as bool? ?? false))
            TextButton.icon(
              icon: const Icon(Icons.block, size: 18, color: AppTheme.danger),
              label: const Text('Cancel / Void', style: TextStyle(color: AppTheme.danger)),
              onPressed: _cancelSI,
            ),
          if (_detail['is_voided'] as bool? ?? false)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
              child: const Text('Voided', style: TextStyle(color: AppTheme.danger, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
        ]),
      ),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Header info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Row(children: [
                  Expanded(child: _InfoRow(label: 'SI No.', value: _detail['voucher_number'] as String? ?? '-')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'Date', value: _detail['voucher_date'] != null
                      ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-')),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _InfoRow(label: 'Customer', value: _detail['customers']?['shop_name'] as String? ?? _detail['sales_orders']?['customers']?['shop_name'] as String? ?? 'Walk-in')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'SO #', value: _detail['sales_orders']?['voucher_number'] as String? ?? '-')),
                  const SizedBox(width: 16),
                  Expanded(child: _InfoRow(label: 'DO #', value: _detail['delivery_orders']?['voucher_number'] as String? ?? '-')),
                ]),
                const SizedBox(height: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('REMARKS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
                  const SizedBox(height: 4),
                  if (_isLocked)
                    Text((_detail['remarks'] as String?)?.trim().isNotEmpty == true ? _detail['remarks'] as String : '—',
                        style: const TextStyle(fontSize: 13))
                  else
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: TextField(
                        controller: _remarksCtrl,
                        minLines: 1, maxLines: 3,
                        decoration: const InputDecoration(
                          hintText: 'Remarks (carried from the order; editable)',
                          isDense: true, border: OutlineInputBorder(),
                        ),
                        style: const TextStyle(fontSize: 13),
                      )),
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: _saveRemarks, child: const Text('Save')),
                    ]),
                ]),
              ]),
            ),

            const SizedBox(height: 16),

            // Items
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                  child: const Row(children: [
                    Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Unit Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Discount %', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Disc. Price/Unit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text('Line Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
                  ]),
                ),
                const Divider(height: 1),
                ..._items.map((item) {
                  final qty = (item['qty_delivered'] as num?)?.toDouble() ?? 0;
                  final price = _siPrice(item);
                  final discPct = (double.tryParse(_discountCtrl[item['id'] as String]?.text ?? '0') ?? 0).clamp(0.0, 100.0);
                  final discAmt = qty * price * discPct / 100;
                  final lineTotal = (qty * price) - discAmt;
                  return Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Flexible(child: Text(item['products']?['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                            if (item['is_foc'] == true) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(color: Colors.teal.withOpacity(0.12), borderRadius: BorderRadius.circular(3)),
                                child: const Text('FOC', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.teal)),
                              ),
                            ],
                          ]),
                          if (item['products']?['sku'] != null) Text(item['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ])),
                        Expanded(flex: 1, child: Text(item['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                        Expanded(flex: 2, child: Text(_n4(qty), style: const TextStyle(fontWeight: FontWeight.w600))),
                        Expanded(flex: 2, child: item['is_foc'] == true
                            ? const Text('Free', style: TextStyle(color: Colors.teal, fontWeight: FontWeight.w600))
                            : (_priceEditable && !_isLocked)
                                ? SizedBox(height: 32, child: TextField(
                                    controller: _priceCtrl[item['id'] as String],
                                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    onChanged: (_) => setState(() {}),
                                  ))
                                : Text(_n4(price))),
                        Expanded(flex: 2, child: _isLocked
                            ? Text('${discPct.toStringAsFixed(2)} %', style: const TextStyle(color: AppTheme.textSecondary))
                            : SizedBox(height: 32, child: TextField(
                                controller: _discountCtrl[item['id'] as String],
                                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder(), suffixText: '%'),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                onChanged: (v) {
                                  final val = double.tryParse(v) ?? 0;
                                  if (val > 100) {
                                    final ctrl = _discountCtrl[item['id'] as String]!;
                                    ctrl.text = '100';
                                    ctrl.selection = TextSelection.fromPosition(const TextPosition(offset: 3));
                                  } else if (val < 0) {
                                    final ctrl = _discountCtrl[item['id'] as String]!;
                                    ctrl.text = '0';
                                    ctrl.selection = TextSelection.fromPosition(const TextPosition(offset: 1));
                                  }
                                  setState(() {});
                                },
                              ))),
                        Expanded(flex: 2, child: item['is_foc'] == true
                            ? const Text('Free', style: TextStyle(color: Colors.teal, fontWeight: FontWeight.w600))
                            : Text(_n4(price * (1 - discPct / 100)), style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary))),
                        Expanded(flex: 2, child: Text(_n4(lineTotal), style: const TextStyle(fontWeight: FontWeight.w700))),
                      ]),
                    ),
                    const Divider(height: 1),
                  ]);
                }),
                // Totals
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    _TotalsRow(label: 'Subtotal', value: _n4(subtotal)),
                    _TotalsRow(label: 'Discount', value: '- ${_n4(discountTotal)}', color: Colors.orange),
                    const Divider(),
                    _TotalsRow(label: 'Grand Total', value: _n4(grandTotal), bold: true),
                  ]),
                ),
              ]),
            ),

            const SizedBox(height: 16),
            _VoucherInfoStrip(
              salesperson: _meta.salespersonName,
              salespersonDiagnostic: _meta.diagnostic,
              customerAddress: ((_detail['customers'] as Map?) ?? (_detail['sales_orders']?['customers'] as Map?))?['address'] as String?,
              customerContact: ((_detail['customers'] as Map?) ?? (_detail['sales_orders']?['customers'] as Map?))?['contact_person'] as String?,
              customerPhone: ((_detail['customers'] as Map?) ?? (_detail['sales_orders']?['customers'] as Map?))?['phone'] as String?,
              preparedBy: _meta.preparedBy,
              createdAt: _detail['created_at'] != null
                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal())
                  : null,
            ),
            const SizedBox(height: 16),
            if (_reviewFlow) ...[
              if (_isPendingReview)
                Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: Colors.blue.withOpacity(0.06), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.blue.withOpacity(0.3))),
                  child: Row(children: [
                    const Icon(Icons.hourglass_top, size: 16, color: Colors.blue), const SizedBox(width: 8),
                    Expanded(child: Text(_isAdmin
                        ? 'Under review. Check the attached documents below, then Approve & Post — or Reject with a reason.'
                        : 'Sent for review. An admin will check the documents and post it.',
                        style: const TextStyle(fontSize: 12, color: Colors.blue))),
                  ])),
              if (_isRejected)
                Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.danger.withOpacity(0.3))),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.cancel_outlined, size: 16, color: AppTheme.danger), const SizedBox(width: 8),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Rejected — edit if needed and Send for Review again.', style: TextStyle(fontSize: 12, color: AppTheme.danger, fontWeight: FontWeight.w600)),
                      if ((_detail['review_reason'] as String?)?.isNotEmpty == true) ...[
                        const SizedBox(height: 2),
                        Text('Reason: ${_detail['review_reason']}', style: const TextStyle(fontSize: 11.5, color: AppTheme.danger)),
                      ],
                    ])),
                  ])),
              VoucherDocsPanel(
                voucherType: 'SI',
                voucherId: _detail['id'] as String,
                voucherNumber: _detail['voucher_number'] as String? ?? '',
                bucket: 'si-documents',
                orgId: _orgId ?? '',
                userId: ref.read(currentUserProvider)?.id,
                canWrite: !_isLocked,
              ),
              const SizedBox(height: 12),
              VoucherRemarksPanel(
                voucherType: 'SI',
                voucherId: _detail['id'] as String,
                orgId: _orgId ?? '',
                userId: ref.read(currentUserProvider)?.id,
                userName: ref.read(currentUserProvider)?.name,
              ),
              const SizedBox(height: 16),
            ],
            _AuditTrailList(voucherId: _detail['id'] as String, voucherType: 'SI'),
          ]),
        ),
      ),
    ]);
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

/// Compact info strip shown on every voucher detail page with salesperson,
/// customer contact details, and the user who prepared the voucher.
class _VoucherInfoStrip extends StatelessWidget {
  final String? salesperson;
  final String? salespersonDiagnostic;
  final String? customerAddress;
  final String? customerContact;
  final String? customerPhone;
  final String? preparedBy;
  final String? createdAt;

  const _VoucherInfoStrip({
    this.salesperson,
    this.salespersonDiagnostic,
    this.customerAddress,
    this.customerContact,
    this.customerPhone,
    this.preparedBy,
    this.createdAt,
  });

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];

    // Always render salesperson — visible failure mode beats invisible bug
    tiles.add(_tile(
      Icons.person_pin_outlined,
      'Salesperson',
      (salesperson != null && salesperson!.isNotEmpty)
          ? salesperson!
          : (salespersonDiagnostic ?? 'Not assigned'),
      muted: salesperson == null || salesperson!.isEmpty,
    ));

    final addrLine = customerAddress;
    if (addrLine != null && addrLine.trim().isNotEmpty) {
      tiles.add(_tile(Icons.location_on_outlined, 'Address', addrLine));
    }
    if (customerContact != null && customerContact!.isNotEmpty) {
      tiles.add(_tile(Icons.account_circle_outlined, 'Contact Person', customerContact!));
    }
    if (customerPhone != null && customerPhone!.isNotEmpty) {
      tiles.add(_tile(Icons.phone_outlined, 'Phone', customerPhone!));
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.background,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 24, runSpacing: 8, children: tiles),
        if (preparedBy != null && preparedBy!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.draw_outlined, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              'Prepared by: ${preparedBy!}${createdAt != null ? "  ·  $createdAt" : ""}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontStyle: FontStyle.italic),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _tile(IconData icon, String label, String value, {bool muted = false}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 6),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, letterSpacing: 0.5)),
          Text(value,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                fontStyle: muted ? FontStyle.italic : FontStyle.normal,
                color: muted ? AppTheme.textSecondary : null,
              )),
        ]),
      ]),
    );
  }
}

class _CustomerSelect extends StatelessWidget {
  final List<Map<String, dynamic>> customers;
  final String? selectedId;
  final ValueChanged<String?> onChanged;
  final Future<void> Function()? ensureLoaded;
  final List<Map<String, dynamic>> Function()? liveCustomers;
  const _CustomerSelect({required this.customers, required this.selectedId, required this.onChanged, this.ensureLoaded, this.liveCustomers});

  String _displayName() {
    if (selectedId == null) return 'Walk-in';
    final c = customers.firstWhere((c) => c['id'] == selectedId, orElse: () => {});
    if (c.isEmpty) return 'Walk-in';
    return '${c['shop_name']} (${c['code']})';
  }

  Future<void> _showPicker(BuildContext context) async {
    // Wait for customers if they're still loading, then read the fresh list.
    if ((liveCustomers?.call() ?? customers).isEmpty && ensureLoaded != null) {
      await ensureLoaded!();
    }
    final list = liveCustomers?.call() ?? customers;
    String search = '';
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final filtered = list.where((c) =>
            search.isEmpty ||
            (c['shop_name'] as String? ?? '').toLowerCase().contains(search.toLowerCase()) ||
            (c['code'] as String? ?? '').toLowerCase().contains(search.toLowerCase())
          ).toList();
          return AlertDialog(
            title: Text('Select Customer  ·  ${list.length} total'),
            contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            content: SizedBox(
              width: 480,
              height: 460,
              child: Column(children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search by name or code...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                  onChanged: (v) => setS(() => search = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(children: [
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.person_off_outlined, size: 18, color: AppTheme.textSecondary),
                      title: const Text('Walk-in', style: TextStyle(fontStyle: FontStyle.italic, color: AppTheme.textSecondary)),
                      selected: selectedId == null,
                      onTap: () => Navigator.of(ctx, rootNavigator: true).pop('__WALKIN__'),
                    ),
                    const Divider(height: 1),
                    if (filtered.isEmpty)
                      const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No customers match', style: TextStyle(color: AppTheme.textSecondary))))
                    else
                      ...filtered.map((c) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.store_outlined, size: 18, color: AppTheme.primary),
                        title: Text(c['shop_name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(c['code'] as String? ?? '', style: const TextStyle(fontSize: 11)),
                        selected: c['id'] == selectedId,
                        onTap: () => Navigator.of(ctx, rootNavigator: true).pop(c['id'] as String),
                      )),
                  ]),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ],
          );
        },
      ),
    );
    if (result != null) onChanged(result == '__WALKIN__' ? null : result);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _showPicker(context),
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Customer',
          isDense: true,
          suffixIcon: Icon(Icons.search, size: 18, color: AppTheme.textSecondary),
        ),
        child: Text(_displayName(), style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}

class _AuditTrailList extends StatelessWidget {
  final String voucherId;
  final String voucherType;
  const _AuditTrailList({required this.voucherId, required this.voucherType});

  Future<List<Map<String, dynamic>>> _load() async {
    try {
      final res = await Supabase.instance.client.from('voucher_audit_log')
          .select('*')
          .eq('voucher_id', voucherId)
          .eq('voucher_type', voucherType)
          .order('performed_at', ascending: true);
      // Resolve names
      final events = List<Map<String, dynamic>>.from(res);
      final userIds = events.map((e) => e['performed_by'] as String?).where((id) => id != null).toSet().toList();
      final users = userIds.isEmpty ? <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(
        await Supabase.instance.client.from('users').select('id, name').inFilter('id', userIds.cast<Object>()),
      );
      final nameById = {for (final u in users) u['id'] as String: u['name'] as String? ?? '-'};
      for (final e in events) {
        e['_userName'] = nameById[e['performed_by'] as String?] ?? '-';
      }
      return events;
    } catch (_) { return []; }
  }

  Color _actionColor(String action) {
    switch (action) {
      case 'created': return AppTheme.primary;
      case 'saved': return AppTheme.primary;
      case 'confirmed': return Colors.blue;
      case 'invoiced': return AppTheme.success;
      case 'locked': return Colors.orange;
      case 'unlocked': return AppTheme.textSecondary;
      case 'cancelled': return AppTheme.danger;
      default: return AppTheme.textSecondary;
    }
  }

  IconData _actionIcon(String action) {
    switch (action) {
      case 'created': return Icons.add_circle_outline;
      case 'saved': return Icons.save_outlined;
      case 'confirmed': return Icons.check_circle_outline;
      case 'invoiced': return Icons.receipt_long_outlined;
      case 'locked': return Icons.lock_outline;
      case 'unlocked': return Icons.lock_open_outlined;
      case 'cancelled': return Icons.cancel_outlined;
      default: return Icons.circle_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _load(),
      builder: (_, snap) {
        final events = snap.data ?? [];
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(height: 60, child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))));
        }
        if (events.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.history, size: 14, color: AppTheme.textSecondary),
              SizedBox(width: 6),
              Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary)),
            ]),
            const SizedBox(height: 8),
            ...events.map((e) {
              final action = e['action'] as String? ?? '-';
              final user = e['_userName'] as String? ?? '-';
              final at = e['performed_at'] as String?;
              final dt = at != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(at).toLocal()) : '-';
              final details = e['details'] as String?;
              final color = _actionColor(action);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(_actionIcon(action), size: 14, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(action[0].toUpperCase() + action.substring(1),
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
                        const SizedBox(width: 6),
                        Flexible(child: Text('by $user',
                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                      ]),
                      if (details != null && details.isNotEmpty)
                        Text(details, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  Text(dt, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ]),
              );
            }),
          ]),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  final Color color;
  const _StatusChip({required this.status, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
    child: Text(status, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
  );
}

class _LockedBadge extends StatelessWidget {
  const _LockedBadge();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.lock_outline, size: 12, color: Colors.orange),
      SizedBox(width: 4),
      Text('Locked', style: TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w500)),
    const SizedBox(height: 2),
    Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
  ]);
}

class _TotalsRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? color;
  const _TotalsRow({required this.label, required this.value, this.bold = false, this.color});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label: ', style: TextStyle(fontSize: bold ? 14 : 12, color: AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      Text(value, style: TextStyle(fontSize: bold ? 15 : 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color)),
    ]),
  );
}

/// A single credit/aging warning line shown in the DO creation alert.
class _CreditIssue {
  final String title;
  final String detail;
  const _CreditIssue(this.title, this.detail);
}
