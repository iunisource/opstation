import 'package:flutter/material.dart';
import '../../../core/widgets/saving_overlay.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/layout/collapsible_list_pane.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../services/voucher_meta.dart';
import '../../../core/permissions/access_control.dart';
import '../../../core/widgets/product_picker.dart';

class ErpPurchaseScreen extends ConsumerStatefulWidget {
  const ErpPurchaseScreen({super.key, this.focusId, this.seedProductId, this.seedQty, this.seedBranchId});
  final String? focusId;
  final String? seedProductId; // from Low Stock "Make PO" — seed a new PO line
  final String? seedQty;
  final String? seedBranchId;
  @override
  ConsumerState<ErpPurchaseScreen> createState() => _ErpPurchaseScreenState();
}

class _ErpPurchaseScreenState extends ConsumerState<ErpPurchaseScreen> {
  List<Map<String, dynamic>> _pos = [];
  List<Map<String, dynamic>> _products = [];
  Map<String, double> _prodCost = {}; // product_id -> cost_price (for the Rates column)
  bool _hideGroupsEnabled = false;
  Map<String, Set<String>> _hiddenByBranch = {};
  List<Map<String, dynamic>> _uoms = [];
  List<Map<String, dynamic>> _suppliers = [];
  String? _selectedId;
  Map<String, dynamic> _detail = {};
  List<Map<String, dynamic>> _items = [];
  VoucherMeta _meta = VoucherMeta();
  bool _approvalRequired = false;       // per-open PO (detail)
  bool _orgApprovalRequired = false;   // org toggle (drives list pending chips)
  bool _showStockConsumption = false;
  bool _showFgStock = false; // org.po_fg_stock — finished-goods stock per raw line
  Map<String, Map<String, dynamic>> _lineMetrics = {};
  bool _hasGrn = false; // true if any GRN exists against this PO (cascade lock)
  bool _listLoading = true;
  bool _detailLoading = false;
  int _auditRefresh = 0; // bump to force the audit trail to reload
  bool _datesEditable = false;
  String _search = '';
  String _filter = 'all';
  String? _addProductId;
  String? _addUomId;
  final _addQtyCtrl = TextEditingController(text: '1');
  final _addQtyFocus = FocusNode();
  final Map<String, TextEditingController> _lineQtyCtrls = {};
  final Map<String, TextEditingController> _lineRateCtrls = {};
  final Map<String, TextEditingController> _lineDescCtrls = {}; // free-text item descriptions

