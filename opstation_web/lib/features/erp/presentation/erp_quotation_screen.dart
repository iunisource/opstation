import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../../../core/widgets/product_picker.dart';

// ============================================================================
// QUOTATION VOUCHER  (Sales module)
// Non-posting document. No GL, no inventory. Exports to SO(Draft) or POS drawer.
// Catalog products only: every line has a real product_id + uom_id.
// ============================================================================

class ErpQuotationScreen extends ConsumerStatefulWidget {
  const ErpQuotationScreen({super.key});
  @override
  ConsumerState<ErpQuotationScreen> createState() => _ErpQuotationScreenState();
}

class _ErpQuotationScreenState extends ConsumerState<ErpQuotationScreen> {
  final _client = Supabase.instance.client;
  String? orgId;
  String? branchId;

  bool _loading = true;
  bool _saving = false;
  String _statusFilter = 'all';
  String _search = '';

  List<Map<String, dynamic>> _list = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _branches = [];

  // Working document (null = list view, non-null = editing/creating)
  Map<String, dynamic>? _doc;              // header
  List<Map<String, dynamic>> _lines = [];  // working lines

  final _notesCtrl = TextEditingController();
  final _globalDiscCtrl = TextEditingController(text: '0');
  String _globalDiscType = 'fixed'; // fixed | percent
  bool _printCompany = true; // include company name on printed quotation
  bool _printBranch = true;  // include branch on printed quotation
  bool _printPreparedBy = true; // include prepared-by (username) on printed quotation
  bool _printCustomCompany = false; // show admin-defined custom company name instead
  bool _customCompanyAllowed = false; // admin toggle (org.quotation_custom_company)
  String _customCompanyName = '';     // admin-defined name (org.quotation_custom_company_name)

  // Per-line field controllers + focus nodes, keyed by the line map identity.
  // Enables the Qty→Price→Discount→(reopen picker) Enter chain on each row.
  final Map<Map<String, dynamic>, Map<String, dynamic>> _lineCtl = {};

  Map<String, dynamic> _ctl(Map<String, dynamic> l) {
    return _lineCtl.putIfAbsent(l, () => {
          'qtyCtrl': TextEditingController(text: (l['quantity'] as num?)?.toString() ?? '1'),
          'priceCtrl': TextEditingController(text: (l['unit_price'] as num?)?.toStringAsFixed(2) ?? '0'),
          'discCtrl': TextEditingController(text: (l['discount'] as num?)?.toString() ?? '0'),
          'qtyFocus': FocusNode(),
          'priceFocus': FocusNode(),
          'discFocus': FocusNode(),
        });
  }

  void _clearAllLineCtl() {
    for (final c in _lineCtl.values) {
      (c['qtyCtrl'] as TextEditingController).dispose();
      (c['priceCtrl'] as TextEditingController).dispose();
      (c['discCtrl'] as TextEditingController).dispose();
      (c['qtyFocus'] as FocusNode).dispose();
      (c['priceFocus'] as FocusNode).dispose();
      (c['discFocus'] as FocusNode).dispose();
    }
    _lineCtl.clear();
  }

