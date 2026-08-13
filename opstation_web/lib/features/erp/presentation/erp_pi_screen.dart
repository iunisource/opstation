import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/layout/collapsible_list_pane.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';
import '../widgets/voucher_docs_panel.dart';
import '../widgets/voucher_remarks_panel.dart';

/// Purchase Invoice (PI) — Stage 3 of purchase flow.
/// Created from a saved GRN. User enters unit cost + discount per line.
/// Auto-locks on "Save Invoice". Only admins can unlock.
/// Marks source GRN as 'invoiced' on save.

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

class ErpPurchaseInvoicesScreen extends ConsumerStatefulWidget {
  const ErpPurchaseInvoicesScreen({super.key, this.focusId});
  final String? focusId;
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
  // The supplier's own invoice number, and a free-text description. Both live on
  // the PI header: the vendor's number is what you reconcile their statement
  // against, and the description is what makes the supplier ledger readable —
  // today every row just repeats "Purchase Invoice PI-2026-0001", which tells a
  // reader nothing they cannot already see in the Voucher column.
  final TextEditingController _vendorNoCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();
  bool _listLoading = true;
  bool _detailLoading = false;
  bool _datesEditable = false;
  bool _reviewFlow = false; // org.doc_review_flow: support docs + admin review
  String _search = '';
  String _filter = 'all';

