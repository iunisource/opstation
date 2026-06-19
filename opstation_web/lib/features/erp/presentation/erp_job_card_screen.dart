import 'package:flutter/material.dart';
import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';
import 'package:go_router/go_router.dart';
import 'running_dot.dart';

class _JobMat {
  static int _seq = 0;
  final String id = 'jm_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? productId; String productLabel = '';
  final TextEditingController qtyCtrl = TextEditingController();
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
  List<Map<String, dynamic>> _products = [];
  Map<String, String> _prodLabel = {};
  Map<String, double> _prodCost = {};
  bool _loadingProducts = true;

  List<Map<String, dynamic>> _customers = [];
  Map<String, String> _custLabel = {};

  List<Map<String, dynamic>> _boms = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _checkpoints = [];

  List<Map<String, dynamic>> _jobs = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  Map<String, dynamic>? _current;
  List<Map<String, dynamic>> _runs = [];
  List<Map<String, dynamic>> _auditTrail = [];
  int _auditSeq = 0;
  String _origMatSig = '';
  String _origOhSig = '';
  DateTime _date = DateTime.now();
  String? _bomId; String _bomLabel = '';
  String? _fgId; String _fgLabel = '';
  double _bomBaseQty = 1;
  final _plannedQtyCtrl = TextEditingController(text: '1');
  final _priorityCtrl = TextEditingController(text: '0');
  final _wcCtrl = TextEditingController();
  String? _assignedTo;
  List<Map<String, dynamic>> _workCenters = [];
  List<Map<String, dynamic>> _workers = [];
  String? _assignedWorkerId;
  String? _customerId; String _customerLabel = '';
  final _notesCtrl = TextEditingController();
  String _status = 'queued';
  List<_JobMat> _materials = [];
  List<_JobOh> _overheads = [];
  List<Map<String, dynamic>> _baseComps = [];
  List<Map<String, dynamic>> _baseOh = [];
  bool _saving = false;
  bool _busy = false;
  RealtimeChannel? _channel;
  Timer? _rtDebounce;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _editable => _status == 'queued' || _status == 'in_progress';
  double get _plannedQty => double.tryParse(_plannedQtyCtrl.text) ?? 0;
  double get _producedQty => (_current?['produced_qty'] as num? ?? 0).toDouble();
  double get _remainingQty => (_plannedQty - _producedQty);
  double get _componentsCost => _materials.fold(0.0, (s, l) => s + l.qty * (_prodCost[l.productId] ?? 0));
  double get _laborOhCost => _overheads.fold(0.0, (s, l) => s + l.amount);
  double get _totalCost => _componentsCost + _laborOhCost;
  double get _unitCost => _plannedQty > 0 ? _totalCost / _plannedQty : 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _pendingJobId = _jobIdFromUrl();
      _loadUsers(); _loadWorkCenters(); _loadWorkers(); _loadCustomers(); _loadCheckpoints();
      await Future.wait([_loadProducts(), _loadBoms()]);
      await _loadJobs();
      if (_pendingJobId != null && mounted) {
        final m = _jobs.where((j) => j['id'] == _pendingJobId).toList();
        if (m.isNotEmpty) {
          _loadJob(m.first);
        } else {
          try {
            final row = await Supabase.instance.client.from('job_cards').select().eq('id', _pendingJobId!).maybeSingle();
            if (row != null && mounted) _loadJob(Map<String, dynamic>.from(row as Map));
          } catch (_) {}
        }
        _pendingJobId = null;
      }
    });
  }

  String? _pendingJobId;
  String? _jobIdFromUrl() {
    try {
      final id = GoRouterState.of(context).uri.queryParameters['id'];
      if (id != null && id.isNotEmpty) return id;
    } catch (_) {}
    final href = html.window.location.href;
    final qIdx = href.lastIndexOf('?');
    if (qIdx == -1) return null;
    return Uri.splitQueryString(href.substring(qIdx + 1))['id'];
  }

  @override
  void dispose() {
    _rtDebounce?.cancel();
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    _plannedQtyCtrl.dispose(); _priorityCtrl.dispose(); _wcCtrl.dispose(); _notesCtrl.dispose();
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
            .select('id, name, sku, cost_price').eq('org_id', orgId).eq('is_active', true)
            .order('name').range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        all.addAll(list);
        if (list.length < page) break;
        from += page; if (from > 100000) break;
      }
      final items = all.map((p) => {'id': p['id'], 'label': "${p['sku'] != null && (p['sku'] as String).isNotEmpty ? '${p['sku']} — ' : ''}${p['name'] ?? ''}"}).toList();
      if (mounted) setState(() {
        _products = items;
        _prodLabel = {for (final p in items) p['id'] as String: p['label'] as String};
        _prodCost = {for (final p in all) p['id'] as String: (p['cost_price'] as num? ?? 0).toDouble()};
        _loadingProducts = false;
      });
    } catch (e) { if (mounted) { _snack('Products load error: $e'); setState(() => _loadingProducts = false); } }
  }

  Future<void> _loadBoms() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('bom_headers').select().eq('org_id', orgId).eq('status', 'active').order('code').limit(500);
      if (mounted) setState(() => _boms = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _loadUsers() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('users').select('id, name').eq('org_id', orgId).order('name').limit(500);
      if (mounted) setState(() => _users = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _loadWorkCenters() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('work_centers').select().eq('org_id', orgId).order('name').limit(500);
      if (mounted) setState(() => _workCenters = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _loadWorkers() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('workers').select().eq('org_id', orgId).order('name').limit(500);
      if (mounted) setState(() => _workers = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _loadCustomers() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('customers').select('id, shop_name, code').eq('org_id', orgId).order('shop_name').limit(5000);
      final list = List<Map<String, dynamic>>.from(rows);
      if (mounted) setState(() {
        _customers = list;
        _custLabel = {for (final c in list) c['id'] as String:
          "${(c['code'] != null && (c['code'] as String).isNotEmpty) ? '${c['code']} — ' : ''}${c['shop_name'] ?? ''}"};
        // keep an open job's loaded customer label in sync once labels arrive
        if (_customerId != null && _customerLabel.isEmpty) _customerLabel = _custLabel[_customerId] ?? '';
      });
    } catch (_) {}
  }

  List<Map<String, dynamic>> _filterCustomers(String q) {
    final ql = q.toLowerCase();
    final list = _customers.where((c) {
      if (ql.isEmpty) return true;
      final sn = (c['shop_name'] as String? ?? '').toLowerCase();
      final cd = (c['code'] as String? ?? '').toLowerCase();
      return sn.contains(ql) || cd.contains(ql);
    }).take(200).toList();
    return list.map((c) => {'id': c['id'], 'label': _custLabel[c['id']] ?? (c['shop_name'] ?? '')}).toList();
  }

  Future<void> _loadCheckpoints() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('qc_checkpoints').select().eq('org_id', orgId).eq('is_active', true).order('sequence');
      if (mounted) setState(() => _checkpoints = List<Map<String, dynamic>>.from(rows));
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
    return list.map((b) => {'id': b['id'], 'label': "${b['code'] ?? ''} — ${_prodLabel[b['product_id']] ?? (b['name'] ?? '')}"}).toList();
  }

  Future<void> _loadJobs() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      final rows = await Supabase.instance.client.from('job_cards').select().eq('org_id', orgId)
          .order('priority', ascending: false).order('created_at', ascending: false).limit(400);
      if (mounted) setState(() { _jobs = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
      _subscribe(orgId);
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  // ── Realtime: keep the drawer list in sync with other users' changes ──────
  void _subscribe(String orgId) {
    if (_channel != null) return;
    _channel = Supabase.instance.client
        .channel('job_card_list_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'job_cards',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'org_id', value: orgId),
          callback: (_) => _scheduleRefresh(),
        )
        .subscribe();
  }

  void _scheduleRefresh() {
    _rtDebounce?.cancel();
    _rtDebounce = Timer(const Duration(milliseconds: 250), _refreshList);
  }

  // Re-pull the drawer list quietly (no spinner). Does NOT touch the open
  // job's editable form — only mirrors the live is_running flag onto it so the
  // header dot / Play-Pause button reflect another user's toggle.
  Future<void> _refreshList() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('job_cards').select().eq('org_id', orgId)
          .order('priority', ascending: false).order('created_at', ascending: false).limit(400);
      if (!mounted) return;
      final fresh = List<Map<String, dynamic>>.from(rows);
      setState(() {
        _jobs = fresh;
        if (_current != null) {
          final m = fresh.where((j) => j['id'] == _current!['id']);
          if (m.isNotEmpty) _current!['is_running'] = m.first['is_running'];
        }
      });
    } catch (_) { /* transient; next event or manual action recovers */ }
  }

  // checkpoints applicable to the current job (by product/bom/global)
  List<Map<String, dynamic>> get _jobCheckpoints {
    final list = _checkpoints.where((c) {
      final s = c['scope'] as String? ?? 'global';
      if (s == 'global') return true;
      if (s == 'product') return c['scope_ref'] == _fgId;
      if (s == 'bom') return c['scope_ref'] == _bomId;
      return false;
    }).toList();
    list.sort((a, b) => ((a['sequence'] ?? 0) as int).compareTo((b['sequence'] ?? 0) as int));
    return list;
  }

  // ---------- form ----------
  void _newJob() {
    for (final l in _materials) l.dispose();
    for (final l in _overheads) l.dispose();
    setState(() {
      _current = null; _runs = []; _status = 'queued';
      _date = DateTime.now();
      _bomId = null; _bomLabel = ''; _fgId = null; _fgLabel = ''; _bomBaseQty = 1;
      _plannedQtyCtrl.text = '1'; _priorityCtrl.text = '0'; _wcCtrl.clear(); _assignedTo = null; _assignedWorkerId = null; _notesCtrl.clear();
      _customerId = null; _customerLabel = '';
      _materials = []; _overheads = []; _baseComps = []; _baseOh = [];
      _origMatSig = ''; _origOhSig = '';
    });
  }

  Future<void> _loadJob(Map<String, dynamic> j) async {
    try {
      final client = Supabase.instance.client;
      final mats = await client.from('job_card_materials').select().eq('job_card_id', j['id'] as String).order('line_order');
      final ohs = await client.from('job_card_overheads').select().eq('job_card_id', j['id'] as String).order('line_order');
      final runs = await client.from('job_card_runs').select().eq('job_card_id', j['id'] as String).order('run_no');
      for (final l in _materials) l.dispose();
      for (final l in _overheads) l.dispose();
      _origMatSig = (mats as List).where((r) => r['product_id'] != null)
          .map((r) => '${r['product_id']}:${_trim((r['planned_qty'] as num? ?? r['issued_qty'] as num? ?? 0).toDouble())}').join(';');
      _origOhSig = (ohs as List)
          .map((r) => '${r['cost_type'] ?? 'overhead'}|${(r['description'] as String? ?? '').trim()}|${_trim((r['amount'] as num? ?? 0).toDouble())}').join(';');
      final newMats = (mats as List).map((r) {
        final l = _JobMat();
        l.productId = r['product_id'] as String?;
        l.productLabel = _prodLabel[l.productId] ?? (l.productId ?? '');
        final q = (r['planned_qty'] as num? ?? r['issued_qty'] as num? ?? 0).toDouble();
        if (q != 0) l.qtyCtrl.text = _trim(q);
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
        _runs = List<Map<String, dynamic>>.from(runs as List);
        _status = j['status'] as String? ?? 'queued';
        final ds = j['voucher_date'] as String?;
        _date = ds != null ? DateTime.tryParse(ds) ?? DateTime.now() : DateTime.now();
        _bomId = j['bom_id'] as String?;
        _fgId = j['product_id'] as String?;
        _fgLabel = _prodLabel[_fgId] ?? (_fgId ?? '');
        _bomLabel = _bomId != null ? (_boms.firstWhere((b) => b['id'] == _bomId, orElse: () => {})['code'] as String? ?? '') : '';
        _plannedQtyCtrl.text = _trim((j['planned_qty'] as num? ?? 1).toDouble());
        _priorityCtrl.text = (j['priority'] ?? 0).toString();
        _wcCtrl.text = j['work_center'] as String? ?? '';
        _assignedTo = j['assigned_to'] as String?;
        _assignedWorkerId = j['assigned_worker_id'] as String?;
        _customerId = j['customer_id'] as String?;
        _customerLabel = _customerId != null ? (_custLabel[_customerId] ?? '') : '';
        _notesCtrl.text = j['notes'] as String? ?? '';
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

  // ---------- save job ----------
  Future<String?> _save({bool silent = false}) async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return null; }
    if (!_editable) { _snack('This job can no longer be edited'); return _current?['id'] as String?; }
    if (_branchId == null) { _snack('No branch selected — pick one in the sidebar'); return null; }
    if (_fgId == null) { _snack('Pick a BOM (sets the finished product)'); return null; }
    if (_plannedQty <= 0) { _snack('Planned quantity must be greater than 0'); return null; }
    final mats = _materials.where((l) => l.productId != null && l.qty > 0).toList();
    final ohs = _overheads.where((l) => l.amount != 0 || l.descCtrl.text.trim().isNotEmpty).toList();
    final userId = ref.read(currentUserProvider)?.id ?? '';
    final wasNew = _current == null;
    final old = _current;
    setState(() => _saving = true);
    String? resultId;
    try {
      final client = Supabase.instance.client;
      String jId, num;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final prio = int.tryParse(_priorityCtrl.text.trim()) ?? 0;
      if (_current == null) {
        final cnt = await client.from('job_cards').select('id').eq('org_id', orgId);
        num = 'JOB-${_date.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        jId = 'job_' + DateTime.now().millisecondsSinceEpoch.toString();
        await client.from('job_cards').insert({
          'id': jId, 'org_id': orgId, 'branch_id': _branchId, 'job_number': num,
          'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId, 'planned_qty': _plannedQty,
          'status': 'queued', 'priority': prio, 'is_locked': false,
          'work_center': _wcCtrl.text.trim(), 'assigned_to': _assignedTo, 'assigned_worker_id': _assignedWorkerId, 'notes': _notesCtrl.text.trim(),
          'customer_id': _customerId,
          'created_by': userId, 'created_at': DateTime.now().toUtc().toIso8601String(), 'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      } else {
        jId = _current!['id'] as String; num = _current!['job_number'] as String? ?? '';
        await client.from('job_cards').update({
          'branch_id': _branchId, 'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId,
          'planned_qty': _plannedQty, 'priority': prio, 'work_center': _wcCtrl.text.trim(),
          'assigned_to': _assignedTo, 'assigned_worker_id': _assignedWorkerId, 'notes': _notesCtrl.text.trim(), 'customer_id': _customerId, 'updated_at': DateTime.now().toUtc().toIso8601String(),
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
          'cost_type': ohs[i].costType, 'description': ohs[i].descCtrl.text.trim(), 'amount': ohs[i].amount, 'line_order': i,
        });
      }
      resultId = jId;
      final updated = await client.from('job_cards').select().eq('id', jId).single();
      if (mounted) setState(() => _current = updated);
      if (wasNew) {
        await _logJobAudit('created', notes: 'Planned qty ${_trim(_plannedQty)} · BOM ${_bomCode(_bomId)}');
      } else if (!silent) {
        final note = _describeSaveChanges(old!, mats, ohs, dateStr, prio);
        if (note.isNotEmpty) await _logJobAudit('updated', notes: note);
      }
      if (!silent) _snack('Job $num saved');
      await _loadJobs();
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
    return resultId;
  }

  // ---------- produce a batch ----------
  Future<void> _produceBatch() async {
    if (_current == null) { _snack('Save the job first'); return; }
    if (_branchId == null) { _snack('No branch selected'); return; }
    final jobId = _current!['id'] as String;
    final producedCtrl = TextEditingController();
    final rejectedCtrl = TextEditingController(text: '0');
    final ohCtrl = TextEditingController(text: _trim(_overheads.fold(0.0, (s, l) => s + l.amount)));
    final checks = _jobCheckpoints;
    final Map<String, bool> results = {for (final c in checks) c['id'] as String: false};
    bool saving = false;

    await showDialog(context: context, builder: (_) => StatefulBuilder(builder: (dCtx, setS) {
      final produced = double.tryParse(producedCtrl.text) ?? 0;
      final rejected = double.tryParse(rejectedCtrl.text) ?? 0;
      final accepted = (produced - rejected).clamp(0, double.infinity);
      final gatingOk = checks.where((c) => (c['is_gating'] as bool?) ?? true).every((c) => results[c['id']] == true);
      final canPost = produced > 0 && rejected >= 0 && rejected <= produced && gatingOk && !saving;
      return AlertDialog(
        title: const Text('Produce a batch'),
        content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Remaining on job: ${_trim(_remainingQty)}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: producedCtrl, keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: const InputDecoration(labelText: 'Produced qty *', isDense: true), onChanged: (_) => setS(() {}))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: rejectedCtrl, keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: const InputDecoration(labelText: 'Rejected', isDense: true), onChanged: (_) => setS(() {}))),
          ]),
          const SizedBox(height: 6),
          Text('Accepted into stock: ${_trim(accepted.toDouble())}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          TextField(controller: ohCtrl, keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Labor & overhead for this batch', isDense: true)),
          const SizedBox(height: 16),
          Row(children: [
            const Text('QC Checkpoints', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            if (checks.isEmpty) const Text('none configured', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(height: 6),
          for (final c in checks) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
            Expanded(child: Row(children: [
              Flexible(child: Text(c['name'] as String? ?? '-', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              if ((c['is_gating'] as bool?) ?? true) Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: Colors.deepOrange.withOpacity(0.12), borderRadius: BorderRadius.circular(3)),
                child: const Text('gating', style: TextStyle(fontSize: 9, color: Colors.deepOrange, fontWeight: FontWeight.w700))),
            ])),
            ToggleButtons(
              isSelected: [results[c['id']] == true, results[c['id']] == false],
              onPressed: (i) => setS(() => results[c['id'] as String] = i == 0),
              constraints: const BoxConstraints(minHeight: 28, minWidth: 52),
              borderRadius: BorderRadius.circular(6),
              selectedColor: Colors.white,
              fillColor: results[c['id']] == true ? Colors.green : Colors.red,
              children: const [Text('Pass', style: TextStyle(fontSize: 11)), Text('Fail', style: TextStyle(fontSize: 11))],
            ),
          ])),
          if (checks.any((c) => (c['is_gating'] as bool?) ?? true) && !gatingOk)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('All gating checkpoints must pass to post this batch.', style: TextStyle(fontSize: 11, color: Colors.deepOrange))),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: canPost ? () async {
              setS(() => saving = true);
              final runId = 'jrun_' + DateTime.now().millisecondsSinceEpoch.toString();
              try {
                final client = Supabase.instance.client;
                final orgId = _orgId!; final userId = ref.read(currentUserProvider)?.id ?? '';
                final nextNo = (_runs.fold<int>(0, (m, r) => ((r['run_no'] ?? 0) as int) > m ? (r['run_no'] as int) : m)) + 1;
                final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
                await client.from('job_card_runs').insert({
                  'id': runId, 'org_id': orgId, 'branch_id': _branchId, 'job_card_id': jobId,
                  'run_no': nextNo, 'run_date': dateStr, 'produced_qty': produced, 'rejected_qty': rejected,
                  'overhead_amount': double.tryParse(ohCtrl.text) ?? 0, 'status': 'draft',
                  'operator_id': userId, 'created_by': userId, 'created_at': DateTime.now().toUtc().toIso8601String(),
                });
                // record per-checkpoint QC results for this run
                int qi = 0;
                for (final c in checks) {
                  await client.from('qc_inspections').insert({
                    'id': 'qc_' + DateTime.now().millisecondsSinceEpoch.toString() + '_' + (qi++).toString(),
                    'org_id': orgId, 'branch_id': _branchId, 'source_type': 'job_run', 'source_id': runId,
                    'run_id': runId, 'job_card_id': jobId, 'checkpoint_id': c['id'], 'checkpoint_name': c['name'],
                    'product_id': _fgId, 'inspected_qty': produced, 'accepted_qty': accepted, 'rejected_qty': rejected,
                    'result': results[c['id']] == true ? 'pass' : 'fail', 'disposition': rejected == 0 ? 'accept' : (accepted == 0 ? 'reject' : 'partial'),
                    'inspector_id': userId, 'inspected_at': DateTime.now().toUtc().toIso8601String(),
                  });
                }
                final res = await client.rpc('post_job_run', params: {'p_run_id': runId});
                if (dCtx.mounted) Navigator.pop(dCtx);
                _snack(res?.toString() ?? 'Batch posted');
                final updated = await client.from('job_cards').select().eq('id', jobId).single();
                await _loadJobs();
                await _loadJob(updated);
              } catch (e) {
                try {
                  await Supabase.instance.client.from('qc_inspections').delete().eq('run_id', runId);
                  await Supabase.instance.client.from('job_card_runs').delete().eq('id', runId);
                } catch (_) {}
                setS(() => saving = false);
                if (dCtx.mounted) ScaffoldMessenger.of(dCtx).showSnackBar(SnackBar(content: Text('Post failed: $e')));
              }
            } : null,
            child: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Post Batch'),
          ),
        ],
      );
    }));
  }

  Future<void> _voidRun(Map<String, dynamic> run) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Void this batch?'),
      content: Text('Batch R${run['run_no']} will be reversed — materials returned, its finished goods removed, GL reversed.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Void')),
      ],
    ));
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final userId = ref.read(currentUserProvider)?.id;
      final res = await Supabase.instance.client.rpc('void_job_run', params: {'p_run_id': run['id'], 'p_user': userId});
      _snack(res?.toString() ?? 'Batch voided');
      final updated = await Supabase.instance.client.from('job_cards').select().eq('id', _current!['id'] as String).single();
      await _loadJobs();
      await _loadJob(updated);
    } catch (e) { _snack('Void failed: $e'); }
    if (mounted) setState(() => _busy = false);
  }

  bool get _isAdminTier {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
  }

  Future<void> _logJobAudit(String action, {String? notes}) async {
    final jid = _current?['id'] as String?;
    if (jid == null) return;
    try {
      final u = ref.read(currentUserProvider);
      await Supabase.instance.client.from('job_card_audit_trail').insert({
        'id': 'jca_' + DateTime.now().millisecondsSinceEpoch.toString() + '_' + (_auditSeq++).toString(),
        'job_card_id': jid,
        'action': action,
        'performed_by': u?.id,
        'performed_by_name': u?.name,
        'notes': notes,
      });
    } catch (_) {}
  }

  Future<void> _loadJobAudit(String jobId) async {
    try {
      final rows = await Supabase.instance.client.from('job_card_audit_trail')
          .select().eq('job_card_id', jobId).order('performed_at', ascending: false);
      if (mounted) setState(() => _auditTrail = List<Map<String, dynamic>>.from(rows as List));
    } catch (_) {
      if (mounted) setState(() => _auditTrail = []);
    }
  }

  Future<void> _openAuditTrail() async {
    final jid = _current?['id'] as String?;
    if (jid == null) return;
    await _loadJobAudit(jid);
    if (mounted) _showJobAuditTrail();
  }

  IconData _auditIcon(String a) {
    switch (a) {
      case 'created': return Icons.add_circle_outline;
      case 'updated': return Icons.edit_outlined;
      case 'started': return Icons.play_circle_outline;
      case 'paused': return Icons.pause_circle_outline;
      case 'batch_posted': return Icons.inventory_2_outlined;
      case 'batch_voided': return Icons.undo;
      case 'completed': return Icons.check_circle_outline;
      default: return Icons.circle_outlined;
    }
  }

  Color _auditColor(String a) {
    switch (a) {
      case 'created': return Colors.blue;
      case 'updated': return Colors.orange;
      case 'started': return Colors.green;
      case 'paused': return Colors.deepOrange;
      case 'batch_posted': return Colors.teal;
      case 'batch_voided': return Colors.red;
      case 'completed': return Colors.green.shade700;
      default: return Colors.grey;
    }
  }

  void _showJobAuditTrail() {
    showDialog(context: context, builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Row(children: [
              const Icon(Icons.history, size: 20), const SizedBox(width: 8),
              const Text('Audit Trail', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
            ])),
          const Divider(height: 1),
          Flexible(child: _auditTrail.isEmpty
            ? const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('No history yet', style: TextStyle(color: Colors.grey))))
            : ListView.separated(
                shrinkWrap: true, padding: const EdgeInsets.all(8),
                itemCount: _auditTrail.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final e = _auditTrail[i];
                  final a = e['action'] as String? ?? '';
                  final label = a.isEmpty ? '' : (a[0].toUpperCase() + a.substring(1)).replaceAll('_', ' ');
                  final who = e['performed_by_name'] as String? ?? 'Unknown';
                  final notes = e['notes'] as String?;
                  DateTime? ts; try { ts = DateTime.parse(e['performed_at'] as String).toLocal(); } catch (_) {}
                  final when = ts != null ? DateFormat('d MMM yyyy, h:mm a').format(ts) : '';
                  final changes = (notes != null && notes.isNotEmpty)
                      ? notes.split(' · ').where((s) => s.trim().isNotEmpty).toList()
                      : <String>[];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(padding: const EdgeInsets.only(top: 1, right: 10), child: Icon(_auditIcon(a), color: _auditColor(a), size: 19)),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          const Spacer(),
                          Text(when, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        ]),
                        const SizedBox(height: 1),
                        Text(who, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        if (changes.isNotEmpty) Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                            children: changes.map((c) => Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                const Padding(padding: EdgeInsets.only(top: 5, right: 6), child: Icon(Icons.circle, size: 4, color: Colors.grey)),
                                Expanded(child: Text(c.trim(), style: const TextStyle(fontSize: 12, height: 1.3))),
                              ]),
                            )).toList()),
                        ),
                      ])),
                    ]),
                  );
                },
              )),
        ]),
      ),
    ));
  }

  String _workerName(String? id) {
    if (id == null) return '—';
    final w = _workers.firstWhere((w) => w['id'] == id, orElse: () => <String, dynamic>{});
    return (w['name'] as String?) ?? id;
  }

  String _bomCode(String? id) {
    if (id == null) return '—';
    final b = _boms.firstWhere((b) => b['id'] == id, orElse: () => <String, dynamic>{});
    return (b['code'] as String?) ?? id;
  }

  String _describeSaveChanges(Map<String, dynamic> old, List<_JobMat> mats, List<_JobOh> ohs, String dateStr, int prio) {
    final ch = <String>[];
    final oldQty = ((old['planned_qty'] as num?) ?? 0).toDouble();
    if (oldQty != _plannedQty) ch.add('Planned qty ${_trim(oldQty)} → ${_trim(_plannedQty)}');
    final oldPrio = (old['priority'] as num?)?.toInt() ?? 0;
    if (oldPrio != prio) ch.add('Priority $oldPrio → $prio');
    final oldWc = (old['work_center'] as String?)?.trim() ?? '';
    final newWc = _wcCtrl.text.trim();
    if (oldWc != newWc) ch.add('Work center ${oldWc.isEmpty ? '—' : oldWc} → ${newWc.isEmpty ? '—' : newWc}');
    final oldW = old['assigned_worker_id'] as String?;
    if (oldW != _assignedWorkerId) ch.add('Assigned to ${_workerName(oldW)} → ${_workerName(_assignedWorkerId)}');
    final oldCust = old['customer_id'] as String?;
    if (oldCust != _customerId) {
      if (_customerId == null) ch.add('Customer cleared');
      else if (oldCust == null) ch.add('Customer set to ${_custLabel[_customerId] ?? _customerId}');
      else ch.add('Customer ${_custLabel[oldCust] ?? oldCust} → ${_custLabel[_customerId] ?? _customerId}');
    }
    final oldBom = old['bom_id'] as String?;
    if (oldBom != _bomId) ch.add('BOM ${_bomCode(oldBom)} → ${_bomCode(_bomId)}');
    final oldDate = old['voucher_date'] as String?;
    if ((oldDate ?? '') != dateStr) ch.add('Date ${oldDate ?? '—'} → $dateStr');
    final oldNotes = (old['notes'] as String?)?.trim() ?? '';
    if (oldNotes != _notesCtrl.text.trim()) ch.add('Notes updated');
    final newMatSig = mats.map((l) => '${l.productId}:${_trim(l.qty)}').join(';');
    if (newMatSig != _origMatSig) ch.add('Materials updated');
    final newOhSig = ohs.map((l) => '${l.costType}|${l.descCtrl.text.trim()}|${_trim(l.amount)}').join(';');
    if (newOhSig != _origOhSig) ch.add('Labor & overhead updated');
    return ch.join(' · ');
  }

  Future<void> _delete() async {
    if (_current == null) return;
    if ((_runs.any((r) => r['status'] == 'posted'))) { _snack('This job has posted batches — void them before deleting'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete job?'),
      content: const Text('This job card and its draft batches will be permanently deleted.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try { await Supabase.instance.client.from('job_cards').delete().eq('id', _current!['id'] as String); _snack('Job deleted'); _newJob(); await _loadJobs(); }
    catch (e) { _snack('Delete failed: $e'); }
  }

  Future<void> _toggleRunning() async {
    if (_current == null) return;
    final id = _current!['id'] as String;
    final next = !((_current!['is_running'] as bool?) ?? false);
    final firstStart = next && _current!['started_at'] == null;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> upd = {'is_running': next, 'updated_at': nowIso};
      if (firstStart) upd['started_at'] = nowIso;
      await Supabase.instance.client.from('job_cards')
          .update(upd)
          .eq('id', id);
      if (mounted) setState(() {
        _current!['is_running'] = next;
        if (firstStart) _current!['started_at'] = nowIso;
        final idx = _jobs.indexWhere((j) => j['id'] == id);
        if (idx >= 0) _jobs[idx]['is_running'] = next;
      });
      await _logJobAudit(next ? 'started' : 'paused');
    } catch (e) { _snack('Could not update status: $e'); }
    if (mounted) setState(() => _busy = false);
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  String _buildJobCardHtml() {
    final jobNo = _current?['job_number'] as String? ?? 'New Job';
    final st = _status;
    final stLabel = st == 'completed' ? 'Completed' : st == 'cancelled' ? 'Voided' : st == 'in_progress' ? 'In progress' : 'Queued';
    final branch = (ref.read(selectedBranchProvider)?['name'] as String?) ?? '—';
    final dateStr = DateFormat('d MMM yyyy').format(_date);
    final bomFg = _bomLabel.isEmpty ? (_fgLabel.isEmpty ? '—' : _fgLabel) : (_fgLabel.isEmpty ? _bomLabel : '$_bomLabel — $_fgLabel');
    final wc = _wcCtrl.text.trim();
    final assignee = _assignedWorkerId != null ? ((_workers.firstWhere((w) => w['id'] == _assignedWorkerId, orElse: () => <String, dynamic>{})['name'] as String?) ?? '') : '';
    final prio = _priorityCtrl.text.trim();
    final comp = _componentsCost, oh = _laborOhCost, total = _totalCost, unit = _unitCost;
    final uid = ref.read(currentUserProvider)?.id;
    final by = uid != null ? ((_users.firstWhere((u) => u['id'] == uid, orElse: () => <String, dynamic>{})['name'] as String?) ?? '') : '';
    final printedAt = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());

    final mat = StringBuffer();
    for (var i = 0; i < _materials.length; i++) {
      final m = _materials[i];
      final lineCost = m.qty * (_prodCost[m.productId] ?? 0);
      mat.write('<tr><td class="n">${i + 1}</td><td>${_esc(m.productLabel)}</td><td class="r">${_trim(m.qty)}</td><td class="r">${_money(lineCost)}</td></tr>');
    }
    final ohb = StringBuffer();
    for (final o in _overheads) {
      final desc = o.descCtrl.text.trim().isNotEmpty ? o.descCtrl.text.trim() : (o.costType == 'labor' ? 'Labor' : 'Overhead');
      ohb.write('<tr><td>${o.costType == 'labor' ? 'Labor' : 'Overhead'}</td><td>${_esc(desc)}</td><td class="r">${_money(o.amount)}</td></tr>');
    }
    final runb = StringBuffer();
    for (final r in _runs) {
      runb.write('<tr><td class="n">R${r['run_no']}</td><td>${_esc((r['run_date'] ?? '').toString())}</td>'
          '<td class="r">${_trim((r['produced_qty'] as num? ?? 0).toDouble())}</td>'
          '<td class="r">${_trim((r['accepted_qty'] as num? ?? 0).toDouble())}</td>'
          '<td class="r">${_trim((r['rejected_qty'] as num? ?? 0).toDouble())}</td>'
          '<td class="r">${_money((r['total_cost'] as num? ?? 0).toDouble())}</td>'
          '<td>${_esc((r['status'] ?? '').toString())}</td></tr>');
    }

    final ohSection = _overheads.isEmpty ? '' :
      '<div class="sec">Labor &amp; overhead</div><table><thead><tr><th>Type</th><th>Description</th><th class="r">Amount</th></tr></thead>'
      '<tbody>${ohb.toString()}</tbody><tfoot><tr><td colspan="2">Total</td><td class="r">${_money(oh)}</td></tr></tfoot></table>';
    final runSection = _runs.isEmpty ? '' :
      '<div class="sec">Production batches</div><table><thead><tr><th class="n">Batch</th><th>Date</th><th class="r">Produced</th><th class="r">Accepted</th><th class="r">Rejected</th><th class="r">Cost</th><th>Status</th></tr></thead>'
      '<tbody>${runb.toString()}</tbody></table>';
    final matBody = mat.toString().isEmpty ? '<tr><td colspan="4" style="color:#999">No components.</td></tr>' : mat.toString();

    return '''<!DOCTYPE html><html><head><meta charset="utf-8"><title>Job Card $jobNo</title>
<style>
  @page { size: A4; margin: 14mm; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; color: #1a1a1a; font-size: 12px; margin: 0; }
  .toolbar { padding: 10px 0; }
  .btn { background: #2f6fed; color: #fff; border: 0; padding: 8px 16px; border-radius: 6px; font-size: 13px; cursor: pointer; }
  h1 { font-size: 20px; margin: 0; }
  .sub { color: #666; font-size: 12px; margin-top: 2px; }
  .hdr { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #222; padding-bottom: 10px; margin-bottom: 12px; }
  .meta { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px 24px; margin-bottom: 14px; }
  .meta .k { color: #888; font-size: 10px; text-transform: uppercase; letter-spacing: .3px; }
  .meta .v { font-size: 13px; font-weight: 600; }
  .cards { display: flex; gap: 10px; margin-bottom: 16px; }
  .card { flex: 1; border: 1px solid #e3e3e3; border-radius: 8px; padding: 8px 10px; }
  .card .k { color: #888; font-size: 10px; }
  .card .v { font-size: 16px; font-weight: 800; margin-top: 2px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 14px; }
  th { text-align: left; font-size: 10px; text-transform: uppercase; color: #888; border-bottom: 1px solid #ccc; padding: 6px 8px; }
  td { padding: 6px 8px; border-bottom: 1px solid #eee; font-size: 12px; }
  td.r, th.r { text-align: right; }
  td.n { color: #999; width: 40px; }
  tfoot td { font-weight: 800; border-top: 2px solid #222; border-bottom: 0; }
  .sec { font-size: 13px; font-weight: 700; margin: 4px 0 6px; }
  .foot { margin-top: 24px; padding-top: 8px; border-top: 1px solid #ddd; color: #888; font-size: 11px; display: flex; justify-content: space-between; }
  @media print { .no-print { display: none !important; } }
</style></head><body>
<div class="toolbar no-print"><button class="btn" onclick="window.print()">Print / Save as PDF</button></div>
<div class="hdr">
  <div><h1>Job Card</h1><div class="sub">$branch</div></div>
  <div style="text-align:right"><div style="font-size:16px;font-weight:800">${_esc(jobNo)}</div><div class="sub">$stLabel</div></div>
</div>
<div class="meta">
  <div><div class="k">Date</div><div class="v">$dateStr</div></div>
  <div><div class="k">BOM / Finished product</div><div class="v">${_esc(bomFg)}</div></div>
  <div><div class="k">Customer</div><div class="v">${_customerLabel.isEmpty ? '—' : _esc(_customerLabel)}</div></div>
  <div><div class="k">Work center</div><div class="v">${wc.isEmpty ? '—' : _esc(wc)}</div></div>
  <div><div class="k">Assigned to</div><div class="v">${assignee.isEmpty ? '—' : _esc(assignee)}</div></div>
  <div><div class="k">Priority</div><div class="v">${prio.isEmpty ? '0' : _esc(prio)}</div></div>
  <div><div class="k">Planned</div><div class="v">${_trim(_plannedQty)}</div></div>
  <div><div class="k">Produced</div><div class="v">${_trim(_producedQty)}</div></div>
  <div><div class="k">Remaining</div><div class="v">${_trim(_remainingQty)}</div></div>
</div>
<div class="cards">
  <div class="card"><div class="k">Components</div><div class="v">${_money(comp)}</div></div>
  <div class="card"><div class="k">Labor &amp; Overhead</div><div class="v">${_money(oh)}</div></div>
  <div class="card"><div class="k">Total absorbed</div><div class="v">${_money(total)}</div></div>
  <div class="card"><div class="k">Unit cost</div><div class="v">${NumberFormat('#,##0.0000').format(unit)}</div></div>
</div>
<div class="sec">Recipe (per planned qty)</div>
<table><thead><tr><th class="n">#</th><th>Component</th><th class="r">Qty</th><th class="r">Cost</th></tr></thead>
<tbody>$matBody</tbody>
<tfoot><tr><td colspan="3">Components total</td><td class="r">${_money(comp)}</td></tr></tfoot></table>
$ohSection
$runSection
<div class="foot"><div>Printed by ${by.isEmpty ? '—' : _esc(by)}</div><div>$printedAt</div></div>
<script>window.onload=function(){setTimeout(function(){window.print();},250);};</script>
</body></html>''';
  }

  void _printJobCard() {
    if (_current == null) { _snack('Open a saved job card to print'); return; }
    try {
      final out = _buildJobCardHtml();
      final blob = html.Blob([out], 'text/html');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.window.open(url, '_blank');
      Future.delayed(const Duration(seconds: 60), () { try { html.Url.revokeObjectUrl(url); } catch (_) {} });
    } catch (e) { _snack('Print failed: $e'); }
  }

  Future<void> _manageWorkCenters() async {
    final orgId = _orgId; if (orgId == null) return;
    final addCtrl = TextEditingController();
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      Future<void> reload() async { await _loadWorkCenters(); setS(() {}); }
      return AlertDialog(
        title: const Text('Manage work centers'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: TextField(controller: addCtrl, decoration: const InputDecoration(hintText: 'New work center', isDense: true))),
            const SizedBox(width: 8),
            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () async {
                final name = addCtrl.text.trim(); if (name.isEmpty) return;
                try {
                  await Supabase.instance.client.from('work_centers').insert({
                    'id': 'wc_${DateTime.now().millisecondsSinceEpoch}', 'org_id': orgId, 'name': name, 'is_active': true,
                    'created_at': DateTime.now().toUtc().toIso8601String()});
                  addCtrl.clear(); await reload();
                } catch (e) { _snack('Add failed: $e'); }
              }, child: const Text('Add')),
          ]),
          const SizedBox(height: 12),
          SizedBox(height: 300, width: 420, child: _workCenters.isEmpty
            ? const Center(child: Text('No work centers yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView(children: _workCenters.map((w) => Row(children: [
                Expanded(child: Text(w['name'] as String? ?? '', style: const TextStyle(fontSize: 13))),
                Switch(value: w['is_active'] != false, onChanged: (v) async {
                  try { await Supabase.instance.client.from('work_centers').update({'is_active': v}).eq('id', w['id'] as String); await reload(); }
                  catch (e) { _snack('Update failed: $e'); }
                }),
              ])).toList())),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      );
    }));
    if (mounted) setState(() {});
  }

  Future<void> _manageWorkers() async {
    final orgId = _orgId; if (orgId == null) return;
    final addCtrl = TextEditingController();
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      Future<void> reload() async { await _loadWorkers(); setS(() {}); }
      return AlertDialog(
        title: const Text('Manage workers'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: TextField(controller: addCtrl, decoration: const InputDecoration(hintText: 'New worker name', isDense: true))),
            const SizedBox(width: 8),
            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () async {
                final name = addCtrl.text.trim(); if (name.isEmpty) return;
                try {
                  await Supabase.instance.client.from('workers').insert({
                    'id': 'wkr_${DateTime.now().millisecondsSinceEpoch}', 'org_id': orgId, 'name': name, 'is_active': true,
                    'created_at': DateTime.now().toUtc().toIso8601String()});
                  addCtrl.clear(); await reload();
                } catch (e) { _snack('Add failed: $e'); }
              }, child: const Text('Add')),
          ]),
          const SizedBox(height: 12),
          SizedBox(height: 300, width: 420, child: _workers.isEmpty
            ? const Center(child: Text('No workers yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView(children: _workers.map((w) => Row(children: [
                Expanded(child: Text(w['name'] as String? ?? '', style: const TextStyle(fontSize: 13))),
                Switch(value: w['is_active'] != false, onChanged: (v) async {
                  try { await Supabase.instance.client.from('workers').update({'is_active': v}).eq('id', w['id'] as String); await reload(); }
                  catch (e) { _snack('Update failed: $e'); }
                }),
              ])).toList())),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      );
    }));
    if (mounted) setState(() {});
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked != null) setState(() => _date = picked);
  }

  // ---------- UI helpers ----------
  Widget _labeled(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
    const SizedBox(height: 5), child,
  ]);
  Widget _readonlyBox(String text) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
    decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
    child: Text(text, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis));
  Widget _dateField() => InkWell(onTap: _editable ? _pickDate : null, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
    child: Row(children: [const Icon(Icons.event, size: 15, color: AppTheme.textSecondary), const SizedBox(width: 8), Text(DateFormat('d MMM yyyy').format(_date), style: const TextStyle(fontSize: 13))])));

  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _jobs : _jobs.where((j) {
      final q = _listSearch.toLowerCase();
      final pn = (_prodLabel[j['product_id']] ?? '').toLowerCase();
      return (j['job_number'] as String? ?? '').toLowerCase().contains(q) || pn.contains(q);
    }).toList();

    final running = (_current?['is_running'] as bool?) ?? false;

    final wcNames = _workCenters.where((w) => w['is_active'] != false).map((w) => w['name'] as String).toList();
    { final cur = _wcCtrl.text.trim(); if (cur.isNotEmpty && !wcNames.contains(cur)) wcNames.add(cur); }
    final activeWorkers = _workers.where((w) => w['is_active'] != false).toList();
    if (_assignedWorkerId != null && !activeWorkers.any((w) => w['id'] == _assignedWorkerId)) {
      final cur = _workers.where((w) => w['id'] == _assignedWorkerId);
      if (cur.isNotEmpty) activeWorkers.add(cur.first);
    }

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
              TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true), onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No job cards yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final j = filtered[i]; final sel = _current?['id'] == j['id'];
                final st = (j['status'] as String? ?? 'queued');
                final c = st == 'completed' ? Colors.green : st == 'cancelled' ? Colors.grey : st == 'in_progress' ? Colors.blue : Colors.orange;
                final lbl = st == 'completed' ? 'Completed' : st == 'cancelled' ? 'Voided' : st == 'in_progress' ? 'In progress' : 'Queued';
                final planned = (j['planned_qty'] as num? ?? 0).toDouble();
                final produced = (j['produced_qty'] as num? ?? 0).toDouble();
                return InkWell(onTap: () => _loadJob(j), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(j['job_number'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))),
                      if (j['is_running'] == true) const Padding(padding: EdgeInsets.only(right: 6), child: RunningDot(size: 7)),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: c.withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                        child: Text(lbl, style: TextStyle(fontSize: 9, color: c, fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: 2),
                    Text(_prodLabel[j['product_id']] ?? '', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    Text('${_trim(produced)} / ${_trim(planned)} done  ·  ${_trim(planned - produced)} left', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                    if (j['customer_id'] != null && (_custLabel[j['customer_id']] ?? '').isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 1), child: Row(children: [
                        const Icon(Icons.storefront_outlined, size: 11, color: AppTheme.textSecondary),
                        const SizedBox(width: 3),
                        Expanded(child: Text(_custLabel[j['customer_id']]!, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                      ])),
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
            if (running) const Padding(padding: EdgeInsets.only(right: 10), child: RunningDot(size: 9, withLabel: true)),
            if (_current != null) Padding(padding: const EdgeInsets.only(right: 8), child: Text('${_trim(_producedQty)} / ${_trim(_plannedQty)}  ·  ${_trim(_remainingQty)} left',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary))),
            if (_current != null && _isAdminTier) IconButton(icon: const Icon(Icons.history, size: 20), onPressed: _openAuditTrail, tooltip: 'Audit Trail'),
            if (_current != null) IconButton(icon: const Icon(Icons.print_outlined, size: 20), onPressed: _printJobCard, tooltip: 'Print / PDF'),
            if (_editable && _current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete'),
            if (_editable) OutlinedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save'), onPressed: _saving || _busy ? null : () => _save()),
            const SizedBox(width: 8),
            if (_current != null && _status != 'completed' && _status != 'cancelled') ...[
              IconButton(
                tooltip: running ? 'Pause' : 'Play',
                icon: Icon(running ? Icons.pause_circle : Icons.play_circle, size: 28,
                  color: running ? Colors.orange.shade800 : Colors.green.shade700),
                onPressed: _busy ? null : _toggleRunning,
              ),
              const SizedBox(width: 8),
            ],
            if (_current != null && _remainingQty > 0 && _status != 'cancelled') ElevatedButton.icon(
              icon: const Icon(Icons.add_task, size: 16), label: const Text('Produce Batch'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
              onPressed: _busy ? null : _produceBatch),
          ])),
        Expanded(child: _loadingProducts
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 190, child: _labeled('Branch', _readonlyBox((ref.watch(selectedBranchProvider)?['name'] as String?) ?? '—'))),
              const SizedBox(width: 12),
              SizedBox(width: 140, child: _labeled('Date', _dateField())),
              const SizedBox(width: 12),
              Expanded(child: _labeled('Bill of Materials *', _editable
                ? _ProductField(key: ValueKey('bom_${_current?['id'] ?? 'new'}_$_bomId'), initialLabel: _bomLabel.isEmpty ? '' : (_bomLabel + (_fgLabel.isNotEmpty ? ' — $_fgLabel' : '')), filterFn: _filterBoms, onPick: (b) => _pickBom(b['id'] as String))
                : _readonlyBox(_bomLabel.isEmpty ? '—' : '$_bomLabel — $_fgLabel'))),
            ]),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 130, child: _labeled('Planned Qty *', TextField(controller: _plannedQtyCtrl, enabled: _editable, keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11)),
                onChanged: (_) { if (_bomId != null && _current == null) _rescale(); setState(() {}); }))),
              const SizedBox(width: 12),
              SizedBox(width: 100, child: _labeled('Priority', TextField(controller: _priorityCtrl, enabled: _editable, keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                decoration: const InputDecoration(isDense: true, hintText: '0', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11))))),
              const SizedBox(width: 12),
              SizedBox(width: 210, child: _labeled('Work Center', Row(children: [
                Expanded(child: DropdownButtonFormField<String?>(
                  value: _wcCtrl.text.trim().isEmpty ? null : _wcCtrl.text.trim(), isExpanded: true,
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                  items: [const DropdownMenuItem<String?>(value: null, child: Text('—')),
                    ...wcNames.map((n) => DropdownMenuItem<String?>(value: n, child: Text(n, overflow: TextOverflow.ellipsis)))],
                  onChanged: _editable ? (v) => setState(() => _wcCtrl.text = v ?? '') : null)),
                if (_editable) IconButton(icon: const Icon(Icons.settings_outlined, size: 16), tooltip: 'Manage work centers',
                  visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 30), onPressed: _manageWorkCenters),
              ]))),
              const SizedBox(width: 12),
              SizedBox(width: 230, child: _labeled('Assigned To', Row(children: [
                Expanded(child: DropdownButtonFormField<String?>(value: _assignedWorkerId, isExpanded: true,
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                  items: [const DropdownMenuItem<String?>(value: null, child: Text('—')),
                    ...activeWorkers.map((w) => DropdownMenuItem<String?>(value: w['id'] as String, child: Text(w['name'] as String? ?? '-', overflow: TextOverflow.ellipsis)))],
                  onChanged: _editable ? (v) => setState(() => _assignedWorkerId = v) : null)),
                if (_editable) IconButton(icon: const Icon(Icons.settings_outlined, size: 16), tooltip: 'Manage workers',
                  visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 30), onPressed: _manageWorkers),
              ]))),
            ]),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 420, child: _labeled('Customer (optional)', _editable
                ? Row(children: [
                    Expanded(child: _ProductField(
                      key: ValueKey('cust_${_current?['id'] ?? 'new'}_$_customerId'),
                      initialLabel: _customerLabel,
                      filterFn: _filterCustomers,
                      onPick: (c) => setState(() { _customerId = c['id'] as String?; _customerLabel = c['label'] as String? ?? ''; }))),
                    if (_customerId != null) IconButton(icon: const Icon(Icons.clear, size: 16), tooltip: 'Clear customer',
                      visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 30),
                      onPressed: () => setState(() { _customerId = null; _customerLabel = ''; })),
                  ])
                : _readonlyBox(_customerLabel.isEmpty ? '—' : _customerLabel))),
            ]),
            const SizedBox(height: 14),
            _labeled('Remarks (optional)', TextField(
              controller: _notesCtrl, enabled: _editable,
              minLines: 1, maxLines: 3,
              decoration: const InputDecoration(isDense: true,
                hintText: 'Note for the floor - special instructions, customer ask, etc.',
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11)),
            )),
            const SizedBox(height: 18),
            if (_materials.isNotEmpty || _overheads.isNotEmpty) ...[
              _costSummary(),
              const SizedBox(height: 14),
            ],
            _recipeSection(),
            const SizedBox(height: 18),
            _runsSection(),
          ]))),
      ])),
    ]));
  }

  Widget _costSummary() {
    final comp = _componentsCost;
    final oh = _laborOhCost;
    final total = comp + oh;
    final unit = _unitCost;
    Widget cell(String label, String value, Color color) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
    ]));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Cost (estimate — actual FIFO computed at batch posting)', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        const SizedBox(height: 9),
        Row(children: [
          cell('Components', _money(comp), AppTheme.primary),
          cell('Labor & Overhead', _money(oh), Colors.green.shade700),
          cell('Total absorbed', _money(total), AppTheme.textPrimary),
          cell('Unit cost', NumberFormat('#,##0.0000').format(unit), Colors.deepPurple),
        ]),
      ]),
    );
  }

  Widget _recipeSection() {
    return Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            Container(width: 6, height: 14, decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            const Text('Recipe (per planned qty)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            const Expanded(child: Text('From the BOM, scaled to Planned Qty. Each batch consumes its share.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          ])),
        if (_materials.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Text('Pick a BOM to load the recipe.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        if (_materials.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: const [
            SizedBox(width: 26, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            Expanded(child: Text('Component', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 12),
            SizedBox(width: 80, child: Text('Qty', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 110, child: Text('Cost', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
          ])),
        for (var i = 0; i < _materials.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7), decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(children: [
              SizedBox(width: 26, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
              Expanded(child: Text(_materials[i].productLabel, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 12),
              SizedBox(width: 80, child: Text(_trim(_materials[i].qty), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
              SizedBox(width: 110, child: Text(_money(_materials[i].qty * (_prodCost[_materials[i].productId] ?? 0)), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            ])),
        if (_materials.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            const Expanded(child: Text('Components total', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
            Text(_money(_componentsCost), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
          ])),
        if (_overheads.isNotEmpty) ...[
          Container(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: const Text('Labor & overhead (planned)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          for (var i = 0; i < _overheads.length; i++)
            Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
              child: Row(children: [
                SizedBox(width: 26, child: Icon(_overheads[i].costType == 'labor' ? Icons.engineering_outlined : Icons.bolt_outlined, size: 14, color: AppTheme.textSecondary)),
                Expanded(child: Text(
                  _overheads[i].descCtrl.text.trim().isNotEmpty ? _overheads[i].descCtrl.text.trim() : (_overheads[i].costType == 'labor' ? 'Labor' : 'Overhead'),
                  style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(3)),
                  child: Text(_overheads[i].costType == 'labor' ? 'Labor' : 'Overhead', style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                const SizedBox(width: 12),
                SizedBox(width: 110, child: Text(_money(_overheads[i].amount), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
              ])),
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              const Expanded(child: Text('Labor & overhead total (planned)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
              Text(_money(_overheads.fold(0.0, (s, l) => s + l.amount)), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
            ])),
        ],
      ]));
  }

  Widget _runsSection() {
    return Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: [
            Container(width: 6, height: 14, decoration: BoxDecoration(color: Colors.teal, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            const Text('Production batches', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const Spacer(),
            Text('${_runs.where((r) => r['status'] == 'posted').length} posted', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ])),
        if (_runs.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Text('No batches yet. Use "Produce Batch" to record production with QC.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        if (_runs.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: const [
            SizedBox(width: 44, child: Text('Batch', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            Expanded(child: Text('Date', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 70, child: Text('Produced', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 70, child: Text('Accepted', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 60, child: Text('Reject', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 100, child: Text('Cost', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
            SizedBox(width: 80, child: Text('', style: TextStyle(fontSize: 11))),
          ])),
        for (final r in _runs)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(children: [
              SizedBox(width: 44, child: Text('R${r['run_no']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
              Expanded(child: Text('${r['run_date'] ?? ''}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
              SizedBox(width: 70, child: Text(_trim((r['produced_qty'] as num? ?? 0).toDouble()), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
              SizedBox(width: 70, child: Text(_trim((r['accepted_qty'] as num? ?? 0).toDouble()), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Colors.green))),
              SizedBox(width: 60, child: Text(_trim((r['rejected_qty'] as num? ?? 0).toDouble()), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Colors.red))),
              SizedBox(width: 100, child: Text(_money((r['total_cost'] as num? ?? 0).toDouble()), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
              SizedBox(width: 80, child: Align(alignment: Alignment.centerRight, child: r['status'] == 'posted'
                ? TextButton(onPressed: _busy ? null : () => _voidRun(r), style: TextButton.styleFrom(foregroundColor: Colors.red, padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero), child: const Text('Void', style: TextStyle(fontSize: 12)))
                : Text(r['status'] as String? ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
            ])),
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
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), child: Text(p['label'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
        )).toList())),
    ]);
  }
}
