import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class _CLine {
  static int _seq = 0;
  final String id = 'cl_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? productId; String productLabel = '';
  String? reasonId;
  final TextEditingController qtyCtrl = TextEditingController();
  final TextEditingController remarksCtrl = TextEditingController();
  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() { qtyCtrl.dispose(); remarksCtrl.dispose(); }
}

class ErpClaimProcessingVoucherScreen extends ConsumerStatefulWidget {
  const ErpClaimProcessingVoucherScreen({super.key});
  @override
  ConsumerState<ErpClaimProcessingVoucherScreen> createState() => _State();
}

class _State extends ConsumerState<ErpClaimProcessingVoucherScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};
  bool _loadingProducts = true;

  List<Map<String, dynamic>> _customers = [];
  Map<String, String> _custLabel = {};

  List<Map<String, dynamic>> _reasons = [];          // {id, name, is_active}
  Map<String, String> _reasonName = {};

  List<Map<String, dynamic>> _vouchers = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  Map<String, dynamic>? _current;
  String? _customerId; String _customerLabel = '';
  DateTime _date = DateTime.now();
  final _notesCtrl = TextEditingController();
  String _status = 'draft';
  List<_CLine> _lines = [];
  bool _saving = false;
  bool _posting = false;

  // ----- insights -----
  String _view = 'entries';                          // entries | insights
  bool _insLoading = false;
  DateTime? _insFrom; DateTime? _insTo;
  int _insClaims = 0; double _insQty = 0; int _insProducts = 0; int _insCustomers = 0;
  List<Map<String, dynamic>> _insByReason = [];
  List<Map<String, dynamic>> _insByProduct = [];
  List<Map<String, dynamic>> _insByCustomer = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isDraft => _status != 'posted';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProducts(); _loadCustomers(); _loadReasons(); _loadVouchers();
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

  // ---------- loaders ----------
  Future<void> _loadProducts() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadProducts(); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('products')
            .select('id, name, sku')
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
        _loadingProducts = false;
      });
    } catch (e) { if (mounted) { _snack('Products load error: $e'); setState(() => _loadingProducts = false); } }
  }

  Future<void> _loadCustomers() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('customers')
            .select('id, shop_name').eq('org_id', orgId).order('shop_name').range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        all.addAll(list);
        if (list.length < page) break;
        from += page; if (from > 100000) break;
      }
      final items = all.map((c) => {'id': c['id'], 'label': (c['shop_name'] ?? c['id']) as String}).toList();
      if (mounted) setState(() {
        _customers = items;
        _custLabel = {for (final c in items) c['id'] as String: c['label'] as String};
      });
    } catch (_) {}
  }

  Future<void> _loadReasons() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('claim_reasons')
          .select('id, name, is_active').eq('org_id', orgId).order('name');
      if (mounted) setState(() {
        _reasons = List<Map<String, dynamic>>.from(rows);
        _reasonName = {for (final r in _reasons) r['id'] as String: r['name'] as String};
      });
    } catch (_) {}
  }

  Future<void> _loadVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      final rows = await Supabase.instance.client.from('claim_vouchers')
          .select().eq('org_id', orgId).order('created_at', ascending: false).limit(300);
      if (mounted) setState(() { _vouchers = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  List<Map<String, dynamic>> _filterProducts(String q) {
    if (q.isEmpty) return _products.take(50).toList();
    return _products.where((p) => matchesQuery('${p['label'] ?? ''}', q)).take(200).toList();
  }

  List<Map<String, dynamic>> _filterCustomers(String q) {
    if (q.isEmpty) return _customers.take(50).toList();
    return _customers.where((c) => matchesQuery('${c['label'] ?? ''}', q)).take(200).toList();
  }

  List<Map<String, dynamic>> get _activeReasons => _reasons.where((r) => r['is_active'] != false).toList();

  // ---------- form state ----------
  void _newVoucher() {
    for (final l in _lines) l.dispose();
    setState(() {
      _current = null; _status = 'draft';
      _date = DateTime.now();
      _customerId = null; _customerLabel = '';
      _notesCtrl.clear();
      _lines = [_CLine()];
    });
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    try {
      final rows = await Supabase.instance.client.from('claim_voucher_lines')
          .select().eq('voucher_id', v['id'] as String).order('line_order');
      for (final l in _lines) l.dispose();
      final newLines = (rows as List).map((r) {
        final l = _CLine();
        l.productId = r['product_id'] as String?;
        l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
        l.reasonId = r['reason_id'] as String?;
        final q = (r['quantity'] as num? ?? 0).toDouble();
        if (q != 0) l.qtyCtrl.text = _trim(q);
        l.remarksCtrl.text = r['remarks'] as String? ?? '';
        return l;
      }).toList();
      if (mounted) setState(() {
        _current = v;
        _status = v['status'] as String? ?? 'draft';
        _customerId = v['customer_id'] as String?;
        _customerLabel = _custLabel[_customerId] ?? (_customerId ?? '');
        final ds = v['voucher_date'] as String?;
        _date = ds != null ? (DateTime.tryParse(ds) ?? DateTime.now()) : DateTime.now();
        _notesCtrl.text = v['notes'] as String? ?? '';
        _lines = newLines.isEmpty ? [_CLine()] : newLines;
      });
    } catch (e) { _snack('Load error: $e'); }
  }

  // ---------- reasons: quick add + manage ----------
  Future<String?> _createReason(String name) async {
    final orgId = _orgId; if (orgId == null) return null;
    final trimmed = name.trim(); if (trimmed.isEmpty) return null;
    final existing = _reasons.firstWhere(
        (r) => (r['name'] as String).toLowerCase() == trimmed.toLowerCase(),
        orElse: () => {});
    if (existing.isNotEmpty) return existing['id'] as String;
    final id = 'cr_' + DateTime.now().millisecondsSinceEpoch.toString();
    try {
      await Supabase.instance.client.from('claim_reasons').insert({
        'id': id, 'org_id': orgId, 'name': trimmed, 'is_active': true,
      });
      await _loadReasons();
      return id;
    } catch (e) { _snack('Could not add reason: $e'); return null; }
  }

  Future<String?> _showAddReasonDialog() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Add claim reason'),
      content: TextField(controller: ctrl, autofocus: true,
        decoration: const InputDecoration(hintText: 'e.g. Broken on arrival, Wrong item, Dead on test', border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Add')),
      ],
    ));
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return null;
    return _createReason(name);
  }

  Future<void> _showManageReasons() async {
    await showDialog(context: context, builder: (ctx) {
      final addCtrl = TextEditingController();
      return StatefulBuilder(builder: (ctx, setLocal) {
        Future<void> refresh() async { await _loadReasons(); setLocal(() {}); }
        return AlertDialog(
          title: const Text('Manage claim reasons'),
          content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: addCtrl, decoration: const InputDecoration(hintText: 'New reason', isDense: true, border: OutlineInputBorder()))),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
                onPressed: () async { if (addCtrl.text.trim().isEmpty) return; await _createReason(addCtrl.text); addCtrl.clear(); await refresh(); },
                child: const Text('Add')),
            ]),
            const SizedBox(height: 12),
            SizedBox(height: 280, width: 420, child: _reasons.isEmpty
              ? const Center(child: Text('No reasons yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
              : ListView.separated(
                  itemCount: _reasons.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _reasons[i]; final active = r['is_active'] != false;
                    return ListTile(dense: true,
                      title: Text(r['name'] as String? ?? '', style: TextStyle(fontSize: 13, color: active ? AppTheme.textPrimary : AppTheme.textSecondary, decoration: active ? null : TextDecoration.lineThrough)),
                      trailing: Switch(value: active, onChanged: (v) async {
                        try { await Supabase.instance.client.from('claim_reasons').update({'is_active': v}).eq('id', r['id'] as String); await refresh(); } catch (e) { _snack('Update failed: $e'); }
                      }));
                  })),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        );
      });
    });
    if (mounted) setState(() {});
  }

  // ---------- save / post / delete ----------
  Future<String?> _save({bool silent = false}) async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return null; }
    if (!_isDraft) { _snack('Finalized claims cannot be edited'); return _current?['id'] as String?; }
    if (_branchId == null) { _snack('No branch selected \u2014 pick one in the sidebar'); return null; }
    final lines = _lines.where((l) => l.productId != null && l.qty > 0).toList();
    if (lines.isEmpty) { _snack('Add at least one product with a quantity'); return null; }
    for (final l in lines) { if (l.reasonId == null) { _snack('Each item needs a claim reason'); return null; } }
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    String? resultId;
    try {
      final client = Supabase.instance.client;
      String vId, num;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final totalQty = lines.fold(0.0, (s, l) => s + l.qty);
      if (_current == null) {
        final cnt = await client.from('claim_vouchers').select('id').eq('org_id', orgId);
        num = 'CLM-${_date.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        vId = 'clm_' + DateTime.now().millisecondsSinceEpoch.toString();
        await client.from('claim_vouchers').insert({
          'id': vId, 'org_id': orgId, 'branch_id': _branchId, 'customer_id': _customerId,
          'voucher_number': num, 'voucher_date': dateStr, 'status': 'draft', 'is_locked': false,
          'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          'total_qty': totalQty, 'line_count': lines.length, 'created_by': userId,
          'created_at': DateTime.now().toIso8601String(), 'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        vId = _current!['id'] as String; num = _current!['voucher_number'] as String? ?? '';
        await client.from('claim_vouchers').update({
          'branch_id': _branchId, 'customer_id': _customerId, 'voucher_date': dateStr,
          'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          'total_qty': totalQty, 'line_count': lines.length, 'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', vId);
      }
      await client.from('claim_voucher_lines').delete().eq('voucher_id', vId);
      for (var i = 0; i < lines.length; i++) {
        await client.from('claim_voucher_lines').insert({
          'id': 'cl_${DateTime.now().microsecondsSinceEpoch}_$i', 'voucher_id': vId,
          'product_id': lines[i].productId, 'quantity': lines[i].qty,
          'reason_id': lines[i].reasonId, 'remarks': lines[i].remarksCtrl.text.trim().isEmpty ? null : lines[i].remarksCtrl.text.trim(),
          'line_order': i,
        });
      }
      resultId = vId;
      final updated = await client.from('claim_vouchers').select().eq('id', vId).single();
      if (mounted) setState(() => _current = updated);
      if (!silent) _snack('Claim $num saved (draft)');
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
      title: const Text('Finalize claim?'),
      content: const Text('This locks the claim record so its data stays consistent for reporting. It does not post to the General Ledger or affect stock. You will not be able to edit it afterward (you can still delete it).'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Finalize')),
      ],
    ));
    if (ok != true) return;
    setState(() => _posting = true);
    try {
      final client = Supabase.instance.client;
      await client.from('claim_vouchers').update({
        'status': 'posted', 'is_locked': true, 'posted_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', id);
      final updated = await client.from('claim_vouchers').select().eq('id', id).single();
      if (mounted) { await _loadVoucher(updated); }
      await _loadVouchers();
      _snack('Claim finalized');
    } catch (e) { _snack('Finalize failed: ' + e.toString()); }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _delete() async {
    final id = _current?['id'] as String?;
    if (id == null) return;
    final finalized = !_isDraft;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(finalized ? 'Delete claim?' : 'Delete draft?'),
      content: Text(finalized
        ? 'This finalized claim and its lines will be permanently deleted. Since a claim has no ledger or stock impact, this is safe — but it cannot be undone.'
        : 'This draft claim voucher and its lines will be permanently deleted.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('claim_voucher_lines').delete().eq('voucher_id', id);
      await Supabase.instance.client.from('claim_vouchers').delete().eq('id', id);
      _snack('Claim deleted');
      _newVoucher();
      await _loadVouchers();
    } catch (e) { _snack('Delete failed: $e'); }
  }

  void _addLine() => setState(() => _lines.add(_CLine()));
  void _removeLine(int i) => setState(() { _lines[i].dispose(); _lines.removeAt(i); });

  // ---------- insights ----------
  Future<void> _loadInsights() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _insLoading = true);
    try {
      final client = Supabase.instance.client;
      final heads = await client.from('claim_vouchers').select('id, voucher_date, customer_id').eq('org_id', orgId);
      final headList = List<Map<String, dynamic>>.from(heads).where((h) {
        final d = h['voucher_date'] != null ? DateTime.tryParse(h['voucher_date'] as String) : null;
        if (_insFrom != null && (d == null || d.isBefore(_insFrom!))) return false;
        if (_insTo != null && (d == null || d.isAfter(_insTo!))) return false;
        return true;
      }).toList();
      final ids = headList.map((h) => h['id'] as String).toList();
      final headById = {for (final h in headList) h['id'] as String: h};

      final rQty = <String, double>{}, pQty = <String, double>{}, cQty = <String, double>{};
      final rCl = <String, Set<String>>{}, pCl = <String, Set<String>>{}, cCl = <String, Set<String>>{};
      double totalQty = 0; final vSet = <String>{}; final prods = <String>{}; final custs = <String>{};

      if (ids.isNotEmpty) {
        // chunk to stay well under PostgREST limits
        const chunk = 200;
        for (var i = 0; i < ids.length; i += chunk) {
          final slice = ids.sublist(i, (i + chunk > ids.length) ? ids.length : i + chunk);
          final lines = await client.from('claim_voucher_lines')
              .select('voucher_id, product_id, reason_id, quantity').inFilter('voucher_id', slice);
          for (final l in lines as List) {
            final vid = l['voucher_id'] as String;
            final qty = (l['quantity'] as num?)?.toDouble() ?? 0;
            final rid = l['reason_id'] as String? ?? '__none__';
            final pid = l['product_id'] as String? ?? '__none__';
            final cid = (headById[vid]?['customer_id'] as String?) ?? '__none__';
            totalQty += qty; vSet.add(vid); if (pid != '__none__') prods.add(pid); if (cid != '__none__') custs.add(cid);
            rQty[rid] = (rQty[rid] ?? 0) + qty; (rCl[rid] ??= <String>{}).add(vid);
            pQty[pid] = (pQty[pid] ?? 0) + qty; (pCl[pid] ??= <String>{}).add(vid);
            cQty[cid] = (cQty[cid] ?? 0) + qty; (cCl[cid] ??= <String>{}).add(vid);
          }
        }
      }

      List<Map<String, dynamic>> rank(Map<String, double> q, Map<String, Set<String>> c, String Function(String) label) {
        final list = q.entries.map((e) => {'label': label(e.key), 'qty': e.value, 'claims': (c[e.key]?.length ?? 0)}).toList();
        list.sort((a, b) => (b['qty'] as double).compareTo(a['qty'] as double));
        return list;
      }

      final byReason = rank(rQty, rCl, (k) => k == '__none__' ? '(no reason)' : (_reasonName[k] ?? k));
      final byProduct = rank(pQty, pCl, (k) => k == '__none__' ? '(no product)' : (_prodLabel[k] ?? k));
      final byCustomer = rank(cQty, cCl, (k) => k == '__none__' ? '(no customer)' : (_custLabel[k] ?? k));

      if (mounted) setState(() {
        _insClaims = vSet.length; _insQty = totalQty; _insProducts = prods.length; _insCustomers = custs.length;
        _insByReason = byReason; _insByProduct = byProduct; _insByCustomer = byCustomer; _insLoading = false;
      });
    } catch (e) { if (mounted) { _snack('Insights load error: $e'); setState(() => _insLoading = false); } }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final filtered = _vouchers.where((v) =>
      matchesQuery('${v['voucher_number'] ?? ''} ${_custLabel[v['customer_id']] ?? ''}', _listSearch)).toList();

    return Container(color: AppTheme.background, child: Column(children: [
      _modeBar(),
      Expanded(child: _view == 'insights' ? _insightsView() : _entriesBody(filtered)),
    ]));
  }

  Widget _modeBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
    child: Row(children: [
      _modeTab('entries', 'Claim Entries', Icons.assignment_outlined),
      const SizedBox(width: 8),
      _modeTab('insights', 'Insights', Icons.insights_outlined),
    ]),
  );

  Widget _modeTab(String v, String label, IconData icon) {
    final sel = _view == v;
    return InkWell(
      onTap: () { setState(() => _view = v); if (v == 'insights') _loadInsights(); },
      borderRadius: BorderRadius.circular(6),
      child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: sel ? AppTheme.primary : AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: sel ? AppTheme.primary : AppTheme.border)),
        child: Row(children: [
          Icon(icon, size: 14, color: sel ? Colors.white : AppTheme.textSecondary),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? Colors.white : AppTheme.textSecondary)),
        ])),
    );
  }

  Widget _entriesBody(List<Map<String, dynamic>> filtered) {
    return Row(children: [
      if (_drawerOpen) Container(width: 300,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Claims', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: _newVoucher),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true, border: OutlineInputBorder()),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No claims yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
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
                        child: Text(posted ? 'Finalized' : 'Draft', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: posted ? Colors.green.shade700 : Colors.orange.shade800))),
                    ]),
                    const SizedBox(height: 2),
                    Text(_custLabel[v['customer_id']] ?? 'No customer', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    Text('${v['voucher_date'] ?? ''}  \u00b7  ${(v['line_count'] as num? ?? 0)} item(s)', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
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
            Expanded(child: Text(_current?['voucher_number'] as String? ?? 'New Claim', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            TextButton.icon(icon: const Icon(Icons.tune, size: 16), label: const Text('Manage reasons', style: TextStyle(fontSize: 12)), onPressed: _showManageReasons),
            const SizedBox(width: 8),
            if (_status == 'posted') Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.green.withOpacity(0.13), borderRadius: BorderRadius.circular(4)),
              child: Text('Finalized', style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w700))),
            if (_current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete claim'),
            const SizedBox(width: 8),
            if (_isDraft) OutlinedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save draft'), onPressed: _saving || _posting ? null : () => _save()),
            const SizedBox(width: 8),
            if (_isDraft) ElevatedButton.icon(
              icon: _posting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.lock_outline, size: 16),
              label: const Text('Finalize'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
              onPressed: _saving || _posting ? null : _post),
          ])),
        Expanded(child: _loadingProducts
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading...', style: TextStyle(color: AppTheme.textSecondary))]))
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 220, child: _labeled('Branch', _readonlyBox((ref.watch(selectedBranchProvider)?['name'] as String?) ?? '\u2014'))),
              const SizedBox(width: 16),
              SizedBox(width: 300, child: _labeled('Customer (optional)', _isDraft
                ? _SearchField(key: ValueKey('cust_${_current?['id'] ?? 'new'}_$_customerId'), initialLabel: _customerLabel, hint: 'Search customer...', filterFn: _filterCustomers, onPick: (c) => setState(() { _customerId = c['id'] as String?; _customerLabel = c['label'] as String? ?? ''; }), onClear: () => setState(() { _customerId = null; _customerLabel = ''; }))
                : _readonlyBox(_customerLabel.isEmpty ? 'No customer' : _customerLabel))),
              const SizedBox(width: 16),
              SizedBox(width: 150, child: _labeled('Date', _dateField())),
            ]),
            const SizedBox(height: 12),
            _labeled('Notes', TextField(controller: _notesCtrl, enabled: _isDraft, minLines: 1, maxLines: 2,
              decoration: const InputDecoration(hintText: 'Optional', isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)))),
            const SizedBox(height: 20),
            _linesSection(),
            const SizedBox(height: 30),
          ]))),
      ])),
    ]);
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

  Widget _reasonField(int i) {
    final l = _lines[i];
    final items = <Map<String, dynamic>>[..._activeReasons];
    if (l.reasonId != null && !items.any((r) => r['id'] == l.reasonId)) {
      final cur = _reasons.firstWhere((r) => r['id'] == l.reasonId, orElse: () => {});
      if (cur.isNotEmpty) items.insert(0, cur);
    }
    final value = (l.reasonId != null && items.any((r) => r['id'] == l.reasonId)) ? l.reasonId : null;
    return DropdownButtonFormField<String>(
      value: value, isDense: true, isExpanded: true,
      hint: const Text('Select reason', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
      style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
      items: [
        ...items.map((r) => DropdownMenuItem(value: r['id'] as String, child: Text(r['name'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
        const DropdownMenuItem(value: '__add__', child: Text('+ Add reason\u2026', style: TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600))),
      ],
      onChanged: (v) async {
        if (v == '__add__') { final id = await _showAddReasonDialog(); if (id != null) setState(() => _lines[i].reasonId = id); }
        else setState(() => _lines[i].reasonId = v);
      });
  }

  Widget _linesSection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: const [
            Text('Defective Items', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            SizedBox(width: 10),
            Expanded(child: Text('Record each defective product returned, why, and any detail.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: const [
            SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            Expanded(flex: 3, child: Text('Product', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 10),
            SizedBox(width: 70, child: Text('Qty', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 10),
            Expanded(flex: 2, child: Text('Reason', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 10),
            Expanded(flex: 3, child: Text('Remarks', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 30),
          ])),
        for (var i = 0; i < _lines.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 26, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
              Expanded(flex: 3, child: _isDraft
                ? _SearchField(key: ValueKey(_lines[i].id), initialLabel: _lines[i].productLabel, hint: 'Search product...', filterFn: _filterProducts, onPick: (p) => setState(() { _lines[i].productId = p['id'] as String?; _lines[i].productLabel = p['label'] as String? ?? ''; }))
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_lines[i].productLabel, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
              const SizedBox(width: 10),
              SizedBox(width: 70, child: _isDraft
                ? TextField(controller: _lines[i].qtyCtrl, textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(hintText: '0', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
                    style: const TextStyle(fontSize: 12), onChanged: (_) => setState(() {}))
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_trim(_lines[i].qty), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: _isDraft
                ? _reasonField(i)
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_reasonName[_lines[i].reasonId] ?? '\u2014', style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 10),
              Expanded(flex: 3, child: _isDraft
                ? TextField(controller: _lines[i].remarksCtrl,
                    decoration: const InputDecoration(hintText: 'Optional', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
                    style: const TextStyle(fontSize: 12))
                : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_lines[i].remarksCtrl.text.isEmpty ? '\u2014' : _lines[i].remarksCtrl.text, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)))),
              SizedBox(width: 30, child: _isDraft ? IconButton(icon: const Icon(Icons.close, size: 14, color: Colors.red), onPressed: () => _removeLine(i), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact) : const SizedBox()),
            ])),
        if (_isDraft) Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('Add item', style: TextStyle(fontSize: 12)), onPressed: _addLine))),
      ]),
    );
  }

  // ---------- insights view ----------
  Widget _insightsView() {
    return Column(children: [
      Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          const Text('Claim Insights', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const Spacer(),
          _dateBtn('From', _insFrom, (d) { setState(() => _insFrom = d); _loadInsights(); }),
          const SizedBox(width: 6),
          _dateBtn('To', _insTo, (d) { setState(() => _insTo = d); _loadInsights(); }),
          if (_insFrom != null || _insTo != null) ...[
            const SizedBox(width: 4),
            IconButton(icon: const Icon(Icons.clear, size: 16), tooltip: 'Clear dates', onPressed: () { setState(() { _insFrom = null; _insTo = null; }); _loadInsights(); }),
          ],
          const SizedBox(width: 6),
          OutlinedButton.icon(icon: const Icon(Icons.refresh, size: 15), label: const Text('Refresh', style: TextStyle(fontSize: 12)), onPressed: _loadInsights),
        ])),
      Expanded(child: _insLoading
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _sumCard('Claims', _insClaims.toString(), AppTheme.primary),
            const SizedBox(width: 12),
            _sumCard('Defective qty', _trim(_insQty), Colors.red.shade600),
            const SizedBox(width: 12),
            _sumCard('Products affected', _insProducts.toString(), Colors.teal),
            const SizedBox(width: 12),
            _sumCard('Customers', _insCustomers.toString(), Colors.indigo),
          ]),
          const SizedBox(height: 22),
          _insSection('By reason', _insByReason),
          const SizedBox(height: 22),
          _insSection('Top products', _insByProduct),
          const SizedBox(height: 22),
          _insSection('By customer', _insByCustomer),
          const SizedBox(height: 30),
        ]))),
    ]);
  }

  Widget _dateBtn(String label, DateTime? value, void Function(DateTime) onPick) => OutlinedButton.icon(
    icon: const Icon(Icons.date_range, size: 15),
    label: Text(value != null ? DateFormat('d MMM yyyy').format(value) : label, style: const TextStyle(fontSize: 12)),
    onPressed: () async {
      final d = await showDatePicker(context: context, initialDate: value ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
      if (d != null) onPick(d);
    });

  Widget _sumCard(String label, String value, Color color) => Expanded(child: Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
    ])));

  Widget _insSection(String title, List<Map<String, dynamic>> rows) {
    final maxQty = rows.fold<double>(0, (m, r) => (r['qty'] as double) > m ? r['qty'] as double : m);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: rows.isEmpty
          ? const Padding(padding: EdgeInsets.all(16), child: Text('No data for this range.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
          : Column(children: [
              for (var i = 0; i < rows.length; i++)
                Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(border: i == rows.length - 1 ? null : Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.5)))),
                  child: Row(children: [
                    SizedBox(width: 240, child: Text(rows[i]['label'] as String? ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 12),
                    Expanded(child: Container(height: 8, decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(4)),
                      child: FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: maxQty > 0 ? ((rows[i]['qty'] as double) / maxQty).clamp(0.02, 1.0) : 0.0,
                        child: Container(decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(4)))))),
                    const SizedBox(width: 12),
                    SizedBox(width: 60, child: Text(_trim(rows[i]['qty'] as double), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                    SizedBox(width: 78, child: Text('${rows[i]['claims']} claim(s)', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                  ])),
            ]),
      ),
    ]);
  }
}

class _SearchField extends StatefulWidget {
  final String initialLabel;
  final String hint;
  final List<Map<String, dynamic>> Function(String) filterFn;
  final void Function(Map<String, dynamic>) onPick;
  final VoidCallback? onClear;
  const _SearchField({super.key, required this.initialLabel, required this.filterFn, required this.onPick, this.hint = 'Search...', this.onClear});
  @override State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
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
        decoration: InputDecoration(hintText: widget.hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          border: OutlineInputBorder(borderSide: BorderSide(color: _picked ? Colors.green : const Color(0xFFE0E0E0))),
          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _picked ? Colors.green : const Color(0xFFE0E0E0))),
          suffixIcon: _picked
            ? GestureDetector(onTap: () { _ctrl.clear(); setState(() { _picked = false; _q = ''; }); widget.onClear?.call(); }, child: const Icon(Icons.close, size: 14, color: AppTheme.textSecondary))
            : null),
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