  @override
  void initState() {
    super.initState();
    _loadList();
    _loadLookups();
    if (widget.focusId != null) _loadDetail(widget.focusId!);
    if (widget.seedProductId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _seedNewPo());
    }
  }

  // Seed a brand-new PO from the Low Stock report's "Make PO": pick a supplier,
  // create the draft, then auto-add the shortfall product line.
  Future<void> _seedNewPo() async {
    if (_suppliers.isEmpty || _products.isEmpty) { await _loadLookups(); }
    await _createNew(); // supplier pick + create + load detail
    final poId = _detail['id'] as String?;
    if (poId == null) return; // user cancelled the supplier picker
    // seedProductId / seedQty may be comma-separated for a bulk "Make PO".
    final ids = (widget.seedProductId ?? '').split(',').where((e) => e.trim().isNotEmpty).toList();
    final qtys = (widget.seedQty ?? '').split(',');
    for (var i = 0; i < ids.length; i++) {
      final pid = ids[i].trim();
      final prod = _products.firstWhere((p) => p['id'] == pid, orElse: () => {});
      if (prod.isEmpty) continue;
      _addProductId = pid;
      _addUomId = prod['base_uom_id'] as String?;
      _addQtyCtrl.text = (i < qtys.length && qtys[i].trim().isNotEmpty) ? qtys[i].trim() : '1';
      await _addItem();
    }
    if (mounted) setState(() {});
  }
  @override
  void dispose() {
    for (final c in _lineQtyCtrls.values) { c.dispose(); }
    for (final c in _lineRateCtrls.values) { c.dispose(); }
    for (final c in _lineDescCtrls.values) { c.dispose(); }
    _addQtyCtrl.dispose();
    _addQtyFocus.dispose();
    super.dispose();
  }

  // ── Rates column (per-PO, remembered in purchase_orders.show_rates) ──────
  bool get _showRates => _detail['show_rates'] as bool? ?? false;
  double _costOf(String? productId) => _prodCost[productId] ?? 0;
  // The rate for a line: its saved unit_cost if set, else the product cost price.
  double _effRate(Map<String, dynamic> it) {
    final uc = (it['unit_cost'] as num?)?.toDouble() ?? 0;
    return uc > 0 ? uc : _costOf(it['product_id'] as String?);
  }
  double get _grandTotal => _items.fold(0.0, (s, it) =>
      s + ((it['quantity_ordered'] as num?)?.toDouble() ?? 0) * _effRate(it));
  double get _totalQty => _items.fold(0.0, (s, it) =>
      s + ((it['quantity_ordered'] as num?)?.toDouble() ?? 0));

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  List<Map<String, dynamic>> get _visibleProducts {
    if (!_hideGroupsEnabled) return _products;
    final bid = ref.read(selectedBranchProvider)?['id'] as String?;
    final hidden = bid == null ? null : _hiddenByBranch[bid];
    if (hidden == null || hidden.isEmpty) return _products;
    return _products.where((p) => !hidden.contains(p['product_main_group'])).toList();
  }
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _detail['is_locked'] as bool? ?? false;
  bool get _isDraft  => !_isLocked;
  bool get _isVoided => _detail['voided_at'] != null;
  // Line items can be added/deleted while no GRN exists (standalone) and the PO
  // isn't voided. Once a GRN is raised, lines are cascade-locked — even for
  // admins. Editing an approved PO clears its approval (re-approval required).
  bool get _canEditLines => !_hasGrn && !_isVoided;
  bool get _canDelete { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canUnlock { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.masterAdmin || r == WebUserRole.admin; }
  bool get _canEditDate => (_datesEditable || _isAdmin) && !_isLocked && !_isVoided;
  bool get _canApprove {
    final access = ref.read(accessSyncProvider);
    if (access == null) {
      final r = ref.read(currentUserProvider)?.role;
      return r == WebUserRole.masterAdmin || r == WebUserRole.admin || r == WebUserRole.superAdmin;
    }
    return access.canViewReportAt('po_approve', _detail['branch_id'] as String?);
  }

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _pickDate() async {
    final cur = _detail['voucher_date'] != null ? DateTime.tryParse(_detail['voucher_date'] as String) : null;
    final picked = await showDatePicker(context: context, initialDate: cur ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked == null) return;
    final iso = DateFormat('yyyy-MM-dd').format(picked);
    try {
      await Supabase.instance.client.from('purchase_orders')
          .update({'voucher_date': iso, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', _detail['id']);
      if (mounted) setState(() => _detail['voucher_date'] = iso);
      await _logAudit(_detail['id'] as String, 'date_changed', 'Voucher date set to \$iso');
      _loadList();
    } catch (e) { _showSnack('Failed: \$e'); }
  }


  Future<void> _loadLookups() async {
    final orgId = _orgId; if (orgId == null) return;
    final client = Supabase.instance.client;
    final results = await Future.wait([
      client.from('products').select('id,name,sku,base_uom_id,product_main_group,cost_price,is_free_text').eq('org_id', orgId).eq('is_active', true).order('name').limit(10000),
      client.from('uoms').select().eq('org_id', orgId).order('name'),
    ]);
    // Paginated suppliers
    final List<Map<String, dynamic>> sup = [];
    var off = 0;
    while (true) {
      final p = await client.from('suppliers').select('id,name').eq('org_id', orgId).order('name').range(off, off + 999);
      sup.addAll(List<Map<String, dynamic>>.from(p));
      if (p.length < 1000) break;
      off += 1000;
    }
    bool hideOn = false; final Map<String, Set<String>> hiddenBy = {};
    try {
      final hc = await client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.hide_main_groups_by_branch').maybeSingle();
      hideOn = (hc?['value'] as String?) == 'true';
      if (hideOn) {
        final hr = await client.from('branch_hidden_main_groups').select('branch_id, main_group').eq('org_id', orgId);
        for (final r in hr as List) { (hiddenBy[r['branch_id'] as String] ??= <String>{}).add(r['main_group'] as String); }
      }
    } catch (_) {}
    final prods = List<Map<String, dynamic>>.from(results[0]);
    final costMap = {for (final p in prods) p['id'] as String: (p['cost_price'] as num? ?? 0).toDouble()};
    if (mounted) setState(() { _products = prods; _prodCost = costMap; _uoms = List<Map<String, dynamic>>.from(results[1]); _suppliers = sup; _hideGroupsEnabled = hideOn; _hiddenByBranch = hiddenBy; });
  }

  Future<void> _loadList() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null) return;
    setState(() => _listLoading = true);
    try {
      var q = Supabase.instance.client.from('purchase_orders')
          .select('id,voucher_number,voucher_date,status,is_locked,voided_at,approved_at,supplier_id,suppliers(name),branches(name)')
          .eq('org_id', orgId);
      if (branchId != null) q = q.eq('branch_id', branchId);
      final r = await q.order('voucher_date', ascending: false).order('voucher_number', ascending: false).limit(2000);
      bool orgApproval = false;
      try {
        final cfg = await Supabase.instance.client.from('app_config').select('value')
            .eq('org_id', orgId).eq('key', 'org.po_approval_required').maybeSingle();
        orgApproval = (cfg?['value'] as String?) == 'true';
      } catch (_) {}
      setState(() { _pos = List<Map<String, dynamic>>.from(r); _orgApprovalRequired = orgApproval; _listLoading = false; });
    } catch (e) { _showSnack('Load error: $e'); setState(() => _listLoading = false); }
  }

  Future<void> _loadDetail(String id) async {
    setState(() { _detailLoading = true; _selectedId = id; });
    try {
      final client = Supabase.instance.client;
      final po = await client.from('purchase_orders').select('*,suppliers(*),branches(name)').eq('id', id).single();
      final items = await client.from('purchase_order_items').select('*,products(name,sku),uoms(abbreviation)').eq('purchase_order_id', id);
      final meta = await VoucherMeta.fetch(orgId: _orgId ?? '', customerId: null, createdById: po['created_by'] as String?);
      final cfg = await client.from('app_config').select('key,value').eq('org_id', _orgId ?? '')
          .inFilter('key', ['org.po_approval_required', 'org.po_show_stock_consumption',
            'org.voucher_dates_editable', 'org.po_fg_stock', 'org.po_fg_branch_id']);
      bool approvalReq = false, showSC = false, datesEd = false, showFg = false;
      String fgBranch = 'all';
      for (final r in cfg as List) {
        if (r['key'] == 'org.po_approval_required') approvalReq = r['value'] == 'true';
        if (r['key'] == 'org.po_show_stock_consumption') showSC = r['value'] == 'true';
        if (r['key'] == 'org.voucher_dates_editable') datesEd = r['value'] == 'true';
        if (r['key'] == 'org.po_fg_stock') showFg = r['value'] == 'true';
        if (r['key'] == 'org.po_fg_branch_id') fgBranch = (r['value'] as String? ?? 'all');
      }
      final itemList = List<Map<String, dynamic>>.from(items);
      Map<String, Map<String, dynamic>> metrics = {};
      if (showSC) {
        final pids = itemList.map((it) => it['product_id'] as String).toSet().toList();
        if (pids.isNotEmpty) {
          try {
            final m = await client.rpc('rpc_po_line_metrics', params: {
              'p_org_id': _orgId ?? '', 'p_branch_id': po['branch_id'], 'p_product_ids': pids,
            });
            for (final r in m as List) {
              metrics[r['product_id'] as String] = {
                'on_hand': (r['on_hand'] as num?)?.toDouble() ?? 0,
                'avg': (r['avg_monthly_out'] as num?)?.toDouble() ?? 0,
              };
            }
          } catch (_) {}
        }
      }
      // ── Finished-goods stock per raw line (BOM reverse lookup) ────────────
      // raw product -> BOM(s) using it as a component -> the BOM's finished
      // product -> that FG's stock at the configured branch ('all' = summed).
      // All batched: 3 queries total regardless of line count.
      if (showFg) {
        try {
          final pids = itemList.map((it) => it['product_id'] as String).toSet().toList();
          if (pids.isNotEmpty) {
            final comps = await client.from('bom_components')
                .select('bom_id, product_id').inFilter('product_id', pids)
                .limit(10000);
            final bomIds = <String>{
              for (final c in (comps as List)) '${c['bom_id']}'
            }.toList();
            if (bomIds.isNotEmpty) {
              // Active BOMs only — a superseded assembly must not link a raw
              // to a finished good it no longer feeds.
              final heads = await client.from('bom_headers')
                  .select('id, product_id').eq('org_id', _orgId ?? '')
                  .eq('status', 'active')
                  .inFilter('id', bomIds);
              final bomFg = <String, String>{
                for (final h in (heads as List))
                  '${h['id']}': h['product_id'] as String
              };
              // raw -> set of FG products (a raw may feed multiple BOMs).
              final rawFgs = <String, Set<String>>{};
              for (final c in comps) {
                final fg = bomFg['${c['bom_id']}'];
                if (fg != null) {
                  (rawFgs[c['product_id'] as String] ??= {}).add(fg);
                }
              }
              final fgIds = rawFgs.values.expand((s) => s).toSet().toList();
              if (fgIds.isNotEmpty) {
                var sq = client.from('inventory_stock')
                    .select('product_id, quantity')
                    .eq('org_id', _orgId ?? '')
                    .inFilter('product_id', fgIds);
                if (fgBranch != 'all' && fgBranch.isNotEmpty) {
                  sq = sq.eq('branch_id', fgBranch);
                }
                final fgStock = <String, double>{};
                for (final s in (await sq) as List) {
                  final pid = s['product_id'] as String;
                  fgStock[pid] = (fgStock[pid] ?? 0) +
                      ((s['quantity'] as num?)?.toDouble() ?? 0);
                }
                rawFgs.forEach((raw, fgs) {
                  double total = 0;
                  for (final fg in fgs) {
                    total += fgStock[fg] ?? 0;
                  }
                  final m = metrics.putIfAbsent(raw, () => {});
                  m['fg_on_hand'] = total;
                  m['fg_count'] = fgs.length;
                });
              }
            }
          }
        } catch (_) {/* FG info is best-effort; the PO renders without it */}
      }
      bool hasGrn = false;
      try {
        final g = await client.from('purchase_grns').select('id').eq('po_id', id).limit(1);
        hasGrn = (g as List).isNotEmpty;
      } catch (_) {}
      setState(() { _detail = Map<String, dynamic>.from(po); _items = itemList; _meta = meta;
        _approvalRequired = approvalReq; _showStockConsumption = showSC; _showFgStock = showFg;
        _lineMetrics = metrics; _datesEditable = datesEd;
        _hasGrn = hasGrn;
        _syncLineCtrls();
        _detailLoading = false; });
    } catch (e) { _showSnack('Detail error: $e'); setState(() => _detailLoading = false); }
  }

  void _syncLineCtrls() {
    final ids = _items.map((i) => i['id'] as String).toSet();
    for (final k in _lineQtyCtrls.keys.where((k) => !ids.contains(k)).toList()) {
      _lineQtyCtrls.remove(k)?.dispose();
    }
    for (final k in _lineRateCtrls.keys.where((k) => !ids.contains(k)).toList()) {
      _lineRateCtrls.remove(k)?.dispose();
    }
    for (final it in _items) {
      final id = it['id'] as String;
      final qty = (it['quantity_ordered'] as num?)?.toDouble() ?? 0;
      final txt = qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2);
      final c = _lineQtyCtrls[id];
      if (c == null) {
        _lineQtyCtrls[id] = TextEditingController(text: txt);
      } else if (c.text != txt) {
        c.text = txt;
      }
      final rate = _effRate(it);
      final rtxt = rate == 0 ? '' : rate.toStringAsFixed(2);
      final rc = _lineRateCtrls[id];
      if (rc == null) {
        _lineRateCtrls[id] = TextEditingController(text: rtxt);
      } else if (rc.text != rtxt) {
        rc.text = rtxt;
      }
      final dtxt = (it['description'] as String?) ?? '';
      final dc = _lineDescCtrls[id];
      if (dc == null) {
        _lineDescCtrls[id] = TextEditingController(text: dtxt);
      } else if (dc.text != dtxt && !dc.selection.isValid) {
        dc.text = dtxt;
      }
    }
    for (final k in _lineDescCtrls.keys.where((k) => !ids.contains(k)).toList()) {
      _lineDescCtrls.remove(k)?.dispose();
    }
  }

  bool _isFreeText(Map<String, dynamic> it) {
    final p = _products.firstWhere((p) => p['id'] == it['product_id'], orElse: () => const {});
    return p['is_free_text'] == true;
  }

  // Save a free-text line's custom description.
  Future<void> _updateLineDesc(String itemId) async {
    if (!_canEditLines) return;
    final c = _lineDescCtrls[itemId];
    final txt = c?.text.trim() ?? '';
    final cur = (_items.firstWhere((i) => i['id'] == itemId, orElse: () => <String, dynamic>{})['description'] as String?) ?? '';
    if (cur == txt) return;
    try {
      await Supabase.instance.client.from('purchase_order_items')
          .update({'description': txt.isEmpty ? null : txt}).eq('id', itemId);
      final idx = _items.indexWhere((i) => i['id'] == itemId);
      if (idx >= 0) _items[idx]['description'] = txt.isEmpty ? null : txt;
      await _resetApprovalIfNeeded();
    } catch (e) { _showSnack('Failed to save description: $e'); }
  }

  // Inline edit of a line's rate (unit_cost). Allowed while lines are editable.
  Future<void> _updateLineRate(String itemId) async {
    if (!_canEditLines) return;
    final c = _lineRateCtrls[itemId];
    final rate = double.tryParse(c?.text.trim() ?? '') ?? -1;
    if (rate < 0) { _showSnack('Rate must be 0 or more'); return; }
    final cur = (_items.firstWhere((i) => i['id'] == itemId, orElse: () => <String, dynamic>{})['unit_cost'] as num?)?.toDouble() ?? 0;
    if (cur == rate) return;
    try {
      await Supabase.instance.client.from('purchase_order_items')
          .update({'unit_cost': rate}).eq('id', itemId);
      setState(() {
        final idx = _items.indexWhere((i) => i['id'] == itemId);
        if (idx >= 0) _items[idx]['unit_cost'] = rate;
      });
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleRates(bool v) async {
    try {
      await Supabase.instance.client.from('purchase_orders')
          .update({'show_rates': v, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', _detail['id']);
      setState(() { _detail['show_rates'] = v; });
      _syncLineCtrls();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // Inline edit of an existing line's ordered qty. Allowed while lines are
  // editable (no GRN, not voided). Like add/delete, it clears approval.
  Future<void> _updateLineQty(String itemId) async {
    if (!_canEditLines) return;
    final c = _lineQtyCtrls[itemId];
    final qty = double.tryParse(c?.text.trim() ?? '') ?? -1;
    final cur = (_items.firstWhere((i) => i['id'] == itemId, orElse: () => <String, dynamic>{})['quantity_ordered'] as num?)?.toDouble();
    if (qty <= 0) {
      _showSnack('Qty must be > 0');
      if (cur != null) c?.text = cur.toStringAsFixed(cur % 1 == 0 ? 0 : 2);
      return;
    }
    if (cur != null && cur == qty) return; // unchanged — no write, no approval reset
    try {
      await Supabase.instance.client.from('purchase_order_items')
          .update({'quantity_ordered': qty}).eq('id', itemId);
      setState(() {
        final idx = _items.indexWhere((i) => i['id'] == itemId);
        if (idx >= 0) _items[idx]['quantity_ordered'] = qty;
      });
      await _logAudit(_detail['id'] as String, 'line_edited', 'Qty changed to ${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2)}');
      await _resetApprovalIfNeeded();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _logAudit(String id, String action, String? details) async {
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'id': 'val_${DateTime.now().microsecondsSinceEpoch}',
        'org_id': _orgId, 'voucher_id': id, 'voucher_type': 'PO',
        'action': action, 'details': details, 'performed_by': ref.read(currentUserProvider)?.id,
        'performed_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (mounted) setState(() => _auditRefresh++);
    } catch (e) { print('[Audit PO] $e'); }
  }

  Future<void> _createNew() async {
    final orgId = _orgId; final branchId = _branchId;
    if (orgId == null || branchId == null) { _showSnack('Select a branch first'); return; }
    final picked = await showDialog<Map<String, dynamic>?>(context: context, builder: (_) => _SupplierPickDialog(suppliers: _suppliers));
    if (picked == null) return;
    setState(() => _detailLoading = true);
    SavingOverlay.show(context, label: 'Creating…');
    try {
      final year = DateTime.now().year;
      final nextNum = await Supabase.instance.client.rpc('next_voucher_number', params: {'p_org_id': orgId, 'p_branch_id': branchId, 'p_type': 'PO', 'p_year': year});
      final vNum = 'PO-$year-${nextNum.toString().padLeft(4, '0')}';
      final poId = 'po_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('purchase_orders').insert({
        'id': poId, 'org_id': orgId, 'branch_id': branchId,
        'voucher_number': vNum, 'voucher_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'supplier_id': picked['id'], 'status': 'draft', 'is_locked': false,
        'created_by': ref.read(currentUserProvider)?.id,
      });
      await _logAudit(poId, 'created', 'PO $vNum created');
      _showSnack('$vNum created — add items below');
      await _loadList();
      _loadDetail(poId);
    } catch (e) { setState(() => _detailLoading = false); _showSnack('Failed: $e'); }
    finally { SavingOverlay.hide(); }
  }

  Future<bool> _addItem() async {
    if (!_canEditLines) { _showSnack('Cannot add: a GRN exists against this PO. Delete the GRN first.'); return false; }
    if (_addProductId == null || _addUomId == null) { _showSnack('Select product and UOM'); return false; }
    if (_items.any((i) => i['product_id'] == _addProductId)) { _showSnack('Already added'); return false; }
    final qty = double.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) { _showSnack('Qty must be > 0'); return false; }
    final prod = _products.firstWhere((p) => p['id'] == _addProductId, orElse: () => {});
    final uom  = _uoms.firstWhere((u) => u['id'] == _addUomId, orElse: () => {});
    final itemId = 'poi_${DateTime.now().microsecondsSinceEpoch}';
    try {
      final initialCost = _showRates ? (_prodCost[_addProductId] ?? 0) : 0;
      await Supabase.instance.client.from('purchase_order_items').insert({
        'id': itemId, 'purchase_order_id': _detail['id'],
        'product_id': _addProductId, 'uom_id': _addUomId,
        'quantity_ordered': qty, 'quantity_received': 0, 'unit_cost': initialCost,
      });
      setState(() {
        _items.add({'id': itemId, 'product_id': _addProductId, 'uom_id': _addUomId,
          'quantity_ordered': qty, 'quantity_received': 0, 'unit_cost': initialCost,
          'products': {'name': prod['name'], 'sku': prod['sku']}, 'uoms': {'abbreviation': uom['abbreviation']}});
        _addProductId = null; _addUomId = null; _addQtyCtrl.text = '1';
        _syncLineCtrls();
      });
      await _resetApprovalIfNeeded();
      return true;
    } catch (e) { _showSnack('Failed: $e'); return false; }
  }

  // Open the product picker (keyboard nav), set product + default UOM, then
  // focus Qty. Shared by the "+ Add product" tap and the Enter loop.
  Future<bool> _pickAddProduct() async {
    if (!_canEditLines) { _showSnack('Cannot add: a GRN exists against this PO. Delete the GRN first.'); return false; }
    final p = await pickProduct(context, _visibleProducts, title: 'Add product');
    if (p == null || p.isEmpty) return false;
    setState(() {
      _addProductId = p['id'] as String?;
      _addUomId = p['base_uom_id'] as String?;
      _addQtyCtrl.text = '1';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _addQtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _addQtyCtrl.text.length);
      _addQtyFocus.requestFocus();
    });
    return true;
  }

  // Enter on Qty: add the line, then reopen the picker for the next product.
  Future<void> _addItemAndPickNext() async {
    final ok = await _addItem();
    if (!ok) return;
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    await _pickAddProduct();
  }

  Future<void> _deleteItem(String itemId) async {
    if (!_canEditLines) { _showSnack('Cannot remove: a GRN exists against this PO. Delete the GRN first.'); return; }
    try {
      await Supabase.instance.client.from('purchase_order_items').delete().eq('id', itemId);
      setState(() => _items.removeWhere((i) => i['id'] == itemId));
      _syncLineCtrls();
      await _resetApprovalIfNeeded();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _confirmOrder() async {
    if (_items.isEmpty) { _showSnack('Add at least one item before confirming'); return; }
    final userId = ref.read(currentUserProvider)?.id;
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'status': 'ordered',
        'is_locked': true,
        'locked_by': userId, 'locked_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'confirmed', 'PO confirmed and locked');
      _showSnack('Purchase Order confirmed');
      ref.invalidate(poPendingApprovalCountProvider);
      _loadDetail(_detail['id'] as String);
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _toggleLock() async {
    if (_isLocked && !_canUnlock) { _showSnack('Only admins can unlock'); return; }
    final newLocked = !_isLocked;
    final userId = ref.read(currentUserProvider)?.id;
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'is_locked': newLocked, 'locked_by': newLocked ? userId : null,
        'locked_at': newLocked ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, newLocked ? 'locked' : 'unlocked', null);
      _showSnack(newLocked ? 'Locked' : 'Unlocked');
      ref.invalidate(poPendingApprovalCountProvider);
      _loadDetail(_detail['id'] as String);
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _delete() async {
    if (!_canDelete) return;
    try {
      final grns = await Supabase.instance.client.from('purchase_grns').select('id,voucher_number').eq('po_id', _detail['id'] as String);
      if ((grns as List).isNotEmpty) { _showSnack('Cannot delete: GRN ${grns.first['voucher_number']} exists. Delete GRN first.'); return; }
    } catch (e) { _showSnack('Check error: $e'); return; }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Purchase Order?'),
      content: Text('Delete ${_detail['voucher_number']}? Cannot be undone.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      await _logAudit(_detail['id'] as String, 'deleted', 'PO ${_detail['voucher_number']} deleted');
      await Supabase.instance.client.from('purchase_order_items').delete().eq('purchase_order_id', _detail['id']);
      await Supabase.instance.client.from('purchase_orders').delete().eq('id', _detail['id']);
      _showSnack('Deleted');
      setState(() { _selectedId = null; _detail = {}; _items = []; });
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _approve() async {
    if (!_canApprove) { _showSnack('You do not have permission to approve.'); return; }
    final u = ref.read(currentUserProvider);
    SavingOverlay.show(context, label: 'Approving…');
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'approved_by': u?.id, 'approved_by_name': u?.name,
        'approved_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'approved', 'Approved by ${u?.name ?? ''}');
      _showSnack('Purchase Order approved');
      ref.invalidate(poPendingApprovalCountProvider);
      _loadDetail(_detail['id'] as String);
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
    finally { SavingOverlay.hide(); }
  }

  // Clears approval after any line-item change, forcing re-approval.
  Future<void> _resetApprovalIfNeeded() async {
    if (_detail['approved_at'] == null) return;
    final id = _detail['id'] as String;
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'approved_by': null, 'approved_by_name': null, 'approved_at': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);
      await _logAudit(id, 'approval_reset', 'Line items changed — approval cleared, re-approval required');
      setState(() { _detail['approved_by'] = null; _detail['approved_by_name'] = null; _detail['approved_at'] = null; });
      _showSnack('Line changed — approval reset, this PO must be approved again');
      ref.invalidate(poPendingApprovalCountProvider);
    } catch (e) { _showSnack('Approval reset failed: $e'); }
  }

  // Approved POs are voided instead of hard-deleted (keeps the audit record).
  Future<void> _void() async {
    if (!_canDelete) return;
    if (_hasGrn) { _showSnack('Cannot void: a GRN exists against this PO. Delete the GRN first.'); return; }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Void Purchase Order?'),
      content: Text('Void ${_detail['voucher_number']}? It will be kept for the record but marked void and cannot be received.'),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800), onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Void'))],
    ));
    if (ok != true) return;
    final u = ref.read(currentUserProvider);
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'voided_by': u?.id, 'voided_by_name': u?.name,
        'voided_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'voided', 'PO ${_detail['voucher_number']} voided by ${u?.name ?? ''}');
      _showSnack('Purchase Order voided');
      ref.invalidate(poPendingApprovalCountProvider);
      _loadDetail(_detail['id'] as String);
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // Outstanding = ordered minus received across all lines. Drives the
  // short-close affordance.
  double get _outstandingQty {
    double o = 0;
    for (final it in _items) {
      final ord = (it['quantity_ordered'] as num?)?.toDouble() ?? 0;
      final rec = (it['quantity_received'] as num?)?.toDouble() ?? 0;
      if (ord > rec) o += ord - rec;
    }
    return o;
  }

  // Change the supplier on an open PO (no GRN, not voided) instead of forcing
  // delete + recreate. Clears approval if the PO was already approved.
  Future<void> _changeSupplier() async {
    if (!_canEditLines) {
      _showSnack('Cannot change supplier: a GRN exists against this PO. Delete the GRN first.');
      return;
    }
    final picked = await showDialog<Map<String, dynamic>?>(
        context: context, builder: (_) => _SupplierPickDialog(suppliers: _suppliers));
    if (picked == null) return;
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'supplier_id': picked['id'],
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'supplier_changed',
          'Supplier changed to ${picked['name']}');
      _showSnack('Supplier updated to ${picked['name']}');
      await _resetApprovalIfNeeded();
      _loadDetail(_detail['id'] as String);
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // Short-close: the vendor order is finished but less arrived than ordered.
  // Marks the PO received (closed) so the outstanding qty stops hanging in the
  // pending/open views. No inventory effect — only GRNs move stock.
  Future<void> _shortClose() async {
    final out = _outstandingQty;
    if (out <= 0) { _showSnack('Nothing outstanding to close.'); return; }
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Close remaining quantity?'),
      content: Text('${_trimQty(out)} unit(s) ordered but not received will be '
          'closed off — ${_detail['voucher_number']} will be marked fully received '
          'and the pending qty will no longer show. This does not affect stock.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Close remaining')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('purchase_orders').update({
        'status': 'received',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _detail['id']);
      await _logAudit(_detail['id'] as String, 'short_closed',
          'Short-closed: ${_trimQty(out)} outstanding unit(s) dropped');
      _showSnack('PO closed — remaining qty dropped');
      ref.invalidate(poPendingApprovalCountProvider);
      _loadDetail(_detail['id'] as String);
      _loadList();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  String _trimQty(double q) => q % 1 == 0 ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  String? _footerWithApproval(String? base) {
    final name = _detail['approved_by_name'] as String?;
    final at = _detail['approved_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['approved_at'] as String).toLocal()) : null;
    if (name == null || at == null) return base;
    final line = 'Approved by $name on $at';
    return (base == null || base.isEmpty) ? line : '$base\n$line';
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final showRates = _showRates;
    final lines = _isDraft ? <VoucherLine>[] : _items.map((it) {
      final qty = (it['quantity_ordered'] as num?)?.toDouble() ?? 0;
      final rate = _effRate(it);
      final desc = (it['description'] as String?)?.trim();
      final baseName = it['products']?['name'] as String? ?? '-';
      return VoucherLine(
        product: (desc != null && desc.isNotEmpty) ? '$baseName — $desc' : baseName,
        sku: it['products']?['sku'] as String?,
        uom: it['uoms']?['abbreviation'] as String?,
        qty: qty,
        unitPrice: showRates ? rate : null,
        lineTotal: showRates ? qty * rate : null,
      );
    }).toList();
    final sup = _detail['suppliers'] as Map?;
    await VoucherPdf.printVoucher(
      voucherNumber: _detail['voucher_number'] as String? ?? '-',
      voucherTypeLabel: 'Purchase Order',
      orgName: user?.orgName ?? 'Opstation',
      branchName: _detail['branches']?['name'] as String?,
      date: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : null,
      customerOrSupplier: sup?['name'] as String? ?? '-',
      customerAddress: sup?['address'] as String?,
      customerContact: sup?['contact_person'] as String?,
      customerPhone: (sup?['contact_number'] ?? sup?['phone']) as String?,
      lines: lines,
      grandTotal: (showRates && !_isDraft) ? _grandTotal : null,
      preparedBy: _meta.preparedBy,
      createdAt: _detail['created_at'] != null
          ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_detail['created_at'] as String).toLocal())
          : null,
      footerNote: _footerWithApproval(_meta.purchaseFooterNote ?? _meta.footerNote),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) { _selectedId = null; _detail = {}; _items = []; _loadList(); });
    return Container(color: AppTheme.background, child: CollapsibleListPane(
      paneWidth: 360,
      detailActive: _selectedId != null,
      onBack: () => setState(() { _selectedId = null; _detail = {}; _items = []; }),
      listChild: _buildList(),
      detailChild: _selectedId == null
          ? const Center(child: Text('Select or create a Purchase Order', style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)))
          : _buildDetail(),
    ));
  }

  Widget _buildList() {
    final q = _search.toLowerCase().trim();
    final filtered = _pos.where((r) {
      final matchSearch = matchesQuery('${r['voucher_number'] ?? ''} ${r['suppliers']?['name'] ?? ''}', q);
      final disp = poDisplayStatus(r);
      final matchFilter = _filter == 'all'
          || (_filter == 'pending' && _poIsPending(r, _orgApprovalRequired))
          || (_filter == 'approved' && disp == 'Approved')
          || (_filter == 'open' && (disp == 'Ordered' || disp == 'Approved'))
          || (_filter == 'received' && (disp == 'Received' || disp == 'Partially Received'))
          || (_filter == 'invoiced' && disp == 'Invoiced');
      return matchSearch && matchFilter;
    }).toList();
    return Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppTheme.border))),
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 12), child: Row(children: [
          const Expanded(child: Text('Purchase Orders', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
          IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary, size: 32), onPressed: _createNew, tooltip: 'New PO'),
        ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: TextField(
          decoration: const InputDecoration(hintText: 'Search PO / supplier…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
          onChanged: (v) => setState(() => _search = v),
        )),
        const SizedBox(height: 8),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
            _PoFilterTab(label: 'All',      value: 'all',      current: _filter, onTap: (v) => setState(() => _filter = v)),
            const SizedBox(width: 5),
            if (_orgApprovalRequired) ...[
              _PoFilterTab(label: 'Pending',  value: 'pending',  current: _filter, onTap: (v) => setState(() => _filter = v)),
              const SizedBox(width: 5),
            ],
            _PoFilterTab(label: 'Open',     value: 'open',     current: _filter, onTap: (v) => setState(() => _filter = v)),
            const SizedBox(width: 5),
            _PoFilterTab(label: 'Approved', value: 'approved', current: _filter, onTap: (v) => setState(() => _filter = v)),
            const SizedBox(width: 5),
            _PoFilterTab(label: 'Received', value: 'received', current: _filter, onTap: (v) => setState(() => _filter = v)),
            const SizedBox(width: 5),
            _PoFilterTab(label: 'Invoiced', value: 'invoiced', current: _filter, onTap: (v) => setState(() => _filter = v)),
          ])),
        const SizedBox(height: 12),
        Expanded(child: _listLoading ? const Center(child: BrandSpinner())
            : filtered.isEmpty ? const Center(child: Text('No POs yet.', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = filtered[i]; final sel = r['id'] == _selectedId;
                  final status = r['status'] as String? ?? 'draft';
                  final voided = r['voided_at'] != null;
                  return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.06),
                    title: Row(children: [
                      Expanded(child: Text(r['voucher_number'] as String? ?? '-', style: TextStyle(fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : null, decoration: voided ? TextDecoration.lineThrough : null))),
                      voided ? const _PoVoidChip() : (_poIsPending(r, _orgApprovalRequired) ? const _PoPendingChip() : _PoStatusBadge(status: poDisplayStatus(r))),
                    ]),
                    subtitle: Text(r['suppliers']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 11)),
                    onTap: () => _loadDetail(r['id'] as String));
                })),
      ]),
    );
  }

  Widget _buildDetail() {
    if (_detailLoading) return const Center(child: BrandSpinner());
    final sup = _detail['suppliers'] as Map?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header
      Container(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: LayoutBuilder(builder: (ctx, cons) {
          final narrow = cons.maxWidth < 640;
          final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(_detail['voucher_number'] as String? ?? '-', softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Text('Purchase Order', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 1.2)),
          ]);
          final actions = <Widget>[
            if (_isDraft && !_isLocked)
              ElevatedButton.icon(icon: const Icon(Icons.check, size: 16), label: const Text('Confirm Order'), onPressed: _confirmOrder),
            if (_isLocked && _approvalRequired && _detail['approved_at'] == null && !_isVoided && _canApprove)
              ElevatedButton.icon(icon: const Icon(Icons.verified_outlined, size: 16), label: const Text('Approve'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green), onPressed: _approve),
            // Only offer short-close once at least one GRN exists, and never
            // after the PO is already marked received (short-close flips it to
            // 'received' — offering it again just re-logged the same drop).
            if (_isLocked && !_isVoided && _hasGrn && _outstandingQty > 0 &&
                _detail['status'] != 'invoiced' && _detail['status'] != 'received')
              OutlinedButton.icon(icon: const Icon(Icons.playlist_add_check, size: 16), label: const Text('Close remaining'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.orange.shade800), onPressed: _shortClose),
            if (_canEditDate)
              IconButton(icon: const Icon(Icons.edit_calendar_outlined, color: AppTheme.textSecondary), tooltip: 'Edit date', onPressed: _pickDate),
            if (!_isDraft || !_isLocked || _canUnlock)
              IconButton(icon: Icon(_isLocked ? Icons.lock_open : Icons.lock_outline, color: _isLocked ? Colors.orange : AppTheme.textSecondary),
                  tooltip: _isLocked ? 'Unlock (admin)' : 'Lock', onPressed: _toggleLock),
            IconButton(icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary), tooltip: 'Print', onPressed: _print),
            if (_canDelete && !_isVoided)
              IconButton(
                icon: Icon(_detail['approved_at'] != null ? Icons.block : Icons.delete_outline,
                    color: _detail['approved_at'] != null ? Colors.orange.shade800 : AppTheme.danger),
                tooltip: _detail['approved_at'] != null ? 'Void (approved PO cannot be deleted)' : 'Delete',
                onPressed: _detail['approved_at'] != null ? _void : _delete),
          ];
          if (narrow) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              title,
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: actions),
            ]);
          }
          return Row(children: [
            Expanded(child: title),
            for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
          ]);
        }),
      ),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 8, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            _PoChip(label: 'Supplier', value: sup?['name'] as String? ?? '-'),
            if (_canEditLines)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 15, color: AppTheme.textSecondary),
                tooltip: 'Change supplier',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.only(left: 2),
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: _changeSupplier),
          ]),
          _PoChip(label: 'Date', value: _detail['voucher_date'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(_detail['voucher_date'] as String)) : '-'),
          _PoChip(label: 'Branch', value: _detail['branches']?['name'] as String? ?? '-'),
          _PoChip(label: 'Status', value: poDisplayStatus(_detail)),
          if (_approvalRequired && _isLocked)
            _PoChip(label: 'Approval', value: _detail['approved_at'] != null
                ? 'Approved · ${_detail['approved_by_name'] ?? ''}'
                : 'Pending approval'),
          if (_isLocked) const _PoLockedChip(),
          if (_isVoided) const _PoVoidChip(),
        ]),
        if (sup != null) _PoInfoStrip(
          address: sup['address'] as String?,
          contact: sup['contact_person'] as String?,
          phone: (sup['contact_number'] ?? sup['phone']) as String?,
          ntn: sup['ntn'] as String?,
          preparedBy: _meta.preparedBy,
        ),
        const SizedBox(height: 20),
        if (_isDraft && !_isLocked)
          Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: Colors.blue.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.blue.withOpacity(0.25))),
            child: const Row(children: [Icon(Icons.info_outline, size: 15, color: Colors.blue), SizedBox(width: 8),
              Expanded(child: Text('Add items, then click "Confirm Order" to lock this PO for GRN creation.', style: TextStyle(fontSize: 12, color: Colors.blue)))])),
        // Rates toggle (per-PO). Remembered on the document.
        Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [
          Transform.scale(scale: 0.85, child: Switch(value: _showRates, onChanged: _detailLoading ? null : (v) => _toggleRates(v))),
          const SizedBox(width: 4),
          const Text('Show rates', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          if (_showRates) const Expanded(child: Text(
            'Rate defaults to each product\'s cost price and is editable per line. It prints unit price, amount and grand total on the PO.',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        ])),
        // Items table
        Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
              child: Row(children: [
                const Expanded(flex: 5, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                const Expanded(flex: 2, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
                const Expanded(flex: 2, child: Text('Qty Ordered', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                if (_showRates) ...[
                  const Expanded(flex: 2, child: Text('Rate', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                  const Expanded(flex: 2, child: Text('Amount', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
                ],
                const SizedBox(width: 44),
              ])),
            const Divider(height: 1),
            if (_items.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('No items — add below', style: TextStyle(color: AppTheme.textSecondary))),
            ..._items.map((it) {
              final qty = (it['quantity_ordered'] as num?)?.toDouble() ?? 0;
              return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it['products']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13)),
                    if (it['products']?['sku'] != null) Text(it['products']!['sku'] as String, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                    if (!_isDraft) Builder(builder: (_) {
                      final ord = (it['quantity_ordered'] as num?)?.toDouble() ?? 0;
                      final rec = (it['quantity_received'] as num?)?.toDouble() ?? 0;
                      final full = ord > 0 && rec >= ord;
                      final c = rec <= 0 ? AppTheme.textSecondary : (full ? AppTheme.success : Colors.orange.shade800);
                      return Padding(padding: const EdgeInsets.only(top: 2), child: Text(
                        full ? 'Received ${_trimQty(rec)} of ${_trimQty(ord)} ✓'
                             : 'Received ${_trimQty(rec)} of ${_trimQty(ord)}',
                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: c)));
                    }),
                    if (_isFreeText(it)) Padding(padding: const EdgeInsets.only(top: 4, right: 8),
                      child: _canEditLines
                        ? TextField(
                            controller: _lineDescCtrls[it['id']],
                            style: const TextStyle(fontSize: 12),
                            minLines: 1, maxLines: 2,
                            decoration: const InputDecoration(isDense: true, hintText: 'Describe the item / service…',
                              prefixIcon: Icon(Icons.notes, size: 14),
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              border: OutlineInputBorder()),
                            onEditingComplete: () => _updateLineDesc(it['id'] as String),
                            onSubmitted: (_) => _updateLineDesc(it['id'] as String),
                          )
                        : Text((it['description'] as String?)?.isNotEmpty == true ? it['description'] as String : '—',
                            style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: AppTheme.textSecondary))),
                    if (_showStockConsumption || _showFgStock) Builder(builder: (_) {
                      final m = _lineMetrics[it['product_id']];
                      final parts = <String>[];
                      if (_showStockConsumption) {
                        final oh = (m?['on_hand'] as double?) ?? 0;
                        final av = (m?['avg'] as double?) ?? 0;
                        parts.add('On-hand: ${oh.toStringAsFixed(oh % 1 == 0 ? 0 : 1)}');
                        parts.add('3-mo avg: ${av.toStringAsFixed(1)}/mo');
                      }
                      if (_showFgStock) {
                        final fg = m?['fg_on_hand'] as double?;
                        if (fg != null) {
                          final n = (m?['fg_count'] as int?) ?? 1;
                          parts.add('FG on-hand: ${fg.toStringAsFixed(fg % 1 == 0 ? 0 : 1)}'
                              '${n > 1 ? ' ($n FGs)' : ''}');
                        }
                        // No BOM links this raw to a finished good -> show nothing
                        // rather than a misleading zero.
                      }
                      if (parts.isEmpty) return const SizedBox.shrink();
                      return Padding(padding: const EdgeInsets.only(top: 2), child: Text(
                        parts.join('  ·  '),
                        style: const TextStyle(fontSize: 10, color: AppTheme.primary, fontWeight: FontWeight.w600)));
                    }),
                  ])),
                  Expanded(flex: 2, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: _canEditLines
                    ? SizedBox(height: 34, child: TextField(
                        controller: _lineQtyCtrls[it['id'] as String],
                        textAlign: TextAlign.right,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _updateLineQty(it['id'] as String),
                        onTapOutside: (_) => _updateLineQty(it['id'] as String),
                      ))
                    : Text(qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                  if (_showRates) ...[
                    Expanded(flex: 2, child: _canEditLines
                      ? Padding(padding: const EdgeInsets.only(left: 8), child: SizedBox(height: 34, child: TextField(
                          controller: _lineRateCtrls[it['id'] as String],
                          textAlign: TextAlign.right,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(isDense: true, prefixText: 'Rs ', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), border: OutlineInputBorder()),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _updateLineRate(it['id'] as String),
                          onTapOutside: (_) => _updateLineRate(it['id'] as String),
                        )))
                      : Text(_effRate(it).toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                    Expanded(flex: 2, child: Text(money(qty * _effRate(it)), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                  ],
                  SizedBox(width: 44, child: _canEditLines ? IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger), onPressed: () => _deleteItem(it['id'] as String)) : null),
                ]));
            }),
            if (_items.isNotEmpty) ...[
              const Divider(height: 1),
              Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(color: AppTheme.background),
                child: Row(children: [
                  const Expanded(flex: 5, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13))),
                  const Expanded(flex: 2, child: SizedBox()),
                  Expanded(flex: 2, child: Text(_trimQty(_totalQty), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13))),
                  if (_showRates) ...[
                    const Expanded(flex: 2, child: SizedBox()),
                    Expanded(flex: 2, child: Padding(padding: const EdgeInsets.only(left: 8), child: Text('Rs ${money(_grandTotal)}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppTheme.primary)))),
                  ],
                  const SizedBox(width: 44),
                ])),
            ],
            if (_canEditLines) ...[
              const Divider(height: 1),
              Container(color: AppTheme.background, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Expanded(flex: 5, child: Builder(builder: (ctx) {
                    final sel = _addProductId == null ? null : _products.firstWhere((x) => x['id'] == _addProductId, orElse: () => <String, dynamic>{});
                    final name = (sel == null || sel.isEmpty) ? null : sel['name'] as String?;
                    return InkWell(
                      onTap: () => _pickAddProduct(),
                      child: InputDecorator(
                        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10), border: OutlineInputBorder()),
                        child: Row(children: [
                          Expanded(child: Text(name ?? 'Pick product', maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: name == null ? AppTheme.textSecondary : Colors.black87))),
                          const Icon(Icons.arrow_drop_down, size: 20, color: AppTheme.textSecondary),
                        ]),
                      ),
                    );
                  })),
                  Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: DropdownButtonFormField<String>(value: _addUomId, isDense: true, isExpanded: true,
                      decoration: const InputDecoration(hintText: 'UOM', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
                      items: _uoms.map((u) => DropdownMenuItem<String>(value: u['id'] as String, child: Text(u['abbreviation'] as String? ?? '', style: const TextStyle(fontSize: 12)))).toList(),
                      onChanged: (v) => setState(() => _addUomId = v)))),
                  Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextField(controller: _addQtyCtrl, focusNode: _addQtyFocus, decoration: const InputDecoration(hintText: 'Qty', isDense: true), textAlign: TextAlign.right,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true), textInputAction: TextInputAction.done, onSubmitted: (_) => _addItemAndPickNext()))),
                  if (_showRates) ...[
                    const Expanded(flex: 2, child: SizedBox()),
                    const Expanded(flex: 2, child: SizedBox()),
                  ],
                  SizedBox(width: 44, child: IconButton(icon: const Icon(Icons.add_circle, color: AppTheme.primary), tooltip: 'Add', onPressed: () => _addItem())),
                ])),
            ],
          ])),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerRight, child: Text('${_items.length} item(s)', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        const SizedBox(height: 16),
        _PoAuditTrail(key: ValueKey('audit_${_selectedId}_$_auditRefresh'), voucherId: _selectedId ?? ''),
      ]))),
    ]);
  }
}

