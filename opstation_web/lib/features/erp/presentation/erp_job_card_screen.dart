import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';
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

  List<Map<String, dynamic>> _boms = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _checkpoints = [];

  List<Map<String, dynamic>> _jobs = [];
  bool _loadingList = true;
  String _listSearch = '';
  bool _drawerOpen = true;

  Map<String, dynamic>? _current;
  List<Map<String, dynamic>> _runs = [];
  DateTime _date = DateTime.now();
  String? _bomId; String _bomLabel = '';
  String? _fgId; String _fgLabel = '';
  double _bomBaseQty = 1;
  final _plannedQtyCtrl = TextEditingController(text: '1');
  final _priorityCtrl = TextEditingController(text: '0');
  final _wcCtrl = TextEditingController();
  String? _assignedTo;
  final _notesCtrl = TextEditingController();
  String _status = 'queued';
  List<_JobMat> _materials = [];
  List<_JobOh> _overheads = [];
  List<Map<String, dynamic>> _baseComps = [];
  List<Map<String, dynamic>> _baseOh = [];
  bool _saving = false;
  bool _busy = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _editable => _status == 'queued' || _status == 'in_progress';
  double get _plannedQty => double.tryParse(_plannedQtyCtrl.text) ?? 0;
  double get _producedQty => (_current?['produced_qty'] as num? ?? 0).toDouble();
  double get _remainingQty => (_plannedQty - _producedQty);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadProducts(); _loadBoms(); _loadUsers(); _loadCheckpoints(); _loadJobs(); });
  }

  @override
  void dispose() {
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
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
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
      _plannedQtyCtrl.text = '1'; _priorityCtrl.text = '0'; _wcCtrl.clear(); _assignedTo = null; _notesCtrl.clear();
      _materials = []; _overheads = []; _baseComps = []; _baseOh = [];
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
          'work_center': _wcCtrl.text.trim(), 'assigned_to': _assignedTo, 'notes': _notesCtrl.text.trim(),
          'created_by': userId, 'created_at': DateTime.now().toIso8601String(), 'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        jId = _current!['id'] as String; num = _current!['job_number'] as String? ?? '';
        await client.from('job_cards').update({
          'branch_id': _branchId, 'voucher_date': dateStr, 'bom_id': _bomId, 'product_id': _fgId,
          'planned_qty': _plannedQty, 'priority': prio, 'work_center': _wcCtrl.text.trim(),
          'assigned_to': _assignedTo, 'notes': _notesCtrl.text.trim(), 'updated_at': DateTime.now().toIso8601String(),
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
                  'operator_id': userId, 'created_by': userId, 'created_at': DateTime.now().toIso8601String(),
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
                    'inspector_id': userId, 'inspected_at': DateTime.now().toIso8601String(),
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
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.from('job_cards')
          .update({'is_running': next, 'updated_at': DateTime.now().toIso8601String()})
          .eq('id', id);
      if (mounted) setState(() {
        _current!['is_running'] = next;
        final idx = _jobs.indexWhere((j) => j['id'] == id);
        if (idx >= 0) _jobs[idx]['is_running'] = next;
      });
    } catch (e) { _snack('Could not update status: $e'); }
    if (mounted) setState(() => _busy = false);
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
            if (_editable && _current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete'),
            if (_editable) OutlinedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save'), onPressed: _saving || _busy ? null : () => _save()),
            const SizedBox(width: 8),
            if (_current != null && _status != 'completed' && _status != 'cancelled') ...[
              OutlinedButton.icon(
                icon: Icon(running ? Icons.pause : Icons.play_arrow, size: 18),
                label: Text(running ? 'Pause' : 'Play'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: running ? Colors.orange.shade800 : Colors.green.shade700,
                  side: BorderSide(color: running ? Colors.orange.shade300 : Colors.green.shade300),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
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
              SizedBox(width: 170, child: _labeled('Work Center', TextField(controller: _wcCtrl, enabled: _editable,
                decoration: const InputDecoration(isDense: true, hintText: 'e.g. Line A', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 11))))),
              const SizedBox(width: 12),
              SizedBox(width: 210, child: _labeled('Assigned To', DropdownButtonFormField<String?>(value: _assignedTo, isExpanded: true,
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                items: [const DropdownMenuItem<String?>(value: null, child: Text('—')),
                  ..._users.map((u) => DropdownMenuItem<String?>(value: u['id'] as String, child: Text(u['name'] as String? ?? '-', overflow: TextOverflow.ellipsis)))],
                onChanged: _editable ? (v) => setState(() => _assignedTo = v) : null))),
            ]),
            const SizedBox(height: 18),
            _recipeSection(),
            const SizedBox(height: 18),
            _runsSection(),
          ]))),
      ])),
    ]));
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
        for (var i = 0; i < _materials.length; i++)
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7), decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
            child: Row(children: [
              SizedBox(width: 26, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
              Expanded(child: Text(_materials[i].productLabel, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 12),
              SizedBox(width: 110, child: Text(_trim(_materials[i].qty), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            ])),
        if (_overheads.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [const Text('Labor & overhead (planned): ', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            Text(_money(_overheads.fold(0.0, (s, l) => s + l.amount)), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))])),
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
