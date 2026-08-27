import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/search/text_search.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/layout/collapsible_list_pane.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';
import '../../../core/utils/friendly_error.dart';

/// Purchase Return Invoices (PRI) — stage 2 of the purchase return flow.
///
/// Flow: PRN (moves stock OUT on save) → PRI (user sets prices → Issue → posts GL).
/// Status: draft → issued.
/// Stock is NOT moved here — that happens at the PRN stage. Issuing posts the
/// invoice to the ledger (via the pri_autopost trigger).
class ErpPurchaseReturnVouchersScreen extends ConsumerStatefulWidget {
  const ErpPurchaseReturnVouchersScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpPurchaseReturnVouchersScreen> createState() => _ErpPurchaseReturnVouchersScreenState();
}

class _ErpPurchaseReturnVouchersScreenState extends ConsumerState<ErpPurchaseReturnVouchersScreen> {
  List<Map<String, dynamic>> _invoices = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  Map<String, TextEditingController> _priceCtrl = {};
  Map<String, TextEditingController> _discCtrl = {};
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  String _search = '';
  String _filter = 'all';
  // Org setting (Admin Settings → "PRI price editable"). When false (default),
  // the return price is frozen to each product's Cost Price and adjusted only
  // via Discount; when true, the price field is freely editable.
  bool _priceEditable = false;

  @override
  void initState() { super.initState(); _loadPriceSetting(); _loadList(); if (widget.focusId != null) _loadDetail(widget.focusId!); }

