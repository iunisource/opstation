import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/search/text_search.dart';
import '../../../core/layout/main_layout.dart' show selectedBranchProvider;
import '../../../core/widgets/product_picker.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';

// ============================================================================
// QUICK COSTING  (Sales)
// Price a prospect's custom spec without creating a product or BOM first.
// All costs are worked out on the server (qc_calc / qc_save, update 426).
// People who may not see costs only ever receive the selling price.
// ============================================================================

class _QLine {
  String? id;
  String kind; // material | labor | overhead
  String? productId;
  String? rateId;
  String label; // product name / one-off description
  String? uom;
  final TextEditingController qtyCtrl;
  final TextEditingController costCtrl; // one-off price, or a replaced cost
  final TextEditingController descCtrl; // one-off description
  final TextEditingController uomCtrl; // one-off unit
  double? unitCost;
  double? amount;
  String? source;

  _QLine({
    this.id,
    required this.kind,
    this.productId,
    this.rateId,
    this.label = '',
    this.uom,
    double qty = 1,
    double? cost,
  })  : qtyCtrl = TextEditingController(text: _num(qty)),
        costCtrl = TextEditingController(text: cost == null ? '' : _num(cost)),
        descCtrl = TextEditingController(text: label),
        uomCtrl = TextEditingController(text: uom ?? '');

  bool get oneOff => kind == 'material' && productId == null;
  double get qty => double.tryParse(qtyCtrl.text.trim()) ?? 0;
  double? get cost => double.tryParse(costCtrl.text.trim());

  void dispose() {
    qtyCtrl.dispose();
    costCtrl.dispose();
    descCtrl.dispose();
    uomCtrl.dispose();
  }

  static String _num(num v) {
    final d = v.toDouble();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }
}

class ErpQuickCostingScreen extends ConsumerStatefulWidget {
  const ErpQuickCostingScreen({super.key});
  @override
  ConsumerState<ErpQuickCostingScreen> createState() => _State();
}

class _State extends ConsumerState<ErpQuickCostingScreen> {
  final _client = Supabase.instance.client;
  String? _orgId;
  String? _branchId;

  bool _loading = true;
  bool _canSee = false;
  double _defaultProfit = 25;
  List<Map<String, dynamic>> _rows = [];
  String _search = '';

  // reference data
  List<Map<String, dynamic>> _products = [];
  Map<String, Map<String, dynamic>> _productById = {};
  List<Map<String, dynamic>> _laborTypes = [];
  List<Map<String, dynamic>> _overheadTypes = [];

  // editor (null = list view)
  Map<String, dynamic>? _doc;
  final List<_QLine> _lines = [];
  final _prospectCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _specsCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _outCtrl = TextEditingController(text: '1');
  final _wasteCtrl = TextEditingController(text: '0');
  final _profitCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _daysCtrl = TextEditingController(text: '7');
  final _notesCtrl = TextEditingController();
  String _basis = 'method';
  Map<String, dynamic>? _calc;
  bool _calcBusy = false;
  bool _saving = false;
  bool _dirty = false;
  Timer? _calcTimer;
  int _calcSeq = 0;

