import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class _DLine {
  static int _seq = 0;
  final String id = 'dl_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? productId; String productLabel = '';
  final TextEditingController qtyCtrl = TextEditingController();
  double unitCostSnap = 0; double lineCostSnap = 0;
  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() { qtyCtrl.dispose(); }
}

class ErpDamageStockVoucherScreen extends ConsumerStatefulWidget {
  const ErpDamageStockVoucherScreen({super.key});
  @override
  ConsumerState<ErpDamageStockVoucherScreen> createState() => _State();
}

class _State extends ConsumerState<ErpDamageStockVoucherScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};
  Map<String, double> _prodCost = {};
  bool _loadingProducts = true;

  List<Map<String, dynamic>> _vouchers = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  Map<String, dynamic>? _current;
  DateTime _date = DateTime.now();
  final _reasonCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  String _status = 'draft';
  List<_DLine> _lines = [];
  bool _saving = false;
  bool _posting = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isDraft => _status != 'posted';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadProducts(); _loadVouchers(); });
  }

  @override
  void dispose() {
    _reasonCtrl.dispose(); _notesCtrl.dispose();
    for (final l in _lines) l.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }
  static String _trim(double v) { if (v == v.roundToDouble()) return v.toStringAsFixed(0); return v.toString(); }
  static String _money(num v) => NumberFormat('#,##0.00').format(v);

  Future<void> _loadProducts() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadProducts(); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('products')
            .select('id, name, sku, cost_price')
            .eq('org_id', orgId).eq('is_active', true).order('name').range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        all.addAll(list);
        if (list.length < page) break;
        from += page; if (from > 100000) break;
      }
      final items = all.map((p) => {
        'id': p['id'],
        'label': "${p['sku'] != null && (p['sku'] as String).isNotEmpty ? '${p['sku']} — ' : ''}${p['name'] ?? ''}",
      }).toList();
      final labelMap = {for (final p in items) p['id'] as String: p['label'] as String};
      final costMap = {for (final p in all) p['id'] as String: (p['cost_price'] as num? ?? 0).toDouble()};
      if (mounted) setState(() { _products = items; _prodLabel = labelMap; _prodCost = costMap; _loadingProducts = false; });
    } catch (e) { if (mounted) { _snack('Products load error: $e'); setState(() => _loadingProducts = false); } }
  }

  List<Map<String, dynamic>> _filterProducts(String q) {
    if (q.isEmpty) return _products.take(50).toList();
    final ql = q.toLowerCase();
    return _products.where((p) => (p['label'] as String).toLowerCase().contains(ql)).take(200).toList();
  }

  Future<void> _loadVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      final rows = await Supabase.instance.client.from('damage_vouchers')
          .select().eq('org_id', orgId).order('created_at', ascending: false).limit(300);
      if (mounted) setState(() { _vouchers = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  void _newVoucher() {
    for (final l in _lines) l.dispose();
    setState(() {
      _current = null; _status = 'draft';
      _date = DateTime.now();
      _reasonCtrl.clear(); _notesCtrl.clear();
      _lines = [_DLine()];
    });
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    try {
      final rows = await Supabase.instance.client.from('damage_voucher_lines')
          .select().eq('voucher_id', v['id'] as String).order('line_order');
      for (final l in _lines) l.dispose();
      final newLines = (rows as List).map((r) {
        final l = _DLine();
        l.productId = r['product_id'] as String?;
        l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
        final q = (r['quantity'] as num? ?? 0).toDouble();
        if (q != 0) l.qtyCtrl.text = _trim(q);
        l.unitCostSnap = (r['unit_cost'] as num? ?? 0).toDouble();
        l.lineCostSnap = (r['line_cost'] as num? ?? 0).toDouble();
        return l;
      }).toList();
      if (mounted) setState(() {
        _current = v;
        _status = v['status'] as String? ?? 'draft';
        final ds = v['voucher_date'] as String?;
        _date = ds != null ? DateTime.tryParse(ds) ?? DateTime.now() : DateTime.now();
        _reasonCtrl.text = v['reason'] as String? ?? '';
        _notesCtrl.text = v['notes'] as String? ?? '';
        _lines = newLines.isEmpty ? [_DLine()] : newLines;
      });
    } catch (e) { _snack('Load error: $e'); }
  }

  double get _estTotal => _lines.fold(0.0, (s, l) => s + l.qty * (_prodCost[l.productId] ?? 0));

  Future<String?> _save({bool silent = false}) async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return null; }
    if (!_isDraft) { _snack('Posted vouchers cannot be edited'); return _current?['id'] as String?; }
    if (_branchId == null) { _snack('No branch selected — pick one in the sidebar'); return null; }
    final lines = _lines.where((l) => l.productId != null && l.qty > 0).toList();
    if (lines.isEmpty) { _snack('Add at least one damaged item'); return null; }
    if (_reasonCtrl.text.trim().isEmpty) { _snack('Enter a reason for the damage'); return null; }
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    String? resultId;
    try {
      final client = Supabase.instance.client;
      String vId, num;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      if (_current == null) {
        final cnt = await client.from('damage_vouchers').select('id').eq('org_id', orgId);
        num = 'DMG-${_date.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        vId = 'dmg_' + DateTime.now().millisecondsSinceEpoch.toString();
        await client.from('damage_vouchers').insert({
          'id': vId, 'org_id': orgId, 'branch_id': _branchId, 'voucher_number': num,
          'voucher_date': dateStr, 'status': 'draft', 'is_locked': false,
          'reason': _reasonCtrl.text.trim(), 'notes': _notesCtrl.text.trim(),
          'created_by': userId, 'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        vId = _current!['id'] as String; num = _current!['voucher_number'] as String? ?? '';
        await client.from('damage_vouchers').update({
          'branch_id': _branchId, 'voucher_date': dateStr,
          'reason': _reasonCtrl.text.trim(), 'notes': _notesCtrl.text.trim(),
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', vId);
      }
      await client.from('damage_voucher_lines').delete().eq('voucher_id', vId);
      for (var i = 0; i < lines.length; i++) {
        await client.from('damage_voucher_lines').insert({
          'id': vId + '_l' + i.toString(), 'voucher_id': vId,
          'product_id': lines[i].productId, 'quantity': lines[i].qty, 'line_order': i,
        });
      }
      resultId = vId;
      final updated = await client.from('damage_vouchers').select().eq('id', vId).single();
      if (mounted) setState(() => _current = updated);
      if (!silent) _snack('Damage voucher $num saved (draft)');
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
      title: const Text('Post damage write-off?'),
      content: const Text('The damaged stock will be removed from inventory (FIFO) and its cost written off to Inventory Adjustment. This posts to the General Ledger and cannot be edited afterward.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Post')),
      ],
    ));
    if (ok != true) return;
    setState(() => _posting = true);
    try {
      final client = Supabase.instance.client;
      await client.from('damage_vouchers').update({'is_locked': true}).eq('id', id);
      final res = await client.rpc('post_damage_voucher', params: {'p_id': id});
      _snack(res?.toString() ?? 'Posted');
      final updated = await client.from('damage_vouchers').select().eq('id', id).single();
      if (mounted) setState(() { _current = updated; _status = updated['status'] as String? ?? 'posted'; });
      await _loadVouchers();
      await _loadVoucher(updated);
    } catch (e) { _snack('Post failed: ' + e.toString()); }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _delete() async {
    if (_current == null) return;
    if (!_isDraft) { _snack('Posted vouchers cannot be deleted'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete draft?'),
      content: const Text('This draft damage voucher will be permanently deleted.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('damage_vouchers').delete().eq('id', _current!['id'] as String);
      _snack('Draft deleted');
      _newVoucher();
      await _loadVouchers();
    } catch (e) { _snack('Delete failed: $e'); }
  }

  void _addLine() => setState(() => _lines.add(_DLine()));
  void _removeLine(int i) => setState(() { _lines[i].dispose(); _lines.removeAt(i); });

  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _vouchers : _vouchers.where((v) {
      final q = _listSearch.toLowerCase();
      return (v['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
             (v['reason'] as String? ?? '').toLowerCase().contains(q);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 300,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Damage Vouchers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: _newVoucher),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No damage vouchers yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final v = filtered[i]; final sel = _current?['id'] == v['id'];
                final posted = (v['status'] as String? ?? 'draft') == 'posted';
                return InkWell(onTap: () => _loadVoucher(v), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(v['voucher_number'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: (posted ? Colors.green : Colors.orange).withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                        child: Text(posted ? 'Posted' : 'Draft', style: TextStyle(fontSize: 9, color: posted ? Colors.green.shade700 : Colors.orange.shade800, fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: 2),
                    Text(v['reason'] as String? ?? '', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    Text('${v['voucher_date'] ?? ''}  ·  ${_money((v['total_cost'] as num? ?? 0))}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
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
            Expanded(child: Text(_current?['voucher_number'] as String? ?? 'New Damage Voucher', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            if (!_isDraft) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.green.withOpacity(0.13), borderRadius: BorderRadius.circular(4)),
              child: Text('Posted', style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w700))),
            if (_isDraft && _current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete draft'),
            const SizedBox(width: 8),
            if (_isDraft) OutlinedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save draft'),
              onPressed: _saving || _posting ? null : () => _save()),
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
              SizedBox(width: 220, child: _labeled('Branch', _readonlyBox((ref.watch(selectedBranchProvider)?['name'] as String?) ?? '—'))),
              const SizedBox(width: 16),
              SizedBox(width: 150, child: _labeled('Date', _dateField())),
              const SizedBox(width: 16),
              Expanded(child: _labeled('Reason *', TextField(controller: _reasonCtrl, enabled: _isDraft,
                decoration: const InputDecoration(hintText: 'e.g. Water damage, breakage in transit', isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12))))),
            ]),
            const SizedBox(height: 10),
            _labeled('Notes', TextField(controller: _notesCtrl, enabled: _isDraft, minLines: 1, maxLines: 3,
              decoration: const InputDecoration(hintText: 'Optional detail', isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)))),
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

  Widget _dateField() => InkWell(
    onTap: _isDraft ? () async {
      final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
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
    final total = posted ? (_current?['total_cost'] as num? ?? 0).toDouble() : _estTotal;
    return Container(padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(posted ? 'Written off (posted, actual FIFO)' : 'Write-off (estimate — actual FIFO computed at posting)',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: posted ? Colors.green.shade700 : AppTheme.textSecondary)),
          const SizedBox(height: 6),
          const Text('Posts Dr Inventory Adjustment / Cr Inventory for the cost of damaged stock.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          const Text('Total write-off', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
          const SizedBox(height: 3),
          Text(_money(total), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.red.shade600)),
        ]),
      ]));
  }

  Widget _linesSection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: const [
            SizedBox(width: 6, height: 14),
            Text('Damaged Items', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            SizedBox(width: 10),
            Expanded(child: Text('Pick the products and quantities being written off.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: const [
            SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            Expanded(child: Text('Product', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 110, child: Text('Quantity', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 120, child: Text('Cost', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 30),
          ])),
        for (var i = 0; i < _lines.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 26, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
              Expanded(child: _isDraft
                ? _ProductField(key: ValueKey(_lines[i].id), initialLabel: _lines[i].productLabel, filterFn: _filterProducts,
                    onPick: (p) => setState(() { _lines[i].productId = p['id'] as String?; _lines[i].productLabel = p['label'] as String? ?? ''; }))
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_lines[i].productLabel, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
              const SizedBox(width: 12),
              SizedBox(width: 110, child: _isDraft
                ? TextField(controller: _lines[i].qtyCtrl, textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(hintText: '0', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
                    style: const TextStyle(fontSize: 12), onChanged: (_) => setState(() {}))
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_trim(_lines[i].qty), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 12),
              SizedBox(width: 120, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(
                _isDraft ? _money(_lines[i].qty * (_prodCost[_lines[i].productId] ?? 0)) : _money(_lines[i].lineCostSnap),
                textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)))),
              SizedBox(width: 30, child: _isDraft ? IconButton(icon: const Icon(Icons.close, size: 14, color: Colors.red), onPressed: () => _removeLine(i), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact) : const SizedBox()),
            ])),
        if (_isDraft) Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('Add item', style: TextStyle(fontSize: 12)), onPressed: _addLine))),
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