  @override
  void initState() { super.initState(); _loadList(); if (widget.focusId != null) _loadDetail(widget.focusId!); }
  @override
  void dispose() { for (final c in _costCtrl.values) c.dispose(); for (final c in _discCtrl.values) c.dispose(); _vendorNoCtrl.dispose(); _descCtrl.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isDraft  => !_isLocked;
  bool get _canDelete { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canUnlock { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canEditDate => (_datesEditable || _isAdmin) && !_isLocked;
  // Review-flow state
  String? get _reviewStatus => _detail['review_status'] as String?;
  bool get _isPendingReview => _reviewStatus == 'pending';
  bool get _isRejected => _reviewStatus == 'rejected';

  // The status label/colour for a list row or the current voucher, taking the
  // review flow into account. Draft only until saved/sent.
  static ({String label, Color color}) _statusOf({required bool locked, String? review}) {
    if (locked) return (label: 'Invoiced', color: AppTheme.success);
    if (review == 'pending') return (label: 'Under Review', color: Colors.blue);
    if (review == 'rejected') return (label: 'Rejected', color: AppTheme.danger);
    return (label: 'Draft', color: Colors.orange);
  }

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _pickDate() async {
    final cur = _detail['voucher_date'] != null ? DateTime.tryParse(_detail['voucher_date'] as String) : null;
    final picked = await showDatePicker(context: context, initialDate: cur ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked == null) return;
    final iso = DateFormat('yyyy-MM-dd').format(picked);
    try {
      await Supabase.instance.client.from('purchase_invoices')
          .update({'voucher_date': iso, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', _detail['id']);
      if (mounted) setState(() => _detail['voucher_date'] = iso);
      await _logAudit(_detail['id'] as String, 'date_changed', 'Voucher date set to \$iso');
      _loadList();
    } catch (e) { _showSnack('Failed: \$e'); }
  }


  void _initCtrls() {
    for (final c in _costCtrl.values) c.dispose();
    for (final c in _discCtrl.values) c.dispose();
    _costCtrl = {}; _discCtrl = {};
    for (final it in _items) {
      final id = it['id'] as String;
      _costCtrl[id] = TextEditingController(text: _plain4(it['unit_cost'] as num?));
      _discCtrl[id]  = TextEditingController(text: _plain4(it['discount'] as num?));
    }
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('purchase_invoices')
          .select('id,voucher_number,voucher_date,grand_total,is_locked,review_status,supplier_id,grn_id,vendor_invoice_no,description,suppliers(name),purchase_grns(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final r = await q.order('voucher_date', ascending: false).order('voucher_number', ascending: false).limit(2000);
      bool reviewFlow = _reviewFlow;
      try {
        final c = await Supabase.instance.client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.doc_review_flow_pi').maybeSingle();
        reviewFlow = (c?['value'] as String?) == 'true';
      } catch (_) {}
      setState(() { _invoices = List<Map<String, dynamic>>.from(r); _reviewFlow = reviewFlow; _listLoading = false; });
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
      bool datesEd = false; bool reviewFlow = false;
      try {
        final cfg = await client.from('app_config').select('key,value').eq('org_id', _orgId ?? '')
            .inFilter('key', ['org.voucher_dates_editable', 'org.doc_review_flow_pi']);
        for (final r in cfg as List) {
          if (r['key'] == 'org.voucher_dates_editable') datesEd = r['value'] == 'true';
          if (r['key'] == 'org.doc_review_flow_pi') reviewFlow = r['value'] == 'true';
        }
      } catch (_) {}
      setState(() {
        _detail = Map<String, dynamic>.from(inv); _items = List<Map<String, dynamic>>.from(items);
        _vendorNoCtrl.text = (inv['vendor_invoice_no'] as String?) ?? '';
        _descCtrl.text = (inv['description'] as String?) ?? '';
        _meta = meta; _detailLoading = false; _datesEditable = datesEd; _reviewFlow = reviewFlow; _initCtrls();
      });
    } catch (e) { _showSnack('Detail error: $e'); setState(() => _detailLoading = false); }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': _orgId, 'voucher_id': id, 'voucher_type': 'PI',
        'action': action, 'details': details, 'performed_by': ref.read(currentUserProvider)?.id,
      });
    } catch (_) {}
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    try {
      final grns = await Supabase.instance.client.from('purchase_grns')
          .select('id,voucher_number,voucher_date,supplier_id,po_id,suppliers(name),purchase_orders(voucher_number)')
          .eq('org_id', orgId).eq('branch_id', branchId).inFilter('status', ['received', 'partially_received', 'saved']).eq('is_locked', true)
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
      // Prefill unit cost from each product's cost_price (still editable before save/lock)
      final pids = <String>{ for (final it in grnItems) it['product_id'] as String };
      final Map<String, double> costMap = {};
      if (pids.isNotEmpty) {
        final prods = await Supabase.instance.client.from('products').select('id,cost_price').inFilter('id', pids.toList());
        for (final p in (prods as List)) { costMap[p['id'] as String] = (p['cost_price'] as num?)?.toDouble() ?? 0; }
      }
      double seedSubtotal = 0;
      final piiRows = <Map<String, dynamic>>[];
      var seq = 0;
      for (final item in grnItems) {
        final pid = item['product_id'] as String;
        final qty = (item['qty_received'] as num?)?.toDouble() ?? 0;
        final cost = costMap[pid] ?? 0;
        final lt = qty * cost; // no discount at creation
        seedSubtotal += lt;
        piiRows.add({
          'id': 'pii_${DateTime.now().microsecondsSinceEpoch}_${seq++}',
          'invoice_id': piId, 'product_id': pid, 'uom_id': item['uom_id'],
          'qty_received': item['qty_received'], 'unit_cost': cost, 'discount': 0, 'line_total': lt,
        });
      }
      // Batched: one insert for all invoice lines instead of one per line.
      if (piiRows.isNotEmpty) {
        await Supabase.instance.client.from('purchase_invoice_items').insert(piiRows);
      }
      if (seedSubtotal > 0) {
        await Supabase.instance.client.from('purchase_invoices').update({
          'subtotal': seedSubtotal, 'discount_total': 0, 'grand_total': seedSubtotal,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', piId);
      }
      await _logAudit(piId, 'created', 'PI $vNum from GRN ${grn['voucher_number']}');
      _showSnack('$vNum created — enter costs then save');
      await _loadList(); _loadDetail(piId);
    } catch (e) { setState(() => _detailLoading = false); _showSnack('Failed: $e'); }
  }

  Future<void> _saveItemCost(String itemId) async {
    final cost = double.tryParse(_costCtrl[itemId]?.text ?? '') ?? 0;
    final disc = (double.tryParse(_discCtrl[itemId]?.text ?? '') ?? 0).clamp(0.0, 100.0);
    final idx = _items.indexWhere((i) => i['id'] == itemId);
    final row = idx >= 0 ? _items[idx] : <String, dynamic>{};
    final oldCost = (row['unit_cost'] as num?)?.toDouble() ?? 0;
    final oldDisc = (row['discount'] as num?)?.toDouble() ?? 0;
    final qty = (row['qty_received'] as num?)?.toDouble() ?? 0;
    final lt = qty * cost * (1 - disc / 100);
    try {
      await Supabase.instance.client.from('purchase_invoice_items').update({'unit_cost': cost, 'discount': disc, 'line_total': lt}).eq('id', itemId);
      setState(() {
        if (idx >= 0) { _items[idx]['unit_cost'] = cost; _items[idx]['discount'] = disc; _items[idx]['line_total'] = lt; }
      });
      await _recalcTotals();
      if (cost != oldCost || disc != oldDisc) {
        final pname = (row['products']?['name'] as String?) ?? 'item';
        await _logAudit(_detail['id'] as String, 'edited', '$pname cost: ${oldCost.toStringAsFixed(2)} -> ${cost.toStringAsFixed(2)}, disc: ${oldDisc.toStringAsFixed(0)}% -> ${disc.toStringAsFixed(0)}%');
      }
    } catch (e) { _showSnack('Save error: $e'); }
  }

  /// Batched equivalent of looping [_saveItemCost] over every line. Instead of
  /// ~3 round trips per line (item update + header recalc + audit), this does
  /// ONE upsert for all lines, ONE header recalc, and ONE audit insert. Used by
  /// the save/post paths where every line is persisted at once.
  Future<void> _saveAllItemCosts() async {
    if (_items.isEmpty) return;
    final userId = ref.read(currentUserProvider)?.id;
    final updates = <Map<String, dynamic>>[];
    final audits = <Map<String, dynamic>>[];
    for (final row in _items) {
      final itemId = row['id'] as String;
      final cost = double.tryParse(_costCtrl[itemId]?.text ?? '') ?? 0;
      final disc = (double.tryParse(_discCtrl[itemId]?.text ?? '') ?? 0).clamp(0.0, 100.0);
      final oldCost = (row['unit_cost'] as num?)?.toDouble() ?? 0;
      final oldDisc = (row['discount'] as num?)?.toDouble() ?? 0;
      final qty = (row['qty_received'] as num?)?.toDouble() ?? 0;
      final lt = qty * cost * (1 - disc / 100);
      updates.add({'id': itemId, 'unit_cost': cost, 'discount': disc, 'line_total': lt});
      if (cost != oldCost || disc != oldDisc) {
        final pname = (row['products']?['name'] as String?) ?? 'item';
        audits.add({
          'org_id': _orgId, 'voucher_id': _detail['id'], 'voucher_type': 'PI',
          'action': 'edited',
          'details': '$pname cost: ${oldCost.toStringAsFixed(2)} -> ${cost.toStringAsFixed(2)}, '
              'disc: ${oldDisc.toStringAsFixed(0)}% -> ${disc.toStringAsFixed(0)}%',
          'performed_by': userId,
        });
      }
    }
    try {
      // CONCURRENT per-row UPDATEs — NOT an upsert. An upsert is an INSERT
      // first, so RLS evaluated its insert-check against a row with no
      // invoice_id and rejected it (42501 "violates row-level security policy
      // for purchase_invoice_items") on every save/approve. Plain updates only
      // face the USING check on the existing row, which passes.
      await Future.wait([
        for (final u in updates)
          Supabase.instance.client
              .from('purchase_invoice_items')
              .update({
                'unit_cost': u['unit_cost'],
                'discount': u['discount'],
                'line_total': u['line_total'],
              })
              .eq('id', u['id'] as String),
      ]);
      // Reflect in memory, then recompute the header total ONCE.
      setState(() {
        for (final u in updates) {
          final idx = _items.indexWhere((i) => i['id'] == u['id']);
          if (idx >= 0) {
            _items[idx]['unit_cost'] = u['unit_cost'];
            _items[idx]['discount'] = u['discount'];
            _items[idx]['line_total'] = u['line_total'];
          }
        }
      });
      await _recalcTotals();
      if (audits.isNotEmpty) {
        try {
          await Supabase.instance.client.from('voucher_audit_log').insert(audits);
        } catch (_) {}
      }
    } catch (e) {
      _showSnack('Save error: $e');
    }
  }

  /// Live totals computed straight from the edit fields (draft only) so the
  /// screen updates as you type, before anything is saved.
  /// Returns [subtotal, discount, grand].
  List<double> _liveTotals() {
    double subtotal = 0, discount = 0;
    for (final it in _items) {
      final id = it['id'] as String;
      final qty = (it['qty_received'] as num?)?.toDouble() ?? 0;
      final cost = double.tryParse(_costCtrl[id]?.text ?? '') ?? 0;
      final disc =
          (double.tryParse(_discCtrl[id]?.text ?? '') ?? 0).clamp(0.0, 100.0);
      subtotal += qty * cost;
      discount += qty * cost * (disc / 100);
    }
    return [subtotal, discount, subtotal - discount];
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

  // Persists any edited costs and checks every line has a cost > 0.
  Future<bool> _prepAndValidate() async {
    if (_items.isEmpty) { _showSnack('No items'); return false; }
    await _saveAllItemCosts();
    for (final it in _items) {
      final cost = (it['unit_cost'] as num?)?.toDouble() ?? 0;
      if (cost <= 0) { _showSnack('Unit cost for "${it['products']?['name'] ?? 'item'}" must be > 0'); return false; }
    }
    return true;
  }

  // Re-entrancy guard: Approve/Save clicked repeatedly while the async post is
  // in flight fired _postCore multiple times (triple "approved" audit rows).
  bool _postingCore = false;

  // The actual post: lock the invoice, mark the GRN invoiced, save header text.
  // When [approved] is true it also stamps the reviewer (Checked By).
  Future<void> _postCore({bool approved = false}) async {
    if (_postingCore) return;
    // Already posted? (Covers stacked confirm dialogs from rapid clicks — each
    // resolves sequentially, so the in-flight flag alone can't catch them.)
    if (_detail['is_locked'] == true &&
        (!approved || _detail['review_status'] == 'approved')) {
      _showSnack('Already posted');
      return;
    }
    _postingCore = true;
    final userId = ref.read(currentUserProvider)?.id;
    final piId = _detail['id'] as String;
    final grnId = _detail['grn_id'] as String?;
    final now = DateTime.now().toUtc().toIso8601String();
    final upd = <String, dynamic>{
      'is_locked': true, 'locked_by': userId, 'locked_at': now,
      'vendor_invoice_no': _vendorNoCtrl.text.trim().isEmpty ? null : _vendorNoCtrl.text.trim(),
      'description': _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
      'updated_at': now,
    };
    if (approved) {
      upd['review_status'] = 'approved';
      upd['reviewed_by'] = userId;
      upd['reviewed_by_name'] = ref.read(currentUserProvider)?.name;
      upd['reviewed_at'] = now;
      // Snapshot the reviewer's signature + the org stamp at approval time.
      final c = Supabase.instance.client;
      try { final u = await c.from('users').select('signature_url').eq('id', userId ?? '').maybeSingle();
        if (u?['signature_url'] != null) upd['reviewer_signature_url'] = u!['signature_url']; } catch (_) {}
      try { final s = await c.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.stamp_url').maybeSingle();
        if (s?['value'] != null) upd['review_stamp_url'] = s!['value']; } catch (_) {}
    }
    try {
      await Supabase.instance.client.from('purchase_invoices').update(upd).eq('id', piId);
      if (grnId != null) {
        await Supabase.instance.client.from('purchase_grns').update({'status': 'invoiced', 'updated_at': now}).eq('id', grnId);
      }
      await _logAudit(piId, approved ? 'approved' : 'saved', approved ? 'Reviewed & posted' : 'Invoice saved and locked');
      // Reflect the new state locally IMMEDIATELY so a queued duplicate call
      // hits the already-posted guard even before _loadDetail returns.
      _detail['is_locked'] = true;
      if (approved) _detail['review_status'] = 'approved';
      _showSnack(approved ? 'Approved & posted' : 'Invoice saved and locked');
      _loadDetail(piId); _loadList();
      ref.invalidate(piReviewPendingProvider);
    } catch (e) { _showSnack('Failed: $e'); }
    finally { _postingCore = false; }
  }

  // Direct save+lock (used when the review flow is OFF).
  Future<void> _saveInvoice() async {
    if (!await _prepAndValidate()) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Save & Lock Invoice?'),
      content: const Text('The GRN will be marked as invoiced and this invoice will be locked. Only admins can unlock.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Save Invoice'))],
    ));
    if (ok != true) return;
    await _postCore();
  }

  // Review flow: park the invoice as pending (no posting) and save its edits.
  Future<void> _sendForReview() async {
    if (_items.isEmpty) { _showSnack('No items'); return; }
    await _saveAllItemCosts();
    final piId = _detail['id'] as String;
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await Supabase.instance.client.from('purchase_invoices').update({
        'review_status': 'pending',
        'vendor_invoice_no': _vendorNoCtrl.text.trim().isEmpty ? null : _vendorNoCtrl.text.trim(),
        'description': _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        'updated_at': now,
      }).eq('id', piId);
      setState(() => _detail['review_status'] = 'pending');
      await _logAudit(piId, 'sent_for_review', 'Invoice sent for admin review');
      _showSnack('Sent for review — an admin will approve and post it');
      _loadList();
      ref.invalidate(piReviewPendingProvider);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // Review flow: admin approves a pending invoice, which posts it.
  Future<void> _approveAndPost() async {
    if (!_isAdmin) { _showSnack('Only admins can approve'); return; }
    if (!await _prepAndValidate()) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Approve & post invoice?'),
      content: const Text('This posts the invoice (locks it and marks the GRN invoiced) and records you as the reviewer. This cannot be undone by non-admins.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Approve & Post'))],
    ));
    if (ok != true) return;
    await _postCore(approved: true);
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
    final piId = _detail['id'] as String;
    try {
      await Supabase.instance.client.from('purchase_invoices').update({
        'review_status': 'rejected',
        'review_reason': reason.isEmpty ? null : reason,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', piId);
      setState(() { _detail['review_status'] = 'rejected'; _detail['review_reason'] = reason.isEmpty ? null : reason; });
      await _logAudit(piId, 'rejected', reason.isEmpty ? 'Invoice rejected' : 'Rejected: $reason');
      _showSnack('Invoice rejected');
      _loadList();
      ref.invalidate(piReviewPendingProvider);
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
      content: Text('Delete ${_detail['voucher_number']}? The GRN will be restored to its received state.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      final grnId = _detail['grn_id'] as String?;
      if (grnId != null) {
        // Recompute the GRN's received status (full vs partial) when un-invoicing it.
        final gItems = await Supabase.instance.client.from('purchase_grn_items').select('qty_ordered,qty_received').eq('grn_id', grnId);
        bool partial = false;
        for (final gi in (gItems as List)) {
          final ord = (gi['qty_ordered'] as num?)?.toDouble() ?? 0;
          final rcv = (gi['qty_received'] as num?)?.toDouble() ?? 0;
          if (rcv < ord) { partial = true; break; }
        }
        await Supabase.instance.client.from('purchase_grns').update({'status': partial ? 'partially_received' : 'received', 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', grnId);
      }
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
    // The supplier's own invoice number belongs on the printed document — it is
    // what they will quote back to you on a statement or a query.
    final vNo = _detail['vendor_invoice_no'] as String?;
    if (vNo != null && vNo.isNotEmpty) refs['Vendor Inv #'] = vNo;
    final vDesc = (_detail['description'] as String?)?.trim();
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
      preparedBy: _meta.preparedBy,
      createdAt: _detail['created_at'] != null
          ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal())
          : null,
      approvedBy: _detail['reviewed_by_name'] as String?,
      approvedAt: _detail['reviewed_at'] != null
          ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['reviewed_at'] as String).toLocal())
          : null,
      approvedSignatureUrl: _detail['reviewer_signature_url'] as String?,
      stampUrl: _detail['review_stamp_url'] as String?,
      // Description leads the footer, then the org's standard purchase note.
      footerNote: [
        if (vDesc != null && vDesc.isNotEmpty) vDesc,
        if ((_meta.purchaseFooterNote ?? _meta.footerNote) != null)
          (_meta.purchaseFooterNote ?? _meta.footerNote)!,
      ].join('\n\n').trim().isEmpty
          ? null
          : [
              if (vDesc != null && vDesc.isNotEmpty) vDesc,
              if ((_meta.purchaseFooterNote ?? _meta.footerNote) != null)
                (_meta.purchaseFooterNote ?? _meta.footerNote)!,
            ].join('\n\n'),
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
      final review = r['review_status'] as String?;
      final matchFilter = _filter == 'all'
          || (_filter == 'draft' && !locked && review == null)
          || (_filter == 'review' && review == 'pending')
          || (_filter == 'rejected' && review == 'rejected')
          || (_filter == 'invoiced' && locked);
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
        if (_reviewFlow) ...[
          _PiFilterTab(label: 'Review', value: 'review', current: _filter, onTap: (v) => setState(() => _filter = v)),
          const SizedBox(width: 6),
          _PiFilterTab(label: 'Rejected', value: 'rejected', current: _filter, onTap: (v) => setState(() => _filter = v)),
          const SizedBox(width: 6),
        ],
        _PiFilterTab(label: 'Invoiced', value: 'invoiced', current: _filter, onTap: (v) => setState(() => _filter = v)),
      ])),
      const SizedBox(height: 12),
      Expanded(child: _listLoading ? const Center(child: CircularProgressIndicator())
          : filtered.isEmpty ? const Center(child: Text('No invoices yet.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = filtered[i]; final sel = r['id'] == _selectedId;
                final locked = r['is_locked'] as bool? ?? false;
                final st = _statusOf(locked: locked, review: r['review_status'] as String?);
                return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.06),
                  title: Row(children: [
                    Expanded(child: Text(r['voucher_number'] as String? ?? '-', style: TextStyle(fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : null))),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: st.color.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                      child: Text(st.label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: st.color))),
                  ]),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(r['suppliers']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 11)),
                    if (r['purchase_grns']?['voucher_number'] != null) Text('← ${r['purchase_grns']['voucher_number']}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ]),
                  trailing: Text(_n4(r['grand_total'] as num?), style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  onTap: () => _loadDetail(r['id'] as String));
              })),
    ]));
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: CircularProgressIndicator());
    final sup = _detail['suppliers'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Builder(builder: (context) {
        final mobile = context.isMobile;
        final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_detail['voucher_number'] as String? ?? '-', style: TextStyle(fontSize: mobile ? 18 : 22, fontWeight: FontWeight.w700)),
          const Text('Purchase Invoice', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
        ]);
        final actions = <Widget>[
          if (_isDraft && !_reviewFlow)
            ElevatedButton.icon(icon: const Icon(Icons.save_outlined, size: 16), label: const Text('Save Invoice'), onPressed: _saveInvoice),
          if (_isDraft && _reviewFlow && !_isPendingReview)
            ElevatedButton.icon(icon: const Icon(Icons.send_outlined, size: 16), label: const Text('Send for Review'), onPressed: _sendForReview),
          if (_isDraft && _reviewFlow && _isPendingReview && _isAdmin) ...[
            OutlinedButton.icon(icon: const Icon(Icons.cancel_outlined, size: 16), label: const Text('Reject'),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger, side: const BorderSide(color: AppTheme.danger)), onPressed: _reject),
            ElevatedButton.icon(icon: const Icon(Icons.verified_outlined, size: 16), label: const Text('Approve & Post'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success), onPressed: _approveAndPost),
          ],
          if (_isDraft && _reviewFlow && _isPendingReview && !_isAdmin)
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.4))),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.hourglass_top, size: 12, color: Colors.orange), SizedBox(width: 4), Text('Pending review', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w600))])),
          if (_canEditDate)
            IconButton(icon: const Icon(Icons.edit_calendar_outlined, color: AppTheme.textSecondary), tooltip: 'Edit date', onPressed: _pickDate),
          if (!_isDraft || _canUnlock)
            IconButton(icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
                tooltip: _isLocked ? 'Unlock (admin)' : 'Lock', onPressed: _toggleLock),
          IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), onPressed: _print),
          if (_canDelete) IconButton(icon: const Icon(Icons.delete_outline, color: AppTheme.danger), onPressed: _delete),
        ];
        return Container(
          padding: EdgeInsets.fromLTRB(mobile ? 16 : 24, 16, mobile ? 12 : 24, mobile ? 12 : 16),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: mobile
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                titleBlock,
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
              ])
            : Row(children: [
                Expanded(child: titleBlock),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
              ]),
        );
      }),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          _PiChip(label: 'Supplier', value: sup?['name'] as String? ?? '-'),
          _PiChip(label: 'Date', value: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
          _PiChip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
          if (_detail['purchase_grns']?['voucher_number'] != null) _PiChip(label: 'GRN #', value: _detail['purchase_grns']['voucher_number'] as String),
          if (_detail['purchase_orders']?['voucher_number'] != null) _PiChip(label: 'PO #', value: _detail['purchase_orders']['voucher_number'] as String),
          if (_isLocked && (_detail['vendor_invoice_no'] as String?)?.isNotEmpty == true)
            _PiChip(label: 'Vendor Inv #', value: _detail['vendor_invoice_no'] as String),
          _PiChip(label: 'Status', value: _isLocked ? 'Invoiced' : 'Draft'),
          if (_isLocked) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.4))), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.lock_outline, size: 12, color: Colors.orange), SizedBox(width: 4), Text('Locked', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w600))])),
        ]),
        if (sup != null) _PiInfoStrip(address: sup['address'] as String?, contact: sup['contact_person'] as String?, phone: (sup['contact_number'] ?? sup['phone']) as String?, ntn: sup['ntn'] as String?, preparedBy: _meta.preparedBy),
        const SizedBox(height: 12),
        // Vendor invoice # and description. Editable while draft; once the invoice
        // is locked they become part of the record (shown as chips / on the PDF).
        if (_isDraft)
          Builder(builder: (context) {
            final vendorField = TextField(
              controller: _vendorNoCtrl,
              decoration: InputDecoration(
                labelText: "Vendor Invoice # (optional)",
                hintText: "Supplier's own number",
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              style: const TextStyle(fontSize: 13),
            );
            final descField = TextField(
              controller: _descCtrl,
              decoration: InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'Shown in the supplier ledger and on the printed invoice',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              style: const TextStyle(fontSize: 13),
            );
            if (context.isMobile) {
              return Column(children: [
                vendorField,
                const SizedBox(height: 12),
                descField,
              ]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 220, child: vendorField),
              const SizedBox(width: 12),
              Expanded(child: descField),
            ]);
          }),
        if (_isDraft) const SizedBox(height: 12),
        if (_isLocked && (_detail['description'] as String?)?.isNotEmpty == true)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(children: [
              const Icon(Icons.notes, size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(child: Text(_detail['description'] as String,
                  style: const TextStyle(fontSize: 12.5))),
            ]),
          ),
        const SizedBox(height: 4),
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
              // In draft, read cost/disc live from the edit fields so the line
              // total updates as you type; once locked, use the saved values.
              final cost = _isDraft
                  ? (double.tryParse(_costCtrl[id]?.text ?? '') ?? 0)
                  : ((it['unit_cost'] as num?)?.toDouble() ?? 0);
              final disc = _isDraft
                  ? (double.tryParse(_discCtrl[id]?.text ?? '') ?? 0)
                      .clamp(0.0, 100.0)
                      .toDouble()
                  : ((it['discount'] as num?)?.toDouble() ?? 0);
              final lt   = _isDraft
                  ? qty * cost * (1 - disc / 100)
                  : ((it['line_total'] as num?)?.toDouble() ?? qty * cost * (1 - disc / 100));
              return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(children: [
                  Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13)),
                    if (it['products']?['sku'] != null) Text(it['products']!['sku'] as String, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ])),
                  Expanded(flex: 1, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 1, child: Text(_n4(qty), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(flex: 2, child: _isDraft
                      ? TextField(controller: _costCtrl[id], decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)), textAlign: TextAlign.right, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}), onSubmitted: (_) => _saveItemCost(id))
                      : Text(_n4(cost), textAlign: TextAlign.right)),
                  Expanded(flex: 1, child: _isDraft
                      ? TextField(controller: _discCtrl[id], decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)), textAlign: TextAlign.right, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}), onSubmitted: (_) => _saveItemCost(id))
                      : Text('${_n4(disc)}%', textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text(_n4(lt), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                ]));
            }),
          ])),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerRight, child: Container(padding: const EdgeInsets.all(12), width: 280,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _piTotalRow('Subtotal', _isDraft ? _liveTotals()[0] : (_detail['subtotal'] as num?)?.toDouble() ?? 0),
            _piTotalRow('Discount', _isDraft ? _liveTotals()[1] : (_detail['discount_total'] as num?)?.toDouble() ?? 0, color: AppTheme.warning),
            const Divider(height: 8),
            _piTotalRow('Grand Total', _isDraft ? _liveTotals()[2] : (_detail['grand_total'] as num?)?.toDouble() ?? 0, bold: true),
          ]))),
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
            voucherType: 'PI',
            voucherId: _detail['id'] as String,
            voucherNumber: _detail['voucher_number'] as String? ?? '',
            bucket: 'pi-documents',
            orgId: _orgId ?? '',
            userId: ref.read(currentUserProvider)?.id,
            canWrite: _isDraft,
          ),
          const SizedBox(height: 12),
          VoucherRemarksPanel(
            voucherType: 'PI',
            voucherId: _detail['id'] as String,
            orgId: _orgId ?? '',
            userId: ref.read(currentUserProvider)?.id,
            userName: ref.read(currentUserProvider)?.name,
          ),
          const SizedBox(height: 16),
        ],
        _PiAuditTrail(voucherId: _selectedId ?? ''),
      ]))),
    ]);
  }

  Widget _piTotalRow(String label, double v, {bool bold = false, Color? color}) => Padding(padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: TextStyle(color: color ?? AppTheme.textSecondary, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: bold ? 14 : 12)),
      Text(_n4(v), style: TextStyle(color: color ?? (bold ? AppTheme.primary : null), fontWeight: bold ? FontWeight.w700 : FontWeight.w600, fontSize: bold ? 15 : 13)),
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