  static final _date = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _calcTimer?.cancel();
    for (final l in _lines) {
      l.dispose();
    }
    for (final c in [_prospectCtrl, _phoneCtrl, _titleCtrl, _specsCtrl, _qtyCtrl, _outCtrl,
      _wasteCtrl, _profitCtrl, _priceCtrl, _daysCtrl, _notesCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  bool get _isAdmin {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
  }

  // ------------------------------------------------------------------ loading
  Future<void> _boot() async {
    _orgId = ref.read(currentUserProvider)?.orgId;
    _branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    if (_orgId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    await Future.wait([_loadList(), _loadRefs()]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadList() async {
    try {
      final res = await _client.rpc('qc_list', params: {
        'p_org': _orgId,
        'p_search': _search.trim().isEmpty ? null : _search.trim(),
      });
      final m = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      setState(() {
        _canSee = m['can_see_costs'] == true;
        final dp = (m['default_profit'] as num?)?.toDouble();
        if (dp != null) _defaultProfit = dp;
        _rows = List<Map<String, dynamic>>.from((m['rows'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)));
      });
    } catch (e) {
      _snack(friendlyError('Could not load costings', e));
    }
  }

  Future<void> _loadRefs() async {
    try {
      final all = <Map<String, dynamic>>[];
      var from = 0;
      while (true) {
        final rows = await _client
            .from('products')
            .select('id, name, sku, base_uom_id, uoms:base_uom_id(name, abbreviation)')
            .eq('org_id', _orgId!)
            .eq('is_active', true)
            .order('name')
            .range(from, from + 999);
        final list = List<Map<String, dynamic>>.from(rows as List);
        all.addAll(list);
        if (list.length < 1000 || from > 100000) break;
        from += 1000;
      }
      final lt = await _client.from('labor_types').select('id, name, rate').eq('org_id', _orgId!).order('name');
      final ot = await _client.from('overhead_types').select('id, name, rate').eq('org_id', _orgId!).order('name');
      if (!mounted) return;
      setState(() {
        _products = all;
        _productById = {for (final p in all) p['id'] as String: p};
        _laborTypes = List<Map<String, dynamic>>.from(lt as List);
        _overheadTypes = List<Map<String, dynamic>>.from(ot as List);
      });
    } catch (e) {
      _snack(friendlyError('Could not load products', e));
    }
  }

  String _uomOf(String? productId) {
    final p = productId == null ? null : _productById[productId];
    final u = p?['uoms'];
    if (u is Map) return '${u['abbreviation'] ?? u['name'] ?? ''}';
    return '';
  }

  String _productLabel(String? id) {
    final p = id == null ? null : _productById[id];
    if (p == null) return 'Product not found';
    final sku = '${p['sku'] ?? ''}'.trim();
    return sku.isEmpty ? '${p['name'] ?? ''}' : '$sku — ${p['name'] ?? ''}';
  }

  String _rateName(String kind, String? id) {
    final list = kind == 'labor' ? _laborTypes : _overheadTypes;
    final r = list.where((e) => e['id'] == id).toList();
    return r.isEmpty ? '' : '${r.first['name'] ?? ''}';
  }

  // ------------------------------------------------------------------ editor
  void _clearEditor() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
    _calc = null;
    _dirty = false;
  }

  void _newCosting() {
    _clearEditor();
    _prospectCtrl.clear();
    _phoneCtrl.clear();
    _titleCtrl.clear();
    _specsCtrl.clear();
    _qtyCtrl.text = '1';
    _outCtrl.text = '1';
    _wasteCtrl.text = '0';
    _profitCtrl.text = _LineNum.fmt(_defaultProfit);
    _priceCtrl.clear();
    _daysCtrl.text = '7';
    _notesCtrl.clear();
    _basis = 'method';
    setState(() => _doc = {});
    _scheduleCalc();
  }

  Future<void> _open(String id) async {
    try {
      final res = await _client.rpc('qc_get', params: {'p_id': id});
      _fill(Map<String, dynamic>.from(res as Map));
    } catch (e) {
      _snack(friendlyError('Could not open costing', e));
    }
  }

  void _fill(Map<String, dynamic> d) {
    _clearEditor();
    _canSee = d['can_see_costs'] == true;
    _prospectCtrl.text = '${d['prospect_name'] ?? ''}';
    _phoneCtrl.text = '${d['prospect_phone'] ?? ''}';
    _titleCtrl.text = '${d['title'] ?? ''}';
    _specsCtrl.text = '${d['specs'] ?? ''}';
    _qtyCtrl.text = _LineNum.fmt(d['quantity']);
    _outCtrl.text = _LineNum.fmt(d['output_qty']);
    _wasteCtrl.text = _LineNum.fmt(d['wastage_pct']);
    _profitCtrl.text = d['profit_pct'] == null ? _LineNum.fmt(_defaultProfit) : _LineNum.fmt(d['profit_pct']);
    _priceCtrl.text = d['price_override'] == null ? '' : _LineNum.fmt(d['price_override']);
    _daysCtrl.text = '${d['valid_days'] ?? 7}';
    _notesCtrl.text = '${d['notes'] ?? ''}';
    _basis = d['basis'] == 'purchase' ? 'purchase' : 'method';
    for (final x in (d['lines'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(x as Map);
      final kind = '${m['kind']}';
      final pid = m['product_id'] as String?;
      final l = _QLine(
        id: m['id'] as String?,
        kind: kind,
        productId: pid,
        rateId: m['rate_id'] as String?,
        label: kind == 'material' ? (pid == null ? '${m['description'] ?? ''}' : _productLabel(pid)) : _rateName(kind, m['rate_id'] as String?),
        uom: pid == null ? m['uom'] as String? : _uomOf(pid),
        qty: (m['qty'] as num?)?.toDouble() ?? 0,
        cost: (m['cost_override'] as num?)?.toDouble(),
      );
      l.unitCost = (m['unit_cost'] as num?)?.toDouble();
      l.amount = (m['amount'] as num?)?.toDouble();
      l.source = m['cost_source'] as String?;
      _lines.add(l);
    }
    setState(() => _doc = d);
    _scheduleCalc(dirty: false);
  }

  Map<String, dynamic> _payload() => {
        if ((_doc?['id'] ?? '') != '') 'id': _doc!['id'],
        'org_id': _orgId,
        'branch_id': _branchId,
        'prospect_name': _prospectCtrl.text.trim(),
        'prospect_phone': _phoneCtrl.text.trim(),
        'title': _titleCtrl.text.trim(),
        'specs': _specsCtrl.text.trim(),
        'quantity': double.tryParse(_qtyCtrl.text.trim()) ?? 0,
        'output_qty': double.tryParse(_outCtrl.text.trim()) ?? 1,
        'wastage_pct': double.tryParse(_wasteCtrl.text.trim()) ?? 0,
        if (_canSee) 'profit_pct': double.tryParse(_profitCtrl.text.trim()) ?? _defaultProfit,
        if (_canSee) 'price_override': double.tryParse(_priceCtrl.text.trim()),
        'valid_days': int.tryParse(_daysCtrl.text.trim()) ?? 7,
        'basis': _basis,
        'notes': _notesCtrl.text.trim(),
        'lines': [
          for (final l in _lines)
            if (l.kind == 'material' ? (l.productId != null || l.descCtrl.text.trim().isNotEmpty) : l.rateId != null)
              {
                if (l.id != null) 'id': l.id,
                'kind': l.kind,
                'product_id': l.productId,
                'rate_id': l.rateId,
                'description': l.oneOff ? l.descCtrl.text.trim() : l.label,
                'uom': l.oneOff ? (l.uom ?? '') : _uomOf(l.productId),
                'qty': l.qty,
                if (l.kind == 'material' && (l.oneOff || _canSee)) 'cost_override': l.cost,
              },
        ],
      };

  void _scheduleCalc({bool dirty = true}) {
    if (dirty && !_dirty) setState(() => _dirty = true);
    _calcTimer?.cancel();
    _calcTimer = Timer(const Duration(milliseconds: 450), _runCalc);
  }

  Future<void> _runCalc() async {
    if (_doc == null || _orgId == null) return;
    final seq = ++_calcSeq;
    setState(() => _calcBusy = true);
    try {
      final payload = _payload();
      final sent = (payload['lines'] as List).length;
      final res = Map<String, dynamic>.from(await _client.rpc('qc_calc', params: {'p': payload}) as Map);
      if (!mounted || seq != _calcSeq) return;
      final back = (res['lines'] as List? ?? []);
      // Map results back onto the lines that were sent (same order).
      final sentLines = [
        for (final l in _lines)
          if (l.kind == 'material' ? (l.productId != null || l.descCtrl.text.trim().isNotEmpty) : l.rateId != null) l,
      ];
      if (back.length == sent) {
        for (var i = 0; i < sentLines.length; i++) {
          final m = Map<String, dynamic>.from(back[i] as Map);
          sentLines[i].unitCost = (m['unit_cost'] as num?)?.toDouble();
          sentLines[i].amount = (m['amount'] as num?)?.toDouble();
          sentLines[i].source = m['cost_source'] as String?;
        }
      }
      setState(() {
        _calc = res;
        _canSee = res['can_see_costs'] == true;
      });
    } catch (e) {
      if (mounted && seq == _calcSeq) _snack(friendlyError('Could not work out the price', e));
    } finally {
      if (mounted && seq == _calcSeq) setState(() => _calcBusy = false);
    }
  }

  Future<bool> _save() async {
    if (_prospectCtrl.text.trim().isEmpty) {
      _snack('Enter the prospect\'s name');
      return false;
    }
    if (_titleCtrl.text.trim().isEmpty) {
      _snack('Enter what is being priced');
      return false;
    }
    if ((double.tryParse(_qtyCtrl.text.trim()) ?? 0) <= 0) {
      _snack('Quantity must be more than zero');
      return false;
    }
    if ((int.tryParse(_daysCtrl.text.trim()) ?? 0) < 1) {
      _snack('Price must be valid for at least 1 day');
      return false;
    }
    if (_lines.where((l) => l.kind == 'material' && (l.productId != null || l.descCtrl.text.trim().isNotEmpty)).isEmpty) {
      _snack('Add at least one material');
      return false;
    }
    if (_lines.any((l) => l.oneOff && l.descCtrl.text.trim().isNotEmpty && (l.cost ?? 0) <= 0)) {
      _snack('Enter a price for each one-off item');
      return false;
    }
    setState(() => _saving = true);
    try {
      final res = await _client.rpc('qc_save', params: {'p': _payload()});
      _fill(Map<String, dynamic>.from(res as Map));
      _snack('Costing ${res['code']} saved');
      unawaited(_loadList());
      return true;
    } catch (e) {
      _snack(friendlyError('Could not save', e));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setStatus(String s) async {
    final id = _doc?['id'] as String?;
    if (id == null) return;
    try {
      await _client.rpc('qc_set_status', params: {'p_id': id, 'p_status': s});
      setState(() => _doc!['status'] = s);
      unawaited(_loadList());
    } catch (e) {
      _snack(friendlyError('Could not change status', e));
    }
  }

  Future<void> _delete() async {
    final id = _doc?['id'] as String?;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this costing?'),
        content: Text('${_doc!['code']} for ${_doc!['prospect_name']} will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _client.rpc('qc_delete', params: {'p_id': id});
      _clearEditor();
      setState(() => _doc = null);
      await _loadList();
      _snack('Costing deleted');
    } catch (e) {
      _snack(friendlyError('Could not delete', e));
    }
  }

  Future<bool> _leaveEditor() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: const Text('Your changes to this costing will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
        ],
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------------------ lines
  Future<void> _addMaterial() async {
    final p = await pickProduct(context, [
      for (final p in _products) {...p, 'name': '${p['name'] ?? ''}'},
    ], title: 'Pick a material');
    if (p == null) return;
    final pid = p['id'] as String;
    final existing = _lines.where((l) => l.kind == 'material' && l.productId == pid).toList();
    if (existing.isNotEmpty) {
      _snack('${_productLabel(pid)} is already in the list — change its quantity instead');
      return;
    }
    setState(() => _lines.add(_QLine(kind: 'material', productId: pid, label: _productLabel(pid), uom: _uomOf(pid))));
    _scheduleCalc();
  }

  void _addOneOff() {
    setState(() => _lines.add(_QLine(kind: 'material', uom: 'pcs')));
  }

  void _addCost() {
    final kind = _laborTypes.isNotEmpty ? 'labor' : 'overhead';
    setState(() => _lines.add(_QLine(kind: kind)));
  }

  void _removeLine(_QLine l) {
    setState(() {
      _lines.remove(l);
    });
    l.dispose();
    _scheduleCalc();
  }

  Future<void> _copyFromBom() async {
    List<Map<String, dynamic>> boms;
    try {
      boms = List<Map<String, dynamic>>.from(await _client
          .from('bom_headers')
          .select('id, code, name, output_qty, product_id')
          .eq('org_id', _orgId!)
          .order('name')
          .limit(2000) as List);
    } catch (e) {
      _snack(friendlyError('Could not load BOMs', e));
      return;
    }
    if (!mounted) return;
    if (boms.isEmpty) {
      _snack('No BOMs yet');
      return;
    }
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _BomPickerDialog(boms: boms),
    );
    if (picked == null) return;
    if (_lines.isNotEmpty && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Replace current lines?'),
          content: Text('Materials, labour and overheads will be replaced with those of ${picked['name']}.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Replace')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      final id = picked['id'] as String;
      final comps = await _client.from('bom_components').select('product_id, quantity').eq('bom_id', id).order('line_order');
      final ohs = await _client.from('bom_overheads').select('cost_type, rate_id, quantity').eq('bom_id', id).order('line_order');
      if (!mounted) return;
      setState(() {
        for (final l in _lines) {
          l.dispose();
        }
        _lines.clear();
        for (final c in comps as List) {
          final pid = c['product_id'] as String?;
          if (pid == null) continue;
          _lines.add(_QLine(kind: 'material', productId: pid, label: _productLabel(pid), uom: _uomOf(pid),
              qty: (c['quantity'] as num?)?.toDouble() ?? 0));
        }
        for (final o in ohs as List) {
          final kind = o['cost_type'] == 'labor' ? 'labor' : 'overhead';
          _lines.add(_QLine(kind: kind, rateId: o['rate_id'] as String?, label: _rateName(kind, o['rate_id'] as String?),
              qty: (o['quantity'] as num?)?.toDouble() ?? 1));
        }
        _outCtrl.text = _LineNum.fmt(picked['output_qty'] ?? 1);
        if (_titleCtrl.text.trim().isEmpty) _titleCtrl.text = '${picked['name'] ?? ''}';
      });
      _scheduleCalc();
    } catch (e) {
      _snack(friendlyError('Could not copy the BOM', e));
    }
  }

  // ------------------------------------------------------------------ print
  Future<void> _print() async {
    if (_dirty || (_doc?['id'] ?? '') == '') {
      if (!await _save()) return;
    }
    final d = _doc!;
    final user = ref.read(currentUserProvider);
    final qty = (d['quantity'] as num?)?.toDouble() ?? 0;
    final price = (d['unit_price'] as num?)?.toDouble() ?? 0;
    final total = (d['total_price'] as num?)?.toDouble() ?? 0;
    final until = DateTime.tryParse('${d['valid_until'] ?? ''}');
    final days = d['valid_days'] ?? 7;
    final remarks = [
      if ('${d['specs'] ?? ''}'.trim().isNotEmpty) 'Specifications: ${'${d['specs']}'.trim()}',
      if ('${d['notes'] ?? ''}'.trim().isNotEmpty) '${d['notes']}'.trim(),
    ].join('\n');
    try {
      await VoucherPdf.printVoucher(
        voucherNumber: '${d['code'] ?? ''}',
        voucherTypeLabel: 'Price Offer',
        orgName: user?.orgName ?? '',
        branchName: ref.read(selectedBranchProvider)?['name'] as String?,
        date: _date.format(DateTime.now()),
        customerOrSupplier: '${d['prospect_name'] ?? ''}',
        customerPhone: (d['prospect_phone'] as String?)?.isEmpty ?? true ? null : d['prospect_phone'] as String?,
        remarks: remarks.isEmpty ? null : remarks,
        lines: [VoucherLine(product: '${d['title'] ?? ''}', qty: qty, unitPrice: price, lineTotal: total)],
        subtotal: total,
        grandTotal: total,
        preparedBy: user?.name,
        footerNote: until == null
            ? 'Prices are valid for $days days.'
            : 'Prices are valid for $days days, until ${_date.format(until)}.',
      );
      if (d['status'] == 'draft') await _setStatus('sent');
    } catch (e) {
      _snack(friendlyError('Could not print', e));
    }
  }

  // ------------------------------------------------------------------ make product
  Future<void> _makeProduct() async {
    if (_dirty) {
      if (!await _save()) return;
    }
    if (_lines.any((l) => l.oneOff)) {
      _snack('Some materials are one-off items. Add them as products first, pick them here, then try again.');
      return;
    }
    List<Map<String, dynamic>> uoms = [];
    List<String> types = [];
    try {
      uoms = List<Map<String, dynamic>>.from(await _client.from('uoms').select('id, name, abbreviation').order('name') as List);
      final t = await _client.from('product_taxonomies').select('name').eq('org_id', _orgId!).eq('type', 'product_type').order('name');
      types = [for (final r in t as List) '${r['name']}'];
    } catch (_) {}
    if (!mounted) return;
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _MakeProductDialog(
        name: '${_doc!['title'] ?? ''}',
        price: (_doc!['unit_price'] as num?)?.toDouble() ?? 0,
        uoms: uoms,
        types: types,
      ),
    );
    if (res == null) return;
    try {
      final out = await _client.rpc('qc_make_product', params: {
        'p_id': _doc!['id'],
        'p_name': res['name'],
        'p_sku': res['sku'],
        'p_uom': res['uom'],
        'p_type': res['type'],
        'p_selling_price': res['price'],
      });
      _snack('Product "${res['name']}" and ${(out as Map)['bom_code']} created');
      await _open(_doc!['id'] as String);
      unawaited(_loadList());
    } catch (e) {
      _snack(friendlyError('Could not create the product', e));
    }
  }

  Future<void> _editDefaultProfit() async {
    final ctrl = TextEditingController(text: _LineNum.fmt(_defaultProfit));
    final v = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Default profit'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Used for new costings, and for costings made by people who can\'t see costs.',
                style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [_LineNum.decimal],
              decoration: const InputDecoration(labelText: 'Profit on cost', suffixText: '%', border: OutlineInputBorder()),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, double.tryParse(ctrl.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (v == null || v < 0) return;
    try {
      await _client.from('app_config').upsert({
        'key': 'org.quick_costing_default_profit',
        'value': _LineNum.fmt(v),
        'org_id': _orgId,
      }, onConflict: 'key,org_id,branch_id');
      setState(() => _defaultProfit = v);
      _snack('Default profit set to ${_LineNum.fmt(v)}%');
    } catch (e) {
      _snack(friendlyError('Could not save the default profit', e));
    }
  }

  // ================================================================== UI
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_orgId == null) return const Center(child: Text('Pick an organisation first.'));
    return _doc == null ? _buildList() : _buildEditor();
  }

  Widget _statusChip(String? s) {
    final (label, color) = switch (s) {
      'sent' => ('Sent', AppTheme.primary),
      'won' => ('Won', AppTheme.success),
      'lost' => ('Lost', AppTheme.danger),
      _ => ('Draft', AppTheme.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildList() {
    final rows = _rows.where((r) => _search.trim().isEmpty ||
        matchesQuery('${r['code']} ${r['prospect_name']} ${r['title']}', _search)).toList();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Quick Costing', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          SizedBox(
            width: 280,
            child: TextField(
              decoration: const InputDecoration(
                  isDense: true, prefixIcon: Icon(Icons.search, size: 20), hintText: 'Search prospect, item or code',
                  border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          FilledButton.icon(onPressed: _newCosting, icon: const Icon(Icons.add), label: const Text('New costing')),
          if (_isAdmin)
            OutlinedButton.icon(
              onPressed: _editDefaultProfit,
              icon: const Icon(Icons.tune, size: 18),
              label: Text('Default profit ${_LineNum.fmt(_defaultProfit)}%'),
            ),
        ]),
        const SizedBox(height: 6),
        const Text('Price a prospect\'s own specification without making a product or BOM first.',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
                color: AppTheme.card, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(12)),
            child: rows.isEmpty
                ? const Center(child: Text('No costings yet. Tap "New costing" to price a request.',
                    style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      final until = DateTime.tryParse('${r['valid_until'] ?? ''}');
                      final expired = until != null &&
                          until.isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));
                      return ListTile(
                        onTap: () => _open(r['id'] as String),
                        title: Text('${r['title']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text([
                          '${r['code']}',
                          '${r['prospect_name']}',
                          'Qty ${_LineNum.fmt(r['quantity'])}',
                          if (until != null) (expired ? 'Expired ${_date.format(until)}' : 'Valid until ${_date.format(until)}'),
                          if ('${r['created_by_name'] ?? ''}'.isNotEmpty) 'by ${r['created_by_name']}',
                        ].join('  ·  ')),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(moneyRs(r['total_price'] as num?), style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text('${moneyRs(r['unit_price'] as num?)} each',
                                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                          ]),
                          const SizedBox(width: 12),
                          _statusChip(r['status'] as String?),
                        ]),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }

  InputDecoration _dec(String label, {String? suffix, String? hint}) => InputDecoration(
      labelText: label, suffixText: suffix, hintText: hint, isDense: true, border: const OutlineInputBorder());

  Widget _card(String title, List<Widget> children, {Widget? action, String? sub}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
            color: AppTheme.card, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            if (action != null) action,
          ]),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(sub, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ],
          const SizedBox(height: 12),
          ...children,
        ]),
      );

  Widget _numField(TextEditingController c, String label, {String? suffix, double width = 140, String? hint}) => SizedBox(
        width: width,
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [_LineNum.decimal],
          decoration: _dec(label, suffix: suffix, hint: hint),
          onChanged: (_) => _scheduleCalc(),
        ),
      );

  Widget _buildEditor() {
    final d = _doc!;
    final saved = (d['id'] ?? '') != '';
    final wide = MediaQuery.of(context).size.width > 1150;
    final left = Column(children: [
      _detailsCard(),
      _materialsCard(),
      _costsCard(),
    ]);
    final right = _resultCard();
    return Column(children: [
      // top bar
      Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
        decoration: const BoxDecoration(color: AppTheme.card, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(
            tooltip: 'Back to list',
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (!await _leaveEditor()) return;
              _clearEditor();
              setState(() => _doc = null);
            },
          ),
          Text(saved ? '${d['code']}' : 'New costing', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          if (saved) _statusChip(d['status'] as String?),
          if (_dirty) const Text('Not saved', style: TextStyle(color: AppTheme.warning, fontWeight: FontWeight.w600)),
          if (d['product_id'] != null)
            Chip(
              avatar: const Icon(Icons.inventory_2_outlined, size: 16),
              label: Text('Product made: ${_productById[d['product_id']]?['name'] ?? d['title']}'),
            ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save'),
          ),
          OutlinedButton.icon(onPressed: _saving ? null : _print, icon: const Icon(Icons.print_outlined, size: 18), label: const Text('Print price offer')),
          if (saved)
            PopupMenuButton<String>(
              tooltip: 'Mark as',
              onSelected: _setStatus,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'sent', child: Text('Mark as sent')),
                PopupMenuItem(value: 'won', child: Text('Mark as won')),
                PopupMenuItem(value: 'lost', child: Text('Mark as lost')),
                PopupMenuItem(value: 'draft', child: Text('Back to draft')),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [Text('Mark as'), Icon(Icons.arrow_drop_down)]),
              ),
            ),
          if (saved && _canSee && d['product_id'] == null)
            OutlinedButton.icon(
              onPressed: _makeProduct,
              icon: const Icon(Icons.add_box_outlined, size: 18),
              label: const Text('Make product & BOM'),
            ),
          if (saved && d['product_id'] == null)
            IconButton(tooltip: 'Delete', onPressed: _delete, icon: const Icon(Icons.delete_outline, color: AppTheme.danger)),
        ]),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: left),
                  const SizedBox(width: 16),
                  SizedBox(width: 360, child: right),
                ])
              : Column(children: [left, right]),
        ),
      ),
    ]);
  }

  Widget _detailsCard() => _card('Request', [
        Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(width: 280, child: TextField(controller: _prospectCtrl, decoration: _dec('Prospect name *'), onChanged: (_) => _markDirty())),
          SizedBox(width: 200, child: TextField(controller: _phoneCtrl, decoration: _dec('Phone'), onChanged: (_) => _markDirty())),
          SizedBox(width: 400, child: TextField(controller: _titleCtrl, decoration: _dec('Item being priced *', hint: 'e.g. 3-core cable 2.5 mm, 100 m coil'), onChanged: (_) => _markDirty())),
          _numField(_qtyCtrl, 'Quantity asked *', width: 160),
          SizedBox(
            width: 170,
            child: TextField(
              controller: _daysCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _dec('Price valid for', suffix: 'days'),
              onChanged: (_) => _markDirty(),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _specsCtrl,
          minLines: 2,
          maxLines: 5,
          decoration: _dec('Specifications', hint: 'Size, gauge, colour, packing, anything the client asked for'),
          onChanged: (_) => _markDirty(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notesCtrl,
          minLines: 1,
          maxLines: 3,
          decoration: _dec('Note for the client (printed)', hint: 'Delivery time, payment terms…'),
          onChanged: (_) => _markDirty(),
        ),
      ]);

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Widget _materialsCard() {
    final mats = _lines.where((l) => l.kind == 'material').toList();
    return _card(
      'Materials',
      [
        Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'method', label: Text('Stock cost'), icon: Icon(Icons.inventory_outlined, size: 18)),
              ButtonSegment(value: 'purchase', label: Text('Last purchase price'), icon: Icon(Icons.receipt_long_outlined, size: 18)),
            ],
            selected: {_basis},
            onSelectionChanged: (s) {
              setState(() => _basis = s.first);
              _scheduleCalc();
            },
          ),
          TextButton.icon(onPressed: _copyFromBom, icon: const Icon(Icons.copy_all_outlined, size: 18), label: const Text('Copy from a BOM')),
        ]),
        const SizedBox(height: 4),
        Text(
          _basis == 'method'
              ? 'Materials are priced at their current stock cost (your costing method).'
              : 'Materials are priced at their latest purchase invoice rate. Items never bought use stock cost.',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 12),
        if (mats.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No materials yet.', style: TextStyle(color: AppTheme.textSecondary)),
          ),
        for (final l in mats) _materialRow(l),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: _addMaterial, icon: const Icon(Icons.add, size: 18), label: const Text('Add material')),
          OutlinedButton.icon(onPressed: _addOneOff, icon: const Icon(Icons.edit_note, size: 18), label: const Text('Add one-off item')),
        ]),
        const SizedBox(height: 14),
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _numField(_wasteCtrl, 'Wastage', suffix: '%', width: 130),
          _numField(_outCtrl, 'One batch makes', suffix: 'units', width: 180),
          const Text('Quantities above are for one batch.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      ],
      sub: 'Pick stocked items, or type one-off items you don\'t stock with their price.',
    );
  }

  Widget _materialRow(_QLine l) {
    final costHint = l.unitCost == null ? null : 'Auto ${money(l.unitCost)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 320,
          child: l.oneOff
              ? TextField(
                  controller: l.descCtrl,
                  decoration: _dec('One-off item', hint: 'Describe the item'),
                  onChanged: (_) => _scheduleCalc(),
                )
              : InputDecorator(
                  decoration: _dec('Material'),
                  child: Text(l.label, overflow: TextOverflow.ellipsis),
                ),
        ),
        SizedBox(
          width: 120,
          child: TextField(
            controller: l.qtyCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [_LineNum.decimal],
            decoration: _dec('Qty', suffix: (l.uom ?? '').isEmpty ? null : l.uom),
            onChanged: (_) => _scheduleCalc(),
          ),
        ),
        if (l.oneOff)
          SizedBox(
            width: 90,
            child: TextField(
              controller: l.uomCtrl,
              decoration: _dec('Unit'),
              onChanged: (v) {
                l.uom = v.trim();
                _markDirty();
              },
            ),
          ),
        if (l.oneOff || _canSee)
          SizedBox(
            width: 170,
            child: TextField(
              controller: l.costCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [_LineNum.decimal],
              decoration: _dec(l.oneOff ? 'Price per unit *' : 'Cost per unit', hint: l.oneOff ? null : costHint),
              onChanged: (_) => _scheduleCalc(),
            ),
          ),
        if (_canSee && l.amount != null)
          SizedBox(
            width: 170,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(moneyRs(l.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(_sourceLabel(l), style: TextStyle(fontSize: 11, color: _sourceColor(l))),
            ]),
          ),
        IconButton(tooltip: 'Remove', onPressed: () => _removeLine(l), icon: const Icon(Icons.close, size: 18)),
      ]),
    );
  }

  String _sourceLabel(_QLine l) => switch (l.source) {
        'manual' => 'Cost typed in',
        'typed' => 'Price typed in',
        'last purchase' => 'Last purchase price',
        'no purchase yet' => 'Never bought — stock cost used',
        'no cost found' => 'No cost found — type a cost',
        'stock cost' => 'Stock cost',
        'BOM cost' => 'Made in-house — BOM cost',
        _ => '',
      };

  Color _sourceColor(_QLine l) =>
      l.source == 'no cost found' ? AppTheme.danger : (l.source == 'no purchase yet' ? AppTheme.warning : AppTheme.textSecondary);

  Widget _costsCard() {
    final costs = _lines.where((l) => l.kind != 'material').toList();
    return _card(
      'Labour & overheads',
      [
        if (_laborTypes.isEmpty && _overheadTypes.isEmpty)
          const Text('No labour or overhead rates are set up yet (Production → rate lists).',
              style: TextStyle(color: AppTheme.textSecondary)),
        if (costs.isEmpty && (_laborTypes.isNotEmpty || _overheadTypes.isNotEmpty))
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('None added.', style: TextStyle(color: AppTheme.textSecondary)),
          ),
        for (final l in costs) _costRow(l),
        if (_laborTypes.isNotEmpty || _overheadTypes.isNotEmpty)
          OutlinedButton.icon(onPressed: _addCost, icon: const Icon(Icons.add, size: 18), label: const Text('Add labour / overhead')),
      ],
      sub: 'From your labour and overhead rate lists, for one batch.',
    );
  }

  Widget _costRow(_QLine l) {
    final list = l.kind == 'labor' ? _laborTypes : _overheadTypes;
    final valid = list.any((r) => r['id'] == l.rateId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 140,
          child: DropdownButtonFormField<String>(
            value: l.kind,
            isDense: true,
            decoration: _dec('Type'),
            items: [
              if (_laborTypes.isNotEmpty || l.kind == 'labor') const DropdownMenuItem(value: 'labor', child: Text('Labour')),
              if (_overheadTypes.isNotEmpty || l.kind == 'overhead') const DropdownMenuItem(value: 'overhead', child: Text('Overhead')),
            ],
            onChanged: (v) {
              if (v == null || v == l.kind) return;
              setState(() {
                l.kind = v;
                l.rateId = null;
                l.amount = null;
              });
              _scheduleCalc();
            },
          ),
        ),
        SizedBox(
          width: 260,
          child: DropdownButtonFormField<String>(
            value: valid ? l.rateId : null,
            isDense: true,
            isExpanded: true,
            decoration: _dec('Rate'),
            items: [
              for (final r in list)
                DropdownMenuItem(
                  value: r['id'] as String,
                  child: Text(_canSee ? '${r['name']} · ${money(r['rate'] as num?)}' : '${r['name']}',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              setState(() {
                l.rateId = v;
                l.label = _rateName(l.kind, v);
              });
              _scheduleCalc();
            },
          ),
        ),
        SizedBox(
          width: 110,
          child: TextField(
            controller: l.qtyCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [_LineNum.decimal],
            decoration: _dec('Qty'),
            onChanged: (_) => _scheduleCalc(),
          ),
        ),
        if (_canSee && l.amount != null) Text(moneyRs(l.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
        IconButton(tooltip: 'Remove', onPressed: () => _removeLine(l), icon: const Icon(Icons.close, size: 18)),
      ]),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color, double size = 14}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: bold ? AppTheme.textPrimary : AppTheme.textSecondary, fontSize: size))),
          Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color, fontSize: size)),
        ]),
      );

  Widget _resultCard() {
    final c = _calc;
    final qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0;
    final days = int.tryParse(_daysCtrl.text.trim()) ?? 7;
    final until = DateTime.now().add(Duration(days: days));
    num? n(String k) => c?[k] as num?;
    final margin = n('margin_pct');
    final unitCost = n('unit_cost');
    final price = n('unit_price');
    final lowMargin = margin != null && margin < 0;
    return _card(
      'Price',
      [
        if (c == null)
          const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
        else ...[
          if (_canSee) ...[
            _row('Materials', moneyRs(n('material_cost'))),
            _row('Wastage (${_LineNum.fmt(n('wastage_pct') ?? 0)}%)', moneyRs(n('wastage_cost'))),
            _row('Labour & overheads', moneyRs(n('labor_cost'))),
            const Divider(height: 18),
            _row('Cost of one batch', moneyRs(n('batch_cost')), bold: true),
            _row('Cost per unit', moneyRs(unitCost), bold: true),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _numField(_profitCtrl, 'Profit on cost', suffix: '%', width: double.infinity)),
            ]),
            const SizedBox(height: 6),
            _row('Suggested price per unit', moneyRs(n('suggested_price'))),
            const SizedBox(height: 8),
            _numField(_priceCtrl, 'Your price per unit (optional)', width: double.infinity, hint: 'Leave empty to use suggested'),
            const SizedBox(height: 6),
            _row('Margin on price', margin == null ? '—' : '${margin.toStringAsFixed(1)}%',
                color: lowMargin ? AppTheme.danger : AppTheme.success),
            if (lowMargin)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('This price is below cost.', style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w600)),
              ),
            const Divider(height: 22),
          ],
          _row('Price per unit', moneyRs(price), bold: true, size: 16),
          _row('Total for ${_LineNum.fmt(qty)} units', moneyRs((price ?? 0) * qty), bold: true, size: 18, color: AppTheme.primary),
          const SizedBox(height: 6),
          Text('Valid for $days days, until ${_date.format(until)}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          if (_calcBusy)
            const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- helpers
class _LineNum {
  static final decimal = FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}'));
  static String fmt(Object? v) {
    final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
    if (d == d.roundToDouble()) return d.toInt().toString();
    return d.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
}

class _BomPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> boms;
  const _BomPickerDialog({required this.boms});
  @override
  State<_BomPickerDialog> createState() => _BomPickerDialogState();
}

