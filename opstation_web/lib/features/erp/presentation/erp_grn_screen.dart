import 'package:flutter/material.dart';
import '../../../core/widgets/saving_overlay.dart';
import '../../../core/utils/friendly_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/layout/collapsible_list_pane.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';
import '../widgets/voucher_docs_panel.dart';
import '../widgets/voucher_remarks_panel.dart';

/// GRN — Goods Receipt Note.
/// Acts like DO but in reverse: receives stock from supplier against a confirmed PO.
/// Items: Product | UOM | Ordered Qty (from PO) | Received Qty (editable in draft)
/// On "Confirm Receipt": stock added (+), PO qty_received updated, GRN auto-locked.
class ErpGrnScreen extends ConsumerStatefulWidget {
  const ErpGrnScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpGrnScreen> createState() => _ErpGrnScreenState();
}

class _ErpGrnScreenState extends ConsumerState<ErpGrnScreen> {
  List<Map<String, dynamic>> _grns = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _linkedPis = []; // invoices raised on this GRN
  bool _adjustMode = false;  // editing a posted (received) GRN after unlock
  bool _adjustBusy = false;
  List<Map<String, dynamic>> _items = [];
  Map<String, TextEditingController> _receivedCtrl = {};
  VoucherMeta _meta = VoucherMeta();
  bool _listLoading = true;
  bool _detailLoading = false;
  bool _datesEditable = false;
  bool _confirmBusy = false; // double-click guard for Confirm Receipt
  bool _superviseEnabled = false; // org toggle: docs + remarks + Supervise
  bool _superviseBusy = false;
  String _search = '';
  String _statusFilter = 'all';
  String _supFilter = 'all'; // supervision filter: all | yes | no (only when toggle on)

  @override
  void initState() { super.initState(); _loadList(); if (widget.focusId != null) _loadDetail(widget.focusId!); }

