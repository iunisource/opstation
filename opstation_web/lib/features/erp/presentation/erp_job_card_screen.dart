import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';

class _JobMat {
  static int _seq = 0;
  final String id = 'jm_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? productId; String productLabel = '';
  final TextEditingController qtyCtrl = TextEditingController();
  double unitCostSnap = 0; double lineCostSnap = 0; // populated for posted jobs
  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() { qtyCtrl.dispose(); }
}

class _JobOh {
  static int _seq = 0;
  final String id = 'jo_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String costType;
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController amountCtrl = TextEditingController();
  _JobOh({this.costType = 'overhead'});
  double get amount => double.tryParse(amountCtrl.text) ?? 0;
  void dispose() { descCtrl.dispose(); amountCtrl.dispose(); }
}

class ErpJobCardScreen extends ConsumerStatefulWidget {
  const ErpJobCardScreen({super.key});
  @override
  ConsumerState<ErpJobCardScreen> createState() => _State();
}

class _State extends ConsumerState<ErpJobCardScreen> {
  // products
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};
  Map<String, double> _prodCost = {};
  bool _loadingProducts = true;

  // boms + users
  List<Map<String, dynamic>> _boms = [];
  List<Map<String, dynamic>> _users = [];

  // job list
  List<Map<String, dynamic>> _jobs = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  // current form
  Map<String, dynamic>? _current;
  DateTime _date = DateTime.now();
  String? _bomId; String _bomLabel = '';
  String? _fgId; String _fgLabel = '';
  double _bomBaseQty = 1;
  final _plannedQtyCtrl = TextEditingController(text: '1');
  final _wcCtrl = TextEditingController();
  String? _assignedTo;
  final _notesCtrl = TextEditingController();
  String _status = 'open';
  List<_JobMat> _materials = [];
  List<_JobOh> _overheads = [];
  List<Map<String, dynamic>> _baseComps = [];
  List<Map<String, dynamic>> _baseOh = [];

  // QC
  final _producedCtrl = TextEditingController();
  final _rejectedCtrl = TextEditingController(text: '0');

  bool _saving = false;
  bool _posting = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isOpen => _status == 'open' || _status == 'in_progress';
  bool get _isDone => _status == 'completed';
  double get _plannedQty => double.tryParse(_plannedQtyCtrl.text) ?? 0;
  double get _producedQty => double.tryParse(_producedCtrl.text) ?? 0;
  double get _rejectedQty => double.tryParse(_rejectedCtrl.text) ?? 0;
  double get _acceptedQty => (_producedQty - _rejectedQty).clamp(0, double.infinity);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProducts(); _loadBoms(); _loadUsers(); _loadJobs();
    });
  }

  @override
  void dispose() {
    _plannedQtyCtrl.dispose(); _wcCtrl.dispose(); _notesCtrl.dispose();
    _producedCtrl.dispose(); _rejectedCtrl.dispose();
    for (final l in _materials) l.dispose();
    for (final l in _overheads) l.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }
  static String _trim(double v) { if (v == v.roundToDouble()) return v.toStringAsFixed(0); return v.toString(); }
  static String _money(num v) => NumberFormat('#,##0.00').format(v);

  // ---------- loaders ----------
  Future<void> _loadProducts() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadProducts(); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client.from('products')
            .select('id, name, sku, cost_price')
            .eq('org_id', orgId).eq('is_active', true)
            .order('name').range(from, from + page - 1);
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

  Future<void> _loadBoms() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('bom_headers')
          .select().eq('org_id', orgId).eq('status', 'active').order('code').limit(500);
      if (mounted) setState(() => _boms = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _loadUsers() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('users')
          .select('id, name').eq('org_id', orgId).order('name').limit(500);
      if (mounted) setState(() => _users = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  List<Map<String, dynamic>> _filterBoms(String q) {
    final ql = q.toLowerCase();
    final list = _boms.where((b) {
      if (ql.isEmpty) return true;
      final code = (b['code'] as String? ?? '').toLowerCase();
      final name = (b['name'] as String? ?? '').toLowerCase();
      final pn = (_prodLabel[b['product_id']] ?? '').toLowerCase();
      return code.contains(ql) || name.contains(ql) || pn.contains(ql);
    }).take(200).toList();
    return list.map((b) => {
      'id': b['id'],
      'label': "${b['code'] ?? ''} — ${_prodLabel[b['product_id']] ?? (b['name'] ?? '')}",
    }).toList();
  }

  Future<void> _loadJobs() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      final rows = await Supabase.instance.client.from('job_cards')
          .select().eq('org_id', orgId).order('created_at', ascending: false).limit(300);
      if (mounted) setState(() { _jobs = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  // ---------- form state ----------
  void _newJob() {
    for (final l in _materials) l.dispose();
    for (final l in _overheads) l.dispose();
    setState(() {
      _current = null; _status = 'open';
      _date = DateTime.now();
      _bomId = null; _bomLabel = ''; _fgId = null; _fgLabel = ''; _bomBaseQty = 1;
      _plannedQtyCtrl.text = '1'; _wcCtrl.clear(); _assignedTo = null; _notesCtrl.clear();
      _producedCtrl.clear(); _rejectedCtrl.text = '0';
      _materials = []; _overheads = []; _baseComps = []; _baseOh = [];
    });
  }

  Future<void> _loadJob(Map<String, dynamic> j) async {
    try {
      final client = Supabase.instance.client;
      final mats = await client.from('job_card_materials').select().eq('job_card_id', j['id'] as String).order('line_order');
      final ohs = await client.from('job_card_overheads').select().eq('job_card_id', j['id'] as String).order('line_order');
      for (final l in _materials) l.dispose();
      for (final l in _overheads) l.dispose();
      final newMats = (mats as List).map((r) {
        final l = _JobMat();
        l.productId = r['product_id'] as String?;
        l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
        final q = (r['issued_qty'] as num? ?? r['planned_qty'] as num? ?? 0).toDouble();
        if (q != 0) l.qtyCtrl.text = _trim(q);
        l.unitCostSnap = (r['unit_cost'] as num? ?? 0).toDouble();
        l.lineCostSnap = (r['line_cost'] as num? ?? 0).toDouble();
        return l;
      }).toList();
      final newOh = (ohs as List).map((r) {
        final l = _JobOh(costType: (r['cost_type'] as String?) ?? 'overhead');
        l.descCtrl.text = (r['description'] as String?) ?? '';
        final a = (r['amount'] as num? ?? 0).toDouble();
        if (a != 0) l.amountCtrl.text = _trim(a);
        return l;
      }).toList();
      if (mounted) setState(() {
        _current = j;
        _status = j['status'] as String? ?? 'open';
        final ds = j['voucher_date'] as String?;
        _date = ds != null ? DateTime.tryParse(ds) ?? DateTime.now() : DateTime.now();
        _bomId = j['bom_id'] as String?;
        _fgId = j['product_id'] as String?;
        _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
        _bomLabel = _bomId != null ? (_boms.firstWhere((b) => b['id'] == _bomId, orElse: () => {})['code'] as String? ?? '') : '';
        _plannedQtyCtrl.text = _trim((j['planned_qty'] as num? ?? 1).toDouble());
        _wcCtrl.text = j['work_center'] as String? ?? '';
        _assignedTo = j['assigned_to'] as String?;
        _notesCtrl.text = j['notes'] as String? ?? '';
        _producedCtrl.text = _trim((j['produced_qty'] as num? ?? (j['planned_qty'] as num? ?? 0)).toDouble());
        _rejectedCtrl.text = _trim((j['rejected_qty'] as num? ?? 0).toDouble());
        _materials = newMats; _overheads = newOh;
      });
    } catch (e) { _snack('Load error: $e'); }
  }

  void _pickBom(String bomId) {
    final bom = _boms.firstWhere((b) => b['id'] == bomId, orElse: () => {});
    if (bom.isEmpty) return;
    setState(() {
      _bomId = bomId;
      _fgId = bom['product_id'] as String?;
      _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
      _bomBaseQty = (bom['output_qty'] as num? ?? 1).toDouble();
      if (_bomBaseQty <= 0) _bomBaseQty = 1;
    });
    _loadBomBase();
  }

  Future<void> _loadBomBase() async {
    if (_bomId == null) return;
    try {
      final client = Supabase.instance.client;
      final comps = await client.from('bom_components').select().eq('bom_id', _bomId!).order('line_order');
      final ohs = await client.from('bom_overheads').select().eq('bom_id', _bomId!).order('line_order');
      _baseComps = List<Map<String, dynamic>>.from(comps as List);
      _baseOh = List<Map<String, dynamic>>.from(ohs as List);
      _rescale();
    } catch (e) { _snack('BOM load error: $e'); }
  }

  void _rescale() {
    final scale = _bomBaseQty > 0 ? (_plannedQty / _bomBaseQty) : 1;
    for (final l in _materials) l.dispose();
    for (final l in _overheads) l.dispose();
    final nm = _baseComps.map((b) {
      final l = _JobMat();
      l.productId = b['product_id'] as String?;
      l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
      final q = (b['quantity'] as num? ?? 0).toDouble() * scale;
      if (q != 0) l.qtyCtrl.text = _trim(double.parse(q.toStringAsFixed(4)));
      return l;
    }).toList();
    final no = _baseOh.map((b) {
      final l = _JobOh(costType: (b['cost_type'] as String?) ?? 'overhead');
      l.descCtrl.text = (b['description'] as String?) ?? '';
      final a = (b['amount'] as num? ?? 0).toDouble() * scale;
      if (a != 0) l.amountCtrl.text = _trim(double.parse(a.toStringAsFixed(2)));
      return l;
    }).toList();
    if (mounted) setState(() { _materials = nm; _overheads = no; });
  }

  // ---------- cost preview ----------
  double get _estMatCost => _materials.fold(0.0, (s, l) => s + l.qty * (_prodCost[l.productId] ?? 0));
  double get _ohTotal => _overheads.fold(0.0, (s, l) => s + l.amount);
  double get _estTotal => _estMatCost + _ohTotal;
  double get _estUnit => _plannedQty > 0 ? _estTotal / _plannedQty : 0;

  // ---------- save / post / void / delete ----------
  Future<String?> _save({bool silent = false}) async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return null; }
    if (!_isOpen) { _snack('Completed jobs cannot be edited'); return _current?['id'] as String?; }
    if (_branchId == null) { _snack('No branch selected — pick one in the sidebar'); return null; }
    if (_fgId == null) { _snack('Pick a BOM (sets the finished product)'); return null; }
    if (_plannedQty <= 0) { _snack('Planned quantity must be greater than 0'); return null; }
    final mats = _materials.where((l) => l.productId != null && l.qty > 0).toList();
    final ohs = _overheads.where((l) => l.amount != 0 || l.descCtrl.text.trim().isNotEmpty).toList();
    if (mats.isEmpty && ohs.isEmpty) { _snack('Add at least one material or overhead line'); return null; }
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    String? resultId;
    try {
      final client = Supabase.instance.client;
      String jId, num;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      if (_current == null) {
        final cnt = await client.from('job_cards').select('id').eq('org_id', orgId);
        num = 'JOB-${_date.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        jId = 'job_' + DateTime.now().millisecondsSinceEpoch.toString();
        await client.from('job_cards').insert({
          'id': jId, 'org_id': orgId, 'branch_id': _branchId, 'job_number': num,
          'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId, 'planned_qty': _plannedQty,
          'status': _status == 'in_progress' ? 'in_progress' : 'open', 'is_locked': false,
          'work_center': _wcCtrl.text.trim(), 'assigned_to': _assignedTo, 'notes': _notesCtrl.text.trim(),
          'created_by': userId, 'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        jId = _current!['id'] as String; num = _current!['job_number'] as String? ?? '';
        await client.from('job_cards').update({
          'branch_id': _branchId, 'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId,
          'planned_qty': _plannedQty, 'work_center': _wcCtrl.text.trim(), 'assigned_to': _assignedTo,
          'notes': _notesCtrl.text.trim(), 'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', jId);
      }
      await client.from('job_card_materials').delete().eq('job_card_id', jId);
      for (var i = 0; i < mats.length; i++) {
        await client.from('job_card_materials').insert({
          'id': jId + '_m' + i.toString(), 'job_card_id': jId,
          'product_id': mats[i].productId, 'planned_qty': mats[i].qty, 'issued_qty': mats[i].qty, 'line_order': i,
        });
      }
      await client.from('job_card_overheads').delete().eq('job_card_id', jId);
      for (var i = 0; i < ohs.length; i++) {
        await client.from('job_card_overheads').insert({
          'id': jId + '_o' + i.toString(), 'job_card_id': jId,
          'cost_type': ohs[i].costType, 'description': ohs[i].descCtrl.text.trim(),
          'amount': ohs[i].amount, 'line_order': i,
        });
      }
      resultId = jId;
      final updated = await client.from('job_cards').select().eq('id', jId).single();
      if (mounted) setState(() => _current = updated);
      if (!silent) _snack('Job card $num saved');
      await _loadJobs();
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
    return resultId;
  }

  Future<void> _start() async {
    setState(() => _status = 'in_progress');
    final id = await _save(silent: true);
    if (id != null) { await Supabase.instance.client.from('job_cards').update({'status': 'in_progress'}).eq('id', id); _snack('Job started'); await _loadJobs(); }
  }

  Future<void> _completeAndPost() async {
    if (!_isOpen) return;
    if (_producedQty <= 0) { _snack('Enter produced quantity (final QC)'); return; }
    if (_rejectedQty < 0 || _rejectedQty > _producedQty) { _snack('Rejected qty must be between 0 and produced qty'); return; }
    final id = await _save(silent: true);
    if (id == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Complete & post job?'),
      content: Text('Materials will be consumed from stock (FIFO) and ${_trim(_producedQty)} finished unit(s) produced. '
          '${_rejectedQty > 0 ? '${_trim(_rejectedQty)} rejected unit(s) will be scrapped, leaving ${_trim(_acceptedQty)} in stock. ' : ''}'
          'This posts to the General Ledger and locks the job (use Void to reverse).'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Complete & Post')),
      ],
    ));
    if (ok != true) return;
    setState(() => _posting = true);
    try {
      final client = Supabase.instance.client;
      final orgId = _orgId!; final userId = ref.read(currentUserProvider)?.id ?? '';
      final disp = _rejectedQty == 0 ? 'accept' : (_acceptedQty == 0 ? 'reject' : 'partial');
      // record QC inspection
      final cnt = await client.from('qc_inspections').select('id').eq('org_id', orgId);
      final qcNum = 'QC-${_date.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
      await client.from('qc_inspections').insert({
        'id': 'qc_' + DateTime.now().millisecondsSinceEpoch.toString(), 'org_id': orgId, 'branch_id': _branchId,
        'qc_number': qcNum, 'source_type': 'job_card', 'source_id': id, 'product_id': _fgId,
        'inspected_qty': _producedQty, 'accepted_qty': _acceptedQty, 'rejected_qty': _rejectedQty,
        'disposition': disp, 'inspector_id': userId, 'inspected_at': DateTime.now().toIso8601String(),
      });
      // write QC result + flip to completed -> autopost trigger posts the job
      await client.from('job_cards').update({
        'produced_qty': _producedQty, 'rejected_qty': _rejectedQty, 'accepted_qty': _acceptedQty,
        'status': 'completed', 'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', id);
      final updated = await client.from('job_cards').select().eq('id', id).single();
      if (mounted) setState(() { _current = updated; _status = updated['status'] as String? ?? 'completed'; });
      _snack('Job posted — accepted ${_trim((updated['accepted_qty'] as num? ?? 0).toDouble())}, scrap value ${_money((updated['scrap_value'] as num? ?? 0).toDouble())}');
      await _loadJobs();
      await _loadJob(updated);
    } catch (e) { _snack('Post failed: ' + e.toString()); }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _void() async {
    if (!_isDone || _current == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Void job?'),
      content: const Text('This reverses the job: materials are returned to stock, the finished goods and any scrap are removed, and the GL entries are reversed.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Void')),
      ],
    ));
    if (ok != true) return;
    setState(() => _posting = true);
    try {
      final client = Supabase.instance.client;
      final userId = ref.read(currentUserProvider)?.id;
      final res = await client.rpc('void_voucher', params: {
        'p_org': _orgId, 'p_ref_id': _current!['id'], 'p_void_date': DateFormat('yyyy-MM-dd').format(DateTime.now()), 'p_user': userId,
      });
      await client.from('job_cards').update({'status': 'cancelled', 'is_locked': false, 'updated_at': DateTime.now().toIso8601String()}).eq('id', _current!['id'] as String);
      _snack(res?.toString() ?? 'Job voided');
      await _loadJobs();
      final updated = await client.from('job_cards').select().eq('id', _current!['id'] as String).single();
      await _loadJob(updated);
    } catch (e) { _snack('Void failed: ' + e.toString()); }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _delete() async {
    if (_current == null) return;
    if (!_isOpen) { _snack('Only open jobs can be deleted — use Void for posted jobs'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete job card?'),
      content: const Text('This open job card will be permanently deleted.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('job_cards').delete().eq('id', _current!['id'] as String);
      _snack('Job card deleted');
      _newJob();
      await _loadJobs();
    } catch (e) { _snack('Delete failed: $e'); }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked != null) setState(() => _date = picked);
  }

  // ---------- UI ----------
  Widget _labeled(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
    const SizedBox(height: 5), child,
  ]);
  Widget _readonlyBox(String text) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
    decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
    child: Text(text, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis));
  Widget _dateField() => InkWell(onTap: _isOpen ? _pickDate : null, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
    child: Row(children: [const Icon(Icons.event, size: 15, color: AppTheme.textSecondary), const SizedBox(width: 8), Text(DateFormat('d MMM yyyy').format(_date), style: const TextStyle(fontSize: 13))])));

  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _jobs : _jobs.where((j) {
      final q = _listSearch.toLowerCase();
      final pn = (_prodLabel[j['product_id']] ?? '').toLowerCase();
      return (j['job_number'] as String? ?? '').toLowerCase().contains(q) || pn.contains(q);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 300,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Job Cards', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: _newJob),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No job cards yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final j = filtered[i]; final sel = _current?['id'] == j['id'];
                final st = (j['status'] as String? ?? 'open');
                final isDone = st == 'completed'; final isCancel = st == 'cancelled';
                final c = isDone ? Colors.green : isCancel ? Colors.grey : Colors.orange;
                final lbl = isDone ? 'Completed' : isCancel ? 'Voided' : (st == 'in_progress' ? 'In progress' : 'Open');
                return InkWell(onTap: () => _loadJob(j), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(j['job_number'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: c.withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                        child: Text(lbl, style: TextStyle(fontSize: 9, color: c, fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: 2),
                    Text(_prodLabel[j['product_id']] ?? '', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    Text('${j['voucher_date'] ?? ''}  ·  plan ${_trim((j['planned_qty'] as num? ?? 0).toDouble())}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
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
            Expanded(child: Text(_current?['job_number'] as String? ?? 'New Job Card', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            if (_isDone) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.green.withOpacity(0.13), borderRadius: BorderRadius.circular(4)),
              child: Text('Completed', style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w700))),
            if (_status == 'cancelled') Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.grey.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
              child: const Text('Voided', style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w700))),
            if (_isOpen && _current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete'),
            const SizedBox(width: 8),
            if (_isOpen) OutlinedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save'),
              onPressed: _saving || _posting ? null : () => _save()),
            const SizedBox(width: 8),
            if (_isOpen) ElevatedButton.icon(
              icon: _posting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Complete & Post'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
              onPressed: _saving || _posting ? null : _completeAndPost),
            if (_isDone) OutlinedButton.icon(
              icon: _posting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.undo, size: 16),
              label: const Text('Void'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              onPressed: _posting ? null : _void),
          ])),
        Expanded(child: _loadingProducts
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading...', style: TextStyle(color: AppTheme.textSecondary))]))
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 200, child: _labeled('Branch', _readonlyBox((ref.watch(selectedBranchProvider)?['name'] as String?) ?? '—'))),
              const SizedBox(width: 14),
              SizedBox(width: 150, child: _labeled('Date', _dateField())),
              const SizedBox(width: 14),
              Expanded(child: _labeled('Bill of Materials *', _isOpen
                ? _ProductField(key: ValueKey('bom_${_current?['id'] ?? 'new'}_$_bomId'), initialLabel: _bomLabel.isEmpty ? '' : (_bomLabel + (_fgLabel.isNotEmpty ? ' — $_fgLabel' : '')), filterFn: _filterBoms, onPick: (b) => _pickBom(b['id'] as String))
                : _readonlyBox(_bomLabel.isEmpty ? '—' : '$_bomLabel — $_fgLabel'))),
            ]),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 150, child: _labeled('Planned Qty *', TextField(
                controller: _plannedQtyCtrl, enabled: _isOpen, keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11)),
                onChanged: (_) { if (_bomId != null) _rescale(); }))),
              const SizedBox(width: 14),
              SizedBox(width: 200, child: _labeled('Work Center', TextField(
                controller: _wcCtrl, enabled: _isOpen,
                decoration: const InputDecoration(isDense: true, hintText: 'e.g. Line A', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11))))),
              const SizedBox(width: 14),
              SizedBox(width: 230, child: _labeled('Assigned To', DropdownButtonFormField<String?>(
                value: _assignedTo, isExpanded: true,
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                items: [const DropdownMenuItem<String?>(value: null, child: Text('—')),
                  ..._users.map((u) => DropdownMenuItem<String?>(value: u['id'] as String, child: Text(u['name'] as String? ?? '-', overflow: TextOverflow.ellipsis)))],
                onChanged: _isOpen ? (v) => setState(() => _assignedTo = v) : null))),
            ]),
            const SizedBox(height: 16),
            _costCard(),
            const SizedBox(height: 16),
            _matSection(),
            const SizedBox(height: 16),
            _ohSection(),
            const SizedBox(height: 16),
            _qcCard(),
          ]))),
      ])),
    ]));
  }

  Widget _costCard() {
    final posted = _isDone;
    final matCost = posted ? _materials.fold(0.0, (s, l) => s + l.lineCostSnap) : _estMatCost;
    final total = matCost + _ohTotal;
    final baseQty = posted ? ((_current?['produced_qty'] as num? ?? _plannedQty).toDouble()) : _plannedQty;
    final unit = baseQty > 0 ? total / baseQty : 0.0;
    return Container(padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(posted ? 'Actual cost (posted)' : 'Estimated cost', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _costCell('Materials', matCost.toDouble(), AppTheme.primary),
          _costCell('Labor & Overhead', _ohTotal, Colors.teal),
          _costCell('Total', total.toDouble(), AppTheme.textPrimary, bold: true),
          _costCell('Unit cost', unit.toDouble(), Colors.deepPurple, bold: true, decimals: 4),
        ]),
      ]));
  }

  Widget _costCell(String label, double v, Color c, {bool bold = false, int decimals = 2}) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
    const SizedBox(height: 3),
    Text(decimals == 4 ? NumberFormat('#,##0.0000').format(v) : _money(v), style: TextStyle(fontSize: bold ? 16 : 14, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: c)),
  ]));

  Widget _matSection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            Container(width: 6, height: 14, decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            const Text('Materials (consumed)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            const Expanded(child: Text('From the BOM, scaled to Planned Qty.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        if (_materials.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Text('Pick a BOM to load materials.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        for (var i = 0; i < _materials.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              SizedBox(width: 26, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
              Expanded(child: Text(_materials[i].productLabel, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 12),
              SizedBox(width: 110, child: _isOpen
                ? TextField(controller: _materials[i].qtyCtrl, keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    textAlign: TextAlign.right, style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                    onChanged: (_) => setState(() {}))
                : Text(_trim(_materials[i].qty), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
              const SizedBox(width: 12),
              SizedBox(width: 120, child: Text(
                _isDone ? _money(_materials[i].lineCostSnap) : _money(_materials[i].qty * (_prodCost[_materials[i].productId] ?? 0)),
                textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            ])),
      ]),
    );
  }

  Widget _ohSection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            Container(width: 6, height: 14, decoration: BoxDecoration(color: Colors.teal, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            const Text('Labor & Overhead (absorbed)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(child: Text('Total ${_money(_ohTotal)} — added to finished-goods cost.', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        for (var i = 0; i < _overheads.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              SizedBox(width: 26, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
              SizedBox(width: 110, child: Text(_overheads[i].costType == 'labor' ? 'Labor' : 'Overhead', style: const TextStyle(fontSize: 12))),
              const SizedBox(width: 12),
              Expanded(child: _isOpen
                ? TextField(controller: _overheads[i].descCtrl, style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(isDense: true, hintText: 'Description', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)))
                : Text(_overheads[i].descCtrl.text, style: const TextStyle(fontSize: 12))),
              const SizedBox(width: 12),
              SizedBox(width: 120, child: _isOpen
                ? TextField(controller: _overheads[i].amountCtrl, keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    textAlign: TextAlign.right, style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                    onChanged: (_) => setState(() {}))
                : Text(_money(_overheads[i].amount), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            ])),
        if (_overheads.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No labor/overhead lines.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
      ]),
    );
  }

  Widget _qcCard() {
    return Container(padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 6, height: 14, decoration: BoxDecoration(color: Colors.indigo, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          const Text('Final QC', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          const Expanded(child: Text('Produced minus rejected = accepted into stock. Rejected units are scrapped.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SizedBox(width: 150, child: _labeled('Produced Qty', TextField(
            controller: _producedCtrl, enabled: _isOpen, keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(isDense: true, hintText: 'e.g. 100', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11)),
            onChanged: (_) => setState(() {})))),
          const SizedBox(width: 14),
          SizedBox(width: 150, child: _labeled('Rejected Qty', TextField(
            controller: _rejectedCtrl, enabled: _isOpen, keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11)),
            onChanged: (_) => setState(() {})))),
          const SizedBox(width: 14),
          SizedBox(width: 150, child: _labeled('Accepted (to stock)', _readonlyBox(_trim(_acceptedQty)))),
          if (_isDone) ...[
            const SizedBox(width: 14),
            SizedBox(width: 150, child: _labeled('Scrap value', _readonlyBox(_money((_current?['scrap_value'] as num? ?? 0).toDouble())))),
          ],
        ]),
      ]));
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