class _BomPickerDialogState extends State<_BomPickerDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final list = widget.boms.where((b) => _q.isEmpty || matchesQuery('${b['code']} ${b['name']}', _q)).take(300).toList();
    return AlertDialog(
      title: const Text('Copy from a BOM'),
      content: SizedBox(
        width: 480,
        height: 460,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Search BOM', border: OutlineInputBorder()),
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) => ListTile(
                dense: true,
                title: Text('${list[i]['name'] ?? ''}'),
                subtitle: Text('${list[i]['code'] ?? ''} · makes ${_LineNum.fmt(list[i]['output_qty'] ?? 1)}'),
                onTap: () => Navigator.pop(context, list[i]),
              ),
            ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

class _MakeProductDialog extends StatefulWidget {
  final String name;
  final double price;
  final List<Map<String, dynamic>> uoms;
  final List<String> types;
  const _MakeProductDialog({required this.name, required this.price, required this.uoms, required this.types});
  @override
  State<_MakeProductDialog> createState() => _MakeProductDialogState();
}

class _MakeProductDialogState extends State<_MakeProductDialog> {
  late final _name = TextEditingController(text: widget.name);
  final _sku = TextEditingController();
  late final _price = TextEditingController(text: _LineNum.fmt(widget.price));
  String? _uom;
  String? _type;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Make product & BOM'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Creates a finished product with this costing\'s materials, labour and overheads as its BOM. '
                'Its cost price is the cost per unit worked out here.',
                style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 14),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Product name *', border: OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 10),
            TextField(controller: _sku, decoration: const InputDecoration(labelText: 'SKU (optional)', border: OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _uom,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Unit *', border: OutlineInputBorder(), isDense: true),
              items: [
                for (final u in widget.uoms)
                  DropdownMenuItem(value: u['id'] as String, child: Text('${u['name'] ?? ''} (${u['abbreviation'] ?? ''})')),
              ],
              onChanged: (v) => setState(() => _uom = v),
            ),
            const SizedBox(height: 10),
            if (widget.types.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                value: _type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Product type', border: OutlineInputBorder(), isDense: true),
                items: [for (final t in widget.types) DropdownMenuItem(value: t, child: Text(t))],
                onChanged: (v) => setState(() => _type = v),
              ),
              const SizedBox(height: 10),
            ],
            TextField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [_LineNum.decimal],
              decoration: const InputDecoration(labelText: 'Selling price', border: OutlineInputBorder(), isDense: true),
            ),
            if (_err != null) ...[
              const SizedBox(height: 10),
              Text(_err!, style: const TextStyle(color: AppTheme.danger)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_name.text.trim().isEmpty) return setState(() => _err = 'Enter the product name');
            if (_uom == null) return setState(() => _err = 'Pick a unit');
            Navigator.pop(context, {
              'name': _name.text.trim(),
              'sku': _sku.text.trim().isEmpty ? null : _sku.text.trim(),
              'uom': _uom,
              'type': _type,
              'price': double.tryParse(_price.text.trim()),
            });
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