  // Pretty label for a GRN status string (handles legacy 'saved').
  String _prettyStatus(String? s) {
    switch (s) {
      case 'received': return 'Received';
      case 'partially_received': return 'Partially Received';
      case 'invoiced': return 'Invoiced';
      case 'saved': return 'Received';
      case 'draft': return 'Draft';
      default: return s ?? 'Draft';
    }
  }
  @override
  void dispose() { for (final c in _receivedCtrl.values) c.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  // GRN status with the legacy 'saved' folded into 'received'.
  String get _grnStatus { final s = _detail['status'] as String? ?? 'draft'; return s == 'saved' ? 'received' : s; }
  // A GRN is "confirmed" once its receipt has moved stock (received / partial /
  // invoiced). It must never offer "Confirm Receipt" again — even if it is not
  // locked — otherwise confirm_grn rejects with "already confirmed (or is locked)".
  bool get _isConfirmed => _grnStatus != 'draft';
  bool get _isDraft  => !_isLocked && !_isConfirmed;
  bool get _canDelete { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canUnlock { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canEditDate => (_datesEditable || _isAdmin) && !_isLocked;
  // A posted (received) GRN can be re-adjusted once an admin has UNLOCKED it —
  // as long as it hasn't been invoiced (an invoice already cleared GRNI, so a
  // change here would unbalance the books). This is the real purpose of unlock.
  bool get _canAdjust => _isConfirmed && !_isLocked && _isAdmin && _linkedPis.isEmpty;

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _pickDate() async {
    final cur = _detail['voucher_date'] != null ? DateTime.tryParse(_detail['voucher_date'] as String) : null;
    final picked = await showDatePicker(context: context, initialDate: cur ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked == null) return;
    final iso = DateFormat('yyyy-MM-dd').format(picked);
    try {
      await Supabase.instance.client.from('purchase_grns')
          .update({'voucher_date': iso, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', _detail['id']);
      if (mounted) setState(() => _detail['voucher_date'] = iso);
      await _logAudit(_detail['id'] as String, 'date_changed', 'Voucher date set to \$iso');
      _loadList();
    } catch (e) { _showSnack('Failed: \$e'); }
  }


  void _initReceivedCtrls() {
    for (final c in _receivedCtrl.values) c.dispose();
    _receivedCtrl = {};
    for (final it in _items) {
      final id = it['id'] as String;
      final qty = (it['qty_received'] as num?)?.toStringAsFixed(2) ?? '0';
      _receivedCtrl[id] = TextEditingController(text: qty);
    }
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId; if (orgId == null) return;
    setState(() => _listLoading = true);
    // Keep the org toggle fresh so the list badge + supervision filter appear.
    try { final c = await Supabase.instance.client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.grn_supervise_flow').maybeSingle(); _superviseEnabled = (c?['value'] as String?) == 'true'; } catch (_) {}
    try {
      var q = Supabase.instance.client.from('purchase_grns')
          .select('id,voucher_number,voucher_date,status,is_locked,supplier_id,po_id,supervised_at,suppliers(name),purchase_orders(voucher_number)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final r = await q.order('voucher_date', ascending: false).order('voucher_number', ascending: false).limit(2000);
      setState(() { _grns = List<Map<String, dynamic>>.from(r); _listLoading = false; });
    } catch (e) { _showSnack('Load error: $e'); setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final grn = await client.from('purchase_grns').select('*,suppliers(*),purchase_orders(voucher_number),branches(name)').eq('id', id).single();
      final items = await client.from('purchase_grn_items')
          .select('*,products(name,sku),uoms(abbreviation)').eq('grn_id', id);
      final meta = await VoucherMeta.fetch(orgId: _orgId ?? '', customerId: null, createdById: grn['created_by'] as String?);
      bool datesEd = false;
      try { final c = await client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.voucher_dates_editable').maybeSingle(); datesEd = (c?['value'] as String?) == 'true'; } catch (_) {}
      bool superviseEn = false;
      try { final c = await client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.grn_supervise_flow').maybeSingle(); superviseEn = (c?['value'] as String?) == 'true'; } catch (_) {}
      // Linked purchase invoice(s) — shown as a clickable chip when invoiced.
      List<Map<String, dynamic>> pis = [];
      try {
        final r = await client.from('purchase_invoices').select('id,voucher_number').eq('grn_id', id);
        pis = List<Map<String, dynamic>>.from(r as List);
      } catch (_) {}
      setState(() {
        _detail = Map<String, dynamic>.from(grn);
        _items = List<Map<String, dynamic>>.from(items);
        _meta = meta; _detailLoading = false; _datesEditable = datesEd;
        _superviseEnabled = superviseEn;
        _linkedPis = pis;
        _initReceivedCtrls();
      });
    } catch (e) { _showSnack('Detail error: $e'); setState(() => _detailLoading = false); }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'org_id': _orgId, 'voucher_id': id, 'voucher_type': 'GRN',
        'action': action, 'details': details, 'performed_by': ref.read(currentUserProvider)?.id,
      });
    } catch (e) { print('[Audit GRN] $e'); }
  }

  Future<bool> _isPoApprovalRequired(String orgId) async {
    try {
      final r = await Supabase.instance.client.from('app_config')
          .select('value').eq('org_id', orgId).eq('key', 'org.po_approval_required').maybeSingle();
      return (r?['value'] as String?) == 'true';
    } catch (_) { return false; }
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    // Fetch confirmed POs not yet fully received
    try {
      final approvalRequired = await _isPoApprovalRequired(orgId);
      var poQuery = Supabase.instance.client.from('purchase_orders')
          .select('id,voucher_number,voucher_date,supplier_id,suppliers(name)')
          .eq('org_id', orgId).eq('branch_id', branchId)
          .inFilter('status', ['ordered', 'partially_received'])
          .filter('voided_at', 'is', null);
      if (approvalRequired) poQuery = poQuery.not('approved_at', 'is', null);
      final pos = await poQuery.order('voucher_date', ascending: false);
      var available = List<Map<String, dynamic>>.from(pos as List);
      // Hide POs that already have an open (draft) GRN — one open receipt per PO at a time.
      // A PO reappears (with remaining qty) once that GRN's receipt is confirmed, or if the draft is deleted.
      if (available.isNotEmpty) {
        final draftGrns = await Supabase.instance.client.from('purchase_grns')
            .select('po_id')
            .eq('org_id', orgId).eq('branch_id', branchId)
            .eq('status', 'draft');
        final blocked = <String>{
          for (final g in (draftGrns as List)) if (g['po_id'] != null) g['po_id'] as String
        };
        if (blocked.isNotEmpty) {
          available = available.where((p) => !blocked.contains(p['id'] as String)).toList();
        }
      }
      if (available.isEmpty) { _showSnack('No POs open for a new GRN (all received, or pending an unconfirmed GRN).'); return; }
      final picked = await showDialog<Map<String, dynamic>?>(context: context,
          builder: (_) => _PoPickerDialog(pos: available));
      if (picked == null) return;
      await _createGrnFromPo(picked);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _createGrnFromPo(Map<String, dynamic> po) async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) return;
    setState(() => _detailLoading = true);
    SavingOverlay.show(context, label: 'Creating…');
    try {
      // Check existing GRN for this PO (allow multiple GRNs for partial)
      final poId = po['id'] as String;
      final poItems = await Supabase.instance.client.from('purchase_order_items')
          .select('*,products(name,sku),uoms(abbreviation)').eq('purchase_order_id', poId);
      if ((poItems as List).isEmpty) { setState(() => _detailLoading = false); _showSnack('PO has no items'); return; }
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'GRN', 'p_year': year});
      final vNum = 'GRN-$year-${nextNum.toString().padLeft(4, '0')}';
      final grnId = 'grn_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('purchase_grns').insert({
        'id': grnId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': vNum, 'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'po_id': poId, 'supplier_id': po['supplier_id'],
        'status': 'draft', 'is_locked': false,
        'created_by': ref.read(currentUserProvider)?.id,
      });
      final grniRows = <Map<String, dynamic>>[];
      var seq = 0;
      for (final item in poItems) {
        final pid = item['id'] as String;
        final ordered  = (item['quantity_ordered'] as num?)?.toDouble() ?? 0;
        final alreadyReceived = (item['quantity_received'] as num?)?.toDouble() ?? 0;
        final remaining = ordered - alreadyReceived;
        if (remaining <= 0) continue;  // already fully received — skip
        grniRows.add({
          'id': 'grni_${DateTime.now().microsecondsSinceEpoch}_${seq++}',
          'grn_id': grnId, 'po_item_id': pid,
          'product_id': item['product_id'], 'uom_id': item['uom_id'],
          'qty_ordered': remaining, 'qty_received': remaining,  // both = remaining unfulfilled qty
        });
      }
      // Batched: one insert for all GRN lines instead of one per line.
      if (grniRows.isNotEmpty) {
        await Supabase.instance.client.from('purchase_grn_items').insert(grniRows);
      }
      await _logAudit(grnId, 'created', 'GRN $vNum from PO ${po['voucher_number']}');
      _showSnack('$vNum created — adjust received qtys then confirm');
      await _loadList();
      _loadDetail(grnId);
    } catch (e) { setState(() => _detailLoading = false); _showSnack('Failed: $e'); }
    finally { SavingOverlay.hide(); }
  }

  Future<void> _saveReceivedQty(String itemId) async {
    final qty = double.tryParse(_receivedCtrl[itemId]?.text ?? '') ?? 0;
    final idx = _items.indexWhere((i) => i['id'] == itemId);
    final old = idx >= 0 ? ((_items[idx]['qty_received'] as num?)?.toDouble() ?? 0) : 0.0;
    if (idx >= 0 && old == qty) return; // no change — skip write + log
    try {
      await Supabase.instance.client.from('purchase_grn_items').update({'qty_received': qty}).eq('id', itemId);
      final pname = idx >= 0 ? (_items[idx]['products']?['name'] as String? ?? 'item') : 'item';
      setState(() {
        if (idx >= 0) _items[idx]['qty_received'] = qty;
      });
      await _logAudit(_detail['id'] as String, 'edited', '$pname received qty: ${old.toStringAsFixed(2)} -> ${qty.toStringAsFixed(2)}');
    } catch (e) { _showSnack('Failed to save: $e'); }
  }

  /// Batched equivalent of looping [_saveReceivedQty] over every line: one
  /// upsert for all changed lines + one audit insert, instead of ~2 round trips
  /// per line. Only changed lines are written.
  Future<void> _saveAllReceivedQty() async {
    final userId = ref.read(currentUserProvider)?.id;
    final updates = <Map<String, dynamic>>[];
    final audits = <Map<String, dynamic>>[];
    for (final row in _items) {
      final itemId = row['id'] as String;
      final qty = double.tryParse(_receivedCtrl[itemId]?.text ?? '') ?? 0;
      final old = (row['qty_received'] as num?)?.toDouble() ?? 0;
      if (old == qty) continue; // no change — skip write + log
      updates.add({'id': itemId, 'qty_received': qty});
      final pname = (row['products']?['name'] as String? ?? 'item');
      audits.add({
        'org_id': _orgId, 'voucher_id': _detail['id'], 'voucher_type': 'GRN',
        'action': 'edited',
        'details': '$pname received qty: ${old.toStringAsFixed(2)} -> ${qty.toStringAsFixed(2)}',
        'performed_by': userId,
      });
    }
    if (updates.isEmpty) return;
    SavingOverlay.show(context, label: 'Saving…');
    try {
      await Supabase.instance.client
          .from('purchase_grn_items')
          .upsert(updates, onConflict: 'id');
      setState(() {
        for (final u in updates) {
          final idx = _items.indexWhere((i) => i['id'] == u['id']);
          if (idx >= 0) _items[idx]['qty_received'] = u['qty_received'];
        }
      });
      if (audits.isNotEmpty) {
        try {
          await Supabase.instance.client.from('voucher_audit_log').insert(audits);
        } catch (_) {}
      }
    } catch (e) {
      _showSnack('Failed to save: $e');
    } finally {
      SavingOverlay.hide();
    }
  }

  void _enterAdjust() {
    _initReceivedCtrls(); // reset editors to current received quantities
    setState(() => _adjustMode = true);
  }

  void _cancelAdjust() {
    _initReceivedCtrls();
    setState(() => _adjustMode = false);
  }

  /// Save edits to a posted (received) GRN. Each changed line is sent to
  /// adjust_grn_received_qty, which posts the DELTA correction (stock, cost
  /// layer, GL and PO progress) so nothing drifts.
  Future<void> _saveAdjustments() async {
    if (_adjustBusy) return;
    final lines = <Map<String, dynamic>>[];
    for (final row in _items) {
      final id = row['id'] as String;
      final newQty = double.tryParse(_receivedCtrl[id]?.text ?? '');
      if (newQty == null) continue;
      final old = (row['qty_received'] as num?)?.toDouble() ?? 0;
      if (newQty == old) continue;
      lines.add({'item_id': id, 'qty': newQty});
    }
    if (lines.isEmpty) { setState(() => _adjustMode = false); return; }
    setState(() => _adjustBusy = true);
    SavingOverlay.show(context, label: 'Adjusting…');
    try {
      await Supabase.instance.client.rpc('adjust_grn_received_qty', params: {
        'p_grn_id': _detail['id'],
        'p_lines': lines,
        'p_user_id': ref.read(currentUserProvider)?.id,
      });
      _showSnack('Quantities adjusted — stock, cost and GL updated');
      setState(() => _adjustMode = false);
      _loadDetail(_detail['id'] as String);
      _loadList();
    } catch (e) {
      _showSnack(friendlyError('adjust the GRN', e));
    } finally {
      SavingOverlay.hide();
      if (mounted) setState(() => _adjustBusy = false);
    }
  }

  Future<void> _confirmReceipt() async {
    if (_items.isEmpty) { _showSnack('No items to receive'); return; }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Confirm Goods Receipt?'),
      content: const Text('Stock will be added to inventory and this GRN will be locked.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Confirm'))],
    ));
    if (ok != true) return;
    // Save any pending received qty edits first (batched).
    await _saveAllReceivedQty();
    if (_confirmBusy) return;
    setState(() => _confirmBusy = true);
    SavingOverlay.show(context, label: 'Posting…');
    final grnId = _detail['id'] as String;
    try {
      // Atomic + idempotent: confirm_grn claims the GRN (status guard + lock),
      // then posts movements, stock, PO progress, PO status, GRN status and the
      // audit-log row in ONE transaction. Double-clicks / retries error cleanly.
      await Supabase.instance.client.rpc('confirm_grn', params: {
        'p_grn_id': grnId,
        'p_user_id': ref.read(currentUserProvider)?.id,
      });
      _showSnack('Receipt confirmed — stock added to inventory');
      _loadDetail(grnId); _loadList();
    } catch (e) {
      _showSnack('Failed: $e');
    } finally {
      SavingOverlay.hide();
      if (mounted) setState(() => _confirmBusy = false);
    }
  }

  Future<void> _toggleLock() async {
    if (_isLocked && !_canUnlock) { _showSnack('Only admins can unlock'); return; }
    final newLocked = !_isLocked;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      await Supabase.instance.client.from('purchase_grns').update({
        'is_locked': newLocked, 'locked_by': newLocked ? userId : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, newLocked ? 'locked' : 'unlocked', null);
      _showSnack(newLocked ? 'Locked' : 'Unlocked');
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // ── Supervision: a NON-BLOCKING admin review mark. Independent of posting —
  // the GRN confirms and moves stock regardless of whether it is supervised.
  Future<void> _supervise() async {
    if (!_isAdmin) { _showSnack('Only admins can supervise'); return; }
    if (_superviseBusy) return;
    setState(() => _superviseBusy = true);
    final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name;
    final now = DateTime.now().toUtc().toIso8601String();
    // Snapshot the supervisor's signature + org stamp so the printed GRN can
    // render them under "Supervised By" (same approach as the SI admin review).
    String? sigUrl; String? stampUrl;
    try { final u = await Supabase.instance.client.from('users').select('signature_url').eq('id', userId ?? '').maybeSingle(); sigUrl = u?['signature_url'] as String?; } catch (_) {}
    try { final s = await Supabase.instance.client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.stamp_url').maybeSingle(); stampUrl = s?['value'] as String?; } catch (_) {}
    try {
      await Supabase.instance.client.from('purchase_grns').update({
        'supervised_by': userId, 'supervised_at': now,
        'supervised_by_name': userName,
        'supervised_signature_url': sigUrl,
        'supervised_stamp_url': stampUrl,
        'updated_at': now,
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'supervised', 'Supervised by ${userName ?? userId ?? 'admin'}');
      if (mounted) setState(() {
        _detail['supervised_by'] = userId; _detail['supervised_at'] = now;
        _detail['supervised_by_name'] = userName;
        _detail['supervised_signature_url'] = sigUrl;
        _detail['supervised_stamp_url'] = stampUrl;
      });
      _showSnack('Marked as supervised');
    } catch (e) { _showSnack('Failed: $e'); }
    finally { if (mounted) setState(() => _superviseBusy = false); }
  }

  Future<void> _clearSupervision() async {
    if (!_isAdmin) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Clear supervision?'),
      content: const Text('Remove the supervised mark on this GRN? This does not affect the receipt or stock.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Clear'))],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('purchase_grns').update({
        'supervised_by': null, 'supervised_at': null,
        'supervised_by_name': null, 'supervised_signature_url': null, 'supervised_stamp_url': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'unsupervised', null);
      if (mounted) setState(() {
        _detail['supervised_by'] = null; _detail['supervised_at'] = null;
        _detail['supervised_by_name'] = null; _detail['supervised_signature_url'] = null; _detail['supervised_stamp_url'] = null;
      });
      _showSnack('Supervision cleared');
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _delete() async {
    if (!_canDelete) return;
    try {
      final pis = await Supabase.instance.client.from('purchase_invoices').select('id,voucher_number').eq('grn_id', _detail['id'] as String);
      if ((pis as List).isNotEmpty) { _showSnack('Cannot delete: PI ${pis.first['voucher_number']} exists. Delete PI first.'); return; }
    } catch (e) { _showSnack('Check error: $e'); return; }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete GRN?'),
      content: Text('Delete ${_detail['voucher_number']}? Stock will be reversed if already confirmed.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    final grnId = _detail['id'] as String;
    try {
      // Atomic: reverses stock + PO progress (if confirmed), writes the audit
      // row, and deletes the GRN in ONE transaction. Errors cleanly if a PI
      // exists or the GRN is already gone.
      await Supabase.instance.client.rpc('delete_grn', params: {
        'p_grn_id': grnId,
        'p_user_id': ref.read(currentUserProvider)?.id,
      });
      _showSnack('Deleted');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final sup = _detail['suppliers'] as Map?;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Goods Receipt Note',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null,
      customerOrSupplier: sup?['name'] as String?,
      customerAddress: sup?['address'] as String?,
      customerContact: sup?['contact_person'] as String?,
      customerPhone: (sup?['contact_number'] ?? sup?['phone']) as String?,
      lines: _isDraft ? [] : _items.map((it) => VoucherLine(
        product: it['products']?['name'] as String? ?? '-',
        sku: it['products']?['sku'] as String?, uom: it['uoms']?['abbreviation'] as String?,
        qty: (it['qty_received'] as num?)?.toDouble() ?? 0,
      )).toList(),
      preparedBy: _meta.preparedBy, footerNote: _meta.purchaseFooterNote ?? _meta.footerNote,
      relatedRefs: _detail['purchase_orders']?['voucher_number'] != null ? {'PO #': _detail['purchase_orders']['voucher_number'] as String} : null,
      // Middle sign-off becomes "Supervised By" when the GRN supervise flow is on.
      checkedByLabel: _superviseEnabled ? 'Supervised By' : null,
      checkedByName: _detail['supervised_by_name'] as String?,
      checkedByAt: _detail['supervised_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['supervised_at'] as String).toLocal()) : null,
      checkedBySignatureUrl: _detail['supervised_signature_url'] as String?,
      checkedByStampUrl: _detail['supervised_stamp_url'] as String?,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) { _selectedId = null; _detail = {}; _items = []; _loadList(); });
    return Container(color: AppTheme.background, child: CollapsibleListPane(
      paneWidth: 360,
      listChild: _buildList(),
      detailChild: _selectedId == null
          ? const Center(child: Text('Select or create a GRN', style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
          : _buildDetail(),
    ));
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _grns.where((r) {
      final matchSearch = q.isEmpty || (r['voucher_number'] as String? ?? '').toLowerCase().contains(q) || ((r['suppliers']?['name'] as String?) ?? '').toLowerCase().contains(q) || ((r['purchase_orders']?['voucher_number'] as String?) ?? '').toLowerCase().contains(q);
      final st = r['status'] as String? ?? 'draft';
      final stNorm = st == 'saved' ? 'received' : st; // fold legacy 'saved'
      final matchStatus = _statusFilter == 'all' || stNorm == _statusFilter;
      final supervised = r['supervised_at'] != null;
      final matchSup = !_superviseEnabled || _supFilter == 'all'
          || (_supFilter == 'yes' && supervised)
          || (_supFilter == 'no' && !supervised);
      return matchSearch && matchStatus && matchSup;
    }).toList();
    return Container(decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))), child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 12), child: Row(children: [
        const Expanded(child: Text('Goods Receipt Notes', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32), onPressed: _createNew, tooltip: 'New GRN'),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: TextField(
        decoration: const InputDecoration(hintText: 'Search GRN / supplier / PO#…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
        onChanged: (v) => setState(() => _search = v))),
      const SizedBox(height: 8),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Wrap(spacing: 6, runSpacing: 6, children: [
        _GrnFilterTab(label: 'All', value: 'all', current: _statusFilter, onTap: (v) => setState(() => _statusFilter = v)),
        _GrnFilterTab(label: 'Draft', value: 'draft', current: _statusFilter, onTap: (v) => setState(() => _statusFilter = v)),
        _GrnFilterTab(label: 'Received', value: 'received', current: _statusFilter, onTap: (v) => setState(() => _statusFilter = v)),
        _GrnFilterTab(label: 'Partial', value: 'partially_received', current: _statusFilter, onTap: (v) => setState(() => _statusFilter = v)),
        _GrnFilterTab(label: 'Invoiced', value: 'invoiced', current: _statusFilter, onTap: (v) => setState(() => _statusFilter = v)),
      ])),
      if (_superviseEnabled) ...[
        const SizedBox(height: 8),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
          const Text('Supervision', style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: [
            _GrnFilterTab(label: 'All', value: 'all', current: _supFilter, onTap: (v) => setState(() => _supFilter = v)),
            _GrnFilterTab(label: 'Supervised', value: 'yes', current: _supFilter, onTap: (v) => setState(() => _supFilter = v)),
            _GrnFilterTab(label: 'Pending', value: 'no', current: _supFilter, count: _grns.where((r) => r['supervised_at'] == null && (r['status'] as String? ?? 'draft') != 'draft').length, onTap: (v) => setState(() => _supFilter = v)),
          ])),
        ])),
      ],
      const SizedBox(height: 12),
      Expanded(child: _listLoading ? const Center(child: BrandSpinner())
          : filtered.isEmpty ? const Center(child: Text('No GRNs yet.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = filtered[i]; final sel = r['id'] == _selectedId;
                final status = r['status'] as String? ?? 'draft';
                final locked = r['is_locked'] as bool? ?? false;
                return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.06),
                  title: Row(children: [
                    Expanded(child: Text(r['voucher_number'] as String? ?? '-', style: TextStyle(fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : null))),
                    if (_superviseEnabled && r['supervised_at'] != null) ...[
                      const _GrnSupListBadge(),
                      const SizedBox(width: 4),
                    ],
                    _GrnBadge(status: status, locked: locked),
                  ]),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(r['suppliers']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 11)),
                    if (r['purchase_orders']?['voucher_number'] != null) Text('← ${r['purchase_orders']['voucher_number']}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ]),
                  onTap: () => _loadDetail(r['id'] as String));
              })),
    ]));
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: BrandSpinner());
    final sup = _detail['suppliers'] as Map?;
    final poVoucher = _detail['purchase_orders']?['voucher_number'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_detail['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Goods Receipt Note', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ])),
          if (_isDraft && !_isLocked) ...[
            ElevatedButton.icon(icon: const Icon(Icons.check_circle_outline, size: 16),
                label: Text(_confirmBusy ? 'Confirming…' : 'Confirm Receipt'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
                onPressed: _confirmBusy ? null : _confirmReceipt),
            const SizedBox(width: 8),
          ],
          if (_adjustMode) ...[
            ElevatedButton.icon(icon: const Icon(Icons.save_outlined, size: 16),
                label: Text(_adjustBusy ? 'Saving…' : 'Save changes'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
                onPressed: _adjustBusy ? null : _saveAdjustments),
            const SizedBox(width: 6),
            TextButton(onPressed: _adjustBusy ? null : _cancelAdjust, child: const Text('Cancel')),
            const SizedBox(width: 8),
          ] else if (_canAdjust) ...[
            OutlinedButton.icon(icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit quantities'),
                onPressed: _enterAdjust),
            const SizedBox(width: 8),
          ],
          if (_superviseEnabled && _isAdmin) ...[
            if (_detail['supervised_at'] == null)
              OutlinedButton.icon(
                icon: _superviseBusy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_user_outlined, size: 16, color: AppTheme.primary),
                label: const Text('Supervise'),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.primary, side: const BorderSide(color: AppTheme.primary)),
                onPressed: _superviseBusy ? null : _supervise)
            else
              TextButton.icon(
                icon: const Icon(Icons.verified, size: 16, color: AppTheme.success),
                label: const Text('Supervised', style: TextStyle(color: AppTheme.success)),
                onPressed: _clearSupervision),
            const SizedBox(width: 8),
          ],
          if (_canEditDate)
            IconButton(icon: const Icon(Icons.edit_calendar_outlined, color: AppTheme.textSecondary), tooltip: 'Edit date', onPressed: _pickDate),
          if (!_isDraft || !_isLocked || _canUnlock)
            IconButton(icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
                tooltip: _isLocked ? 'Unlock (admin)' : 'Lock', onPressed: _toggleLock),
          IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), onPressed: _print),
          if (_canDelete) IconButton(icon: const Icon(Icons.delete_outline, color: AppTheme.danger), onPressed: _delete),
        ])),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          _GrnChip(label: 'Supplier', value: sup?['name'] as String? ?? '-'),
          _GrnChip(label: 'Date', value: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
          _GrnChip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
          if (poVoucher != null) _GrnChip(label: 'PO #', value: poVoucher),
          _GrnChip(label: 'Status', value: _prettyStatus(_detail['status'] as String?)),
          // Clickable invoice chip(s): jump straight to the PI raised on this GRN.
          for (final pi in _linkedPis)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => context.go('/erp/purchase-invoices?focus=${pi['id']}'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.purple.withOpacity(0.35))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.receipt_long, size: 13, color: Colors.purple),
                  const SizedBox(width: 5),
                  Text('Invoice: ${pi['voucher_number'] ?? pi['id']}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.purple)),
                  const SizedBox(width: 3),
                  const Icon(Icons.open_in_new, size: 11, color: Colors.purple),
                ]),
              ),
            ),
          if (_isLocked) const _GrnLockedChip(),
          if (_superviseEnabled && _detail['supervised_at'] != null)
            _GrnSupervisedChip(date: DateFormat('d MMM yyyy').format(DateTime.parse(_detail['supervised_at'] as String).toLocal())),
        ]),
        if (_isDraft && !_isLocked) Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: Colors.green.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.withOpacity(0.25))),
          child: const Row(children: [Icon(Icons.edit_note, size: 15, color: Colors.green), SizedBox(width: 8),
            Expanded(child: Text('Adjust received quantities below, then click "Confirm Receipt" to move stock.', style: TextStyle(fontSize: 12, color: Colors.green)))])),
        if (_adjustMode) Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.primary.withOpacity(0.25))),
          child: const Row(children: [Icon(Icons.tune, size: 15, color: AppTheme.primary), SizedBox(width: 8),
            Expanded(child: Text('Editing a posted GRN. Changing a received quantity re-posts a correction — stock, cost layer and GL all move by the difference. Then click "Save changes".', style: TextStyle(fontSize: 12, color: AppTheme.primary)))])),
        if (_isConfirmed && !_isLocked && _linkedPis.isNotEmpty && _isAdmin) Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: Colors.purple.withOpacity(0.06), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.purple.withOpacity(0.25))),
          child: const Row(children: [Icon(Icons.info_outline, size: 15, color: Colors.purple), SizedBox(width: 8),
            Expanded(child: Text('This GRN is invoiced, so quantities are locked to keep GRNI and payables balanced. Adjust or delete the linked invoice first to edit the received quantities.', style: TextStyle(fontSize: 12, color: Colors.purple)))])),
        const SizedBox(height: 16),
        // Items table
        Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
              child: const Row(children: [
                Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text('Ordered', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                Expanded(flex: 2, child: Text('Received', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
              ])),
            const Divider(height: 1),
            if (_items.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('No items', style: TextStyle(color: AppTheme.textSecondary))),
            ..._items.map((it) {
              final id = it['id'] as String;
              final ordered = (it['qty_ordered'] as num?)?.toDouble() ?? 0;
              final received = (it['qty_received'] as num?)?.toDouble() ?? 0;
              return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13)),
                    if (it['products']?['sku'] != null) Text(it['products']!['sku'] as String, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ])),
                  Expanded(flex: 1, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text(ordered.toStringAsFixed(ordered % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: (_isDraft || _adjustMode)
                      ? TextField(controller: _receivedCtrl[id],
                          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)),
                          textAlign: TextAlign.right, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          onSubmitted: _isDraft ? (_) => _saveReceivedQty(id) : null)
                      : Text(received.toStringAsFixed(received % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary))),
                ]));
            }),
          ])),
        if (_superviseEnabled) ...[
          const SizedBox(height: 16),
          VoucherDocsPanel(
            voucherType: 'GRN',
            voucherId: _selectedId ?? '',
            voucherNumber: _detail['voucher_number'] as String? ?? '-',
            bucket: 'grn-documents',
            orgId: _orgId ?? '',
            userId: ref.read(currentUserProvider)?.id,
            canWrite: true,
          ),
          const SizedBox(height: 12),
          VoucherRemarksPanel(
            voucherType: 'GRN',
            voucherId: _selectedId ?? '',
            orgId: _orgId ?? '',
            userId: ref.read(currentUserProvider)?.id,
            userName: ref.read(currentUserProvider)?.name,
            canWrite: true,
          ),
        ],
        const SizedBox(height: 16),
        _GrnAuditTrail(voucherId: _selectedId ?? ''),
      ]))),
    ]);
  }
}