  Future<void> _loadPriceSetting() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final row = await Supabase.instance.client.from('app_config')
          .select('value').eq('key', 'org.pri_price_editable').eq('org_id', orgId).maybeSingle();
      if (mounted) setState(() => _priceEditable = (row?['value'] as String?) == 'true');
    } catch (_) {}
  }

  // Product cost price for a return line (used when the price is frozen).
  double _costOf(Map<String, dynamic> it) =>
      (it['products']?['cost_price'] as num?)?.toDouble() ?? 0;

  // Whether the price field is actually editable: governed solely by the org
  // toggle (org.pri_price_editable). When OFF, the price is frozen for everyone
  // — including admin-tier users — and can only be adjusted via Discount.
  bool get _priceFieldEditable => _priceEditable;

  // Effective unit price: the product's cost price when frozen, otherwise the
  // edited/stored unit price.
  double _effPrice(Map<String, dynamic> it) =>
      _priceFieldEditable ? ((it['unit_price'] as num?)?.toDouble() ?? 0) : _costOf(it);

  @override
  void dispose() {
    for (final c in _priceCtrl.values) c.dispose();
    for (final c in _discCtrl.values) c.dispose();
    super.dispose();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isDraft  => (_detail['status'] as String? ?? 'draft') == 'draft';
  bool get _canDelete {
    final role = ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ── Controllers for editable prices ────────────────────────────────────────
  void _initControllers() {
    for (final c in _priceCtrl.values) c.dispose();
    for (final c in _discCtrl.values) c.dispose();
    _priceCtrl = {};
    _discCtrl = {};
    for (final it in _items) {
      final id = it['id'] as String;
      // Frozen mode shows the product cost price (read-only); editable mode
      // shows the stored unit price.
      final priceVal = _priceFieldEditable ? ((it['unit_price'] as num?)?.toDouble() ?? 0) : _costOf(it);
      final price = priceVal.toStringAsFixed(2);
      final disc  = (it['discount']   as num?)?.toStringAsFixed(2) ?? '0.00';
      _priceCtrl[id] = TextEditingController(text: price);
      _discCtrl[id]  = TextEditingController(text: disc);
    }
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('purchase_return_invoices')
          .select('id, voucher_number, voucher_date, grand_total, status, supplier_id, prn_id, suppliers(name), purchase_returns(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final r = await q
          .order('voucher_date', ascending: false)
          .order('voucher_number', ascending: false)
          .limit(2000);
      setState(() { _invoices = List<Map<String, dynamic>>.from(r); _listLoading = false; });
    } catch (e) {
      print('[PRI] loadList: $e');
      _showSnack('Failed to load list: $e');
      setState(() => _listLoading = false);
    }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final inv = await client.from('purchase_return_invoices')
          .select('*, suppliers(*), branches(name), purchase_returns(voucher_number)')
          .eq('id', id).single();
      final items = await client.from('purchase_return_invoice_items')
          .select('*, products(name, sku, cost_price), uoms(abbreviation)')
          .eq('voucher_id', id);
      final meta = await VoucherMeta.fetch(
        orgId: _orgId ?? '',
        customerId: null,
        createdById: inv['created_by'] as String?,
      );
      setState(() {
        _detail = Map<String, dynamic>.from(inv);
        _items = List<Map<String, dynamic>>.from(items);
        _meta = meta;
        _detailLoading = false;
        _initControllers();
      });
    } catch (e) {
      print('[PRI] loadDetail: $e');
      _showSnack('Failed to load: $e');
      setState(() => _detailLoading = false);
    }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': _orgId,
        'voucher_id': id, 'voucher_type': 'PRI',
        'action': action, 'details': details,
        'performed_by': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  // ── Create from a saved PRN ────────────────────────────────────────────────
  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    try {
      final prns = await Supabase.instance.client.from('purchase_returns')
          .select('id, voucher_number, voucher_date, supplier_id, suppliers(name)')
          .eq('org_id', orgId).eq('branch_id', branchId).eq('status', 'saved')
          .order('voucher_date', ascending: false);
      if ((prns as List).isEmpty) {
        _showSnack('No saved PRNs available — save a PRN first');
        return;
      }
      final picked = await showDialog<Map<String, dynamic>?>(context: context,
          builder: (_) => _PrnPickerDialog(prns: List<Map<String, dynamic>>.from(prns)));
      if (picked == null) return;
      await _generateFromPrn(picked);
    } catch (e) { _showSnack(friendlyError('That did not save', e)); }
  }

  Future<void> _generateFromPrn(Map<String, dynamic> prn) async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) return;
    final prnId = prn['id'] as String;
    // Check not already invoiced
    final exists = await Supabase.instance.client.from('purchase_return_invoices')
        .select('id, voucher_number').eq('prn_id', prnId);
    if ((exists as List).isNotEmpty) {
      _showSnack('Invoice ${exists.first['voucher_number']} already exists for this PRN');
      return;
    }
    setState(() => _detailLoading = true);
    final userId = ref.read(currentUserProvider)?.id;
    try {
      final srnItems = await Supabase.instance.client.from('purchase_return_items')
          .select('*').eq('return_id', prnId);
      if ((srnItems as List).isEmpty) {
        setState(() => _detailLoading = false);
        _showSnack('PRN has no items'); return;
      }
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number',
          params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'PRI', 'p_year': year});
      final voucherNum = 'PRI-$year-${nextNum.toString().padLeft(4, '0')}';
      final invId = 'prv_${DateTime.now().millisecondsSinceEpoch}';

      await Supabase.instance.client.from('purchase_return_invoices').insert({
        'id': invId,
        'org_id': orgId,
        'branch_id': branchId,
        'voucher_number': voucherNum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'prn_id': prnId,
        'supplier_id': prn['supplier_id'],
        'subtotal': 0, 'discount_total': 0, 'grand_total': 0,
        'status': 'draft',
        'is_locked': false,
        'created_by': userId,
      });

      // Prefill price from each product's cost_price (still editable before Issue).
      final pids = <String>{ for (final si in srnItems) si['product_id'] as String };
      final Map<String, double> costMap = {};
      if (pids.isNotEmpty) {
        final prods = await Supabase.instance.client.from('products').select('id,cost_price').inFilter('id', pids.toList());
        for (final p in (prods as List)) { costMap[p['id'] as String] = (p['cost_price'] as num?)?.toDouble() ?? 0; }
      }
      double seedSubtotal = 0;
      for (final si in srnItems) {
        final pid = si['product_id'] as String;
        final qty = (si['quantity'] as num?)?.toDouble() ?? 0;
        final price = costMap[pid] ?? 0;
        final lt = qty * price;
        seedSubtotal += lt;
        await Supabase.instance.client.from('purchase_return_invoice_items').insert({
          'id': 'prvi_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'voucher_id': invId,
          'prn_item_id': si['id'],
          'product_id': pid,
          'uom_id': si['uom_id'],
          'quantity': si['quantity'],
          'unit_price': price,
          'discount': 0,
          'line_total': lt,
        });
      }
      if (seedSubtotal > 0) {
        await Supabase.instance.client.from('purchase_return_invoices').update({
          'subtotal': seedSubtotal, 'discount_total': 0, 'grand_total': seedSubtotal,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', invId);
      }

      await _logAudit(invId, 'created', 'Draft PRI from PRN ${prn['voucher_number']}');
      _showSnack('$voucherNum created — set prices below, then issue to post to the ledger');
      await _loadList();
      _loadDetail(invId);
    } catch (e) {
      setState(() => _detailLoading = false);
      _showSnack(friendlyError('That did not save', e));
    }
  }

  // ── Save price/discount edit for one item ────────────────────────────────
  Future<void> _saveItemPrice(String itemId) async {
    final item  = _items.firstWhere((i) => i['id'] == itemId, orElse: () => {});
    // When price is frozen, persist the product's cost price regardless of any
    // controller text; value is adjusted only through discount.
    final price = _priceFieldEditable
        ? (double.tryParse(_priceCtrl[itemId]?.text ?? '') ?? 0)
        : _costOf(item);
    final disc  = (double.tryParse(_discCtrl[itemId]?.text ?? '') ?? 0).clamp(0.0, 100.0);
    final qty   = (item['quantity'] as num?)?.toDouble() ?? 0;
    final lt    = qty * price * (1 - disc / 100);
    try {
      await Supabase.instance.client.from('purchase_return_invoice_items').update({
        'unit_price': price, 'discount': disc, 'line_total': lt,
      }).eq('id', itemId);
      setState(() {
        final idx = _items.indexWhere((i) => i['id'] == itemId);
        if (idx >= 0) {
          _items[idx]['unit_price'] = price;
          _items[idx]['discount']   = disc;
          _items[idx]['line_total'] = lt;
        }
      });
      await _recalcTotals();
    } catch (e) { _showSnack('Failed to save price: $e'); }
  }

  Future<void> _recalcTotals() async {
    double subtotal = 0, discount = 0;
    for (final it in _items) {
      final qty   = (it['quantity']   as num?)?.toDouble() ?? 0;
      final price = _effPrice(it);
      final disc  = (it['discount']   as num?)?.toDouble() ?? 0;
      subtotal += qty * price;
      discount += qty * price * (disc / 100);
    }
    final grand = subtotal - discount;
    try {
      await Supabase.instance.client.from('purchase_return_invoices').update({
        'subtotal': subtotal, 'discount_total': discount, 'grand_total': grand,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      setState(() {
        _detail['subtotal'] = subtotal;
        _detail['discount_total'] = discount;
        _detail['grand_total'] = grand;
        final idx = _invoices.indexWhere((r) => r['id'] == _detail['id']);
        if (idx >= 0) _invoices[idx]['grand_total'] = grand;
      });
    } catch (_) {}
  }

  // ── Issue Invoice: moves stock + locks ────────────────────────────────────
  Future<void> _issueInvoice() async {
    if (_items.isEmpty) { _showSnack('No items to issue'); return; }
    // Save any unsaved prices first
    for (final it in _items) {
      await _saveItemPrice(it['id'] as String);
    }
    // Zero-value guard: every line must carry a price > 0. Value is reduced via
    // Discount, never by a zero price.
    final zero = _items.where((it) => ((it['unit_price'] as num?)?.toDouble() ?? 0) <= 0).toList();
    if (zero.isNotEmpty) {
      final names = zero.map((it) => (it['products']?['name'] as String?) ?? 'item').take(4).join(', ');
      _showSnack(_priceFieldEditable
          ? 'Cannot issue — price must be greater than 0 for: $names. Reduce value using Discount, not a zero price.'
          : 'Cannot issue — no Cost Price set on: $names. Set their cost price in the product profile first.');
      return;
    }
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Issue Purchase Return Invoice?'),
      content: const Text('This posts the return invoice to the ledger. Stock was already returned at the PRN stage. This action cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Issue')),
      ],
    ));
    if (confirm != true) return;

    final userId = ref.read(currentUserProvider)?.id;
    final invId = _detail['id'] as String;
    final prnId = _detail['prn_id'] as String?;

    try {
      // Post the invoice. The pri_autopost trigger posts the GL entries on this
      // update. Stock is intentionally NOT moved here — that happened at the PRN.
      await Supabase.instance.client.from('purchase_return_invoices').update({
        'status': 'issued',
        'is_locked': true,
        'locked_by': userId,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', invId);

      // Flip PRN to invoiced + lock
      if (prnId != null) {
        await Supabase.instance.client.from('purchase_returns').update({
          'status': 'invoiced', 'is_locked': true,
          'locked_by': userId, 'locked_at': DateTime.now().toUtc().toIso8601String(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', prnId);
      }

      await _logAudit(invId, 'issued', 'Invoice posted to ledger');
      _showSnack('Issued — posted to ledger');
      _loadDetail(invId);
      _loadList();
    } catch (e) { _showSnack(friendlyError('That did not save', e)); }
  }

  Future<void> _toggleLock() async {
    final newLocked = !_isLocked;
    try {
      await Supabase.instance.client.from('purchase_return_invoices').update({
        'is_locked': newLocked,
        'locked_by': newLocked ? ref.read(currentUserProvider)?.id : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, newLocked ? 'locked' : 'unlocked', null);
      _showSnack(newLocked ? 'Locked' : 'Unlocked');
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack(friendlyError('That did not save', e)); }
  }

  Future<void> _delete() async {
    if (!_canDelete) return;
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Purchase Return Invoice?'),
      content: Text('Delete ${_detail['voucher_number']}? The source PRN will be restored to saved (its stock stays returned).'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete')),
      ],
    ));
    if (confirm != true) return;

    try {
      // PRI no longer moves stock, so nothing to reverse here. Restore the source
      // PRN to 'saved' (still locked — its stock remains returned) so it can be re-invoiced.
      final prnId = _detail['prn_id'] as String?;
      if (prnId != null) {
        await Supabase.instance.client.from('purchase_returns').update({
          'status': 'saved', 'is_locked': true,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', prnId);
      }
      await _logAudit(_detail['id'] as String, 'deleted', 'Invoice deleted');
      await Supabase.instance.client.from('purchase_return_invoice_items').delete().eq('voucher_id', _detail['id']);
      await Supabase.instance.client.from('purchase_return_invoices').delete().eq('id', _detail['id']);
      _showSnack('Deleted — PRN restored');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      await _loadList();
    } catch (e) { _showSnack(friendlyError('That did not save', e)); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final lines = _items.map((it) {
      final qty   = (it['quantity']   as num?)?.toDouble() ?? 0;
      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
      final disc  = (it['discount']   as num?)?.toDouble() ?? 0;
      final lt    = (it['line_total'] as num?)?.toDouble() ?? qty * price * (1 - disc / 100);
      return VoucherLine(product: it['products']?['name'] as String? ?? '-',
          sku: it['products']?['sku'] as String?,
          uom: it['uoms']?['abbreviation'] as String?,
          qty: qty, unitPrice: price, discountPct: disc, lineTotal: lt);
    }).toList();
    final sup = _detail['suppliers'] as Map?;
    final prnVoucher = _detail['purchase_returns']?['voucher_number'] as String?;
    final date = _detail['voucher_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null;
    final createdAt = _detail['created_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal()) : null;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Purchase Return Invoice',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: date,
      customerOrSupplier: sup?['name'] as String? ?? 'Cash Supplier',
      customerAddress: sup?['address'] as String?,
      customerContact: sup?['contact_person'] as String?,
      customerPhone: (sup?['contact_number'] ?? sup?['phone']) as String?,
      lines: lines,
      subtotal: (_detail['subtotal'] as num?)?.toDouble() ?? 0,
      discountTotal: (_detail['discount_total'] as num?)?.toDouble() ?? 0,
      grandTotal: (_detail['grand_total'] as num?)?.toDouble() ?? 0,
      preparedBy: _meta.preparedBy,
      createdAt: createdAt,
      footerNote: _meta.footerNote,
      relatedRefs: prnVoucher != null ? {'PRN #': prnVoucher} : null,
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
            ? const Center(child: Text('Select or create a Purchase Return Invoice',
                style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
            : _buildDetail(),
      ),
    );
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _invoices.where((r) {
      final matchSearch = matchesQuery(
          '${r['voucher_number'] ?? ''} ${r['suppliers']?['name'] ?? ''} ${r['purchase_returns']?['voucher_number'] ?? ''}',
          q);
      final matchFilter = _filter == 'all' || (r['status'] as String? ?? 'draft') == _filter;
      return matchSearch && matchFilter;
    }).toList();
    return Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Row(children: [
            const Expanded(child: Text('Purchase Return Invoices', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
            IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32),
                onPressed: _createNew, tooltip: 'New PRI from PRN'),
          ]),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search PRI / PRN / supplier…',
                prefixIcon: Icon(Icons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            _FilterTab(label: 'All',    value: 'all',    current: _filter, onTap: (v) => setState(() => _filter = v)),
            const SizedBox(width: 6),
            _FilterTab(label: 'Draft',  value: 'draft',  current: _filter, onTap: (v) => setState(() => _filter = v)),
            const SizedBox(width: 6),
            _FilterTab(label: 'Issued', value: 'issued', current: _filter, onTap: (v) => setState(() => _filter = v)),
          ]),
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
                        title: Row(children: [
                          Expanded(child: Text(r['voucher_number'] as String? ?? '-',
                              style: TextStyle(fontWeight: FontWeight.w700, color: selected ? AppTheme.primary : null))),
                          _PriStatusBadge(r['status'] as String? ?? 'draft'),
                        ]),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(r['suppliers']?['name'] as String? ?? 'Cash Supplier', style: const TextStyle(fontSize: 11)),
                          if (r['purchase_returns']?['voucher_number'] != null)
                            Text('← ${r['purchase_returns']['voucher_number']}',
                                style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                        ]),
                        trailing: Text(money(r['grand_total'] as num?),
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
    final sup = _detail['suppliers'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header
      Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Purchase Return Invoice',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ])),
          if (_isDraft) ...[
            ElevatedButton.icon(
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Issue Invoice'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
              onPressed: _issueInvoice,
            ),
            const SizedBox(width: 8),
          ],
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
            // Info chips
            Wrap(spacing: 12, runSpacing: 8, children: [
              _Chip(label: 'Supplier', value: sup?['name'] as String? ?? 'Cash Supplier'),
              _Chip(label: 'Date', value: _detail['voucher_date'] != null
                  ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
              _Chip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
              _Chip(label: 'Source PRN', value: _detail['purchase_returns']?['voucher_number'] as String? ?? '-'),
              _Chip(label: 'Status', value: _detail['status'] as String? ?? 'draft'),
            ]),
            // Supplier strip
            if (sup != null && (sup['address'] != null || sup['contact_person'] != null))
              _SupplierInfoStrip(
                address: sup['address'] as String?,
                contact: sup['contact_person'] as String?,
                phone: (sup['contact_number'] ?? sup['phone']) as String?,
                ntn: sup['ntn'] as String?,
                preparedBy: _meta.preparedBy,
              ),

            const SizedBox(height: 20),

            // Draft hint
            if (_isDraft)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Row(children: [
                  const Icon(Icons.edit_note, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                      _priceFieldEditable
                          ? 'Draft — set prices below, then click "Issue Invoice" to post it to the ledger.'
                          : 'Draft — prices are frozen to each product\'s Cost Price; adjust value using Discount. Click "Issue Invoice" to post.',
                      style: const TextStyle(fontSize: 12, color: Colors.orange))),
                ]),
              ),

            // Items table
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                // Header row
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
                if (_items.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text('No items.', style: TextStyle(color: AppTheme.textSecondary))),
                ..._items.map((it) {
                  final id    = it['id'] as String;
                  final qty   = (it['quantity']   as num?)?.toDouble() ?? 0;
                  final disc  = (it['discount']   as num?)?.toDouble() ?? 0;
                  // Frozen drafts show cost price (read-only); editable drafts
                  // show the stored unit price in an editable field; issued
                  // invoices show the locked-in unit price.
                  final price = (_isDraft && !_priceFieldEditable)
                      ? _costOf(it)
                      : ((it['unit_price'] as num?)?.toDouble() ?? 0);
                  final lt    = price > 0 ? qty * price * (1 - disc / 100) : 0.0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(children: [
                      Expanded(flex: 4, child: Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text(qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(flex: 2, child: (_isDraft && _priceFieldEditable)
                          ? TextField(controller: _priceCtrl[id],
                              decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)),
                              textAlign: TextAlign.right,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              onSubmitted: (_) => _saveItemPrice(id))
                          : Tooltip(
                              message: (_isDraft && !_priceFieldEditable) ? 'Frozen to product Cost Price — adjust value via Discount' : '',
                              child: Text(price.toStringAsFixed(2), textAlign: TextAlign.right,
                                  style: TextStyle(color: (_isDraft && !_priceFieldEditable) ? AppTheme.textSecondary : null)))),
                      Expanded(flex: 1, child: _isDraft
                          ? TextField(controller: _discCtrl[id],
                              decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)),
                              textAlign: TextAlign.right,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              onSubmitted: (_) => _saveItemPrice(id))
                          : Text('${disc.toStringAsFixed(0)}%', textAlign: TextAlign.right)),
                      Expanded(flex: 2, child: Text(money(lt), textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                    ]),
                  );
                }),
              ]),
            ),

            const SizedBox(height: 16),

            // Totals
            Align(alignment: Alignment.centerRight, child: Container(
              padding: const EdgeInsets.all(12), width: 280,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _totalRow('Subtotal', (_detail['subtotal'] as num?)?.toDouble() ?? 0),
                _totalRow('Discount', (_detail['discount_total'] as num?)?.toDouble() ?? 0, color: AppTheme.warning),
                const Divider(height: 8),
                _totalRow('Grand Total', (_detail['grand_total'] as num?)?.toDouble() ?? 0, bold: true),
              ]),
            )),

            const SizedBox(height: 16),
            _AuditTrailWidget(voucherId: _selectedId ?? '', voucherType: 'PRI'),
          ]),
        ),
      ),
    ]);
  }

  Widget _totalRow(String label, double v, {bool bold = false, Color? color}) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(color: color ?? AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: bold ? 14 : 12)),
        Text(money(v), style: TextStyle(color: color ?? (bold ? AppTheme.primary : null), fontWeight: bold ? FontWeight.w700 : FontWeight.w600, fontSize: bold ? 15 : 13)),
      ]));
  }
}

