import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
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
  bool _kanban = true;
  bool _allBranches = false;
  List<Map<String, dynamic>> _jobs = [];
  Map<String, String> _prodLabel = {};
  Map<String, String> _userLabel = {};
  Map<String, String> _custLabel = {};
  RealtimeChannel? _channel;
  Timer? _debounce;

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
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
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

    return Container(color: AppTheme.background, padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Production Floor', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(width: 16),
        _statChip('Queued', queued.length, Colors.orange),
        const SizedBox(width: 8),
        _statChip('In progress', inProg.length, Colors.blue),
        const SizedBox(width: 8),
        _statChip('Completed', done.length, Colors.green),
        const SizedBox(width: 8),
        _statChip('Units to make', _trim(openUnits), Colors.deepPurple),
        const Spacer(),
        Row(children: [
          const Text('All branches', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          Switch(value: _allBranches, onChanged: (v) => setState(() => _allBranches = v)),
        ]),
        const SizedBox(width: 8),
        ToggleButtons(
          isSelected: [_kanban, !_kanban],
          onPressed: (i) => setState(() => _kanban = i == 0),
          borderRadius: BorderRadius.circular(8),
          constraints: const BoxConstraints(minHeight: 34, minWidth: 44),
          children: const [Icon(Icons.view_column_outlined, size: 18), Icon(Icons.table_rows_outlined, size: 18)],
        ),
        const SizedBox(width: 8),
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
      ]),
      const SizedBox(height: 16),
      Expanded(child: _loading ? const Center(child: CircularProgressIndicator())
        : jobs.isEmpty ? const Center(child: Text('No jobs to show. Create one in Job Card.', style: TextStyle(color: AppTheme.textSecondary)))
        : _kanban ? _kanbanView(queued, inProg, done) : _gridView([...queued, ...inProg, ...done, ...voided])),
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

  Widget _kanbanView(List<Map<String, dynamic>> queued, List<Map<String, dynamic>> inProg, List<Map<String, dynamic>> done) {
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
    try {
      final runs = await Supabase.instance.client.from('job_card_runs')
          .select().eq('job_card_id', widget.job['id'] as String).order('run_no');
      if (mounted) setState(() { _runs = List<Map<String, dynamic>>.from(runs as List); _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  DateTime? _ts(dynamic v) { if (v == null) return null; try { return DateTime.parse(v as String).toLocal(); } catch (_) { return null; } }
  static String _num(dynamic v) { final d = (v as num? ?? 0).toDouble(); return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString(); }

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

    String timerLabel; String timerValue; Color timerColor;
    if (isCancelled) { timerLabel = 'Status'; timerValue = 'Cancelled'; timerColor = Colors.grey; }
    else if (started == null) { timerLabel = 'Not started'; timerValue = '—'; timerColor = Colors.orange; }
    else if (isDone && completed != null) { timerLabel = 'Total time'; timerValue = _fmtDur(completed.difference(started)); timerColor = Colors.green.shade700; }
    else { timerLabel = estimated ? 'Elapsed (since first batch)' : 'Elapsed'; timerValue = _fmtDur(_now.difference(started)); timerColor = AppTheme.primary; }

    final events = <Widget>[];
    events.add(_event(Icons.add_circle, Colors.blue, 'Created', created, null, first: true));
    if (startedReal != null && !startedBad) events.add(_event(Icons.play_circle_fill, Colors.green, 'Started', startedReal, null));
    for (final r in _runs) {
      final rt = _ts(r['created_at']) ?? _ts(r['run_date']);
      final prod = _num(r['produced_qty']); final acc = _num(r['accepted_qty']); final rej = _num(r['rejected_qty']);
      final rstatus = r['status'] as String? ?? 'draft';
      events.add(_event(Icons.inventory_2, Colors.teal, 'Batch #${r['run_no'] ?? ''}${rstatus == 'posted' ? '' : ' (draft)'}', rt,
        'Produced $prod  ·  Accepted $acc  ·  Rejected $rej'));
    }
    if (isDone) events.add(_event(Icons.check_circle, Colors.green.shade700, 'Completed', completed, null, last: true));
    else if (isCancelled) events.add(_event(Icons.cancel, Colors.grey, 'Cancelled', _ts(j['updated_at']), null, last: true));

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
            decoration: BoxDecoration(color: timerColor.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Text(timerLabel, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const Spacer(),
              Text(timerValue, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: timerColor)),
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