class _SupplierPickDialog extends StatefulWidget {
  final List<Map<String, dynamic>> suppliers;
  const _SupplierPickDialog({required this.suppliers});
  @override State<_SupplierPickDialog> createState() => _SupplierPickDialogState();
}
class _SupplierPickDialogState extends State<_SupplierPickDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final filtered = widget.suppliers.where((s) => matchesQuery('${s['name'] ?? ''}', q)).toList();
    return AlertDialog(
      title: Text('Select Supplier  ·  ${widget.suppliers.length} total'),
      content: SizedBox(width: 480, height: 440, child: Column(children: [
        TextField(decoration: const InputDecoration(hintText: 'Search supplier…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _q = v), autofocus: true),
        const SizedBox(height: 12),
        Expanded(child: filtered.isEmpty
            ? const Center(child: Text('No suppliers.', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) { final s = filtered[i]; return ListTile(dense: true,
                  title: Text(s['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.pop(context, s)); })),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
    );
  }
}

class _PoInfoStrip extends StatelessWidget {
  final String? address, contact, phone, ntn, preparedBy;
  const _PoInfoStrip({this.address, this.contact, this.phone, this.ntn, this.preparedBy});
  @override
  Widget build(BuildContext context) {
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

class _PoChip extends StatelessWidget {
  final String label, value;
  const _PoChip({required this.label, required this.value});
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label: ', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
    ]));
}

class _PoLockedChip extends StatelessWidget {
  const _PoLockedChip();
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.4))),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.lock_outline, size: 12, color: Colors.orange), SizedBox(width: 4), Text('Locked', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w600))]));
}

