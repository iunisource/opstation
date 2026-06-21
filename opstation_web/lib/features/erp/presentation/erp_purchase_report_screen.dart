// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpPurchaseReportScreen extends ConsumerStatefulWidget {
  const ErpPurchaseReportScreen({super.key});
  @override
  ConsumerState<ErpPurchaseReportScreen> createState() => _ErpPurchaseReportScreenState();
}

class _ErpPurchaseReportScreenState extends ConsumerState<ErpPurchaseReportScreen> {
  late DateTime _from;
  late DateTime _to;
  String? _supplierId; // null = all suppliers
  String? _categoryId; // null = all categories
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _rows = [];
  bool _loadingFilters = true;
  bool _running = false;
  bool _hasRun = false;
  String? _runError;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month, now.day);
    _loadFilters();
  }

  Future<void> _loadFilters() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loadingFilters = false);
      return;
    }
    try {
      final client = Supabase.instance.client;
      final sup = await client
          .from('suppliers')
          .select('id, name, category_id')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      List<Map<String, dynamic>> cats = [];
      try {
        final c = await client
            .from('supplier_categories')
            .select('id, name')
            .eq('org_id', orgId)
            .eq('is_active', true)
            .order('name');
        cats = List<Map<String, dynamic>>.from(c);
      } catch (_) {}
      setState(() {
        _suppliers = List<Map<String, dynamic>>.from(sup);
        _categories = cats;
        _loadingFilters = false;
      });
    } catch (_) {
      setState(() => _loadingFilters = false);
    }
  }

  List<Map<String, dynamic>> get _suppliersForCategory => _categoryId == null
      ? _suppliers
      : _suppliers.where((s) => s['category_id'] == _categoryId).toList();

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _pretty(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _group(String s) {
    final neg = s.startsWith('-');
    s = neg ? s.substring(1) : s;
    final dot = s.indexOf('.');
    final intPart = dot == -1 ? s : s.substring(0, dot);
    final frac = dot == -1 ? '' : s.substring(dot);
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '${neg ? '-' : ''}$buf$frac';
  }

  String _num0(num? n) {
    final v = (n ?? 0).toDouble();
    final whole = v.roundToDouble() == v;
    return _group(whole ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
  }

  String _num2(num? n) => _group((n ?? 0).toDouble().toStringAsFixed(2));

  String _nameOf(List<Map<String, dynamic>> list, String? id, String allLabel) {
    if (id == null) return allLabel;
    for (final m in list) {
      if (m['id'] == id) return m['name'] as String? ?? '';
    }
    return '';
  }

  Future<void> _pickDate(bool isFrom) async {
    final init = isFrom ? _from : _to;
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      if (isFrom) {
        _from = d;
      } else {
        _to = d;
      }
    });
  }

  Future<void> _run() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      final res = await Supabase.instance.client.rpc('fn_purchase_report', params: {
        'p_org_id': orgId,
        'p_from': _ymd(_from),
        'p_to': _ymd(_to),
        'p_supplier_id': _supplierId,
        'p_category_id': _categoryId,
      });
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _running = false;
        _hasRun = true;
      });
    } catch (e) {
      setState(() {
        _running = false;
        _hasRun = true;
        _runError = '$e';
        _rows = [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Purchase Report',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          if (_loadingFilters)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator())
          else
            _filterBar(),
          const SizedBox(height: 16),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _dateField('From', _from, () => _pickDate(true)),
          _dateField('To', _to, () => _pickDate(false)),
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String?>(
              value: _categoryId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('All categories')),
                ..._categories.map((c) => DropdownMenuItem<String?>(
                    value: c['id'] as String, child: Text(c['name'] as String? ?? ''))),
              ],
              onChanged: (v) => setState(() {
                _categoryId = v;
                if (_supplierId != null &&
                    !_suppliersForCategory.any((s) => s['id'] == _supplierId)) {
                  _supplierId = null;
                }
              }),
            ),
          ),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String?>(
              value: _supplierId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Supplier'),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('All suppliers')),
                ..._suppliersForCategory.map((s) => DropdownMenuItem<String?>(
                    value: s['id'] as String, child: Text(s['name'] as String? ?? ''))),
              ],
              onChanged: (v) => setState(() => _supplierId = v),
            ),
          ),
          ElevatedButton.icon(
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.assessment_outlined, size: 18),
            label: Text(_running ? 'Running…' : 'Run Report'),
          ),
        ],
      ),
    );
  }

  Widget _dateField(String label, DateTime d, VoidCallback onTap) {
    return SizedBox(
      width: 150,
      child: InkWell(
        onTap: onTap,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: const Icon(Icons.calendar_today_outlined, size: 16),
          ),
          child: Text(_pretty(d), style: const TextStyle(fontSize: 14)),
        ),
      ),
    );
  }

  Widget _results() {
    if (_running) return const Center(child: CircularProgressIndicator());
    if (!_hasRun) {
      return const Center(
          child: Text('Choose filters and tap Run Report.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    if (_runError != null) {
      return Center(
          child: Text('Failed to run report:\n$_runError',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.danger)));
    }
    if (_rows.isEmpty) {
      return const Center(
          child: Text('No purchases found for these filters.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }

    // Group by supplier, preserving the RPC's ordering.
    final groups = <String, List<Map<String, dynamic>>>{};
    final supplierNames = <String, String>{};
    for (final r in _rows) {
      final sid = (r['supplier_id'] as String?) ?? '';
      supplierNames[sid] = (r['supplier_name'] as String?) ?? '';
      (groups[sid] ??= []).add(r);
    }

    final grandTotal = _rows.fold<double>(
        0, (a, r) => a + ((r['total'] as num?)?.toDouble() ?? 0));
    final singleSupplier = _supplierId != null;
    final catLabel = _nameOf(_categories, _categoryId, 'All categories');
    final supLabel = _nameOf(_suppliers, _supplierId, 'All suppliers');

    return SingleChildScrollView(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_pretty(_from)}  to  ${_pretty(_to)}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 2),
            Text('Supplier: $supLabel     Category: $catLabel',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            for (final entry in groups.entries) ...[
              if (!singleSupplier) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: Text(supplierNames[entry.key] ?? '',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w800))),
                  Text(
                      _num2(entry.value.fold<double>(
                          0, (a, r) => a + ((r['total'] as num?)?.toDouble() ?? 0))),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 6),
              ],
              _tableHeader(),
              const Divider(height: 1),
              ...entry.value.map(_productRow),
              const Divider(height: 1),
              const SizedBox(height: 12),
            ],
            const Divider(height: 1, thickness: 1.4),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: Text(singleSupplier ? 'Total' : 'Grand Total',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800))),
              Text(_num2(grandTotal),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _tableHeader() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(
            flex: 5,
            child: Text('Product',
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(
            flex: 2,
            child: Text('Qty',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(
            flex: 2,
            child: Text('Rate',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(
            flex: 3,
            child: Text('Total',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary))),
      ]),
    );
  }

  Widget _productRow(Map<String, dynamic> r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(
            flex: 5,
            child: Text(r['product_name'] as String? ?? '',
                style: const TextStyle(fontSize: 13))),
        Expanded(
            flex: 2,
            child: Text(_num0(r['qty'] as num?),
                textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
        Expanded(
            flex: 2,
            child: Text(_num2(r['rate'] as num?),
                textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
        Expanded(
            flex: 3,
            child: Text(_num2(r['total'] as num?),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}
