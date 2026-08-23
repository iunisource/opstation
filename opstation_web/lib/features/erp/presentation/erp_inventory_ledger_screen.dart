import 'dart:html' as html;
// ignore_for_file: avoid_web_libraries_in_flutter
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpInventoryLedgerScreen extends ConsumerStatefulWidget {
  /// Optional product id to preselect (deep link, e.g. from global search).
  final String? focusProductId;
  const ErpInventoryLedgerScreen({super.key, this.focusProductId});
  @override
  ConsumerState<ErpInventoryLedgerScreen> createState() => _ErpInventoryLedgerScreenState();
}

class _ErpInventoryLedgerScreenState extends ConsumerState<ErpInventoryLedgerScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, dynamic>? _selectedProduct;
  List<Map<String, dynamic>> _movements = [];
  List<Map<String, dynamic>> _filteredMovements = [];
  List<Map<String, dynamic>> _branches = [];
  Set<String> _selectedBranchIds = {};
  String _branchMode = 'current';

  bool _loading = false;
  bool _loadingProducts = true;

  String? _mainGroupFilter;
  String? _groupFilter;
  final _productSearchCtrl = TextEditingController();

  final _movementsSearchCtrl = TextEditingController();
  String _typeFilter = 'All';
  DateTime? _dateFrom;
  DateTime? _dateTo;

  Map<String, String> _voucherNumbers = {};
  Map<String, String> _voucherSourceTables = {};
  // Per stock-transfer: {from_branch_id, to_branch_id, notes} — for the ledger
  // description "Transferred X to <branch>" / "Received X from <branch>".
  Map<String, Map<String, dynamic>> _transferInfo = {};
  // Per production voucher: {name (finished good), output_qty} — for the ledger
  // description "Produced X units of <finished good>".
  Map<String, Map<String, dynamic>> _productionInfo = {};

  static const _availableTypes = [
    'All', 'purchase', 'sale', 'pos', 'pos return', 'sale return',
    'purchase return', 'transfer', 'adjustment',
  ];

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _loadBranches();
    _productSearchCtrl.addListener(() => setState(() {}));
    _movementsSearchCtrl.addListener(_applyFilters);
  }

  @override
  void dispose() {
    _productSearchCtrl.dispose();
    _movementsSearchCtrl.dispose();
    super.dispose();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _loadProducts() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loadingProducts = false); return; }
    try {
      final products = await Supabase.instance.client
          .from('products').select('id, name, sku, product_main_group, product_group, uoms(abbreviation)')
          .eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      setState(() {
        _products = List<Map<String, dynamic>>.from(products);
        _loadingProducts = false;
      });
      // Deep link: preselect a product and load its ledger straight away.
      final fid = widget.focusProductId;
      if (fid != null && _selectedProduct == null) {
        Map<String, dynamic>? match;
        for (final p in _products) {
          if (p['id'] == fid) { match = p; break; }
        }
        if (match != null) {
          setState(() => _selectedProduct = match);
          _loadMovements(fid);
        }
      }
    } catch (_) { setState(() => _loadingProducts = false); }
  }

  Future<void> _loadBranches() async {
    // Only the branches this user is allocated to (userBranchesProvider
    // already returns ALL branches for admin tiers and only the allocated
    // ones for ERP users). "All Branches" and Multi-select thus never expose
    // branches the user has no access to.
    try {
      final rows = await ref.read(userBranchesProvider.future);
      final list = rows
          .map((b) => {'id': b['id'], 'name': b['name']})
          .toList()
        ..sort((a, b) =>
            (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''));
      setState(() { _branches = List<Map<String, dynamic>>.from(list); });
    } catch (_) { }
  }

  List<String> _activeBranchIds() {
    if (_branchMode == 'current') {
      final bid = _branchId;
      return bid != null ? [bid] : [];
    } else if (_branchMode == 'all') {
      return _branches.map((b) => b['id'] as String).toList();
    } else {
      return _selectedBranchIds.toList();
    }
  }

  String _branchModeLabel() {
    if (_branchMode == 'current') {
      final b = ref.read(selectedBranchProvider);
      return (b?['name'] as String?) ?? 'Current Branch';
    } else if (_branchMode == 'all') {
      return 'All Branches';
    } else {
      final names = _branches.where((b) => _selectedBranchIds.contains(b['id']))
          .map((b) => b['name'] as String).toList();
      return names.isEmpty ? 'Multi (none)' : names.join(', ');
    }
  }

  List<Map<String, dynamic>> get _visibleProducts {
    final q = _productSearchCtrl.text.toLowerCase().trim();
    return _products.where((p) {
      if (_mainGroupFilter != null && (p['product_main_group'] as String? ?? '') != _mainGroupFilter) return false;
      if (_groupFilter != null && (p['product_group'] as String? ?? '') != _groupFilter) return false;
      if (q.isEmpty) return true;
      return (p['name'] as String? ?? '').toLowerCase().contains(q) ||
             (p['sku'] as String? ?? '').toLowerCase().contains(q);
    }).toList();
  }

  List<String> get _mainGroupOptions => _products
      .map((p) => p['product_main_group'] as String? ?? '')
      .where((s) => s.isNotEmpty).toSet().toList()..sort();

  List<String> get _groupOptions => _products
      .where((p) => _mainGroupFilter == null || (p['product_main_group'] as String? ?? '') == _mainGroupFilter)
      .map((p) => p['product_group'] as String? ?? '')
      .where((s) => s.isNotEmpty).toSet().toList()..sort();

  Future<void> _loadMovements(String productId) async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() {
      _loading = true; _movements = []; _filteredMovements = [];
      _voucherNumbers = {}; _voucherSourceTables = {};
    });
    final branchIds = _activeBranchIds();
    try {
      var query = Supabase.instance.client
          .from('inventory_movements')
          .select('*, uoms(abbreviation)')
          .eq('org_id', orgId)
          .eq('product_id', productId);
      if (branchIds.isNotEmpty) query = query.inFilter('branch_id', branchIds);
      final movements = await query.order('moved_at', ascending: true);

      double runningQty = 0;
      final perBranch = <String, double>{};
      final entries = (movements as List).map((m) {
        final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
        runningQty += qty;
        final bid = m['branch_id'] as String? ?? '';
        final br = (perBranch[bid] ?? 0) + qty;
        perBranch[bid] = br;
        return {
          ...Map<String, dynamic>.from(m),
          'running_qty': runningQty,
          'branch_running': br, // per-branch running balance
        };
      }).toList();

      await _fetchVoucherNumbers(entries);
      setState(() { _movements = entries; _loading = false; });
      _applyFilters();
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load error: ' + e.toString())));
    }
  }

  String _normalizeRefTable(String refType) {
    final r = refType.toLowerCase();
    // Order matters: more specific prefixes first.
    if (r.startsWith('pos')) return 'pos_transactions';
    if (r.startsWith('sales_return_invoice') || r == 'sale_return_invoice') return 'sales_return_invoices';
    if (r.startsWith('purchase_return_invoice') || r.startsWith('purchase_return_voucher')) return 'purchase_return_invoices';
    if (r.startsWith('purchase_return')) return 'purchase_returns';
    if (r.startsWith('sales_return') || r.startsWith('sale_return')) return 'sales_returns';
    if (r.startsWith('sales_invoice') || r == 'si') return 'sales_invoices';
    if (r.startsWith('purchase_invoice')) return 'purchase_invoices';
    if (r.startsWith('delivery_order')) return 'delivery_orders';
    if (r.startsWith('grn') || r.startsWith('purchase_grn') || r.startsWith('goods_received')) return 'purchase_grns';
    if (r.startsWith('stock_transfer')) return 'stock_transfers';
    if (r.startsWith('stock_adjustment')) return 'stock_adjustments';
    if (r == 'damage' || r.startsWith('damage')) return 'damage_vouchers';
    if (r.startsWith('production')) return 'production_vouchers';
    if (r.startsWith('job')) return 'job_card_runs'; // job_run movements
    return refType;
  }

  // Clean human label for movements that don't resolve to a voucher number
  // (deleted/voided source rows, or types with no document like opening stock).
  // Description shown in the ledger's Description column: the movement's own
  // notes/remarks if present, otherwise a generated sentence from the movement
  // type + quantity + unit cost. (The counterparty name isn't loaded for the
  // list — it appears in the voucher popup on click.)
  String _movementDescription(Map<String, dynamic> m) {
    final notes = (m['notes'] as String?)?.trim() ?? '';
    if (notes.isNotEmpty) return notes;
    final type = ((m['movement_type'] as String?) ?? '').toLowerCase();
    final ref = ((m['reference_type'] as String?) ?? '').toLowerCase();
    final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
    final qtyAbs = qty.abs();
    final qtyStr = qtyAbs == qtyAbs.roundToDouble() ? qtyAbs.toStringAsFixed(0) : qtyAbs.toStringAsFixed(2);
    final cost = (m['unit_cost'] as num?)?.toDouble() ?? 0;
    final at = cost > 0 ? ' @ ${cost.toStringAsFixed(2)}' : '';
    // A GRN quantity edit posts a system correction (never a manual tweak) —
    // label it as such and tie it back to the GRN so the ledger isn't ambiguous.
    if (ref == 'grn_qty_correction') {
      final refId = m['reference_id'] as String?;
      final vno = refId != null ? _voucherNumbers[refId] : null;
      final dir = qty < 0 ? 'reduced' : 'increased';
      return '${vno ?? 'GRN'} quantity $dir by $qtyStr pcs';
    }
    final t = type.isNotEmpty ? type : ref;
    if (t.contains('sale') && t.contains('return')) return 'Sale return $qtyStr pcs$at';
    if (t.contains('pos')) return 'Sold $qtyStr pcs$at';
    if (t.contains('sale')) return 'Sold $qtyStr pcs$at';
    if (t.contains('purchase') && t.contains('return')) return 'Purchase return $qtyStr pcs$at';
    if (t.contains('purchase') || t.contains('grn') || t.contains('goods_received')) return 'Received $qtyStr pcs$at';
    if (t.contains('damage')) return 'Damaged $qtyStr pcs$at';
    if (t.contains('transfer')) {
      final refId = m['reference_id'] as String?;
      final info = refId != null ? _transferInfo[refId] : null;
      final tnotes = (info?['notes'] as String?)?.trim() ?? '';
      final noteSuffix = tnotes.isNotEmpty ? ' — $tnotes' : '';
      if (qty < 0) {
        final to = _branchNameById(info?['to_branch_id'] as String?);
        return 'Transferred $qtyStr units${to != null ? ' to $to' : ''}$noteSuffix';
      } else {
        final from = _branchNameById(info?['from_branch_id'] as String?);
        return 'Received $qtyStr units${from != null ? ' from $from' : ''}$noteSuffix';
      }
    }
    if (t.contains('adjust')) return 'Adjusted $qtyStr pcs$at';
    if (t.contains('opening')) return 'Opening stock $qtyStr pcs$at';
    if (t.contains('production') || t.contains('manufactur') || t.contains('job')) {
      final refId = m['reference_id'] as String?;
      final info = refId != null ? _productionInfo[refId] : null;
      final fg = (info?['name'] as String?)?.trim() ?? '';
      if (fg.isNotEmpty) {
        final oq = (info?['output_qty'] as num?)?.toDouble();
        if (oq != null && oq > 0) {
          final oqStr = oq == oq.roundToDouble() ? oq.toStringAsFixed(0) : oq.toStringAsFixed(2);
          return 'Produced $oqStr units of $fg';
        }
        return 'Produced $fg';
      }
      return 'Produced $qtyStr pcs$at';
    }
    return _friendlyRefLabel(m['reference_type'] as String?);
  }

  String? _branchNameById(String? id) {
    if (id == null) return null;
    final b = _branches.firstWhere((e) => e['id'] == id, orElse: () => const {});
    return b['name'] as String?;
  }

  String _friendlyRefLabel(String? refType) {
    final r = (refType ?? '').toLowerCase();
    if (r.isEmpty) return '-';
    final undone = r.contains('delet') || r.contains('void') || r.contains('revers');
    String tag(String base) => undone ? '$base (reversed)' : base;
    if (r == 'opening_stock') return 'Opening stock';
    if (r.startsWith('stock_transfer')) return 'Stock transfer';
    if (r == 'damage') return 'Damage';
    if (r == 'adjustment' || r.startsWith('stock_adjustment')) return 'Stock adjustment';
    if (r.startsWith('delivery_order')) return tag('Delivery Order');
    if (r.startsWith('grn') || r.startsWith('purchase_grn') || r.startsWith('goods_received')) return tag('GRN');
    if (r.startsWith('purchase_return_voucher') || r.startsWith('purchase_return_invoice')) return tag('Purchase Return Invoice');
    if (r.startsWith('purchase_return')) return tag('Purchase Return');
    if (r.startsWith('sales_return_invoice')) return tag('Sales Return Invoice');
    if (r.startsWith('sales_return') || r.startsWith('sale_return')) return tag('Sales Return');
    if (r.startsWith('purchase_invoice')) return 'Purchase Invoice';
    if (r.startsWith('sales_invoice')) return 'Sales Invoice';
    if (r.startsWith('pos')) return 'POS';
    if (r.startsWith('production')) return 'Production Voucher';
    if (r.startsWith('job')) return 'Job Run';
    return r.split('_').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
  }

  Future<void> _fetchVoucherNumbers(List<Map<String, dynamic>> entries) async {
    final client = Supabase.instance.client;
    final byTable = <String, Set<String>>{};
    final idToTable = <String, String>{};
    for (final m in entries) {
      final rt = m['reference_type'] as String?;
      final id = m['reference_id'] as String?;
      if (rt == null || id == null || id.isEmpty) continue;
      final tbl = _normalizeRefTable(rt);
      byTable.putIfAbsent(tbl, () => {}).add(id);
      idToTable[id] = tbl;
    }
    final vMap = <String, String>{};
    final transferInfo = <String, Map<String, dynamic>>{};
    final productionInfo = <String, Map<String, dynamic>>{};
    for (final entry in byTable.entries) {
      final tbl = entry.key;
      final ids = entry.value.toList();
      try {
        final rows = await client.from(tbl)
            // Job runs have no voucher_number of their own — the number is
            // built from the parent job card (JOB-xxxx-R<run_no>).
            .select(tbl == 'job_card_runs' ? '*, job_cards(job_number)' : '*')
            .inFilter('id', ids);
        for (final r in rows as List) {
          final id = r['id'] as String?;
          if (id == null) continue;
          String vno = (r['voucher_number'] ?? r['invoice_number'] ?? r['transaction_number'] ?? '') as String;
          if (tbl == 'job_card_runs' && vno.isEmpty) {
            final jn = (r['job_cards'] is Map ? r['job_cards']['job_number'] as String? : null) ?? 'JOB';
            vno = '$jn-R${r['run_no'] ?? ''}';
          }
          if (vno.isNotEmpty) vMap[id] = vno;
          if (tbl == 'stock_transfers') {
            transferInfo[id] = {
              'from_branch_id': r['from_branch_id'],
              'to_branch_id': r['to_branch_id'],
              'notes': r['notes'],
            };
          }
          if (tbl == 'production_vouchers') {
            productionInfo[id] = {
              'product_id': r['product_id'],
              'output_qty': r['output_qty'],
            };
          }
        }
      } catch (_) { }
    }
    // Resolve the finished-good names for the production vouchers in one query,
    // so the ledger can say "Produced X units of <finished good>".
    final fgIds = productionInfo.values
        .map((v) => v['product_id'] as String?)
        .where((s) => s != null && s.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList();
    if (fgIds.isNotEmpty) {
      try {
        final prods = await client.from('products').select('id, name').inFilter('id', fgIds);
        final nameById = {for (final p in prods as List) p['id'] as String: p['name'] as String? ?? ''};
        for (final info in productionInfo.values) {
          info['name'] = nameById[info['product_id'] as String?] ?? '';
        }
      } catch (_) { }
    }
    setState(() {
      _voucherNumbers = vMap;
      _voucherSourceTables = idToTable;
      _transferInfo = transferInfo;
      _productionInfo = productionInfo;
    });
  }

  String _displayType(Map m) {
    final type = ((m['movement_type'] as String?) ?? '').toLowerCase();
    final ref = ((m['reference_type'] as String?) ?? '').toLowerCase();
    final notes = ((m['notes'] as String?) ?? '').toLowerCase();
    final combined = ref + ' ' + notes;
    if (ref == 'grn_qty_correction') return 'GRN correction';
    if (type == 'adjustment') {
      if (combined.contains('sales_return') || combined.contains('sale_return')) return 'sale return';
      if (combined.contains('pos_return')) return 'pos return';
      if (combined.contains('purchase_return')) return 'purchase return';
      return 'adjustment';
    }
    return type;
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'purchase': return AppTheme.success;
      case 'sale': return AppTheme.danger;
      case 'pos': return Colors.orange;
      case 'pos return': return Colors.deepOrange;
      case 'sale return': return Colors.amber.shade800;
      case 'purchase return': return Colors.teal;
      case 'transfer': return Colors.blue;
      case 'adjustment': return Colors.purple;
      case 'GRN correction': return Colors.indigo;
      default: return AppTheme.textSecondary;
    }
  }

  void _applyFilters() {
    final q = _movementsSearchCtrl.text.toLowerCase().trim();
    setState(() {
      _filteredMovements = _movements.where((m) {
        if (_typeFilter != 'All' && _displayType(m) != _typeFilter) return false;
        if (_dateFrom != null || _dateTo != null) {
          final mAt = m['moved_at'] as String?;
          if (mAt == null) return false;
          final dt = DateTime.tryParse(mAt);
          if (dt == null) return false;
          if (_dateFrom != null && dt.isBefore(_dateFrom!)) return false;
          if (_dateTo != null && dt.isAfter(_dateTo!.add(const Duration(days: 1)))) return false;
        }
        if (q.isNotEmpty) {
          final type = _displayType(m).toLowerCase();
          final notes = (m['notes'] as String? ?? '').toLowerCase();
          final refType = (m['reference_type'] as String? ?? '').toLowerCase();
          final refId = m['reference_id'] as String?;
          final vno = refId != null ? (_voucherNumbers[refId] ?? '').toLowerCase() : '';
          final dateStr = m['moved_at'] != null
              ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(m['moved_at'] as String).toLocal()).toLowerCase() : '';
          if (!(type.contains(q) || notes.contains(q) || refType.contains(q) || vno.contains(q) || dateStr.contains(q))) return false;
        }
        return true;
      }).toList();
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedProduct = null;
      _movements = []; _filteredMovements = [];
      _movementsSearchCtrl.clear();
      _typeFilter = 'All'; _dateFrom = null; _dateTo = null;
      _voucherNumbers = {}; _voucherSourceTables = {};
    });
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: (_dateFrom != null && _dateTo != null)
          ? DateTimeRange(start: _dateFrom!, end: _dateTo!) : null,
    );
    if (picked != null) {
      setState(() { _dateFrom = picked.start; _dateTo = picked.end; });
      _applyFilters();
    }
  }

  void _clearDateRange() {
    setState(() { _dateFrom = null; _dateTo = null; });
    _applyFilters();
  }

  void _showBranchMultiSelect() {
    if (_branches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No branches loaded')));
      return;
    }
    final tempSelected = Set<String>.from(_selectedBranchIds);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Select Branches'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: _branches.map((b) {
              final id = b['id'] as String;
              return CheckboxListTile(
                dense: true,
                title: Text(b['name'] as String? ?? ''),
                value: tempSelected.contains(id),
                onChanged: (v) => setLocal(() {
                  if (v == true) { tempSelected.add(id); } else { tempSelected.remove(id); }
                }),
              );
            }).toList()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(onPressed: () {
            setState(() {
              _selectedBranchIds = tempSelected;
              _branchMode = tempSelected.isEmpty ? 'current' : 'multi';
            });
            Navigator.of(ctx).pop();
            if (_selectedProduct != null) _loadMovements(_selectedProduct!['id'] as String);
          }, child: const Text('Apply')),
        ],
      )),
    );
  }

  Future<void> _openVoucherFromMovement(Map<String, dynamic> m) async {
    final refType = m['reference_type'] as String?;
    final refId = m['reference_id'] as String?;
    if (refType == null || refId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No reference to open')));
      return;
    }
    final tbl = _normalizeRefTable(refType);
    Map<String, dynamic>? voucher;
    List<dynamic> lines = [];
    String title = 'Voucher';
    String? err;
    try {
      final client = Supabase.instance.client;
      switch (tbl) {
        case 'sales_invoices':
          title = 'Sales Invoice';
          voucher = await client.from('sales_invoices').select('*, customers(shop_name, code)').eq('id', refId).maybeSingle();
          if (voucher != null) lines = await client.from('sales_invoice_items').select('*, products(name, sku)').eq('invoice_id', refId);
          break;
        case 'sales_return_invoices':
          title = 'Sales Return Invoice';
          voucher = await client.from('sales_return_invoices').select('*, customers(shop_name, code)').eq('id', refId).maybeSingle();
          if (voucher != null) lines = await client.from('sales_return_invoice_items').select('*, products(name, sku)').eq('invoice_id', refId);
          break;
        case 'purchase_invoices':
          title = 'Purchase Invoice';
          voucher = await client.from('purchase_invoices').select('*, suppliers(name)').eq('id', refId).maybeSingle();
          if (voucher != null) lines = await client.from('purchase_invoice_items').select('*, products(name, sku)').eq('invoice_id', refId);
          break;
        case 'purchase_return_invoices':
          title = 'Purchase Return Invoice';
          voucher = await client.from('purchase_return_invoices').select('*, suppliers(name)').eq('id', refId).maybeSingle();
          if (voucher != null) lines = await client.from('purchase_return_invoice_items').select('*, products(name, sku)').eq('invoice_id', refId);
          break;
        case 'pos_transactions':
          title = 'POS Transaction';
          voucher = await client.from('pos_transactions').select('*, customers(shop_name, code)').eq('id', refId).maybeSingle();
          if (voucher != null) lines = await client.from('pos_transaction_items').select('*, products(name, sku)').eq('transaction_id', refId);
          break;
        case 'delivery_orders':
          title = 'Delivery Order';
          voucher = await client.from('delivery_orders').select('*, customers(shop_name, code)').eq('id', refId).maybeSingle();
          if (voucher != null) {
            for (final fk in const ['delivery_order_id', 'do_id', 'order_id']) {
              try {
                final l = await client.from('delivery_order_items').select('*, products(name, sku)').eq(fk, refId);
                if ((l as List).isNotEmpty) { lines = l; break; }
              } catch (_) { }
            }
          }
          break;
        case 'purchase_grns':
          title = 'Goods Receipt Note';
          voucher = await client.from('purchase_grns').select('*, suppliers(name)').eq('id', refId).maybeSingle();
          if (voucher != null) lines = await client.from('purchase_grn_items').select('*, products(name, sku)').eq('grn_id', refId);
          break;
        case 'purchase_returns':
          title = 'Purchase Return Note';
          voucher = await client.from('purchase_returns').select('*, suppliers(name)').eq('id', refId).maybeSingle();
          if (voucher != null) lines = await client.from('purchase_return_items').select('*, products(name, sku)').eq('return_id', refId);
          break;
        case 'sales_returns':
          title = 'Sales Return Note';
          voucher = await client.from('sales_returns').select('*, customers(shop_name, code)').eq('id', refId).maybeSingle();
          if (voucher != null) lines = await client.from('sales_return_items').select('*, products(name, sku)').eq('return_id', refId);
          break;
        case 'stock_transfers':
          title = 'Stock Transfer';
          voucher = await client.from('stock_transfers')
              .select('*, from_branch:branches!from_branch_id(name), to_branch:branches!to_branch_id(name)')
              .eq('id', refId).maybeSingle();
          if (voucher != null) {
            lines = await client.from('stock_transfer_items').select('*, products(name, sku)').eq('transfer_id', refId);
          }
          break;
        case 'stock_adjustments':
          title = 'Stock Adjustment';
          voucher = await client.from('stock_adjustments').select('*').eq('id', refId).maybeSingle();
          if (voucher != null) {
            try { lines = await client.from('stock_adjustment_items').select('*, products(name, sku)').eq('adjustment_id', refId); } catch (_) { }
          }
          break;
        case 'damage_vouchers':
          title = 'Damage Voucher';
          voucher = await client.from('damage_vouchers').select('*').eq('id', refId).maybeSingle();
          if (voucher != null) {
            for (final fk in const ['voucher_id', 'damage_id', 'damage_voucher_id']) {
              try {
                final l = await client.from('damage_voucher_lines').select('*, products(name, sku)').eq(fk, refId);
                if ((l as List).isNotEmpty) { lines = l; break; }
              } catch (_) { }
            }
          }
          break;
        case 'production_vouchers':
          title = 'Production Voucher';
          voucher = await client.from('production_vouchers').select('*').eq('id', refId).maybeSingle();
          if (voucher != null) {
            try { lines = await client.from('production_voucher_components').select('*, products(name, sku)').eq('voucher_id', refId); } catch (_) { }
          }
          break;
        case 'job_card_runs':
          title = 'Job Run';
          voucher = await client.from('job_card_runs').select('*, job_cards(job_number)').eq('id', refId).maybeSingle();
          if (voucher != null) {
            final jn = (voucher['job_cards'] is Map ? voucher['job_cards']['job_number'] as String? : null) ?? 'JOB';
            voucher['voucher_number'] = '$jn-R${voucher['run_no'] ?? ''}';
            final jobId = voucher['job_card_id'] as String?;
            if (jobId != null) {
              try { lines = await client.from('job_card_materials').select('*, products(name, sku)').eq('job_card_id', jobId); } catch (_) { }
            }
          }
          break;
        default:
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Unknown reference: ' + refType)));
          return;
      }
    } catch (e) { err = e.toString(); }
    if (!mounted) return;
    final v = voucher;
    if (v == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: ' + (err ?? 'not found'))));
      return;
    }
    await showDialog(context: context, builder: (ctx) => _buildVoucherDialog(ctx, title, v, lines));
  }

  Widget _buildVoucherDialog(BuildContext ctx, String title, Map<String, dynamic> v, List<dynamic> lines) {
    final vNum = ((v['voucher_number'] ?? v['invoice_number'] ?? v['transaction_number'] ?? '') as String);
    final dateStr = ((v['voucher_date'] ?? v['invoice_date'] ?? v['transacted_at'] ?? v['transfer_date'] ?? v['run_date'] ?? v['created_at'] ?? '') as String);
    final dt = DateTime.tryParse(dateStr);
    final dateFmt = dt != null ? DateFormat('d MMM yyyy').format(dt) : '-';
    final cust = v['customers']; final supp = v['suppliers'];
    final entityName = (cust is Map ? (cust['shop_name'] ?? cust['name']) as String? : null)
                    ?? (supp is Map ? (supp['name'] ?? supp['shop_name']) as String? : null) ?? '';
    final entityCode = (cust is Map ? cust['code'] as String? : null) ?? '';
    final total = ((v['grand_total'] ?? v['total'] ?? v['total_amount'] ?? v['net_amount'] ?? v['total_cost']) as num?)?.toDouble() ?? 0;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
            ]),
            const SizedBox(height: 4),
            Text(vNum, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.primary)),
            const SizedBox(height: 8),
            Wrap(spacing: 18, runSpacing: 6, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.calendar_today, size: 13, color: AppTheme.textSecondary),
                const SizedBox(width: 5),
                Text(dateFmt, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ]),
              if (entityName.isNotEmpty) Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.person, size: 13, color: AppTheme.textSecondary),
                const SizedBox(width: 5),
                Text(entityName + (entityCode.isNotEmpty ? ' (' + entityCode + ')' : ''), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ]),
              if (v['from_branch'] != null || v['to_branch'] != null) Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.swap_horiz, size: 14, color: AppTheme.textSecondary),
                const SizedBox(width: 5),
                Text('${v['from_branch']?['name'] ?? '-'} → ${v['to_branch']?['name'] ?? '-'}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ]),
              if (v['status'] != null) Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(10)),
                child: Text((v['status'] as String).toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.primary)),
              ),
            ]),
            if ((v['reason'] as String?)?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.info_outline, size: 15, color: Color(0xFFB26A00)),
                  const SizedBox(width: 6),
                  Expanded(child: Text('Reason: ${(v['reason'] as String).trim()}', style: const TextStyle(fontSize: 12, color: Color(0xFF8A5200)))),
                ]),
              ),
            ],
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Flexible(child: SingleChildScrollView(child: _voucherLines(lines))),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            if (total > 0) Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              const Text('Total: ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              Text('Rs. ' + money(total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _voucherLines(List<dynamic> lines) {
    if (lines.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No lines', style: TextStyle(color: AppTheme.textSecondary))));
    return Column(children: [
      Container(color: const Color(0xFFF5F5F5), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Row(children: const [
        Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 1, child: Text('Qty', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Price', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Total', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
      ])),
      ...lines.map((line) {
        final qty = ((line['quantity'] ?? line['qty'] ?? line['qty_delivered'] ?? line['qty_received'] ?? line['planned_qty'] ?? line['issued_qty']) as num?)?.toDouble() ?? 0;
        final price = ((line['unit_price'] ?? line['price'] ?? line['unit_cost']) as num?)?.toDouble() ?? 0;
        final lineTotal = ((line['line_total'] ?? line['total'] ?? line['amount'] ?? line['line_cost']) as num?)?.toDouble() ?? (qty * price);
        final prod = line['products'];
        final prodName = (prod is Map ? prod['name'] as String? : null) ?? (line['product_name'] as String?) ?? '';
        return Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            Expanded(flex: 4, child: Text(prodName, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 1, child: Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toString(), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text(price > 0 ? 'Rs. ' + money(price) : '-', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text(lineTotal > 0 ? 'Rs. ' + money(lineTotal) : '-', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
        );
      }),
    ]);
  }

  void _printLedger() {
    try {
      if (_selectedProduct == null || _filteredMovements.isEmpty) return;
      final p = _selectedProduct!;
      final user = ref.read(currentUserProvider);
      final branchName = _branchModeLabel();
      final uomAbbr = p['uoms']?['abbreviation'] as String? ?? '';
      final currentStock = _movements.isNotEmpty ? (_movements.last['running_qty'] as double) : 0.0;
      final genTime = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
      final genBy = user?.name ?? user?.email ?? 'Unknown';
      final periodStr = (_dateFrom != null || _dateTo != null)
          ? ((_dateFrom != null ? DateFormat('d MMM yy').format(_dateFrom!) : 'Beginning') + ' to ' + (_dateTo != null ? DateFormat('d MMM yy').format(_dateTo!) : 'Today'))
          : '';
      final rowsBuf = StringBuffer();
      double totalIn = 0, totalOut = 0;
      for (final m in _filteredMovements) {
        final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
        if (qty > 0) totalIn += qty; else totalOut += -qty;
        final runQty = m['running_qty'] as double;
        final entryUom = m['uoms']?['abbreviation'] as String? ?? uomAbbr;
        final date = m['moved_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(m['moved_at'] as String).toLocal()) : '-';
        final type = _displayType(m);
        final refId = m['reference_id'] as String?;
        final vno = refId != null ? (_voucherNumbers[refId] ?? _friendlyRefLabel(m['reference_type'] as String?)) : (m['notes'] as String? ?? '-');
        final inStr = qty > 0 ? '+' + qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2) + ' ' + entryUom : '-';
        final outStr = qty < 0 ? qty.abs().toStringAsFixed(qty.abs() % 1 == 0 ? 0 : 2) + ' ' + entryUom : '-';
        final printBal = _branchMode != 'current'
            ? ((m['branch_running'] as double?) ?? 0)
            : runQty;
        final balStr = printBal.toStringAsFixed(printBal % 1 == 0 ? 0 : 2) + ' ' + entryUom;
        final brCell = _branchMode != 'current'
            ? '<td>' + (_branchNameById(m['branch_id'] as String?) ?? '-') + '</td>'
            : '';
        final descRaw = _movementDescription(m);
        final desc = descRaw.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
        final manualTag = (((m['created_by'] as String?) ?? '').isEmpty && (m['reference_type'] as String?) != 'grn_qty_correction')
            ? ' <span class="badge" style="background:#fef3c7;color:#b45309;">manual</span>'
            : '';
        rowsBuf.write('<tr><td>' + date + '</td>' + brCell + '<td><span class="badge">' + type + '</span>' + manualTag + '</td><td>' + vno + '</td><td>' + desc + '</td><td class="num green">' + inStr + '</td><td class="num red">' + outStr + '</td><td class="num bold">' + balStr + '</td></tr>');
      }
      final productName = (p['name'] as String?) ?? '';
      final sku = (p['sku'] as String?) ?? '';
      final mainGroup = (p['product_main_group'] as String?) ?? '';
      final group = (p['product_group'] as String?) ?? '';
      final htmlDoc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Inventory Ledger - ' + productName + '</title>'
        '<style>'
        '@page { margin: 0.5cm; } '
        'body { font-family: Arial, sans-serif; padding: 16px; font-size: 10px; color: #000; margin: 0; } '
        '.header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #000; padding-bottom: 8px; margin-bottom: 10px; } '
        'h1 { font-size: 18px; margin: 0 0 4px 0; } '
        '.info { font-size: 10px; margin: 2px 0; } '
        '.stats { display: flex; gap: 10px; margin: 8px 0 12px 0; } '
        '.stat { padding: 6px 10px; border: 1px solid #ddd; border-radius: 4px; } '
        '.stat-label { font-size: 8px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; } '
        '.stat-value { font-weight: 800; font-size: 12px; margin-top: 2px; } '
        '.green { color: #2e7d32; } .red { color: #c62828; } '
        'table { width: 100%; border-collapse: collapse; } '
        'th, td { padding: 4px 6px; border-bottom: 1px solid #ddd; text-align: left; font-size: 9.5px; } '
        'th { background: #f5f5f5; font-weight: 700; border-bottom: 1.5px solid #000; } '
        '.num { text-align: right; white-space: nowrap; } .bold { font-weight: 800; } '
        '.badge { display: inline-block; padding: 1px 5px; border-radius: 3px; background: #eee; font-size: 8px; font-weight: 700; text-transform: lowercase; } '
        '.footer { margin-top: 18px; padding-top: 6px; border-top: 1px solid #ddd; font-size: 8px; color: #888; text-align: right; } '
        '</style></head><body>'
        '<div class="header"><div><h1>Inventory Ledger</h1>'
        '<div class="info"><strong>Product:</strong> ' + productName + (sku.isNotEmpty ? ' &middot; SKU: ' + sku : '') + '</div>'
        + (mainGroup.isNotEmpty || group.isNotEmpty ? '<div class="info"><strong>Category:</strong> ' + mainGroup + (group.isNotEmpty ? ' &middot; ' + group : '') + '</div>' : '') +
        '<div class="info"><strong>Branch:</strong> ' + branchName + '</div>'
        + (periodStr.isNotEmpty ? '<div class="info"><strong>Period:</strong> ' + periodStr + '</div>' : '') +
        '</div></div>'
        '<div class="stats">'
        '<div class="stat"><div class="stat-label">Current Stock</div><div class="stat-value">' + (currentStock % 1 == 0 ? currentStock.toInt().toString() : currentStock.toString()) + ' ' + uomAbbr + '</div></div>'
        '<div class="stat"><div class="stat-label">Total In</div><div class="stat-value green">+' + totalIn.toStringAsFixed(totalIn % 1 == 0 ? 0 : 2) + ' ' + uomAbbr + '</div></div>'
        '<div class="stat"><div class="stat-label">Total Out</div><div class="stat-value red">-' + totalOut.toStringAsFixed(totalOut % 1 == 0 ? 0 : 2) + ' ' + uomAbbr + '</div></div>'
        '<div class="stat"><div class="stat-label">Entries</div><div class="stat-value">' + _filteredMovements.length.toString() + '</div></div>'
        '</div><table>'
        '<thead><tr><th>Date</th>' + (_branchMode != 'current' ? '<th>Branch</th>' : '') + '<th>Type</th><th>Voucher / Notes</th><th>Description</th><th class="num">In</th><th class="num">Out</th><th class="num">' + (_branchMode != 'current' ? 'Branch Bal.' : 'Balance') + '</th></tr></thead>'
        '<tbody>' + rowsBuf.toString() + '</tbody>'
        '</table>'
        '<div class="footer">Generated by ' + genBy + ' &middot; ' + genTime + '</div>'
        '</body></html>';
      final blob = html.Blob([htmlDoc], 'text/html;charset=utf-8');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.window.open(url, '_blank');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Print error: ' + e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    // When the app-level branch toggle changes and we're scoped to the current
    // branch with a product open, re-query that product's movements.
    ref.listen(selectedBranchProvider, (prev, next) {
      final prevId = prev?['id'] as String?;
      final nextId = next?['id'] as String?;
      if (prevId == nextId) return;
      if (_branchMode == 'current' && _selectedProduct != null) {
        _loadMovements(_selectedProduct!['id'] as String);
      }
    });
    ref.watch(selectedBranchProvider); // keep the "Branch:" label in sync
    return LayoutBuilder(builder: (context, c) {
      final mobile = c.maxWidth < 640;
      final pad = mobile ? 16.0 : 32.0;
      return Container(
        color: AppTheme.background,
        padding: EdgeInsets.all(pad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Inventory Ledger',
              style: TextStyle(fontSize: mobile ? 22 : 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Branch: ' + _branchModeLabel(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.textSecondary)),
          SizedBox(height: mobile ? 14 : 20),
          if (_loadingProducts)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_selectedProduct == null)
            _buildPicker(mobile)
          else
            _buildLedger(mobile),
        ]),
      );
    });
  }

  Widget _buildPicker(bool mobile) {
    final visible = _visibleProducts;
    final branchScope = DropdownButtonFormField<String>(
      value: _branchMode,
      isDense: true,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Branch Scope', isDense: true),
      items: const [
        DropdownMenuItem(value: 'current', child: Text('Current Branch')),
        DropdownMenuItem(value: 'all', child: Text('All Branches')),
        DropdownMenuItem(value: 'multi', child: Text('Multi-select...')),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (v == 'multi') {
          _showBranchMultiSelect();
        } else {
          setState(() { _branchMode = v; });
          if (_selectedProduct != null) _loadMovements(_selectedProduct!['id'] as String);
        }
      },
    );
    final mainGroup = DropdownButtonFormField<String?>(
      value: _mainGroupFilter,
      isDense: true,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Main Group', isDense: true),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('All', style: TextStyle(color: AppTheme.textSecondary))),
        ..._mainGroupOptions.map((g) => DropdownMenuItem<String?>(value: g, child: Text(g, overflow: TextOverflow.ellipsis))),
      ],
      onChanged: (v) => setState(() {
        _mainGroupFilter = v;
        if (_groupFilter != null && !_groupOptions.contains(_groupFilter)) _groupFilter = null;
      }),
    );
    final group = DropdownButtonFormField<String?>(
      value: _groupFilter,
      isDense: true,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Group', isDense: true),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('All', style: TextStyle(color: AppTheme.textSecondary))),
        ..._groupOptions.map((g) => DropdownMenuItem<String?>(value: g, child: Text(g, overflow: TextOverflow.ellipsis))),
      ],
      onChanged: (v) => setState(() => _groupFilter = v),
    );
    final search = TextField(
      controller: _productSearchCtrl,
      decoration: const InputDecoration(
        labelText: 'Search Product',
        prefixIcon: Icon(Icons.search, size: 18),
        isDense: true,
      ),
    );
    final filters = mobile
        ? Column(children: [
            branchScope,
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: mainGroup),
              const SizedBox(width: 10),
              Expanded(child: group),
            ]),
            const SizedBox(height: 10),
            search,
          ])
        : Wrap(spacing: 12, runSpacing: 8, children: [
            SizedBox(width: 220, child: branchScope),
            SizedBox(width: 220, child: mainGroup),
            SizedBox(width: 220, child: group),
            SizedBox(width: 320, child: search),
          ]);
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        filters,
        const SizedBox(height: 12),
        Text(visible.length.toString() + ' of ' + _products.length.toString() + ' products',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
            child: visible.isEmpty
                ? const Center(child: Text('No products match the filters.', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = visible[i];
                      final sub = [
                        p['sku'] as String?,
                        p['product_main_group'] as String?,
                        p['product_group'] as String?,
                      ].where((s) => s != null && s.isNotEmpty).join('  ·  ');
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.inventory_2_outlined, size: 18, color: AppTheme.primary),
                        title: Text(p['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        subtitle: sub.isNotEmpty ? Text(sub, style: const TextStyle(fontSize: 11)) : null,
                        trailing: const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
                        onTap: () {
                          setState(() => _selectedProduct = p);
                          _loadMovements(p['id'] as String);
                        },
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _buildLedger(bool mobile) {
    final p = _selectedProduct!;
    final uomAbbr = p['uoms']?['abbreviation'] as String? ?? '';
    final currentStock = _movements.isNotEmpty ? (_movements.last['running_qty'] as double) : 0.0;
    // Multi-branch view: bifurcate. Final per-branch balances for the header,
    // and a Branch column + per-branch running balance in the table.
    final multiBranch = _branchMode != 'current';
    final branchTotals = <String, double>{};
    if (multiBranch) {
      for (final m in _movements) {
        branchTotals[m['branch_id'] as String? ?? ''] =
            (m['branch_running'] as double?) ?? 0;
      }
    }
    String fmtQ(double q) => q % 1 == 0 ? q.toInt().toString() : q.toString();

    final stockCard = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Current Stock', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        Text((currentStock % 1 == 0 ? currentStock.toInt().toString() : currentStock.toString()) + ' ' + uomAbbr,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: currentStock > 0 ? AppTheme.success : AppTheme.danger)),
        if (multiBranch && branchTotals.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
                branchTotals.entries
                    .map((e) => '${_branchNameById(e.key) ?? '—'}: ${fmtQ(e.value)}')
                    .join('  ·  '),
                style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
          ),
      ]),
    );
    final movesCard = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Total Movements', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        Text(_movements.length.toString(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      ]),
    );
    final printBtn = OutlinedButton.icon(
      onPressed: _printLedger,
      icon: const Icon(Icons.print_outlined, size: 16),
      label: const Text('Print / PDF'),
      style: OutlinedButton.styleFrom(foregroundColor: AppTheme.primary),
    );
    final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(p['name'] as String? ?? '',
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      Text([
        p['sku'] as String?,
        p['product_main_group'] as String?,
        p['product_group'] as String?,
      ].where((s) => s != null && s.isNotEmpty).join('  ·  '),
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
    ]);

    final Widget header = mobile
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconButton(onPressed: _clearSelection, icon: const Icon(Icons.arrow_back, size: 20), tooltip: 'Back to products'),
              Expanded(child: titleBlock),
            ]),
            if (_movements.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: stockCard),
                const SizedBox(width: 10),
                Expanded(child: movesCard),
              ]),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: printBtn),
            ],
          ])
        : Row(children: [
            IconButton(onPressed: _clearSelection, icon: const Icon(Icons.arrow_back, size: 20), tooltip: 'Back to products'),
            Expanded(child: titleBlock),
            if (_movements.isNotEmpty) ...[
              printBtn,
              const SizedBox(width: 12),
              stockCard,
              const SizedBox(width: 12),
              movesCard,
            ],
          ]);

    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header,
        const SizedBox(height: 16),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_movements.isEmpty)
          const Expanded(child: Center(child: Text('No movements for this product.', style: TextStyle(color: AppTheme.textSecondary))))
        else ...[
          Builder(builder: (context) {
            final searchField = TextField(
              controller: _movementsSearchCtrl,
              decoration: InputDecoration(
                labelText: 'Search entries',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                suffixIcon: _movementsSearchCtrl.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => _movementsSearchCtrl.clear())
                    : null,
              ),
            );
            final typeField = DropdownButtonFormField<String>(
              value: _typeFilter,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type', isDense: true),
              items: _availableTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() { _typeFilter = v; });
                _applyFilters();
              },
            );
            final dateBtn = OutlinedButton.icon(
              onPressed: _pickDateRange,
              icon: const Icon(Icons.calendar_today, size: 14),
              label: Text((_dateFrom != null && _dateTo != null)
                  ? DateFormat('d MMM yy').format(_dateFrom!) + ' - ' + DateFormat('d MMM yy').format(_dateTo!)
                  : 'Date Range', overflow: TextOverflow.ellipsis),
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.primary),
            );
            final clearDate = (_dateFrom != null || _dateTo != null)
                ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: _clearDateRange, tooltip: 'Clear date range')
                : null;
            if (mobile) {
              return Column(children: [
                searchField,
                const SizedBox(height: 10),
                typeField,
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: dateBtn),
                  if (clearDate != null) clearDate,
                ]),
              ]);
            }
            return Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 320, child: searchField),
              SizedBox(width: 180, child: typeField),
              dateBtn,
              if (clearDate != null) clearDate,
            ]);
          }),
          const SizedBox(height: 6),
          if (_filteredMovements.length != _movements.length)
            Text(_filteredMovements.length.toString() + ' of ' + _movements.length.toString() + ' entries match',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Expanded(
            child: mobile
                ? (_filteredMovements.isEmpty
                    ? const Center(child: Text('No entries match.', style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: _filteredMovements.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _movementCard(_filteredMovements[i], multiBranch),
                      ))
                : Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                  child: Row(children: [
                    const Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    if (multiBranch)
                      const Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    const Expanded(flex: 2, child: Text('Type', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    const Expanded(flex: 3, child: Text('Voucher / Notes', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: multiBranch ? 2 : 3, child: const Text('Description', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    const Expanded(flex: 2, child: Text('In', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    const Expanded(flex: 2, child: Text('Out', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text(multiBranch ? 'Branch Bal.' : 'Balance', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _filteredMovements.isEmpty
                      ? const Center(child: Text('No entries match.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: _filteredMovements.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final m = _filteredMovements[i];
                            final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
                            final runQty = m['running_qty'] as double;
                            final entryUom = m['uoms']?['abbreviation'] as String? ?? '';
                            final date = m['moved_at'] != null
                                ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(m['moved_at'] as String).toLocal()) : '-';
                            final type = _displayType(m);
                            final refId = m['reference_id'] as String?;
                            final refType = m['reference_type'] as String?;
                            final vno = refId != null ? (_voucherNumbers[refId] ?? '') : '';
                            final hasVoucher = vno.isNotEmpty && refType != null && refId != null;
                            final displayRef = vno.isNotEmpty ? vno : ((m['notes'] as String? ?? '').isNotEmpty ? m['notes'] as String : _friendlyRefLabel(refType));
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              child: Row(children: [
                                Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 12))),
                                if (multiBranch)
                                  Expanded(flex: 2, child: Text(
                                      _branchNameById(m['branch_id'] as String?) ?? '—',
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                                Expanded(flex: 2, child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(spacing: 4, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: _typeColor(type).withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                      child: Text(type, style: TextStyle(fontSize: 11, color: _typeColor(type), fontWeight: FontWeight.w600)),
                                    ),
                                    // A movement with no created_by was NOT posted from the app —
                                    // every screen stamps the user. It came from a script / manual
                                    // SQL repair. Flag it so data fixes announce themselves instead
                                    // of masquerading as ordinary vouchers.
                                    if (((m['created_by'] as String?) ?? '').isEmpty && refType != 'grn_qty_correction')
                                      Tooltip(
                                        message: 'No user recorded — this entry was made by a script or manual database repair, not from a screen in the app.',
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AppTheme.warning.withOpacity(0.12),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: AppTheme.warning.withOpacity(0.45)),
                                          ),
                                          child: Row(mainAxisSize: MainAxisSize.min, children: const [
                                            Icon(Icons.terminal, size: 10, color: AppTheme.warning),
                                            SizedBox(width: 3),
                                            Text('manual', style: TextStyle(fontSize: 10, color: AppTheme.warning, fontWeight: FontWeight.w700)),
                                          ]),
                                        ),
                                      ),
                                  ]),
                                )),
                                Expanded(flex: 3, child: hasVoucher
                                    ? MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          onTap: () => _openVoucherFromMovement(m),
                                          child: Text(displayRef, style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
                                        ),
                                      )
                                    : Text(displayRef, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                Expanded(flex: multiBranch ? 2 : 3, child: Text(_movementDescription(m),
                                    maxLines: 2, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(qty > 0 ? '+' + qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2) + ' ' + entryUom : '-',
                                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.success))),
                                Expanded(flex: 2, child: Text(qty < 0 ? qty.abs().toStringAsFixed(qty.abs() % 1 == 0 ? 0 : 2) + ' ' + entryUom : '-',
                                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.danger))),
                                Expanded(flex: 2, child: Builder(builder: (_) {
                                  // Multi-branch: show that BRANCH's running
                                  // balance (bifurcated); single: combined.
                                  final bal = multiBranch
                                      ? ((m['branch_running'] as double?) ?? 0)
                                      : runQty;
                                  return Text(bal.toStringAsFixed(bal % 1 == 0 ? 0 : 2) + ' ' + entryUom,
                                      style: TextStyle(fontWeight: FontWeight.w700, color: bal > 0 ? AppTheme.success : AppTheme.danger));
                                })),
                              ]),
                            );
                          }),
                ),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  // Mobile: one movement rendered as a compact card instead of a table row.
  Widget _movementCard(Map<String, dynamic> m, bool multiBranch) {
    final qty = (m['quantity'] as num?)?.toDouble() ?? 0;
    final runQty = m['running_qty'] as double;
    final entryUom = m['uoms']?['abbreviation'] as String? ?? '';
    final date = m['moved_at'] != null
        ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(m['moved_at'] as String).toLocal()) : '-';
    final type = _displayType(m);
    final refId = m['reference_id'] as String?;
    final refType = m['reference_type'] as String?;
    final vno = refId != null ? (_voucherNumbers[refId] ?? '') : '';
    final hasVoucher = vno.isNotEmpty && refType != null && refId != null;
    final displayRef = vno.isNotEmpty ? vno : ((m['notes'] as String? ?? '').isNotEmpty ? m['notes'] as String : _friendlyRefLabel(refType));
    final desc = _movementDescription(m);
    final bal = multiBranch ? ((m['branch_running'] as double?) ?? 0) : runQty;
    final isManual = ((m['created_by'] as String?) ?? '').isEmpty && refType != 'grn_qty_correction';

    Widget kv(String label, String value, Color color) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 2),
            Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          ],
        );

    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: _typeColor(type).withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
            child: Text(type, style: TextStyle(fontSize: 11.5, color: _typeColor(type), fontWeight: FontWeight.w700)),
          ),
          if (isManual) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.warning.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.warning.withOpacity(0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.terminal, size: 10, color: AppTheme.warning),
                SizedBox(width: 3),
                Text('manual', style: TextStyle(fontSize: 10, color: AppTheme.warning, fontWeight: FontWeight.w700)),
              ]),
            ),
          ],
          const Spacer(),
          Text(date, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 8),
        hasVoucher
            ? InkWell(
                onTap: () => _openVoucherFromMovement(m),
                child: Text(displayRef,
                    style: const TextStyle(fontSize: 13, color: AppTheme.primary, fontWeight: FontWeight.w700, decoration: TextDecoration.underline)),
              )
            : Text(displayRef, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (desc.isNotEmpty && desc != displayRef) ...[
          const SizedBox(height: 3),
          Text(desc, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ],
        if (multiBranch) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.store_outlined, size: 13, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text(_branchNameById(m['branch_id'] as String?) ?? '—',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ],
        const SizedBox(height: 10),
        const Divider(height: 1),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: kv('In', qty > 0 ? '+' + qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2) + ' ' + entryUom : '—', AppTheme.success)),
          Expanded(child: kv('Out', qty < 0 ? qty.abs().toStringAsFixed(qty.abs() % 1 == 0 ? 0 : 2) + ' ' + entryUom : '—', AppTheme.danger)),
          Expanded(child: kv(multiBranch ? 'Branch Bal.' : 'Balance',
              bal.toStringAsFixed(bal % 1 == 0 ? 0 : 2) + ' ' + entryUom, bal > 0 ? AppTheme.success : AppTheme.danger)),
        ]),
      ]),
    );
  }
}