// Collapsible, resilient audit trail. Reads `performed_at` (not created_at) and
// resolves performer names in a second query — no PostgREST embed that can 400
// and silently blank the panel.
class _PiAuditTrail extends StatefulWidget {
  final String voucherId; const _PiAuditTrail({required this.voucherId});
  @override State<_PiAuditTrail> createState() => _PiAuditTrailState();
}

class _PiAuditTrailState extends State<_PiAuditTrail> {
  bool _expanded = false;
  Future<List<Map<String, dynamic>>>? _future;

  @override void initState() { super.initState(); _future = _load(); }
  @override void didUpdateWidget(covariant _PiAuditTrail old) {
    super.didUpdateWidget(old);
    if (old.voucherId != widget.voucherId) _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    if (widget.voucherId.isEmpty) return [];
    final sb = Supabase.instance.client;
    final rows = List<Map<String, dynamic>>.from(await sb.from('voucher_audit_log')
        .select('action, details, performed_by, performed_at')
        .eq('voucher_id', widget.voucherId).eq('voucher_type', 'PI')
        .order('performed_at', ascending: false).limit(30));
    final ids = rows.map((e) => e['performed_by'] as String?).whereType<String>().toSet().toList();
    final names = <String, String>{};
    if (ids.isNotEmpty) {
      try { final us = await sb.from('users').select('id, name').inFilter('id', ids);
        for (final u in us as List) names[u['id'] as String] = (u['name'] as String?) ?? '—'; } catch (_) {}
    }
    for (final e in rows) e['_by'] = names[e['performed_by'] as String?] ?? '—';
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.voucherId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (ctx, snap) {
        final entries = snap.data ?? const <Map<String, dynamic>>[];
        return Container(
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: Row(children: [
                const Icon(Icons.history, size: 15, color: AppTheme.textSecondary), const SizedBox(width: 8),
                const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)),
                const SizedBox(width: 6),
                if (snap.connectionState == ConnectionState.waiting)
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                else if (entries.isNotEmpty)
                  Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                    child: Text('${entries.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary))),
                const Spacer(),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: AppTheme.textSecondary),
              ])),
            ),
            if (_expanded) ...[
              const Divider(height: 1),
              if (snap.hasError)
                Padding(padding: const EdgeInsets.all(12), child: Text("Couldn't load audit trail: ${snap.error}", style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))
              else if (entries.isEmpty)
                const Padding(padding: EdgeInsets.all(12), child: Text('No activity logged yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
              else
                Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final e in entries) _row(e),
                ])),
            ],
          ]));
      });
  }

  Widget _row(Map<String, dynamic> e) {
    final action = e['action'] as String? ?? '-';
    final by = e['_by'] as String? ?? '—';
    final ts = e['performed_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(e['performed_at'] as String).toLocal()) : '';
    final details = e['details'] as String? ?? '';
    Color color;
    switch (action) {
      case 'created': color = AppTheme.success; break;
      case 'saved': case 'approved': color = AppTheme.primary; break;
      case 'sent_for_review': color = Colors.blue; break;
      case 'rejected': case 'deleted': color = AppTheme.danger; break;
      case 'locked': case 'unlocked': color = Colors.orange; break;
      default: color = AppTheme.textSecondary;
    }
    return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.circle, size: 8, color: color), const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(action.replaceAll('_', ' '), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)),
          const SizedBox(width: 8),
          Text('by $by', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const Spacer(),
          Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
        if (details.isNotEmpty) Text(details, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ])),
    ]));
  }
}