class _PoVoidChip extends StatelessWidget {
  const _PoVoidChip();
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.danger.withOpacity(0.4))),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.block, size: 12, color: AppTheme.danger), SizedBox(width: 4), Text('Voided', style: TextStyle(fontSize: 11, color: AppTheme.danger, fontWeight: FontWeight.w600))]));
}

/// Human status shown on the badge/chip and used by the list filters.
/// draft -> Ordered (locked) -> Approved -> Partially Received -> Received ->
/// Invoiced, with Voided taking precedence.
String poDisplayStatus(Map<String, dynamic> r) {
  if (r['voided_at'] != null) return 'Voided';
  final s = (r['status'] as String?) ?? 'draft';
  if (s == 'received') return 'Received';
  if (s == 'partially_received') return 'Partially Received';
  if (s == 'invoiced') return 'Invoiced';
  if (r['approved_at'] != null) return 'Approved';
  if (s == 'ordered' || r['is_locked'] == true) return 'Ordered';
  return 'Draft';
}

bool _poIsPending(Map<String, dynamic> r, bool orgApprovalRequired) {
  if (!orgApprovalRequired) return false;
  final status = r['status'] as String? ?? '';
  final locked = r['is_locked'] as bool? ?? false;
  return locked && r['approved_at'] == null && r['voided_at'] == null && status != 'received';
}