class _PoPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> pos;
  const _PoPickerDialog({required this.pos});
  @override State<_PoPickerDialog> createState() => _PoPickerDialogState();
}
class _PoPickerDialogState extends State<_PoPickerDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final filtered = widget.pos.where((p) => q.isEmpty || (p['voucher_number'] as String? ?? '').toLowerCase().contains(q) || ((p['suppliers']?['name'] as String?) ?? '').toLowerCase().contains(q)).toList();
    return AlertDialog(
      title: Text('Select Confirmed PO  ·  ${widget.pos.length} available'),
      content: SizedBox(width: 520, height: 440, child: Column(children: [
        TextField(decoration: const InputDecoration(hintText: 'Search PO # / supplier', prefixIcon: Icon(Icons.search, size: 18), isDense: true), onChanged: (v) => setState(() => _q = v), autofocus: true),
        const SizedBox(height: 12),
        Expanded(child: filtered.isEmpty ? const Center(child: Text('No confirmed POs.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) { final p = filtered[i]; return ListTile(dense: true,
                title: Text(p['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${p['suppliers']?['name'] ?? '-'}  ·  ${p['status'] ?? ''}', style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(context, p)); })),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
    );
  }
}

class _GrnChip extends StatelessWidget { final String label, value; const _GrnChip({required this.label, required this.value}); @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)), child: Row(mainAxisSize: MainAxisSize.min, children: [Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)), Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12))])); }
class _GrnLockedChip extends StatelessWidget { const _GrnLockedChip(); @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.4))), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.lock_outline, size: 12, color: Colors.orange), SizedBox(width: 4), Text('Locked', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w600))])); }
class _GrnSupListBadge extends StatelessWidget { const _GrnSupListBadge(); @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: AppTheme.success.withOpacity(0.12), borderRadius: BorderRadius.circular(4)), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.verified, size: 10, color: AppTheme.success), SizedBox(width: 2), Text('Supervised', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.success))])); }
class _GrnSupervisedChip extends StatelessWidget { final String date; const _GrnSupervisedChip({required this.date}); @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: AppTheme.success.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.success.withOpacity(0.4))), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.verified, size: 12, color: AppTheme.success), const SizedBox(width: 4), Text('Supervised · $date', style: const TextStyle(fontSize: 11, color: AppTheme.success, fontWeight: FontWeight.w600))])); }
class _GrnBadge extends StatelessWidget { final String status; final bool locked; const _GrnBadge({required this.status, required this.locked}); @override Widget build(BuildContext context) { Color bg; Color fg; String label; switch (status) { case 'received': case 'saved': bg = AppTheme.success.withOpacity(0.12); fg = AppTheme.success; label = 'Received'; break; case 'partially_received': bg = AppTheme.warning.withOpacity(0.14); fg = AppTheme.warning; label = 'Partial'; break; case 'invoiced': bg = Colors.purple.withOpacity(0.12); fg = Colors.purple; label = 'Invoiced'; break; default: bg = Colors.orange.withOpacity(0.12); fg = Colors.orange; label = 'Draft'; } return Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)), child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg))); } }
class _GrnFilterTab extends StatelessWidget { final String label, value, current; final int count; final ValueChanged<String> onTap; const _GrnFilterTab({required this.label, required this.value, required this.current, required this.onTap, this.count = 0}); @override Widget build(BuildContext context) { final active = value == current; return GestureDetector(onTap: () => onTap(value), child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: active ? AppTheme.primary : AppTheme.background, borderRadius: BorderRadius.circular(12), border: Border.all(color: active ? AppTheme.primary : AppTheme.border)), child: Row(mainAxisSize: MainAxisSize.min, children: [Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)), if (count > 0) ...[const SizedBox(width: 5), Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), constraints: const BoxConstraints(minWidth: 15), decoration: BoxDecoration(color: active ? Colors.white.withOpacity(0.25) : AppTheme.warning, borderRadius: BorderRadius.circular(8)), child: Text('$count', textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white, height: 1.3)))]]))); } }

