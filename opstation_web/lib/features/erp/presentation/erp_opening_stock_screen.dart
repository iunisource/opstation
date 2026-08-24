import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class _OsLine {
  static int _seq = 0;
  final String id = 'ol_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? productId; String productLabel = '';
  String? uomId; String uomLabel = '';
  final TextEditingController qtyCtrl = TextEditingController();
  final TextEditingController costCtrl = TextEditingController();
  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  double get cost => double.tryParse(costCtrl.text) ?? 0;
  double get value => qty * cost;
  void dispose() { qtyCtrl.dispose(); costCtrl.dispose(); }
}

class ErpOpeningStockScreen extends ConsumerStatefulWidget {
  const ErpOpeningStockScreen({super.key});
  @override
  ConsumerState<ErpOpeningStockScreen> createState() => _ErpOpeningStockScreenState();
}

class _ErpOpeningStockScreenState extends ConsumerState<ErpOpeningStockScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};
  Map<String, String?> _prodBaseUom = {};
  Map<String, String> _uomAbbr = {};
  bool _loadingProducts = true;

  List<Map<String, dynamic>> _branches = [];

  List<Map<String, dynamic>> _vouchers = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  Map<String, dynamic>? _current;
  String? _branchId;
  DateTime _date = DateTime.now();
  final _notesCtrl = TextEditingController();
  String _status = 'draft';
  bool _isVoided = false;
  List<_OsLine> _lines = [];
  String _lineSearch = ''; // filters the voucher's product lines for review
  bool _saving = false;
  bool _posting = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isDraft => _status == 'draft';
  bool get _canVoid => _status == 'posted' && !_isVoided;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProducts(); _loadUoms(); _loadBranches(); _loadVouchers();
    });
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    for (final l in _lines) l.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }
  static String _trim(double v) { if (v == v.roundToDouble()) return v.toStringAsFixed(0); return v.toString(); }
  static String _money(num v) => money(v);

  // ---------- loaders ----------
  Future<void> _loadProducts() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadProducts(); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('products')
            .select('id, name, sku, base_uom_id')
            .eq('org_id', orgId).eq('is_active', true).order('name').range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        all.addAll(list);
        if (list.length < page) break;
        from += page; if (from > 100000) break;
      }
      final items = all.map((p) => {
        'id': p['id'],
        'label': "${p['sku'] != null && (p['sku'] as String).isNotEmpty ? '${p['sku']} \u2014 ' : ''}${p['name'] ?? ''}",
      }).toList();
      if (mounted) setState(() {
        _products = items;
        _prodLabel = {for (final p in items) p['id'] as String: p['label'] as String};
        _prodBaseUom = {for (final p in all) p['id'] as String: p['base_uom_id'] as String?};
        _loadingProducts = false;
      });
    } catch (e) { if (mounted) { _snack('Products load error: $e'); setState(() => _loadingProducts = false); } }
  }

  Future<void> _loadUoms() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('uoms').select('id, name, abbreviation').eq('org_id', orgId).order('name');
      if (mounted) setState(() => _uomAbbr = {for (final u in rows as List) u['id'] as String: (u['abbreviation'] ?? u['name'] ?? '') as String});
    } catch (_) {}
  }

  List<Map<String, dynamic>> _filterProducts(String q) {
    if (q.isEmpty) return _products.take(50).toList();
    return _products.where((p) => matchesQuery('${p['label'] ?? ''}', q)).take(200).toList();
  }

  Future<void> _loadBranches() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('branches').select().eq('org_id', orgId).eq('is_active', true).order('name');
      final list = List<Map<String, dynamic>>.from(rows);
      if (mounted) setState(() {
        _branches = list;
        _branchId ??= (ref.read(selectedBranchProvider)?['id'] as String?) ?? (list.isNotEmpty ? list.first['id'] as String? : null);
      });
    } catch (_) {}
  }

  Future<void> _loadVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      final rows = await Supabase.instance.client.from('opening_stock_vouchers')
          .select('*, branches(name)').eq('org_id', orgId).order('created_at', ascending: false).limit(300);
      if (mounted) setState(() { _vouchers = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  // ---------- form state ----------
  void _newVoucher() {
    for (final l in _lines) l.dispose();
    setState(() {
      _current = null; _status = 'draft'; _isVoided = false;
      _date = DateTime.now();
      _notesCtrl.clear();
      _branchId = (ref.read(selectedBranchProvider)?['id'] as String?) ?? (_branches.isNotEmpty ? _branches.first['id'] as String? : null);
      _lines = [_OsLine()];
      _lineSearch = '';
    });
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    try {
      final rows = await Supabase.instance.client.from('opening_stock')
          .select().eq('voucher_id', v['id'] as String).order('created_at');
      for (final l in _lines) l.dispose();
      final newLines = (rows as List).map((r) {
        final l = _OsLine();
        l.productId = r['product_id'] as String?;
        l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
        l.uomId = r['uom_id'] as String?;
        l.uomLabel = _uomAbbr[l.uomId] ?? '';
        final q = (r['quantity'] as num? ?? 0).toDouble();
        final c = (r['unit_cost'] as num? ?? 0).toDouble();
        if (q != 0) l.qtyCtrl.text = _trim(q);
        if (c != 0) l.costCtrl.text = _trim(c);
        return l;
      }).toList();
      if (mounted) setState(() {
        _current = v;
        _status = v['status'] as String? ?? 'draft';
        _isVoided = v['is_voided'] == true;
        _branchId = v['branch_id'] as String?;
        final ds = v['voucher_date'] as String?;
        _date = ds != null ? (DateTime.tryParse(ds) ?? DateTime.now()) : DateTime.now();
        _notesCtrl.text = v['notes'] as String? ?? '';
        _lines = newLines.isEmpty ? [_OsLine()] : newLines;
        _lineSearch = '';
      });
    } catch (e) { _snack('Load error: $e'); }
  }

  void _onPickProduct(int i, Map<String, dynamic> p) {
    setState(() {
      _lines[i].productId = p['id'] as String?;
      _lines[i].productLabel = p['label'] as String? ?? '';
      final bu = _prodBaseUom[_lines[i].productId];
      _lines[i].uomId = bu;
      _lines[i].uomLabel = _uomAbbr[bu] ?? '';
    });
  }

  double get _total => _lines.fold(0.0, (s, l) => s + l.value);

  // ---------- save / post / void / delete ----------
  Future<String?> _save({bool silent = false}) async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return null; }
    if (!_isDraft) { _snack('Only draft vouchers can be edited'); return _current?['id'] as String?; }
    if (_branchId == null) { _snack('Select a branch'); return null; }
    final lines = _lines.where((l) => l.productId != null && l.qty > 0).toList();
    if (lines.isEmpty) { _snack('Add at least one product with a quantity'); return null; }
    for (final l in lines) { if (l.uomId == null) { _snack('A line is missing its unit of measure'); return null; } }
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    String? resultId;
    try {
      final client = Supabase.instance.client;
      String vId, num;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final total = lines.fold(0.0, (s, l) => s + l.value);
      if (_current == null) {
        final cnt = await client.from('opening_stock_vouchers').select('id').eq('org_id', orgId);
        num = 'OPEN-${_date.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        vId = 'osv_' + DateTime.now().millisecondsSinceEpoch.toString();
        await client.from('opening_stock_vouchers').insert({
          'id': vId, 'org_id': orgId, 'branch_id': _branchId, 'voucher_number': num,
          'voucher_date': dateStr, 'status': 'draft', 'is_locked': false, 'is_voided': false,
          'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          'total_value': total, 'created_by': userId,
          'created_at': DateTime.now().toIso8601String(), 'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        vId = _current!['id'] as String; num = _current!['voucher_number'] as String? ?? '';
        await client.from('opening_stock_vouchers').update({
          'branch_id': _branchId, 'voucher_date': dateStr,
          'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          'total_value': total, 'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', vId);
      }
      // replace lines
      await client.from('opening_stock').delete().eq('voucher_id', vId);
      for (var i = 0; i < lines.length; i++) {
        await client.from('opening_stock').insert({
          'id': 'os_${DateTime.now().microsecondsSinceEpoch}_$i',
          'org_id': orgId, 'branch_id': _branchId, 'voucher_id': vId,
          'product_id': lines[i].productId, 'uom_id': lines[i].uomId,
          'quantity': lines[i].qty, 'unit_cost': lines[i].cost,
          'entry_date': dateStr, 'created_by': userId,
        });
      }
      resultId = vId;
      final updated = await client.from('opening_stock_vouchers').select('*, branches(name)').eq('id', vId).single();
      if (mounted) setState(() => _current = updated);
      if (!silent) _snack('Opening stock $num saved (draft)');
      await _loadVouchers();
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
    return resultId;
  }

  Future<void> _post() async {
    if (!_isDraft) return;
    final id = await _save(silent: true);
    if (id == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Post opening stock?'),
      content: const Text('This sets the on-hand quantities and posts Dr Inventory / Cr Opening Equity for the value of these items. It posts to the General Ledger and cannot be edited afterward (it can be voided if nothing has been sold yet).'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Post')),
      ],
    ));
    if (ok != true) return;
    setState(() => _posting = true);
    try {
      final client = Supabase.instance.client;
      final res = await client.rpc('post_opening_stock_voucher', params: {'p_id': id});
      _snack(res?.toString() ?? 'Posted');
      final updated = await client.from('opening_stock_vouchers').select('*, branches(name)').eq('id', id).single();
      if (mounted) { await _loadVoucher(updated); }
      await _loadVouchers();
    } catch (e) { _snack('Post failed: ' + e.toString()); }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _void() async {
    final id = _current?['id'] as String?;
    if (id == null || !_canVoid) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Void opening stock?'),
      content: const Text('This reverses the GL entry, removes the cost layers, and reverses the on-hand quantities for this voucher. It will refuse if any of this opening stock has already been sold or transferred. This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Void')),
      ],
    ));
    if (ok != true) return;
    setState(() => _posting = true);
    try {
      final client = Supabase.instance.client;
      final res = await client.rpc('void_opening_stock_voucher', params: {'p_id': id, 'p_user': ref.read(currentUserProvider)?.id});
      _snack(res?.toString() ?? 'Voided');
      final updated = await client.from('opening_stock_vouchers').select('*, branches(name)').eq('id', id).single();
      if (mounted) { await _loadVoucher(updated); }
      await _loadVouchers();
    } catch (e) { _snack('Void failed: ' + e.toString()); }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _delete() async {
    final id = _current?['id'] as String?;
    if (id == null) return;
    if (!_isDraft) { _snack('Only drafts can be deleted \u2014 posted vouchers must be voided'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete draft?'),
      content: const Text('This draft opening-stock voucher and its lines will be permanently deleted.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('opening_stock').delete().eq('voucher_id', id);
      await Supabase.instance.client.from('opening_stock_vouchers').delete().eq('id', id);
      _snack('Draft deleted');
      _newVoucher();
      await _loadVouchers();
    } catch (e) { _snack('Delete failed: $e'); }
  }

  void _addLine() => setState(() => _lines.add(_OsLine()));
  void _removeLine(int i) => setState(() { _lines[i].dispose(); _lines.removeAt(i); });

  String _branchName(String? id) => _branches.firstWhere((b) => b['id'] == id, orElse: () => {})['name'] as String? ?? '';

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _vouchers : _vouchers.where((v) {
      return matchesQuery('${v['voucher_number'] ?? ''} ${v['branches']?['name'] ?? ''}', _listSearch);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 300,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Opening Stock', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: _newVoucher),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true, border: OutlineInputBorder()),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No opening stock vouchers yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final v = filtered[i]; final sel = _current?['id'] == v['id'];
                final st = (v['status'] as String? ?? 'draft');
                final voided = v['is_voided'] == true || st == 'voided';
                final posted = !voided && st == 'posted';
                final badgeText = voided ? 'Voided' : (posted ? 'Posted' : 'Draft');
                final badgeColor = voided ? Colors.red : (posted ? Colors.green : Colors.orange);
                return InkWell(onTap: () => _loadVoucher(v), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(v['voucher_number'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: badgeColor.withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                        child: Text(badgeText, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: badgeColor))),
                    ]),
                    const SizedBox(height: 2),
                    Text(v['branches']?['name'] as String? ?? '', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    Text('${v['voucher_date'] ?? ''}  \u00b7  ${_money((v['total_value'] as num? ?? 0))}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ]),
                ));
              })),
        ])),

      Expanded(child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            IconButton(icon: Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, size: 18), onPressed: () => setState(() => _drawerOpen = !_drawerOpen), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            const SizedBox(width: 8),
            Expanded(child: Text(_current?['voucher_number'] as String? ?? 'New Opening Stock', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            if (_isVoided) const Padding(padding: EdgeInsets.only(right: 8), child: Chip(label: Text('VOIDED'), backgroundColor: Color(0xFFFDE2E1))),
            if (_status == 'posted' && !_isVoided) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.green.withOpacity(0.13), borderRadius: BorderRadius.circular(4)),
              child: Text('Posted', style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w700))),
            if (_canVoid) Padding(padding: const EdgeInsets.only(left: 8), child: OutlinedButton.icon(
              icon: const Icon(Icons.undo, size: 16, color: Colors.red), label: const Text('Void', style: TextStyle(color: Colors.red)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
              onPressed: _posting ? null : _void)),
            if (_isDraft && _current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete draft'),
            const SizedBox(width: 8),
            if (_isDraft) OutlinedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save draft'), onPressed: _saving || _posting ? null : () => _save()),
            const SizedBox(width: 8),
            if (_isDraft) ElevatedButton.icon(
              icon: _posting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Post'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
              onPressed: _saving || _posting ? null : _post),
          ])),
        Expanded(child: _loadingProducts
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading...', style: TextStyle(color: AppTheme.textSecondary))]))
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 240, child: _labeled('Branch *', _branchField())),
              const SizedBox(width: 16),
              SizedBox(width: 150, child: _labeled('Date', _dateField())),
              const SizedBox(width: 16),
              Expanded(child: _labeled('Notes', TextField(controller: _notesCtrl, enabled: _isDraft,
                decoration: const InputDecoration(hintText: 'Optional', isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12))))),
            ]),
            const SizedBox(height: 20),
            _summaryCard(),
            const SizedBox(height: 20),
            _linesSection(),
            const SizedBox(height: 30),
          ]))),
      ])),
    ]));
  }

  Widget _labeled(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
    const SizedBox(height: 4), child,
  ]);

  Widget _readonlyBox(String text) => Container(width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
    child: Text(text, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis));

  Widget _branchField() {
    final ids = _branches.map((b) => b['id'] as String).toSet();
    if (!_isDraft || (_branchId != null && !ids.contains(_branchId))) {
      return _readonlyBox(_branchName(_branchId).isEmpty ? '\u2014' : _branchName(_branchId));
    }
    return DropdownButtonFormField<String>(
      value: ids.contains(_branchId) ? _branchId : null, isDense: true,
      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
      style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
      items: _branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (v) => setState(() => _branchId = v));
  }

  Widget _dateField() => InkWell(
    onTap: _isDraft ? () async {
      final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime(2100));
      if (d != null) setState(() => _date = d);
    } : null,
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
      child: Row(children: [
        Expanded(child: Text(DateFormat('yyyy-MM-dd').format(_date), style: const TextStyle(fontSize: 12))),
        const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
      ])));

  Widget _summaryCard() {
    final posted = !_isDraft;
    final total = posted ? (_current?['total_value'] as num? ?? 0).toDouble() : _total;
    return Container(padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(posted ? 'Opening value (posted)' : 'Opening value',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: posted ? Colors.green.shade700 : AppTheme.textSecondary)),
          const SizedBox(height: 6),
          const Text('Posts Dr Inventory / Cr Opening Equity for the total below, and sets on-hand quantities.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          const Text('Total value', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
          const SizedBox(height: 3),
          Text(_money(total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)),
        ]),
      ]));
  }

  Widget _linesSection() {
    final q = _lineSearch.trim();
    final matches = [
      for (var i = 0; i < _lines.length; i++)
        if (matchesQuery(_lines[i].productLabel, _lineSearch)) i
    ];
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        if (_lines.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(children: [
              Expanded(child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search product in this voucher',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  border: const OutlineInputBorder(),
                  suffixIcon: q.isEmpty ? null : IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _lineSearch = ''),
                  ),
                ),
                style: const TextStyle(fontSize: 12),
                onChanged: (v) => setState(() => _lineSearch = v),
              )),
              if (q.isNotEmpty) Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text('${matches.length} of ${_lines.length}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
            ]),
          ),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: const [
            SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            Expanded(child: Text('Product', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 60, child: Text('UOM', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 90, child: Text('Quantity', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 100, child: Text('Unit Cost', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 110, child: Text('Value', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 30),
          ])),
        if (matches.isEmpty && q.isNotEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('No product in this voucher matches your search',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        for (final i in matches)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 26, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
              Expanded(child: _isDraft
                ? _ProductField(key: ValueKey(_lines[i].id), initialLabel: _lines[i].productLabel, filterFn: _filterProducts, onPick: (p) => _onPickProduct(i, p))
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_lines[i].productLabel, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
              const SizedBox(width: 12),
              SizedBox(width: 60, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(_lines[i].uomLabel.isEmpty ? '\u2014' : _lines[i].uomLabel, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)))),
              const SizedBox(width: 12),
              SizedBox(width: 90, child: _isDraft
                ? TextField(controller: _lines[i].qtyCtrl, textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(hintText: '0', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
                    style: const TextStyle(fontSize: 12), onChanged: (_) => setState(() {}))
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_trim(_lines[i].qty), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 12),
              SizedBox(width: 100, child: _isDraft
                ? TextField(controller: _lines[i].costCtrl, textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(hintText: '0.00', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
                    style: const TextStyle(fontSize: 12), onChanged: (_) => setState(() {}))
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_money(_lines[i].cost), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 12),
              SizedBox(width: 110, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(_money(_lines[i].value), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)))),
              SizedBox(width: 30, child: _isDraft ? IconButton(icon: const Icon(Icons.close, size: 14, color: Colors.red), onPressed: () => _removeLine(i), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact) : const SizedBox()),
            ])),
        if (_isDraft) Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('Add product', style: TextStyle(fontSize: 12)), onPressed: _addLine))),
      ]),
    );
  }
}