// ─── PRN Picker Dialog ────────────────────────────────────────────────────────
class _PrnPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> prns;
  const _PrnPickerDialog({required this.prns});
  @override
  State<_PrnPickerDialog> createState() => _PrnPickerDialogState();
}
class _PrnPickerDialogState extends State<_PrnPickerDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final filtered = widget.prns.where((s) => matchesQuery(
        '${s['voucher_number'] ?? ''} ${s['suppliers']?['name'] ?? ''}', q)).toList();
    return AlertDialog(
      title: Text('Pick a saved PRN  ·  ${widget.prns.length} eligible'),
      content: SizedBox(width: 520, height: 460, child: Column(children: [
        TextField(decoration: const InputDecoration(hintText: 'Search PRN # / supplier',
            prefixIcon: Icon(Icons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _q = v), autofocus: true),
        const SizedBox(height: 12),
        Expanded(child: filtered.isEmpty
            ? const Center(child: Text('No saved PRNs match.'))
            : ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = filtered[i];
                  return ListTile(dense: true,
                    title: Text(s['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(s['suppliers']?['name'] as String? ?? 'Cash Supplier', style: const TextStyle(fontSize: 11)),
                    onTap: () => Navigator.pop(context, s));
                })),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
    );
  }
}

// ─── Supplier Info Strip ──────────────────────────────────────────────────────
class _SupplierInfoStrip extends StatelessWidget {
  final String? address, contact, phone, ntn, preparedBy;
  const _SupplierInfoStrip({this.address, this.contact, this.phone, this.ntn, this.preparedBy});
  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      if (address != null && address!.isNotEmpty) _tile(Icons.location_on_outlined, 'Address', address!),
      if (contact != null && contact!.isNotEmpty) _tile(Icons.account_circle_outlined, 'Contact', contact!),
      if (phone != null && phone!.isNotEmpty)     _tile(Icons.phone_outlined, 'Phone', phone!),
      if (ntn != null && ntn!.isNotEmpty)         _tile(Icons.badge_outlined, 'NTN', ntn!),
    ];
    if (tiles.isEmpty && (preparedBy == null || preparedBy!.isEmpty)) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.background, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tiles.isNotEmpty) Wrap(spacing: 24, runSpacing: 8, children: tiles),
        if (preparedBy != null && preparedBy!.isNotEmpty) ...[
          if (tiles.isNotEmpty) const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.draw_outlined, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text('Prepared by: $preparedBy', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
          ]),
        ],
      ]),
    );
  }
  Widget _tile(IconData icon, String label, String value) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 300),
    child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: AppTheme.textSecondary),
      const SizedBox(width: 6),
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        Text(value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
      ]),
    ]),
  );
}