class _GrnAuditTrail extends StatelessWidget {
  final String voucherId; const _GrnAuditTrail({required this.voucherId});
  @override Widget build(BuildContext context) {
    if (voucherId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<dynamic>>(
      future: Supabase.instance.client.from('voucher_audit_log').select('*, users(name)').eq('voucher_id', voucherId).eq('voucher_type', 'GRN').order('created_at', ascending: false).limit(20),
      builder: (ctx, snap) {
        if (!snap.hasData || (snap.data as List).isEmpty) return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)), child: const Row(children: [Icon(Icons.history, size: 14, color: AppTheme.textSecondary), SizedBox(width: 8), Text('No activity logged yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))]));
        final entries = List<Map<String, dynamic>>.from(snap.data!);
        return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)), const SizedBox(height: 8),
            ...entries.map((e) { final action = e['action'] as String? ?? '-'; final who = (e['users']?['name'] as String?) ?? ''; final ts = e['created_at'] != null ? DateFormat('d MMM HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : ''; final details = e['details'] as String? ?? ''; Color color; switch (action) { case 'created': color = AppTheme.primary; break; case 'confirmed': color = AppTheme.success; break; case 'deleted': color = AppTheme.danger; break; case 'locked': color = Colors.orange; break; case 'unlocked': color = Colors.orange; break; case 'edited': color = AppTheme.warning; break; case 'supervised': color = AppTheme.success; break; case 'unsupervised': color = AppTheme.textSecondary; break; default: color = AppTheme.textSecondary; } return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.history, size: 13, color: color), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Text(action, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)), if (who.isNotEmpty) Text('  by $who', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)), const Spacer(), Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]), if (details.isNotEmpty) Text(details, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]))])); }),
          ]));
      });
  }
}