class _PoPendingChip extends StatelessWidget {
  const _PoPendingChip();
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.14), borderRadius: BorderRadius.circular(4),
      border: Border.all(color: Colors.orange.withOpacity(0.5))),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.hourglass_top, size: 10, color: Colors.orange), SizedBox(width: 3),
      Text('Pending', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.orange)),
    ]));
}

class _PoStatusBadge extends StatelessWidget {
  final String status;
  const _PoStatusBadge({required this.status});
  @override Widget build(BuildContext context) {
    Color bg; Color fg;
    switch (status) {
      case 'Approved':           bg = AppTheme.primary.withOpacity(0.12);  fg = AppTheme.primary;  break;
      case 'Ordered':            bg = Colors.blue.withOpacity(0.12);       fg = Colors.blue;       break;
      case 'Received':           bg = AppTheme.success.withOpacity(0.12);  fg = AppTheme.success;  break;
      case 'Partially Received': bg = Colors.orange.withOpacity(0.12);     fg = Colors.orange;     break;
      case 'Invoiced':           bg = Colors.purple.withOpacity(0.12);     fg = Colors.purple;     break;
      case 'Voided':             bg = AppTheme.danger.withOpacity(0.12);   fg = AppTheme.danger;   break;
      default:                   bg = AppTheme.border;                      fg = AppTheme.textSecondary;
    }
    return Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg)));
  }
}