class _ProductField extends StatefulWidget {
  final String initialLabel;
  final List<Map<String, dynamic>> Function(String) filterFn;
  final void Function(Map<String, dynamic>) onPick;
  const _ProductField({super.key, required this.initialLabel, required this.filterFn, required this.onPick});
  @override State<_ProductField> createState() => _ProductFieldState();
}

class _ProductFieldState extends State<_ProductField> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _open = false; String _q = ''; bool _picked = false;

  @override void initState() {
    super.initState();
    _ctrl.text = widget.initialLabel;
    _picked = widget.initialLabel.isNotEmpty;
    _focus.addListener(() { if (!_focus.hasFocus) Future.delayed(const Duration(milliseconds: 160), () { if (mounted && !_focus.hasFocus) setState(() => _open = false); }); });
  }
  @override void dispose() { _ctrl.dispose(); _focus.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final res = widget.filterFn(_q);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(controller: _ctrl, focusNode: _focus,
        decoration: InputDecoration(hintText: 'Search...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          border: OutlineInputBorder(borderSide: BorderSide(color: _picked ? Colors.green : const Color(0xFFE0E0E0))),
          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _picked ? Colors.green : const Color(0xFFE0E0E0))),
          suffixIcon: _picked ? const Icon(Icons.check_circle, size: 14, color: Colors.green) : null),
        style: const TextStyle(fontSize: 12),
        onChanged: (v) => setState(() { _q = v; _open = true; _picked = false; }),
        onTap: () => setState(() { _q = _picked ? '' : _ctrl.text; _open = true; })),
      if (_open && res.isNotEmpty) Container(constraints: const BoxConstraints(maxHeight: 220), margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
        child: ListView(shrinkWrap: true, children: res.map((p) => InkWell(
          onTap: () { widget.onPick(p); _ctrl.text = p['label'] as String? ?? ''; setState(() { _open = false; _picked = true; _q = ''; }); _focus.unfocus(); },
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(p['label'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
        )).toList())),
    ]);
  }
}
