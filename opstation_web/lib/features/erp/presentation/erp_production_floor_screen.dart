import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../../core/widgets/adaptive_master_detail.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';
import 'running_dot.dart';

class ErpProductionFloorScreen extends ConsumerStatefulWidget {
  const ErpProductionFloorScreen({super.key});
  @override
  ConsumerState<ErpProductionFloorScreen> createState() => _State();
}

class _State extends ConsumerState<ErpProductionFloorScreen> {
  bool _loading = true;
  int _viewMode = 0; // 0 = Board (kanban), 1 = Table, 2 = History
  bool _allBranches = false;
  List<Map<String, dynamic>> _jobs = [];
  Map<String, String> _prodLabel = {};
  Map<String, String> _userLabel = {};
  Map<String, String> _custLabel = {};
  RealtimeChannel? _channel;
  Timer? _debounce;

  // ── Job History state ──
  bool _histLoading = false;
  bool _histInit = false;
  List<Map<String, dynamic>> _histJobs = [];
  final _histSearchCtrl = TextEditingController();
  String _histSearch = '';
  DateTime _histFrom = DateTime.now().subtract(const Duration(days: 30));
  DateTime _histTo = DateTime.now();
  String _histStatus = 'all';
  String? _histWorker; // user id or null = all
  Timer? _histDebounce;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => _load()); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }
  static String _trim(double v) { if (v == v.roundToDouble()) return v.toStringAsFixed(0); return v.toString(); }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _load(); return; }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final prods = await client.from('products').select('id, name, sku').eq('org_id', orgId).limit(10000);
      final users = await client.from('users').select('id, name').eq('org_id', orgId).limit(2000);
      final custs = await client.from('customers').select('id, shop_name, code').eq('org_id', orgId).limit(10000);
      final jobs = await client.from('job_cards').select().eq('org_id', orgId)
          .order('priority', ascending: false).order('created_at', ascending: false).limit(1000);
      _prodLabel = {for (final p in (prods as List)) p['id'] as String: "${p['sku'] != null && (p['sku'] as String).isNotEmpty ? '${p['sku']} — ' : ''}${p['name'] ?? ''}"};
      _userLabel = {for (final u in (users as List)) u['id'] as String: (u['name'] as String? ?? '-')};
      _custLabel = {for (final c in (custs as List)) c['id'] as String: "${(c['code'] != null && (c['code'] as String).isNotEmpty) ? '${c['code']} — ' : ''}${c['shop_name'] ?? ''}"};
      if (mounted) setState(() { _jobs = List<Map<String, dynamic>>.from(jobs); _loading = false; });
      _subscribe(orgId);
    } catch (e) { if (mounted) { _snack('Load failed: $e'); setState(() => _loading = false); } }
  }

  // ── Realtime: keep the board live when job_cards change anywhere ──────────
  void _subscribe(String orgId) {
    if (_channel != null) return;
    final client = Supabase.instance.client;
    _channel = client
        .channel('production_floor_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'job_cards',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'org_id', value: orgId),
          callback: (_) => _scheduleReload(),
        )
        .subscribe();
  }

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _reloadJobs);
  }

  // Lightweight refresh: re-pull jobs only (no spinner, labels stay cached).
  Future<void> _reloadJobs() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final jobs = await Supabase.instance.client.from('job_cards').select().eq('org_id', orgId)
          .order('priority', ascending: false).order('created_at', ascending: false).limit(1000);
      if (mounted) setState(() => _jobs = List<Map<String, dynamic>>.from(jobs));
    } catch (_) { /* transient; next event or manual refresh will recover */ }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _histDebounce?.cancel();
    _histSearchCtrl.dispose();
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
  }

  // ── Job History: query job_cards directly (reaches beyond the board's cap) ──
  Future<void> _loadHistory() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _histLoading = true);
    try {
      final client = Supabase.instance.client;
      final fromStr = DateFormat('yyyy-MM-dd').format(_histFrom);
      final toStr = DateFormat('yyyy-MM-dd').format(_histTo);
      var q = client.from('job_cards').select().eq('org_id', orgId)
          .gte('voucher_date', fromStr).lte('voucher_date', toStr);
      if (_histStatus != 'all') q = q.eq('status', _histStatus);
      if (_histWorker != null) q = q.eq('assigned_to', _histWorker as Object);
      final rows = await q.order('voucher_date', ascending: false).limit(2000);
      if (mounted) setState(() {
        _histJobs = List<Map<String, dynamic>>.from(rows as List);
        _histLoading = false;
        _histInit = true;
      });
    } catch (e) {
      if (mounted) setState(() { _histLoading = false; _histInit = true; });
    }
  }

  void _histQueryDebounced() {
    _histDebounce?.cancel();
    _histDebounce = Timer(const Duration(milliseconds: 350), _loadHistory);
  }

  List<Map<String, dynamic>> get _histFiltered {
    final q = _histSearch.trim().toLowerCase();
    if (q.isEmpty) return _histJobs;
    return _histJobs.where((j) {
      final num = (j['job_number'] as String? ?? '').toLowerCase();
      final prod = (_prodLabel[j['product_id']] ?? '').toLowerCase();
      final cust = (_custLabel[j['customer_id']] ?? '').toLowerCase();
      return num.contains(q) || prod.contains(q) || cust.contains(q);
    }).toList();
  }

  List<Map<String, dynamic>> get _visible {
    if (_allBranches || _branchId == null) return _jobs;
    return _jobs.where((j) => j['branch_id'] == _branchId).toList();
  }

  double _planned(Map<String, dynamic> j) => (j['planned_qty'] as num? ?? 0).toDouble();
  double _produced(Map<String, dynamic> j) => (j['produced_qty'] as num? ?? 0).toDouble();
  double _remaining(Map<String, dynamic> j) => _planned(j) - _produced(j);

  @override
  Widget build(BuildContext context) {
    final jobs = _visible;
    final queued = jobs.where((j) => (j['status'] ?? 'queued') == 'queued').toList();
    final inProg = jobs.where((j) => j['status'] == 'in_progress').toList();
    final done = jobs.where((j) => j['status'] == 'completed').toList();
    final voided = jobs.where((j) => j['status'] == 'cancelled').toList();
    final openUnits = [...queued, ...inProg].fold(0.0, (s, j) => s + _remaining(j));
    bool openJob(Map<String, dynamic> j) { final s = j['status'] ?? 'queued'; return s != 'completed' && s != 'cancelled'; }
    final onFloorJobs = jobs.where((j) => j['on_floor'] == true && openJob(j)).toList();
    final finishedAwaiting = jobs.where((j) => j['on_floor'] != true && j['floor_finished_at'] != null && openJob(j)).toList();

    return Container(color: AppTheme.background, padding: context.pagePadding, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Title, count chips and controls all flow. In a Row they overflowed the
      // moment the window narrowed; the chips ended up stacking one letter high.
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
        Text('Production Floor', style: TextStyle(fontSize: context.isMobile ? 20 : 24, fontWeight: FontWeight.w800)),
        _statChip('On the floor', onFloorJobs.length, AppTheme.primary),
        _statChip('Queued', queued.length, Colors.orange),
        _statChip('In progress', inProg.length, Colors.blue),
        _statChip('Completed', done.length, Colors.green),
        _statChip('Units to make', _trim(openUnits), Colors.deepPurple),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('All branches', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          Switch(value: _allBranches, onChanged: (v) => setState(() => _allBranches = v)),
        ]),
        ToggleButtons(
          isSelected: [_viewMode == 0, _viewMode == 1, _viewMode == 2],
          onPressed: (i) {
            setState(() => _viewMode = i);
            if (i == 2 && !_histInit) _loadHistory(); // first open → last 30 days
          },
          borderRadius: BorderRadius.circular(8),
          constraints: const BoxConstraints(minHeight: 34, minWidth: 44),
          children: const [
            Icon(Icons.view_column_outlined, size: 18),
            Icon(Icons.table_rows_outlined, size: 18),
            Icon(Icons.history, size: 18),
          ],
        ),
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
      ]),
      if (_viewMode != 2 && !_loading) _runningNowBand(onFloorJobs, finishedAwaiting),
      const SizedBox(height: 16),
      Expanded(child: _viewMode == 2
        ? _historyView()
        : _loading ? const Center(child: CircularProgressIndicator())
          : jobs.isEmpty ? const Center(child: Text('No jobs to show. Create one in Job Card.', style: TextStyle(color: AppTheme.textSecondary)))
          : _viewMode == 0 ? _kanbanView(queued, inProg, done) : _gridView([...queued, ...inProg, ...done, ...voided])),
    ]));
  }

  Widget _statChip(String label, Object value, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(color: c.withOpacity(0.10), borderRadius: BorderRadius.circular(8), border: Border.all(color: c.withOpacity(0.25))),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$value', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: c)),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    ]));

  // ── "Running now" band: every job currently On the Floor (worker scanned the
  // job-card QR, or the manager tapped "Put on floor"), regardless of the manual
  // play/pause. Plus a note for jobs a worker flagged Finished, awaiting the
  // manager to post the final batch.
  Widget _runningNowBand(List<Map<String, dynamic>> onFloor, List<Map<String, dynamic>> finished) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primary.withOpacity(0.20)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const RunningDot(size: 9),
          const SizedBox(width: 8),
          Text('Running now  ·  ${onFloor.length}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          const Spacer(),
          if (finished.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFF16A34A).withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: Text('${finished.length} finished — awaiting close', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF166534))),
            ),
        ]),
        const SizedBox(height: 10),
        if (onFloor.isEmpty && finished.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('No jobs on the floor right now. A job appears here when a worker scans its QR or the manager taps "Put on floor".', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
        else
          Wrap(spacing: 10, runSpacing: 10, children: [
            ...onFloor.map((j) => _runningCard(j, finished: false)),
            ...finished.map((j) => _runningCard(j, finished: true)),
          ]),
      ]),
    );
  }

  Widget _runningCard(Map<String, dynamic> j, {required bool finished}) {
    final c = finished ? const Color(0xFF16A34A) : AppTheme.primary;
    final planned = _planned(j); final produced = _produced(j);
    final since = j['on_floor_at'] != null ? DateTime.tryParse(j['on_floor_at'] as String)?.toLocal() : null;
    final sinceLbl = since != null ? DateFormat('d MMM, HH:mm').format(since) : null;
    return InkWell(
      onTap: () => context.go('/manufacturing/job-card?id=${j['id']}'),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.withOpacity(0.35))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (finished) Icon(Icons.flag_rounded, size: 13, color: c) else const RunningDot(size: 7),
            const SizedBox(width: 6),
            Expanded(child: Text(j['job_number'] as String? ?? '-', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: c), overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 4),
          Text(_prodLabel[j['product_id']] ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Text('${_trim(produced)} / ${_trim(planned)} made', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
          if (finished)
            const Padding(padding: EdgeInsets.only(top: 3), child: Text('Finished — post final batch', style: TextStyle(fontSize: 10.5, color: Color(0xFF166534), fontWeight: FontWeight.w600)))
          else if (sinceLbl != null)
            Padding(padding: const EdgeInsets.only(top: 3), child: Text('On floor since $sinceLbl', style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary))),
        ]),
      ),
    );
  }

  // ── Job History view: filters + results table (full history via DB) ──
  Future<void> _pickHistDate(bool isFrom) async {
    final init = isFrom ? _histFrom : _histTo;
    final d = await showDatePicker(
      context: context, initialDate: init,
      firstDate: DateTime(2020), lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() { if (isFrom) _histFrom = d; else _histTo = d; });
      _loadHistory();
    }
  }

  String _histStatusLabel(String st) => st == 'completed' ? 'Completed'
      : st == 'cancelled' ? 'Voided' : st == 'in_progress' ? 'In progress' : 'Queued';

  String _num(dynamic v) { final d = (v as num? ?? 0).toDouble(); return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString(); }

  Widget _historyView() {
    final workers = _userLabel.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    final results = _histFiltered;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(width: 240, child: TextField(
          controller: _histSearchCtrl,
          decoration: const InputDecoration(
            labelText: 'Search job / product / customer', isDense: true,
            prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
          onChanged: (v) => setState(() => _histSearch = v),
        )),
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today, size: 15),
          label: Text('From: ${DateFormat('dd MMM yyyy').format(_histFrom)}'),
          onPressed: () => _pickHistDate(true),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today, size: 15),
          label: Text('To: ${DateFormat('dd MMM yyyy').format(_histTo)}'),
          onPressed: () => _pickHistDate(false),
        ),
        SizedBox(width: 160, child: DropdownButtonFormField<String>(
          value: _histStatus, isDense: true,
          decoration: const InputDecoration(labelText: 'Status', isDense: true, border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All statuses')),
            DropdownMenuItem(value: 'queued', child: Text('Queued')),
            DropdownMenuItem(value: 'in_progress', child: Text('In progress')),
            DropdownMenuItem(value: 'completed', child: Text('Completed')),
            DropdownMenuItem(value: 'cancelled', child: Text('Voided')),
          ],
          onChanged: (v) { setState(() => _histStatus = v ?? 'all'); _loadHistory(); },
        )),
        SizedBox(width: 180, child: DropdownButtonFormField<String?>(
          value: _histWorker, isDense: true,
          decoration: const InputDecoration(labelText: 'Worker', isDense: true, border: OutlineInputBorder()),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All workers')),
            for (final w in workers) DropdownMenuItem<String?>(value: w.key, child: Text(w.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) { setState(() => _histWorker = v); _loadHistory(); },
        )),
        IconButton(icon: const Icon(Icons.refresh), tooltip: 'Reload', onPressed: _loadHistory),
      ]),
      const SizedBox(height: 12),
      Text('${results.length} job(s)', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      const SizedBox(height: 8),
      Expanded(child: _histLoading
        ? const Center(child: CircularProgressIndicator())
        : results.isEmpty
          ? const Center(child: Text('No jobs match these filters.', style: TextStyle(color: AppTheme.textSecondary)))
          : SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
              headingRowHeight: 40, dataRowMinHeight: 40, dataRowMaxHeight: 52,
              columns: const [
                DataColumn(label: Text('Job #', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                DataColumn(label: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                DataColumn(label: Text('Customer', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                DataColumn(label: Text('Status', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                DataColumn(label: Text('Planned', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: true),
                DataColumn(label: Text('Produced', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: true),
                DataColumn(label: Text('Date', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                DataColumn(label: Text('Worker', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
              ],
              rows: [for (final j in results) DataRow(
                onSelectChanged: (_) => _showTimeline(j),
                cells: [
                  DataCell(Text(j['job_number'] as String? ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                  DataCell(Text(_prodLabel[j['product_id']] ?? '—', style: const TextStyle(fontSize: 12))),
                  DataCell(Text(j['customer_id'] != null ? (_custLabel[j['customer_id']] ?? '—') : '—', style: const TextStyle(fontSize: 12))),
                  DataCell(Text(_histStatusLabel(j['status'] as String? ?? ''), style: const TextStyle(fontSize: 12))),
                  DataCell(Text(_num(j['planned_qty']), style: const TextStyle(fontSize: 12))),
                  DataCell(Text(_num(j['produced_qty']), style: const TextStyle(fontSize: 12))),
                  DataCell(Text(j['voucher_date'] as String? ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  DataCell(Text(j['assigned_to'] != null ? (_userLabel[j['assigned_to']] ?? '—') : '—', style: const TextStyle(fontSize: 12))),
                ],
              )],
            )))),
    ]);
  }

  Widget _kanbanView(List<Map<String, dynamic>> queued, List<Map<String, dynamic>> inProg, List<Map<String, dynamic>> done) {
    // Three columns at 380px gives each ~118px — a job card cannot render in that.
    // On a phone the same three lanes become tabs, so one lane gets full width.
    if (context.isMobile) {
      return _MobileKanbanTabs(
        queued: _column('Queued', Colors.orange, queued),
        inProgress: _column('In Progress', Colors.blue, inProg),
        completed: _column('Completed', Colors.green, done),
        counts: [queued.length, inProg.length, done.length],
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _column('Queued', Colors.orange, queued)),
      const SizedBox(width: 12),
      Expanded(child: _column('In Progress', Colors.blue, inProg)),
      const SizedBox(width: 12),
      Expanded(child: _column('Completed', Colors.green, done)),
    ]);
  }

  Widget _column(String title, Color c, List<Map<String, dynamic>> items) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border)), borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: Text('${items.length}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c))),
          ])),
        Expanded(child: items.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('—', style: TextStyle(color: AppTheme.textSecondary))))
          : ListView.builder(padding: const EdgeInsets.all(8), itemCount: items.length, itemBuilder: (_, i) => _card(items[i], c))),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> j, Color c) {
    final planned = _planned(j); final produced = _produced(j); final remaining = _remaining(j);
    final pct = planned > 0 ? (produced / planned).clamp(0.0, 1.0) : 0.0;
    final prio = (j['priority'] ?? 0) as int;
    final assignee = j['assigned_to'] != null ? _userLabel[j['assigned_to']] : null;
    final wc = j['work_center'] as String?;
    final customer = j['customer_id'] != null ? _custLabel[j['customer_id']] : null;
    return InkWell(
      onTap: () => context.go('/manufacturing/job-card?id=${j['id']}'),
      child: Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 4, offset: const Offset(0, 1))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (j['is_running'] == true) const Padding(padding: EdgeInsets.only(right: 6), child: RunningDot(size: 7)),
            Expanded(child: Text(j['job_number'] as String? ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800))),
            if (prio > 0) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: Colors.red.withOpacity(0.10), borderRadius: BorderRadius.circular(4)),
              child: Text('P$prio', style: const TextStyle(fontSize: 10, color: Colors.red, fontWeight: FontWeight.w700))),
            const SizedBox(width: 4),
            InkWell(onTap: () => _showTimeline(j), borderRadius: BorderRadius.circular(12),
              child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.info_outline, size: 15, color: AppTheme.textSecondary))),
          ]),
          const SizedBox(height: 3),
          Text(_prodLabel[j['product_id']] ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: pct, minHeight: 6, backgroundColor: const Color(0xFFEDEFF2), color: c)),
          const SizedBox(height: 5),
          Text('${_trim(produced)} / ${_trim(planned)} done  ·  ${_trim(remaining)} left', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          if (assignee != null || (wc != null && wc.isNotEmpty)) Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
            if (wc != null && wc.isNotEmpty) ...[const Icon(Icons.place_outlined, size: 12, color: AppTheme.textSecondary), const SizedBox(width: 3),
              Flexible(child: Text(wc, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis))],
            if (assignee != null) ...[const SizedBox(width: 8), const Icon(Icons.person_outline, size: 12, color: AppTheme.textSecondary), const SizedBox(width: 3),
              Flexible(child: Text(assignee, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis))],
          ])),
          if (customer != null && customer.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Row(children: [
            const Icon(Icons.storefront_outlined, size: 12, color: AppTheme.primary), const SizedBox(width: 3),
            Flexible(child: Text(customer, style: const TextStyle(fontSize: 10, color: AppTheme.primary, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          ])),
          if (((j['notes'] as String?)?.trim() ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.sticky_note_2_outlined, size: 12, color: AppTheme.textSecondary), const SizedBox(width: 3),
            Flexible(child: Text((j['notes'] as String).trim(), style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontStyle: FontStyle.italic), maxLines: 2, overflow: TextOverflow.ellipsis)),
          ])),
        ]),
      ),
    );
  }

  void _showTimeline(Map<String, dynamic> j) {
    showDialog(context: context, builder: (_) => _JobTimelineDialog(
      job: j,
      productLabel: _prodLabel[j['product_id']] ?? '',
    ));
  }

  Widget _gridView(List<Map<String, dynamic>> items) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
        headingRowHeight: 42, dataRowMinHeight: 40, dataRowMaxHeight: 52,
        columns: const [
          DataColumn(label: Text('Job #', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          DataColumn(label: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          DataColumn(label: Text('Customer', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          DataColumn(label: Text('Status', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          DataColumn(label: Text('Planned', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: true),
          DataColumn(label: Text('Produced', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: true),
          DataColumn(label: Text('Left', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: true),
          DataColumn(label: Text('Accepted', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: true),
          DataColumn(label: Text('Rejected', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: true),
          DataColumn(label: Text('Prio', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: true),
          DataColumn(label: Text('Work Center', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          DataColumn(label: Text('Assignee', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          DataColumn(label: Text('Date', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          DataColumn(label: Text('Remarks', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        ],
        rows: items.map((j) {
          final st = (j['status'] as String? ?? 'queued');
          final c = st == 'completed' ? Colors.green : st == 'cancelled' ? Colors.grey : st == 'in_progress' ? Colors.blue : Colors.orange;
          final lbl = st == 'completed' ? 'Completed' : st == 'cancelled' ? 'Voided' : st == 'in_progress' ? 'In progress' : 'Queued';
          return DataRow(
            onSelectChanged: (_) => context.go('/manufacturing/job-card?id=${j['id']}'),
            cells: [
              DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                InkWell(onTap: () => _showTimeline(j), borderRadius: BorderRadius.circular(12),
                  child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.info_outline, size: 15, color: AppTheme.textSecondary))),
                const SizedBox(width: 6),
                Text(j['job_number'] as String? ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ])),
              DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240), child: Text(_prodLabel[j['product_id']] ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
              DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: Text(j['customer_id'] != null ? (_custLabel[j['customer_id']] ?? '—') : '—', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
              DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                if (j['is_running'] == true) const Padding(padding: EdgeInsets.only(right: 6), child: RunningDot(size: 7)),
                Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                  child: Text(lbl, style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w700))),
              ])),
              DataCell(Text(_trim(_planned(j)), style: const TextStyle(fontSize: 12))),
              DataCell(Text(_trim(_produced(j)), style: const TextStyle(fontSize: 12))),
              DataCell(Text(_trim(_remaining(j)), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              DataCell(Text(_trim((j['accepted_qty'] as num? ?? 0).toDouble()), style: const TextStyle(fontSize: 12, color: Colors.green))),
              DataCell(Text(_trim((j['rejected_qty'] as num? ?? 0).toDouble()), style: const TextStyle(fontSize: 12, color: Colors.red))),
              DataCell(Text('${j['priority'] ?? 0}', style: const TextStyle(fontSize: 12))),
              DataCell(Text(j['work_center'] as String? ?? '—', style: const TextStyle(fontSize: 12))),
              DataCell(Text(j['assigned_to'] != null ? (_userLabel[j['assigned_to']] ?? '—') : '—', style: const TextStyle(fontSize: 12))),
              DataCell(Text(j['voucher_date'] as String? ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
              DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240),
                child: ((j['notes'] as String?)?.trim() ?? '').isEmpty
                  ? const Text('—', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
                  : Tooltip(message: (j['notes'] as String).trim(),
                      child: Text((j['notes'] as String).trim(), style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic), maxLines: 1, overflow: TextOverflow.ellipsis)))),
            ],
          );
        }).toList(),
      ))),
    );
  }
}

class _JobTimelineDialog extends StatefulWidget {
  final Map<String, dynamic> job;
  final String productLabel;
  const _JobTimelineDialog({required this.job, required this.productLabel});
  @override
  State<_JobTimelineDialog> createState() => _JobTimelineDialogState();
}

class _JobTimelineDialogState extends State<_JobTimelineDialog> {
  bool _loading = true;
  List<Map<String, dynamic>> _runs = [];
  List<Map<String, dynamic>> _audit = [];   // job_card_audit_trail (start/pause/etc)
  List<Map<String, dynamic>> _qc = [];       // qc_inspections for this job
  Map<String, String> _userNames = {};       // user_id -> name
  Timer? _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() => _now = DateTime.now()); });
    _load();
  }

  @override
  void dispose() { _ticker?.cancel(); super.dispose(); }

  Future<void> _load() async {
    final jobId = widget.job['id'] as String;
    try {
      final client = Supabase.instance.client;
      final runs = await client.from('job_card_runs').select().eq('job_card_id', jobId).order('run_no');
      List auditRows = const [];
      List qcRows = const [];
      try {
        auditRows = await client.from('job_card_audit_trail').select().eq('job_card_id', jobId).order('created_at');
      } catch (_) {}
      try {
        qcRows = await client.from('qc_inspections').select().eq('job_card_id', jobId);
      } catch (_) {}
      // resolve operator/inspector names
      final ids = <String>{};
      for (final r in (runs as List)) { final o = r['operator_id'] as String?; if (o != null) ids.add(o); }
      for (final q in qcRows) { final o = q['inspector_id'] as String?; if (o != null) ids.add(o); }
      final names = <String, String>{};
      if (ids.isNotEmpty) {
        try {
          final us = await client.from('users').select('id, name').inFilter('id', ids.toList());
          for (final u in (us as List)) { names[u['id'] as String] = (u['name'] as String?) ?? ''; }
        } catch (_) {}
      }
      if (mounted) setState(() {
        _runs = List<Map<String, dynamic>>.from(runs);
        _audit = List<Map<String, dynamic>>.from(auditRows);
        _qc = List<Map<String, dynamic>>.from(qcRows);
        _userNames = names;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Actual time on the floor = sum of (start -> stop) intervals from the audit
  // trail. A job can be started/stopped many times across days; this excludes
  // the gaps in between. If it's currently on the floor, counts up to now.
  static const _startActions = {'started', 'floor_started'};
  static const _stopActions = {'paused', 'floor_stopped', 'floor_removed', 'floor_finished', 'completed', 'cancelled'};
  Duration _activeTime() {
    DateTime? runningSince;
    Duration total = Duration.zero;
    for (final a in _audit) {
      final action = a['action'] as String?;
      final t = _ts(a['created_at'] ?? a['performed_at']);
      if (t == null || action == null) continue;
      if (_startActions.contains(action)) {
        runningSince ??= t;
      } else if (_stopActions.contains(action)) {
        if (runningSince != null) { total += t.difference(runningSince); runningSince = null; }
      }
    }
    if (runningSince != null) total += _now.difference(runningSince);
    return total;
  }
  bool get _currentlyOnFloor => widget.job['on_floor'] == true;

  String? _runOperator(Map<String, dynamic> r) {
    final id = r['operator_id'] as String?;
    if (id == null) return null;
    final n = _userNames[id];
    return (n != null && n.isNotEmpty) ? n : null;
  }

  // QC summary for a run: "QC: Finishing Quality PASS (by Ali)" per checkpoint.
  List<String> _runQc(String runId) {
    final out = <String>[];
    for (final q in _qc) {
      if (q['run_id'] != runId) continue;
      final name = q['checkpoint_name'] as String? ?? 'QC';
      final res = (q['result'] as String? ?? '').toUpperCase();
      final insId = q['inspector_id'] as String?;
      final ins = insId != null ? (_userNames[insId] ?? '') : '';
      out.add('$name: $res${ins.isNotEmpty ? ' (by $ins)' : ''}');
    }
    return out;
  }

  DateTime? _ts(dynamic v) { if (v == null) return null; try { return DateTime.parse(v as String).toLocal(); } catch (_) { return null; } }
  static String _num(dynamic v) { final d = (v as num? ?? 0).toDouble(); return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString(); }

  // Icon + colour + human label for each audit-trail action.
  (IconData, Color, String) _auditMeta(String action) {
    switch (action) {
      case 'created': return (Icons.add_circle, Colors.blue, 'Created');
      case 'acknowledged': return (Icons.how_to_reg, Colors.indigo, 'Acknowledged by manager');
      case 'started': return (Icons.play_circle_fill, Colors.green, 'Started');
      case 'floor_started': return (Icons.play_circle_fill, AppTheme.primary, 'Put on the floor');
      case 'paused': return (Icons.pause_circle_filled, Colors.orange, 'Paused');
      case 'floor_stopped': return (Icons.stop_circle, Colors.orange, 'Stopped (off the floor)');
      case 'floor_removed': return (Icons.stop_circle, Colors.orange, 'Taken off the floor');
      case 'floor_finished': return (Icons.flag_circle, Colors.green, 'Finished — ready to close');
      case 'closed_short': return (Icons.flag, Colors.brown, 'Closed short');
      case 'completed': return (Icons.check_circle, Color(0xFF15803D), 'Completed');
      case 'cancelled': return (Icons.cancel, Colors.grey, 'Cancelled / Voided');
      default:
        final label = action.isEmpty ? 'Event' : action.replaceAll('_', ' ');
        return (Icons.fiber_manual_record, AppTheme.textSecondary, '${label[0].toUpperCase()}${label.substring(1)}');
    }
  }

  String _fmtDur(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final days = d.inDays; final h = d.inHours % 24; final m = d.inMinutes % 60; final s = d.inSeconds % 60;
    if (days > 0) return '${days}d ${h}h ${m}m';
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final j = widget.job;
    final status = j['status'] as String? ?? 'queued';
    final created = _ts(j['created_at']);
    final startedReal = _ts(j['started_at']);
    DateTime? earliestRun;
    for (final r in _runs) { final t = _ts(r['created_at']) ?? _ts(r['run_date']); if (t != null && (earliestRun == null || t.isBefore(earliestRun))) earliestRun = t; }
    final bool startedBad = startedReal != null && startedReal.isAfter(_now);
    final started = (startedReal != null && !startedBad) ? startedReal : earliestRun;
    final estimated = (startedReal == null || startedBad) && started != null;
    final isDone = status == 'completed';
    final isCancelled = status == 'cancelled';

    DateTime? completed;
    if (isDone) {
      for (final r in _runs) { final t = _ts(r['created_at']) ?? _ts(r['run_date']); if (t != null && (completed == null || t.isAfter(completed))) completed = t; }
      completed ??= _ts(j['updated_at']);
    }

    // Primary metric is ACTUAL time on the floor (sum of start→stop spans),
    // not raw wall-clock since start — that was the confusing "Elapsed".
    final onFloorTotal = _activeTime();

    // Build one merged, time-ordered event list from the audit trail + batches,
    // so every start / stop / finish / batch / completion shows with who + when.
    final rows = <Map<String, dynamic>>[];
    // Created is always first (from the job itself, in case audit lacks it).
    rows.add({'t': created, 'kind': 'created'});
    for (final a in _audit) {
      final action = a['action'] as String? ?? '';
      // Batches are rendered from job_card_runs (they carry the quantities);
      // skip the audit duplicates and low-value noise.
      if (action == 'batch_posted' || action == 'updated' || action == 'created') continue;
      rows.add({'t': _ts(a['created_at'] ?? a['performed_at']), 'kind': 'audit', 'action': action, 'who': a['performed_by_name'] as String?, 'notes': a['notes'] as String?});
    }
    for (final r in _runs) {
      rows.add({'t': _ts(r['created_at']) ?? _ts(r['run_date']), 'kind': 'run', 'run': r});
    }
    // Sort by time; nulls sink to the bottom.
    rows.sort((x, y) {
      final tx = x['t'] as DateTime?; final ty = y['t'] as DateTime?;
      if (tx == null) return 1; if (ty == null) return -1;
      return tx.compareTo(ty);
    });

    final events = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final first = i == 0; final last = i == rows.length - 1;
      final t = row['t'] as DateTime?;
      if (row['kind'] == 'created') {
        events.add(_event(Icons.add_circle, Colors.blue, 'Created', t, null, first: first, last: last));
      } else if (row['kind'] == 'run') {
        final r = row['run'] as Map<String, dynamic>;
        final prod = _num(r['produced_qty']); final acc = _num(r['accepted_qty']); final rej = _num(r['rejected_qty']);
        final rstatus = r['status'] as String? ?? 'draft';
        final op = _runOperator(r);
        final qcLines = _runQc(r['id'] as String? ?? '');
        final detail = StringBuffer('Produced $prod  ·  Accepted $acc  ·  Rejected $rej');
        if (op != null) detail.write('\nBy $op');
        for (final q in qcLines) { detail.write('\n$q'); }
        events.add(_event(Icons.inventory_2, Colors.teal, 'Batch #${r['run_no'] ?? ''}${rstatus == 'posted' ? '' : ' (draft)'}', t, detail.toString(), first: first, last: last));
      } else {
        final meta = _auditMeta(row['action'] as String? ?? '');
        final who = (row['who'] as String?)?.trim();
        final notes = (row['notes'] as String?)?.trim();
        final detail = [if (who != null && who.isNotEmpty) 'By $who', if (notes != null && notes.isNotEmpty) notes].join('\n');
        events.add(_event(meta.$1, meta.$2, meta.$3, t, detail.isEmpty ? null : detail, first: first, last: last));
      }
    }

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 620),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 18, 12, 10), child: Row(children: [
            const Icon(Icons.timeline, size: 20), const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${j['job_number'] ?? ''} — Timeline', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              if (widget.productLabel.isNotEmpty) Text(widget.productLabel, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ])),
            IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(context)),
          ])),
          Container(width: double.infinity, margin: const EdgeInsets.fromLTRB(20, 0, 20, 8), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: (_currentlyOnFloor ? AppTheme.primary : Colors.deepPurple).withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              // Real work time: total spent on the floor (sum of start→stop spans).
              Row(children: [
                Row(children: [
                  Text('Time on the floor', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  if (_currentlyOnFloor) ...[
                    const SizedBox(width: 6),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                      child: const Text('on floor now', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: AppTheme.primary))),
                  ],
                ]),
                const Spacer(),
                Text(started == null && onFloorTotal == Duration.zero ? '—' : _fmtDur(onFloorTotal),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _currentlyOnFloor ? AppTheme.primary : Colors.deepPurple)),
              ]),
              const SizedBox(height: 8),
              // Calendar time (what "Elapsed" used to show) — clearly labelled so
              // it isn't mistaken for actual working time.
              Row(children: [
                Text(isDone ? 'Lead time (created → done)' : (started == null ? 'Not started yet' : 'Calendar time since started'),
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                const Spacer(),
                Text(
                  isCancelled ? 'Cancelled'
                    : started == null ? '—'
                    : isDone && completed != null ? _fmtDur(completed.difference(created ?? started))
                    : _fmtDur(_now.difference(started)),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
              ]),
            ])),
          const Divider(height: 1),
          Flexible(child: _loading
            ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: events))),
        ]),
      ),
    );
  }

  Widget _event(IconData icon, Color color, String title, DateTime? ts, String? detail, {bool first = false, bool last = false}) {
    final when = ts != null ? DateFormat('d MMM yyyy, h:mm a').format(ts) : '—';
    return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Column(children: [
        Container(width: 2, height: 6, color: first ? Colors.transparent : AppTheme.border),
        Icon(icon, size: 18, color: color),
        Expanded(child: Container(width: 2, color: last ? Colors.transparent : AppTheme.border)),
      ]),
      const SizedBox(width: 12),
      Expanded(child: Padding(padding: const EdgeInsets.only(bottom: 14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        Text(when, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        if (detail != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(detail, style: const TextStyle(fontSize: 12))),
      ]))),
    ]));
  }
}

/// The kanban's three lanes as tabs. Keeps the same columns — they just get the
/// full width one at a time instead of a third of a phone screen each.
class _MobileKanbanTabs extends StatefulWidget {
  final Widget queued, inProgress, completed;
  final List<int> counts;
  const _MobileKanbanTabs({
    required this.queued,
    required this.inProgress,
    required this.completed,
    required this.counts,
  });

  @override
  State<_MobileKanbanTabs> createState() => _MobileKanbanTabsState();
}

class _MobileKanbanTabsState extends State<_MobileKanbanTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tc = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      TabBar(
        controller: _tc,
        labelColor: AppTheme.primary,
        unselectedLabelColor: AppTheme.textSecondary,
        indicatorColor: AppTheme.primary,
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        tabs: [
          Tab(text: 'Queued (${widget.counts[0]})'),
          Tab(text: 'Active (${widget.counts[1]})'),
          Tab(text: 'Done (${widget.counts[2]})'),
        ],
      ),
      const SizedBox(height: 10),
      Expanded(
        child: TabBarView(
          controller: _tc,
          children: [widget.queued, widget.inProgress, widget.completed],
        ),
      ),
    ]);
  }
}