class _PoAuditTrail extends StatelessWidget {
  final String voucherId;
  const _PoAuditTrail({super.key, required this.voucherId});
  @override Widget build(BuildContext context) {
    if (voucherId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<dynamic>>(
      future: Supabase.instance.client.from('voucher_audit_log')
          .select().eq('voucher_id', voucherId).eq('voucher_type', 'PO')
          .order('performed_at', ascending: false).limit(30),
      builder: (ctx, snap) {
        if (!snap.hasData || (snap.data as List).isEmpty) return Container(
          margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: const Row(children: [Icon(Icons.history, size: 14, color: AppTheme.textSecondary), SizedBox(width: 8),
            Text('No activity logged yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))]));
        final entries = List<Map<String, dynamic>>.from(snap.data!);
        return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)),
            const SizedBox(height: 8),
            ...entries.map((e) {
              final action = e['action'] as String? ?? '-';
              final ts = e['performed_at'] != null ? DateFormat('d MMM HH:mm').format(DateTime.parse(e['performed_at'] as String).toLocal()) : '';
              final details = e['details'] as String? ?? '';
              Color color;
              switch (action) { case 'created': case 'saved': color = AppTheme.primary; break; case 'confirmed': color = AppTheme.success; break; case 'deleted': case 'cancelled': color = AppTheme.danger; break; case 'locked': color = Colors.orange; break; default: color = AppTheme.textSecondary; }
              return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.history, size: 13, color: color), const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Text(action, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color)), const Spacer(), Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))]),
                  if (details.isNotEmpty) Text(details, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ])),
              ]));
            }),
          ]));
      });
  }
}

class _PoFilterTab extends StatelessWidget {
  final String label, value, current;
  final ValueChanged<String> onTap;
  const _PoFilterTab({required this.label, required this.value, required this.current, required this.onTap});
  @override Widget build(BuildContext context) {
    final active = value == current;
    return GestureDetector(onTap: () => onTap(value), child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: active ? AppTheme.primary : AppTheme.background,
        borderRadius: BorderRadius.circular(12), border: Border.all(color: active ? AppTheme.primary : AppTheme.border)),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
          color: active ? Colors.white : AppTheme.textSecondary))));
  }
}