  void _disposeLineCtl(Map<String, dynamic> l) {
    final c = _lineCtl.remove(l);
    if (c != null) {
      (c['qtyCtrl'] as TextEditingController).dispose();
      (c['priceCtrl'] as TextEditingController).dispose();
      (c['discCtrl'] as TextEditingController).dispose();
      (c['qtyFocus'] as FocusNode).dispose();
      (c['priceFocus'] as FocusNode).dispose();
      (c['discFocus'] as FocusNode).dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _globalDiscCtrl.dispose();
    for (final c in _lineCtl.values) {
      (c['qtyCtrl'] as TextEditingController).dispose();
      (c['priceCtrl'] as TextEditingController).dispose();
      (c['discCtrl'] as TextEditingController).dispose();
      (c['qtyFocus'] as FocusNode).dispose();
      (c['priceFocus'] as FocusNode).dispose();
      (c['discFocus'] as FocusNode).dispose();
    }
    super.dispose();
  }

  Future<void> _boot() async {
    orgId = ref.read(currentUserProvider)?.orgId;
    branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    await _loadRefs();
    await _loadCustomCompanyConfig();
    await _loadList();
    if (mounted) setState(() => _loading = false);
  }

  // Load the admin-defined custom company name settings from app_config.
  Future<void> _loadCustomCompanyConfig() async {
    if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId as Object)
          .inFilter('key', ['org.quotation_custom_company', 'org.quotation_custom_company_name']);
      bool allowed = false; String name = '';
      for (final r in (rows as List)) {
        final k = r['key'] as String?; final v = r['value'] as String?;
        if (k == 'org.quotation_custom_company') allowed = v == 'true';
        if (k == 'org.quotation_custom_company_name') name = v ?? '';
      }
      if (mounted) setState(() {
        _customCompanyAllowed = allowed && name.trim().isNotEmpty;
        _customCompanyName = name.trim();
      });
    } catch (_) {}
  }

  Future<void> _loadRefs() async {
    if (orgId == null) return;
    try {
      final prods = await _client
          .from('products')
          .select('id, name, sku, selling_price, cost_price, base_uom_id, uoms:base_uom_id(name, abbreviation)')
          .eq('org_id', orgId!)
          .eq('is_active', true)
          .order('name');
      final custs = await _client
          .from('customers')
          .select('id, shop_name, phone')
          .eq('org_id', orgId!)
          .order('shop_name');
      final brs = await _client
          .from('branches')
          .select('id, name')
          .eq('org_id', orgId!)
          .eq('is_active', true)
          .order('name');
      if (!mounted) return;
      setState(() {
        _products = List<Map<String, dynamic>>.from(prods);
        _customers = List<Map<String, dynamic>>.from(custs);
        _branches = List<Map<String, dynamic>>.from(brs);
      });
    } catch (_) {}
  }

  Future<void> _loadList() async {
    if (orgId == null) return;
    try {
      // No FK from quotations → customers/branches, so we can't use PostgREST
      // embedded joins (they'd throw PGRST200 and the list would silently stay
      // empty). Fetch plain rows and merge names from the already-loaded
      // _customers / _branches reference lists.
      final rows = await _client
          .from('quotations')
          .select('*')
          .eq('org_id', orgId!)
          .order('created_at', ascending: false);
      if (!mounted) return;
      final list = List<Map<String, dynamic>>.from(rows);
      for (final r in list) {
        final cid = r['customer_id'] as String?;
        final bid = r['branch_id'] as String?;
        r['_customer_name'] = cid == null ? null
            : (_customers.firstWhere((c) => c['id'] == cid, orElse: () => {})['shop_name'] as String?);
        r['_branch_name'] = bid == null ? null
            : (_branches.firstWhere((b) => b['id'] == bid, orElse: () => {})['name'] as String?);
      }
      setState(() => _list = list);
    } catch (_) {}
  }

  // ── Line math ──────────────────────────────────────────────────────────────
  double _lineTotal(Map<String, dynamic> l) {
    final qty = (l['quantity'] as num?)?.toDouble() ?? 0;
    final price = (l['unit_price'] as num?)?.toDouble() ?? 0;
    final d = (l['discount'] as num?)?.toDouble() ?? 0;
    final dt = l['discount_type'] as String? ?? 'fixed';
    final gross = qty * price;
    final da = dt == 'percent' ? gross * d.clamp(0, 100) / 100 : d.clamp(0, gross);
    return gross - da;
  }

  // Sum of line totals (after per-line discounts) — this is the subtotal.
  double get _linesSubtotal => _lines.fold(0.0, (s, l) => s + _lineTotal(l));

  // Global discount amount, applied to the subtotal AFTER line discounts.
  double get _globalDiscAmt {
    final raw = double.tryParse(_globalDiscCtrl.text.trim()) ?? 0;
    if (_globalDiscType == 'percent') {
      return _linesSubtotal * raw.clamp(0, 100) / 100;
    }
    return raw.clamp(0, _linesSubtotal);
  }

  double get _grandTotal => _linesSubtotal - _globalDiscAmt;

  // Kept for existing callers (POS/print totals): the final payable.
  double get _docTotal => _grandTotal;

  // ── New / open / edit ────────────────────────────────────────────────────
  void _newDoc() {
    setState(() {
      _doc = {
        'customer_id': null,
        'branch_id': branchId,
        'voucher_date': DateTime.now(),
        'valid_until': null,
        'status': 'saved',
      };
      _clearAllLineCtl();
      _lines = [];
      _notesCtrl.clear();
      _globalDiscCtrl.text = '0';
      _globalDiscType = 'fixed';
    });
  }

  Future<void> _openDoc(Map<String, dynamic> row) async {
    try {
      final items = await _client
          .from('quotation_items')
          .select('*')
          .eq('quotation_id', row['id'] as String)
          .order('sr_no');
      if (!mounted) return;
      _clearAllLineCtl();
      setState(() {
        _doc = {
          'id': row['id'],
          'customer_id': row['customer_id'],
          'branch_id': row['branch_id'],
          'voucher_number': row['voucher_number'],
          'voucher_date': row['voucher_date'] != null ? DateTime.parse(row['voucher_date'] as String) : DateTime.now(),
          'valid_until': row['valid_until'] != null ? DateTime.parse(row['valid_until'] as String) : null,
          'status': row['status'] ?? 'draft',
          'created_by': row['created_by'],
        };
        _lines = List<Map<String, dynamic>>.from(items).map((it) => {
              'product_id': it['product_id'],
              'item_name': it['item_name'],
              'uom_id': it['uom_id'],
              'quantity': (it['quantity'] as num?)?.toDouble() ?? 1,
              'unit_price': (it['unit_price'] as num?)?.toDouble() ?? 0,
              'discount': (it['discount'] as num?)?.toDouble() ?? 0,
              'discount_type': it['discount_type'] ?? 'fixed',
            }).toList();
        _notesCtrl.text = row['notes'] as String? ?? '';
        _globalDiscCtrl.text = ((row['global_discount'] as num?)?.toDouble() ?? 0).toString();
        _globalDiscType = row['global_discount_type'] as String? ?? 'fixed';
      });
    } catch (_) {}
  }

  void _closeDoc() => setState(() { _clearAllLineCtl(); _doc = null; _lines = []; });

  void _pickProduct(int idx, Map<String, dynamic> p) {
    setState(() {
      final l = _lines[idx];
      l['product_id'] = p['id'];
      l['item_name'] = p['name'];
      l['uom_id'] = p['base_uom_id'];
      final newPrice = (p['selling_price'] as num?)?.toDouble() ?? 0.0;
      l['unit_price'] = newPrice;
      // keep the price field's controller in sync with the new product
      (_ctl(l)['priceCtrl'] as TextEditingController).text = newPrice.toStringAsFixed(2);
    });
  }

  // ── Save ─────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (_doc == null || orgId == null) return;
    if (_doc!['branch_id'] == null) { _toast('Select a branch'); return; }
    if (_lines.isEmpty) { _toast('Add at least one line'); return; }
    if (_lines.any((l) => l['product_id'] == null)) { _toast('Every line needs a product'); return; }

    setState(() => _saving = true);
    try {
      final isNew = _doc!['id'] == null;
      String qid = _doc!['id'] as String? ?? 'qt_${DateTime.now().microsecondsSinceEpoch}';
      String? vnum = _doc!['voucher_number']?.toString();

      if (isNew) {
        final y = DateTime.now().year;
        try {
          final res = await _client.rpc('next_voucher_number', params: {
            'p_org_id': orgId, 'p_branch_id': _doc!['branch_id'], 'p_type': 'QT', 'p_year': y,
          });
          vnum = res?.toString(); // RPC returns an integer sequence; store raw like SO
        } catch (_) { vnum = null; }
      }

      final header = {
        'id': qid,
        'org_id': orgId,
        'branch_id': _doc!['branch_id'],
        'customer_id': _doc!['customer_id'],
        'voucher_number': vnum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(_doc!['voucher_date'] as DateTime),
        'valid_until': _doc!['valid_until'] != null ? DateFormat('yyyy-MM-dd').format(_doc!['valid_until'] as DateTime) : null,
        'status': _doc!['status'] ?? 'saved',
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        'global_discount': double.tryParse(_globalDiscCtrl.text.trim()) ?? 0,
        'global_discount_type': _globalDiscType,
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (isNew) {
        header['created_by'] = ref.read(currentUserProvider)?.id;
        await _client.from('quotations').insert(header);
      } else {
        await _client.from('quotations').update(header).eq('id', qid);
        await _client.from('quotation_items').delete().eq('quotation_id', qid);
      }

      int sr = 1;
      final itemRows = _lines.map((l) => {
            'id': 'qti_${DateTime.now().microsecondsSinceEpoch}_${sr}',
            'quotation_id': qid,
            'org_id': orgId,
            'sr_no': sr++,
            'product_id': l['product_id'],
            'item_name': l['item_name'],
            'uom_id': l['uom_id'],
            'quantity': (l['quantity'] as num?)?.toDouble() ?? 1,
            'unit_price': (l['unit_price'] as num?)?.toDouble() ?? 0,
            'discount': (l['discount'] as num?)?.toDouble() ?? 0,
            'discount_type': l['discount_type'] ?? 'fixed',
            'line_total': _lineTotal(l),
          }).toList();
      await _client.from('quotation_items').insert(itemRows);

      _doc!['id'] = qid;
      _doc!['voucher_number'] = vnum;
      if (!mounted) return;
      _toast('Quotation ${vnum ?? ''} saved');
      await _loadList();
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Save failed: $e');
    }
  }

  // ── Export ─────────────────────────────────────────────────────────────────
  Future<void> _exportDialog() async {
    if (_doc == null) return;
    if (_doc!['id'] == null) { _toast('Save the quotation first'); return; }
    final choice = await showDialog<String>(
      context: context,
      builder: (dctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 4), child: Row(children: [
              const Icon(Icons.ios_share, size: 20, color: AppTheme.primary),
              const SizedBox(width: 8),
              const Text('Export Quotation', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(dctx)),
            ])),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.description_outlined, color: AppTheme.primary),
              title: const Text('Sales Order (Draft)', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Create a draft SO with these lines'),
              onTap: () => Navigator.pop(dctx, 'so'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.point_of_sale, color: AppTheme.primary),
              title: const Text('POS Drawer', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text("Send to the branch's open POS session as a held bill"),
              onTap: () => Navigator.pop(dctx, 'pos'),
            ),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
    if (choice == 'so') await _exportToSO();
    if (choice == 'pos') await _exportToPOS();
  }

  Future<void> _markExported() async {
    final id = _doc?['id'] as String?;
    if (id == null) return;
    try {
      await _client.from('quotations').update({'status': 'exported', 'updated_at': DateTime.now().toIso8601String()}).eq('id', id);
      _doc!['status'] = 'exported';
      await _loadList();
    } catch (_) {}
  }

  Future<void> _setStatus(String status) async {
    final id = _doc?['id'] as String?;
    if (id == null) { _toast('Save the quotation first'); return; }
    try {
      await _client.from('quotations').update({'status': status, 'updated_at': DateTime.now().toIso8601String()}).eq('id', id);
      setState(() => _doc!['status'] = status);
      await _loadList();
      _toast('Marked as ${status[0].toUpperCase()}${status.substring(1)}');
    } catch (e) { _toast('Failed: $e'); }
  }

  // Searchable customer picker: type to filter by shop name, plus a
  // "Walk-in / none" option at the top to clear the selection.
  Future<void> _pickCustomer() async {
    String q = '';
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setModal) {
        final ql = q.trim().toLowerCase();
        final filtered = ql.isEmpty
            ? _customers
            : _customers.where((c) =>
                (c['shop_name'] as String? ?? '').toLowerCase().contains(ql) ||
                (c['phone'] as String? ?? '').toLowerCase().contains(ql)).toList();
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 6), child: Row(children: [
                const Expanded(child: Text('Select Customer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(dctx).pop()),
              ])),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(
                autofocus: true,
                decoration: InputDecoration(hintText: 'Search name or phone…', prefixIcon: const Icon(Icons.search, size: 20), isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
                onChanged: (v) => setModal(() => q = v),
              )),
              const Divider(height: 1),
              Flexible(child: ListView(children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_off_outlined, size: 18, color: AppTheme.textSecondary),
                  title: const Text('Walk-in / none', style: TextStyle(fontSize: 13.5)),
                  onTap: () => Navigator.of(dctx).pop({'id': null}),
                ),
                const Divider(height: 1),
                ...filtered.map((c) => ListTile(
                      dense: true,
                      title: Text(c['shop_name'] as String? ?? '-', style: const TextStyle(fontSize: 13.5)),
                      subtitle: (c['phone'] as String?)?.isNotEmpty == true
                          ? Text(c['phone'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))
                          : null,
                      onTap: () => Navigator.of(dctx).pop(c),
                    )),
              ])),
            ]),
          ),
        );
      }),
    );
    if (picked != null) {
      setState(() => _doc!['customer_id'] = picked['id'] as String?);
    }
  }

  Future<void> _exportToSO() async {
    if (orgId == null || _doc == null) return;
    setState(() => _saving = true);
    try {
      final y = DateTime.now().year;
      String? soVnum;
      try {
        soVnum = await _client.rpc('next_voucher_number', params: {
          'p_org_id': orgId, 'p_branch_id': _doc!['branch_id'], 'p_type': 'SO', 'p_year': y,
        }) as String?;
      } catch (_) { soVnum = null; }

      final soId = 'so_${DateTime.now().microsecondsSinceEpoch}';
      await _client.from('sales_orders').insert({
        'id': soId,
        'org_id': orgId,
        'customer_id': _doc!['customer_id'],
        'branch_id': _doc!['branch_id'],
        'status': 'draft',
        'is_locked': false,
        'source': 'quotation',
        'voucher_number': soVnum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(_doc!['voucher_date'] as DateTime),
        'notes': (() {
          final base = 'From quotation ${_doc!['voucher_number'] ?? ''}';
          final gd = double.tryParse(_globalDiscCtrl.text.trim()) ?? 0;
          if (gd <= 0) return base;
          final label = _globalDiscType == 'percent' ? '$gd%' : 'Rs. ${gd.toStringAsFixed(2)}';
          return '$base | Global discount: $label (apply at invoice)';
        })(),
        'created_by': ref.read(currentUserProvider)?.id,
        'ordered_at': DateTime.now().toIso8601String(),
      });

      final soItems = _lines.map((l) => {
            'id': 'soi_${DateTime.now().microsecondsSinceEpoch}_${_lines.indexOf(l)}',
            'sales_order_id': soId,
            'product_id': l['product_id'],
            'uom_id': l['uom_id'],
            'quantity': (l['quantity'] as num?)?.toDouble() ?? 1,
            'unit_price': (l['unit_price'] as num?)?.toDouble() ?? 0,
            'discount': (l['discount'] as num?)?.toDouble() ?? 0,
            'qty_delivered': 0,
            'is_foc': false,
          }).toList();
      await _client.from('sales_order_items').insert(soItems);

      await _markExported();
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Draft SO ${soVnum ?? ''} created');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('SO export failed: $e');
    }
  }

  Future<void> _exportToPOS() async {
    if (orgId == null || _doc == null) return;
    setState(() => _saving = true);
    try {
      // Find an OPEN POS session for this branch.
      final sessions = await _client
          .from('pos_sessions')
          .select('id, branch_id, status')
          .eq('org_id', orgId!)
          .eq('branch_id', _doc!['branch_id'])
          .eq('status', 'open')
          .order('opened_at', ascending: false)
          .limit(1);
      final list = List<Map<String, dynamic>>.from(sessions);
      if (list.isEmpty) {
        if (!mounted) return;
        setState(() => _saving = false);
        final bname = _branches.firstWhere((b) => b['id'] == _doc!['branch_id'], orElse: () => {'name': 'this branch'})['name'];
        _toast('No open POS session for $bname — open one first');
        return;
      }
      final sessionId = list.first['id'] as String;

      // Build the held-bill items jsonb from the quotation lines.
      final items = _lines.map((l) => {
            'product_id': l['product_id'],
            'name': l['item_name'],
            'uom_id': l['uom_id'],
            'quantity': (l['quantity'] as num?)?.toDouble() ?? 1,
            'unit_price': (l['unit_price'] as num?)?.toDouble() ?? 0,
            'discount': (l['discount'] as num?)?.toDouble() ?? 0,
            'discount_type': l['discount_type'] ?? 'fixed',
          }).toList();

      final custName = _doc!['customer_id'] != null
          ? (_customers.firstWhere((c) => c['id'] == _doc!['customer_id'], orElse: () => {'shop_name': 'Walk-in'})['shop_name'] as String?)
          : 'Walk-in';

      await _client.from('pos_held_bills').insert({
        'id': 'hb_${DateTime.now().microsecondsSinceEpoch}',
        'org_id': orgId,
        'branch_id': _doc!['branch_id'],
        'session_id': sessionId,
        'customer_id': _doc!['customer_id'],
        'customer_name': custName,
        'items': items,
        'order_discount': double.tryParse(_globalDiscCtrl.text.trim()) ?? 0,
        'order_discount_type': _globalDiscType,
        'payment_method': 'cash',
        'total': _docTotal,
        'held_by': ref.read(currentUserProvider)?.id,
        'held_at': DateTime.now().toIso8601String(),
        'status': 'held',
      });

      await _markExported();
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Sent to POS Holds (${_doc!['voucher_number'] ?? ''})');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('POS export failed: $e');
    }
  }

  // ── Print / PDF ──────────────────────────────────────────────────────────
  Future<void> _printQuotation() async {
    if (_doc == null || _doc!['id'] == null) { _toast('Save the quotation first'); return; }
    try {
      final custName = _doc!['customer_id'] != null
          ? (_customers.firstWhere((c) => c['id'] == _doc!['customer_id'], orElse: () => {'shop_name': 'Walk-in'})['shop_name'] as String?)
          : 'Walk-in';
      final custPhone = _doc!['customer_id'] != null
          ? (_customers.firstWhere((c) => c['id'] == _doc!['customer_id'], orElse: () => {'phone': null})['phone'] as String?)
          : null;
      final branchName = _branches.firstWhere((b) => b['id'] == _doc!['branch_id'], orElse: () => {'name': null})['name'] as String?;

      double subtotal = 0;
      double discTotal = 0;
      final lines = _lines.map((l) {
        final qty = (l['quantity'] as num?)?.toDouble() ?? 0;
        final price = (l['unit_price'] as num?)?.toDouble() ?? 0;
        final d = (l['discount'] as num?)?.toDouble() ?? 0;
        final dt = l['discount_type'] as String? ?? 'fixed';
        final gross = qty * price;
        final da = dt == 'percent' ? gross * d.clamp(0, 100) / 100 : d.clamp(0, gross);
        final pct = gross > 0 ? (da / gross * 100) : 0.0; // effective % for the PDF column
        subtotal += gross;
        discTotal += da;
        final prod = _products.firstWhere((p) => p['id'] == l['product_id'], orElse: () => {});
        final uomAbbr = prod.isEmpty ? null : ((prod['uoms']?['abbreviation'] as String?) ?? (prod['uoms']?['name'] as String?));
        return VoucherLine(
          product: l['item_name'] as String? ?? '-',
          sku: prod['sku'] as String?,
          uom: uomAbbr,
          qty: qty,
          unitPrice: price,
          discountPct: pct,
          lineTotal: gross - da,
        );
      }).toList();

      final realOrg = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
      final realBranch = _branches.firstWhere((b) => b['id'] == _doc!['branch_id'], orElse: () => {'name': null})['name'] as String?;
      final validUntil = _doc!['valid_until'] != null
          ? DateFormat('dd MMM yyyy').format(_doc!['valid_until'] as DateTime)
          : null;
      final globalDisc = _globalDiscAmt;
      final remarksText = _notesCtrl.text.trim();

      // "Prepared By" = the user who created/saved this quotation.
      String? preparedBy;
      final createdBy = _doc!['created_by'] as String?;
      if (createdBy != null) {
        try {
          final u = await _client.from('users').select('name').eq('id', createdBy).maybeSingle();
          preparedBy = u?['name'] as String?;
        } catch (_) {}
      }
      preparedBy ??= ref.read(currentUserProvider)?.name;

      // Validity + Remarks share one row (as relatedRefs cells) to save space.
      final refs = <String, String>{};
      if (validUntil != null) refs['Valid Until'] = validUntil;
      if (remarksText.isNotEmpty) refs['Remarks'] = remarksText;

      await VoucherPdf.printVoucher(
        voucherNumber: (_doc!['voucher_number']?.toString().isNotEmpty ?? false)
            ? _doc!['voucher_number'].toString()
            : '(unsaved)',
        voucherTypeLabel: 'Quotation',
        orgName: _printCustomCompany && _customCompanyAllowed
            ? _customCompanyName
            : (_printCompany ? realOrg : ''),
        branchName: _printBranch ? realBranch : null,
        date: DateFormat('dd MMM yyyy').format(_doc!['voucher_date'] as DateTime),
        customerOrSupplier: custName,
        customerPhone: custPhone,
        status: null, // no voucher status on quotation print
        remarks: null, // remarks now rendered in the shared row below
        relatedRefs: refs.isEmpty ? null : refs,
        preparedBy: _printPreparedBy ? preparedBy : null,
        lines: lines,
        subtotal: subtotal,
        discountTotal: discTotal + globalDisc,
        grandTotal: subtotal - discTotal - globalDisc,
        footerNote: null,
      );
    } catch (e) {
      _toast('Print failed: $e');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return _doc == null ? _buildList() : _buildEditor();
  }

  bool _isExpired(Map<String, dynamic> r) {
    final vu = r['valid_until'] as String?;
    if (vu == null || vu.isEmpty) return false;
    final d = DateTime.tryParse(vu);
    if (d == null) return false;
    final today = DateTime.now();
    return d.isBefore(DateTime(today.year, today.month, today.day));
  }

  Widget _buildList() {
    final q = _search.trim().toLowerCase();
    final rows = _list.where((r) {
      final status = r['status'] as String? ?? 'saved';
      final expired = _isExpired(r);
      switch (_statusFilter) {
        case 'all': break;
        case 'expired':
          if (!expired) return false;
          break;
        case 'saved':
        case 'draft':
        case 'exported':
          // An expired quote is shown under Expired, not its stored status.
          if (expired || status != _statusFilter) return false;
          break;
        default:
          if (status != _statusFilter) return false;
      }
      if (q.isEmpty) return true;
      final vn = (r['voucher_number'] as String? ?? '').toLowerCase();
      final cn = (r['_customer_name'] as String? ?? '').toLowerCase();
      return vn.contains(q) || cn.contains(q);
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Quotations', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _newDoc,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Quotation'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
          ),
        ]),
        const SizedBox(height: 4),
        Text('${_list.length} quotations', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: TextField(
            decoration: InputDecoration(
              hintText: 'Search by number or customer...',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true, filled: true, fillColor: const Color(0xFFF8F9FA),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
            onChanged: (v) => setState(() => _search = v),
          )),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _statusFilter,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(value: 'saved', child: Text('Saved')),
              DropdownMenuItem(value: 'draft', child: Text('Draft')),
              DropdownMenuItem(value: 'exported', child: Text('Exported')),
              DropdownMenuItem(value: 'expired', child: Text('Expired')),
            ],
            onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
          ),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
          child: Row(children: const [
            Expanded(flex: 2, child: Text('Number', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 3, child: Text('Customer', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Value', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
            Expanded(flex: 2, child: Text('Valid Until', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: rows.isEmpty
          ? const Center(child: Text('No quotations', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = rows[i];
                final status = _isExpired(r) ? 'expired' : (r['status'] as String? ?? 'saved');
                return InkWell(
                  onTap: () => _openDoc(r),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(children: [
                      Expanded(flex: 2, child: Text(r['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary))),
                      Expanded(flex: 3, child: Text(r['_customer_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Text(r['_branch_name'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text(r['voucher_date'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Rs. ${((r['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
                      Expanded(flex: 2, child: Text(r['valid_until'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: _statusChip(status)),
                    ]),
                  ),
                );
              },
            )),
      ]),
    );
  }

  Widget _statusChip(String s) {
    Color c;
    switch (s) {
      case 'saved': c = Colors.green; break;
      case 'exported': c = AppTheme.primary; break;
      case 'expired': c = Colors.red; break;
      case 'draft': c = Colors.orange; break;
      default: c = Colors.grey;
    }
    return Align(alignment: Alignment.centerLeft, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(s[0].toUpperCase() + s.substring(1), style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700)),
    ));
  }

  Widget _buildEditor() {
    final isNew = _doc!['id'] == null;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: _closeDoc),
          const SizedBox(width: 4),
          Text(isNew ? 'New Quotation' : (_doc!['voucher_number'] as String? ?? 'Quotation'),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (!isNew) OutlinedButton.icon(
            onPressed: _saving ? null : _printQuotation,
            icon: const Icon(Icons.print_outlined, size: 18),
            label: const Text('Print'),
          ),
          if (!isNew) PopupMenuButton<String>(
            tooltip: 'Options',
            icon: const Icon(Icons.tune, size: 18),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'company', checked: _printCompany, child: const Text('Show company name')),
              if (_customCompanyAllowed)
                CheckedPopupMenuItem(value: 'customCompany', checked: _printCustomCompany, child: const Text('Show custom company name')),
              CheckedPopupMenuItem(value: 'branch', checked: _printBranch, child: const Text('Show branch')),
              CheckedPopupMenuItem(value: 'preparedBy', checked: _printPreparedBy, child: const Text('Show prepared by')),
              const PopupMenuDivider(),
              if ((_doc!['status'] as String? ?? 'saved') != 'draft')
                const PopupMenuItem(value: 'mark_draft', child: Text('Mark as Draft')),
              if ((_doc!['status'] as String? ?? 'saved') != 'saved')
                const PopupMenuItem(value: 'mark_saved', child: Text('Mark as Saved')),
            ],
            onSelected: (v) {
              if (v == 'company') setState(() {
                _printCompany = !_printCompany;
                if (_printCompany) _printCustomCompany = false; // mutually exclusive
              });
              if (v == 'customCompany') setState(() {
                _printCustomCompany = !_printCustomCompany;
                if (_printCustomCompany) _printCompany = false; // mutually exclusive
              });
              if (v == 'branch') setState(() => _printBranch = !_printBranch);
              if (v == 'preparedBy') setState(() => _printPreparedBy = !_printPreparedBy);
              if (v == 'mark_draft') _setStatus('draft');
              if (v == 'mark_saved') _setStatus('saved');
            },
          ),
          if (!isNew) const SizedBox(width: 10),
          if (!isNew) OutlinedButton.icon(
            onPressed: _saving ? null : _exportDialog,
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('Export'),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 18),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
          ),
        ]),
        const SizedBox(height: 16),
        // Header fields
        Wrap(spacing: 16, runSpacing: 12, children: [
          _field('Customer', SizedBox(width: 260, child: InkWell(
            onTap: _pickCustomer,
            child: InputDecorator(
              decoration: _dec(),
              child: Row(children: [
                Expanded(child: Text(
                  _doc!['customer_id'] == null
                      ? 'Walk-in / none'
                      : (_customers.firstWhere((c) => c['id'] == _doc!['customer_id'], orElse: () => {'shop_name': '-'})['shop_name'] as String? ?? '-'),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: _doc!['customer_id'] == null ? AppTheme.textSecondary : Colors.black87),
                )),
                const Icon(Icons.arrow_drop_down, size: 20, color: AppTheme.textSecondary),
              ]),
            ),
          ))),
          _field('Branch', SizedBox(width: 220, child: DropdownButtonFormField<String>(
            value: _doc!['branch_id'] as String?,
            isExpanded: true,
            decoration: _dec(),
            items: _branches.map((b) => DropdownMenuItem<String>(value: b['id'] as String, child: Text(b['name'] as String? ?? '-', overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setState(() => _doc!['branch_id'] = v),
          ))),
          _field('Date', SizedBox(width: 160, child: InkWell(
            onTap: () async {
              final d = await showDatePicker(context: context, initialDate: _doc!['voucher_date'] as DateTime, firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) setState(() => _doc!['voucher_date'] = d);
            },
            child: InputDecorator(decoration: _dec(), child: Text(DateFormat('dd MMM yyyy').format(_doc!['voucher_date'] as DateTime), style: const TextStyle(fontSize: 13))),
          ))),
          _field('Valid Until (optional)', SizedBox(width: 180, child: InkWell(
            onTap: () async {
              final d = await showDatePicker(context: context, initialDate: (_doc!['valid_until'] as DateTime?) ?? DateTime.now().add(const Duration(days: 15)), firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) setState(() => _doc!['valid_until'] = d);
            },
            child: InputDecorator(decoration: _dec(), child: Row(children: [
              Expanded(child: Text(_doc!['valid_until'] != null ? DateFormat('dd MMM yyyy').format(_doc!['valid_until'] as DateTime) : '—', style: const TextStyle(fontSize: 13))),
              if (_doc!['valid_until'] != null) InkWell(onTap: () => setState(() => _doc!['valid_until'] = null), child: const Icon(Icons.clear, size: 14)),
            ])),
          ))),
        ]),
        const SizedBox(height: 20),
        // Lines header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
          child: Row(children: const [
            SizedBox(width: 40, child: Text('Sr#', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 4, child: Text('Item', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 1, child: Text('UoM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Rate', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Discount', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            SizedBox(width: 40),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: ListView.separated(
          itemCount: _lines.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) => _lineRow(i),
        )),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
          TextButton.icon(onPressed: _addLineAndPick, icon: const Icon(Icons.add, size: 18), label: const Text('Add Line')),
          const SizedBox(width: 8),
          if (_lines.isNotEmpty)
            TextButton.icon(onPressed: _bulkDiscountDialog, icon: const Icon(Icons.percent, size: 16), label: const Text('Discount All Lines')),
          const Spacer(),
        ])),
        // Totals block: Subtotal → Global Discount (fixed/%) → Grand Total
        Align(
          alignment: Alignment.centerRight,
          child: SizedBox(width: 360, child: Column(children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
              const Text('Subtotal', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const Spacer(),
              Text('Rs. ${_linesSubtotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ])),
            Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
              const Text('Global Discount', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const Spacer(),
              SizedBox(width: 90, child: TextField(
                controller: _globalDiscCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.right,
                decoration: _dec(),
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => setState(() {}),
              )),
              const SizedBox(width: 6),
              DropdownButton<String>(
                value: _globalDiscType,
                underline: const SizedBox(),
                isDense: true,
                items: const [DropdownMenuItem(value: 'fixed', child: Text('Rs', style: TextStyle(fontSize: 12))), DropdownMenuItem(value: 'percent', child: Text('%', style: TextStyle(fontSize: 12)))],
                onChanged: (v) => setState(() => _globalDiscType = v ?? 'fixed'),
              ),
              const SizedBox(width: 6),
              SizedBox(width: 70, child: Text('- ${_globalDiscAmt.toStringAsFixed(2)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: Colors.orange))),
            ])),
            const Divider(),
            Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
              const Text('Grand Total', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const Spacer(),
              Text('Rs. ${_grandTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)),
            ])),
          ])),
        ),
        const SizedBox(height: 12),
        SizedBox(width: 420, child: TextField(
          controller: _notesCtrl,
          decoration: InputDecoration(labelText: 'Remarks (optional)', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          maxLines: 2,
        )),
      ]),
    );
  }

  Widget _lineRow(int i) {
    final l = _lines[i];
    final c = _ctl(l);
    final prod = _products.firstWhere((p) => p['id'] == l['product_id'], orElse: () => {});
    final uomAbbr = prod.isEmpty ? '-' : ((prod['uoms']?['abbreviation'] as String?) ?? (prod['uoms']?['name'] as String?) ?? '-');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        SizedBox(width: 40, child: Text('${i + 1}', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Expanded(flex: 4, child: InkWell(
          onTap: () => _productPicker(i),
          child: InputDecorator(
            decoration: _dec(),
            child: Text(l['item_name'] as String? ?? '+ Select product',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: l['item_name'] == null ? AppTheme.textSecondary : Colors.black87)),
          ),
        )),
        Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(uomAbbr, style: const TextStyle(fontSize: 13)))),
        Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: TextField(
          controller: c['qtyCtrl'] as TextEditingController,
          focusNode: c['qtyFocus'] as FocusNode,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          decoration: _dec(),
          style: const TextStyle(fontSize: 13),
          onChanged: (v) => setState(() => l['quantity'] = double.tryParse(v) ?? 0),
          onSubmitted: (_) {
            final f = c['priceFocus'] as FocusNode;
            final pc = c['priceCtrl'] as TextEditingController;
            pc.selection = TextSelection(baseOffset: 0, extentOffset: pc.text.length);
            f.requestFocus();
          },
        ))),
        Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: TextField(
          controller: c['priceCtrl'] as TextEditingController,
          focusNode: c['priceFocus'] as FocusNode,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          decoration: _dec(),
          style: const TextStyle(fontSize: 13),
          onChanged: (v) => setState(() => l['unit_price'] = double.tryParse(v) ?? 0),
          onSubmitted: (_) {
            final f = c['discFocus'] as FocusNode;
            final dc = c['discCtrl'] as TextEditingController;
            dc.selection = TextSelection(baseOffset: 0, extentOffset: dc.text.length);
            f.requestFocus();
          },
        ))),
        Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Row(children: [
          Expanded(child: TextField(
            controller: c['discCtrl'] as TextEditingController,
            focusNode: c['discFocus'] as FocusNode,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            decoration: _dec(),
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => setState(() => l['discount'] = double.tryParse(v) ?? 0),
            onSubmitted: (_) => _addLineAndPick(), // reopen picker for next line
          )),
          const SizedBox(width: 4),
          DropdownButton<String>(
            value: l['discount_type'] as String? ?? 'fixed',
            underline: const SizedBox(),
            isDense: true,
            items: const [DropdownMenuItem(value: 'fixed', child: Text('Rs', style: TextStyle(fontSize: 12))), DropdownMenuItem(value: 'percent', child: Text('%', style: TextStyle(fontSize: 12)))],
            onChanged: (v) => setState(() => l['discount_type'] = v),
          ),
        ]))),
        Expanded(flex: 2, child: Text('Rs. ${_lineTotal(l).toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        SizedBox(width: 40, child: IconButton(
          icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() { _disposeLineCtl(l); _lines.removeAt(i); }),
        )),
      ]),
    );
  }

  // Open the shared product picker (keyboard nav) for an existing line row.
  Future<void> _productPicker(int idx) async {
    final picked = await pickProduct(context, _products, title: 'Select product');
    if (picked != null && picked.isNotEmpty) _pickProduct(idx, picked);
  }

  // Add-product loop with per-line Enter chain:
  //   pick product → line added → focus its Qty → Enter → Price → Enter →
  //   Discount → Enter → reopen picker → repeat. Ends when the picker is
  //   dismissed (× or Esc).
  Future<void> _addLineAndPick() async {
    final picked = await pickProduct(context, _products, title: 'Add product to quotation');
    if (picked == null || picked.isEmpty) return; // × / Esc ends the loop
    final line = {
      'product_id': picked['id'],
      'item_name': picked['name'],
      'uom_id': picked['base_uom_id'],
      'quantity': 1.0,
      'unit_price': (picked['selling_price'] as num?)?.toDouble() ?? 0.0,
      'discount': 0.0,
      'discount_type': 'percent',
    };
    setState(() => _lines.add(line));
    // After the row builds, focus its Qty field and select the text so typing
    // replaces the default. The Enter chain (wired in _lineRow) carries through
    // Price → Discount → back into this method to reopen the picker.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _ctl(line);
      final qc = c['qtyCtrl'] as TextEditingController;
      qc.selection = TextSelection(baseOffset: 0, extentOffset: qc.text.length);
      (c['qtyFocus'] as FocusNode).requestFocus();
    });
  }

  // Bulk discount: choose a type (Rs/%) applied to ALL lines, and optionally a
  // value. If a value is entered it's pushed to every line (overwriting); if
  // left blank only the type is applied and each line keeps its own value.
  Future<void> _bulkDiscountDialog() async {
    String type = _globalDiscType == 'percent' ? 'percent' : 'fixed';
    final valCtrl = TextEditingController();
    final applied = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setModal) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Discount All Lines', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Discount type', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(children: [
            ChoiceChip(label: const Text('Rs (Fixed)'), selected: type == 'fixed', onSelected: (_) => setModal(() => type = 'fixed')),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text('% (Percent)'), selected: type == 'percent', onSelected: (_) => setModal(() => type = 'percent')),
          ]),
          const SizedBox(height: 16),
          const Text('Value (optional)', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: valCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              hintText: type == 'percent' ? 'e.g. 10 (applies 10% to all lines)' : 'e.g. 50 (applies Rs. 50 to all lines)',
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 8),
          const Text('Leave value blank to change only the type on every line (each line keeps its own amount). Entering a value overwrites every line\u2019s discount.',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('Apply to all')),
        ],
      )),
    );
    if (applied != true) return;
    final raw = valCtrl.text.trim();
    final hasValue = raw.isNotEmpty;
    final value = double.tryParse(raw) ?? 0;
    setState(() {
      for (final l in _lines) {
        l['discount_type'] = type;
        if (hasValue) l['discount'] = value;
        // sync the row's controllers so the grid reflects the change
        final c = _ctl(l);
        if (hasValue) (c['discCtrl'] as TextEditingController).text = value.toString();
      }
    });
  }

  Widget _field(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        child,
      ]);

  InputDecoration _dec() => InputDecoration(
        isDense: true,
        filled: true, fillColor: const Color(0xFFF8F9FA),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      );
}