class _Chip extends StatelessWidget {
  final String label, value;
  const _Chip({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
    ]),
  );
}

// ─── Audit Trail Widget ───────────────────────────────────────────────────────
class _AuditTrailWidget extends StatelessWidget {
  final String voucherId, voucherType;
  const _AuditTrailWidget({required this.voucherId, required this.voucherType});

  // Load the log WITHOUT a PostgREST users(name) embed. That embed needs a
  // declared FK from voucher_audit_log.performed_by -> users; when it isn't
  // present the request 400s, and the old `if (snap.hasError) shrink()` made
  // this whole panel silently disappear. We fetch the rows plainly and resolve
  // performer names in a second lookup, so a missing FK can never hide it.
  Future<List<Map<String, dynamic>>> _load() async {
    final sb = Supabase.instance.client;
    final rows = List<Map<String, dynamic>>.from(
      await sb
          .from('voucher_audit_log')
          .select('action, details, performed_by, performed_at')
          .eq('voucher_id', voucherId)
          .eq('voucher_type', voucherType)
          .order('performed_at', ascending: false)
          .limit(30),
    );
    final ids = rows
        .map((e) => e['performed_by'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    final names = <String, String>{};
    if (ids.isNotEmpty) {
      try {
        final us = await sb.from('users').select('id, name').inFilter('id', ids);
        for (final u in us as List) {
          names[u['id'] as String] = (u['name'] as String?) ?? '—';
        }
      } catch (_) {/* names are best-effort; never block the trail on them */}
    }
    for (final e in rows) {
      e['_by'] = names[e['performed_by'] as String?] ?? '—';
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    if (voucherId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _load(),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        if (snap.hasError) {
          // Surface failures instead of vanishing — this is exactly the case
          // that previously looked like "no audit trail at all".
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Row(children: [
                const Icon(Icons.error_outline, size: 14, color: AppTheme.danger),
                const SizedBox(width: 8),
                Expanded(child: Text('Couldn\'t load audit trail: ${snap.error}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
              ]),
            ),
          );
        }
        final entries = snap.data ?? const <Map<String, dynamic>>[];
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE5E7EB))),
              child: const Row(children: [
                Icon(Icons.history, size: 14, color: Color(0xFF9CA3AF)),
                SizedBox(width: 8),
                Text('No activity logged yet', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
              ]),
            ),
          );
        }
        return Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)),
            const SizedBox(height: 8),
            ...entries.map((e) {
              final action = e['action'] as String? ?? '-';
              final ts = e['performed_at'] != null
                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(e['performed_at'] as String).toLocal())
                  : '';
              final by = e['_by'] as String? ?? '—';
              final details = e['details'] as String? ?? '';
              Color color;
              IconData icon;
              switch (action) {
                case 'created':  icon = Icons.add_circle_outline;   color = AppTheme.success; break;
                case 'saved':    icon = Icons.save_outlined;        color = AppTheme.primary; break;
                case 'invoiced': icon = Icons.receipt_long_outlined; color = AppTheme.success; break;
                case 'issued':   icon = Icons.check_circle_outline; color = AppTheme.success; break;
                case 'locked':   icon = Icons.lock_outline;         color = Colors.orange; break;
                case 'unlocked': icon = Icons.lock_open;            color = AppTheme.textSecondary; break;
                case 'deleted':
                case 'cancelled': icon = Icons.delete_outline;      color = AppTheme.danger; break;
                default:         icon = Icons.history;              color = AppTheme.textSecondary;
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(action, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)),
                      const SizedBox(width: 8),
                      Text('by $by', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const Spacer(),
                      Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ]),
                    if (details.isNotEmpty) Text(details, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ])),
                ]),
              );
            }),
          ]),
        );
      },
    );
  }
}

class _FilterTab extends StatelessWidget {
  final String label, value, current;
  final ValueChanged<String> onTap;
  const _FilterTab({required this.label, required this.value, required this.current, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final active = value == current;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary : AppTheme.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? AppTheme.primary : AppTheme.border),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: active ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }
}

class _PriStatusBadge extends StatelessWidget {
  final String status;
  const _PriStatusBadge(this.status);
  @override
  Widget build(BuildContext context) {
    Color bg, fg; String label;
    switch (status) {
      case 'issued': bg = AppTheme.success.withOpacity(0.12); fg = AppTheme.success; label = 'Issued'; break;
      default:       bg = Colors.orange.withOpacity(0.12);    fg = Colors.orange;    label = 'Draft';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}
