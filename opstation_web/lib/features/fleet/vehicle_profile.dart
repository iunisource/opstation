import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import 'fleet_common.dart';

/// Vehicle profile (Logistics → Fleet). [readOnly] is the view opened from the
/// Dispatch Dashboard: everything visible, nothing editable.
Future<void> showVehicleProfile(BuildContext context, String vehicleId,
    {bool readOnly = false, VoidCallback? onChanged, Future<void> Function(Map<String, dynamic>)? onEdit}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 900, maxHeight: MediaQuery.of(ctx).size.height * 0.9),
        child: VehicleProfile(vehicleId: vehicleId, readOnly: readOnly, onChanged: onChanged, onEdit: onEdit),
      ),
    ),
  );
}

class VehicleProfile extends StatefulWidget {
  final String vehicleId;
  final bool readOnly;
  final VoidCallback? onChanged;
  final Future<void> Function(Map<String, dynamic>)? onEdit;
  const VehicleProfile({super.key, required this.vehicleId, this.readOnly = false, this.onChanged, this.onEdit});
  @override
  State<VehicleProfile> createState() => _VehicleProfileState();
}

class _VehicleProfileState extends State<VehicleProfile> {
  Map<String, dynamic>? _v;
  List<Map<String, dynamic>> _services = [], _log = [], _tasks = [], _miles = [];
  Map<String, String> _users = {};
  num _lead = 200;
  bool _loading = true;
  int _photo = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await fleetDb.from('fleet_vehicles').select().eq('id', widget.vehicleId).maybeSingle();
      if (v == null) { if (mounted) setState(() => _loading = false); return; }
      final org = v['org_id'] as String;
      final r = await Future.wait([
        fleetDb.from('fleet_services').select().eq('vehicle_id', widget.vehicleId).eq('is_active', true).order('created_at'),
        fleetDb.from('fleet_service_log').select().eq('vehicle_id', widget.vehicleId).order('done_date', ascending: false).limit(100),
        fleetDb.from('fleet_tasks').select().eq('vehicle_id', widget.vehicleId).order('opened_at', ascending: false).limit(100),
        fleetDb.from('fleet_mileage_log').select().eq('vehicle_id', widget.vehicleId).order('log_date', ascending: false).order('created_at', ascending: false).limit(120),
        fleetDb.from('users').select('id, name').eq('org_id', org),
      ]);
      final lead = await fleetLeadKm(org);
      if (!mounted) return;
      setState(() {
        _v = v;
        _services = List<Map<String, dynamic>>.from(r[0] as List);
        _log = List<Map<String, dynamic>>.from(r[1] as List);
        _tasks = List<Map<String, dynamic>>.from(r[2] as List);
        _miles = List<Map<String, dynamic>>.from(r[3] as List);
        _users = {for (final u in r[4] as List) '${u['id']}': '${u['name'] ?? ''}'};
        _lead = lead;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _changed() {
    widget.onChanged?.call();
    _load();
  }

  void _snack(String m) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));

  num get _odo => (_v?['odometer'] as num?) ?? 0;
  List<String> get _photos => [for (final p in (_v?['photos'] as List? ?? const [])) '$p'];
  String get _drivers => [for (final id in (_v?['driver_ids'] as List? ?? const [])) _users['$id'] ?? '—'].join(', ');

  num get _monthKm {
    final n = DateTime.now();
    num t = 0;
    for (final m in _miles) {
      final d = DateTime.tryParse('${m['log_date']}');
      if (d != null && d.year == n.year && d.month == n.month && m['source'] == 'auto') t += (m['km'] as num?) ?? 0;
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox(height: 300, child: Center(child: CircularProgressIndicator()));
    final v = _v;
    if (v == null) {
      return const SizedBox(height: 200, child: Center(child: Text('Vehicle not found.')));
    }
    final state = vehicleState(_services, _odo, _lead);
    final openTasks = _tasks.where((t) => t['status'] == 'open').length;
    return DefaultTabController(
      length: 4,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 8, 6),
          child: Wrap(spacing: 18, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.start, children: [
            _gallery(v),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text('${v['reg_no'] ?? ''}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
                  const SizedBox(width: 8),
                  _statePill(state),
                ]),
                const SizedBox(height: 3),
                Text([
                  vehicleTitle(v),
                  if ((v['colour'] ?? '') != '') '${v['colour']}',
                  if ((v['fuel'] ?? '') != '') '${v['fuel']}',
                ].where((x) => x.isNotEmpty).join(' · '), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                if (_drivers.isNotEmpty)
                  Text('Driver: $_drivers', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                const SizedBox(height: 12),
                Wrap(spacing: 28, runSpacing: 8, children: [
                  _big('Odometer', km(_odo)),
                  _big('This month', '+${km(_monthKm)}', small: true),
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(onPressed: _print, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
                  if (!widget.readOnly && widget.onEdit != null)
                    OutlinedButton.icon(
                      onPressed: () async { await widget.onEdit!(v); _changed(); },
                      icon: const Icon(Icons.edit_outlined, size: 16), label: const Text('Edit')),
                  if (!widget.readOnly)
                    OutlinedButton.icon(onPressed: _addReading, icon: const Icon(Icons.speed_outlined, size: 16), label: const Text('Odometer reading')),
                  if (widget.readOnly)
                    TextButton(
                      onPressed: () { Navigator.pop(context); context.go('/fleet?v=${v['id']}'); },
                      child: const Text('Open in Fleet')),
                ]),
              ]),
            ),
          ]),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ),
        TabBar(isScrollable: true, labelColor: AppTheme.primary, tabs: [
          const Tab(text: 'Service plan'),
          Tab(text: 'Repairs & tasks${openTasks > 0 ? ' ($openTasks)' : ''}'),
          const Tab(text: 'Mileage log'),
          const Tab(text: 'History'),
        ]),
        Flexible(
          child: SizedBox(
            height: 380,
            child: TabBarView(children: [_servicesTab(), _tasksTab(), _milesTab(), _historyTab()]),
          ),
        ),
      ]),
    );
  }

  Widget _big(String l, String v, {bool small = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        Text(v, style: TextStyle(fontSize: small ? 22 : 30, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
      ]);

  Widget _statePill(String st) {
    final c = st == 'overdue' ? const Color(0xFFDC2626) : st == 'due' ? const Color(0xFFD97706) : const Color(0xFF059669);
    final t = st == 'overdue' ? 'Overdue' : st == 'due' ? 'Service due soon' : 'Good';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(999)),
      child: Text(t, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _gallery(Map v) {
    final ph = _photos;
    final main = Container(
      width: 220, height: 140,
      decoration: BoxDecoration(color: const Color(0xFFDBEAFE), borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ph.isEmpty
          ? Icon(vehicleIcon(v['vehicle_type'] as String?), size: 64, color: AppTheme.primary)
          : Image.network(ph[_photo.clamp(0, ph.length - 1)], fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      main,
      if (ph.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(spacing: 6, children: [
            for (var i = 0; i < ph.length; i++)
              InkWell(
                onTap: () => setState(() => _photo = i),
                child: Container(
                  width: 46, height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: i == _photo ? AppTheme.primary : AppTheme.border, width: i == _photo ? 2 : 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.network(ph[i], fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
                ),
              ),
          ]),
        ),
    ]);
  }

  // ── tabs ──────────────────────────────────────────────────────────────────
  Widget _servicesTab() => ListView(padding: const EdgeInsets.all(14), children: [
        if (_services.isEmpty)
          const Padding(padding: EdgeInsets.all(8), child: Text('No regular services set.', style: TextStyle(color: AppTheme.textSecondary))),
        for (final s in _services) _serviceCard(s),
        if (!widget.readOnly)
          Align(alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: () => _editService(null), icon: const Icon(Icons.add, size: 16), label: const Text('Add a service'))),
      ]);

  Widget _serviceCard(Map<String, dynamic> s) {
    final st = serviceState(s, _odo, _lead);
    final everyKm = (s['every_km'] as num?) ?? 0;
    final months = (s['every_months'] as num?) ?? 0;
    final since = everyKm > 0 ? _odo - ((s['last_km'] as num?) ?? 0) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Wrap(spacing: 14, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 180,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text([
              if (everyKm > 0) 'every ${km(everyKm)}',
              if (months > 0) 'every $months month${months == 1 ? '' : 's'}',
            ].join(' or '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ]),
        ),
        SizedBox(
          width: 200,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: st.progress.clamp(0, 1).toDouble(), minHeight: 7,
                backgroundColor: const Color(0xFFE2E8F0), color: st.color),
          ),
        ),
        if (since != null) Text('${km(since)} / ${km(everyKm)}', style: const TextStyle(fontSize: 12.5)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: st.color.withOpacity(0.12), borderRadius: BorderRadius.circular(999)),
          child: Text(st.label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: st.color)),
        ),
        if (!widget.readOnly) ...[
          OutlinedButton(onPressed: () => _markDone(s), child: const Text('Mark done')),
          IconButton(tooltip: 'Edit', onPressed: () => _editService(s), icon: const Icon(Icons.edit_outlined, size: 18)),
        ],
      ]),
    );
  }

  Widget _tasksTab() => ListView(padding: const EdgeInsets.all(14), children: [
        if (_tasks.isEmpty)
          const Padding(padding: EdgeInsets.all(8), child: Text('No repairs or tasks.', style: TextStyle(color: AppTheme.textSecondary))),
        for (final t in _tasks)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(t['kind'] == 'task' ? Icons.task_alt_outlined : Icons.build_outlined, size: 18, color: AppTheme.textSecondary),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${t['kind'] == 'task' ? 'Task' : 'Repair'} · ${t['title']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                Text([
                  'Opened ${fdate(t['opened_at'])}${(t['opened_by_name'] ?? '') != '' ? ' by ${t['opened_by_name']}' : ''}',
                  if ((t['workshop'] ?? '') != '') 'at ${t['workshop']}',
                  if (t['est_cost'] != null) 'est. ${rs(t['est_cost'] as num)}',
                  if (t['actual_cost'] != null) 'cost ${rs(t['actual_cost'] as num)}',
                  if (t['status'] == 'closed') 'closed ${fdate(t['closed_at'])}${(t['closed_by_name'] ?? '') != '' ? ' by ${t['closed_by_name']}' : ''}',
                ].join(' · '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                if ((t['note'] ?? '') != '') Text('${t['note']}', style: const TextStyle(fontSize: 12)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: t['status'] == 'open' ? const Color(0xFFF1F5F9) : const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(999)),
                child: Text(t['status'] == 'open' ? 'Ongoing' : 'Closed',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                        color: t['status'] == 'open' ? const Color(0xFF475569) : const Color(0xFF047857))),
              ),
              if (!widget.readOnly && t['status'] == 'open') ...[
                const SizedBox(width: 6),
                OutlinedButton(onPressed: () => _closeTask(t), child: const Text('Close')),
              ],
            ]),
          ),
        if (!widget.readOnly)
          Align(alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _addTask, icon: const Icon(Icons.add, size: 16), label: const Text('Add repair or task'))),
      ]);

  Widget _milesTab() => ListView(padding: const EdgeInsets.all(14), children: [
        Text('Started at ${km(_v?['start_odometer'] as num?)} on ${fdate(_v?['start_date'])}. '
            'Km are added every day from the drivers\' trips and deliveries.',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        if (_miles.isEmpty)
          const Padding(padding: EdgeInsets.all(8), child: Text('Nothing yet.', style: TextStyle(color: AppTheme.textSecondary))),
        for (final m in _miles)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9)))),
            child: Row(children: [
              SizedBox(width: 100, child: Text(fdate(m['log_date']), style: const TextStyle(fontSize: 12.5))),
              SizedBox(
                width: 90,
                child: Text('${((m['km'] as num?) ?? 0) >= 0 ? '+' : '−'}${km(((m['km'] as num?) ?? 0).abs())}',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
              SizedBox(width: 100, child: Text(km(m['odometer_after'] as num?), style: const TextStyle(fontSize: 12.5))),
              Expanded(child: Text(
                m['source'] == 'reading'
                    ? 'Odometer reading ${km(m['reading'] as num?)}${(m['by_name'] ?? '') != '' ? ' by ${m['by_name']}' : ''}${(m['ref'] ?? '') != '' && m['ref'] != 'Odometer reading' ? ' · ${m['ref']}' : ''}'
                    : 'Trips & deliveries${_drivers.isNotEmpty ? ' · $_drivers' : ''}',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
            ]),
          ),
      ]);

  Widget _historyTab() => ListView(padding: const EdgeInsets.all(14), children: [
        if (_log.isEmpty)
          const Padding(padding: EdgeInsets.all(8), child: Text('No services recorded yet.', style: TextStyle(color: AppTheme.textSecondary))),
        for (final l in _log)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9)))),
            child: Row(children: [
              SizedBox(width: 100, child: Text(fdate(l['done_date']), style: const TextStyle(fontSize: 12.5))),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l['service_name'] ?? ''}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text([
                  if (l['odometer'] != null) 'at ${km(l['odometer'] as num)}',
                  if (l['cost'] != null) rs(l['cost'] as num),
                  if ((l['done_by_name'] ?? '') != '') 'by ${l['done_by_name']}',
                  if ((l['note'] ?? '') != '') '${l['note']}',
                ].join(' · '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
              ])),
            ]),
          ),
      ]);

  // ── actions ───────────────────────────────────────────────────────────────
  Future<Map<String, String>?> _form(String title, List<(String, String, String, bool)> fields, {String ok = 'Save'}) async {
    final ctrls = {for (final f in fields) f.$1: TextEditingController(text: f.$3)};
    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final f in fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: ctrls[f.$1],
                  keyboardType: f.$4 ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
                  inputFormatters: f.$4 ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))] : null,
                  decoration: InputDecoration(labelText: f.$2, isDense: true, border: const OutlineInputBorder()),
                ),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, {for (final e in ctrls.entries) e.key: e.value.text.trim()}), child: Text(ok)),
        ],
      ),
    );
  }

  Future<void> _markDone(Map<String, dynamic> s) async {
    final r = await _form('${s['name']} done', [
      ('odo', 'Odometer at service (km)', _odo.round().toString(), true),
      ('cost', 'Cost (Rs, optional)', '', true),
      ('note', 'Note (workshop, parts…)', '', false),
    ], ok: 'Mark done');
    if (r == null) return;
    try {
      await fleetDb.rpc('fleet_service_done', params: {
        'p_service': s['id'],
        'p_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'p_odometer': num.tryParse(r['odo'] ?? ''),
        'p_cost': num.tryParse(r['cost'] ?? ''),
        'p_note': r['note'],
      });
      _changed();
    } catch (e) {
      _snack(friendlyError('Could not save', e));
    }
  }

  Future<void> _editService(Map<String, dynamic>? s) async {
    final r = await _form(s == null ? 'Add a service' : 'Edit ${s['name']}', [
      ('name', 'Service (e.g. Oil change)', '${s?['name'] ?? ''}', false),
      ('km', 'Every … km (optional)', s?['every_km'] == null ? '' : '${s!['every_km']}', true),
      ('months', 'Every … months (optional)', s?['every_months'] == null ? '' : '${s!['every_months']}', true),
      ('last', 'Last done at (km)', '${s?['last_km'] ?? _odo.round()}', true),
    ]);
    if (r == null || (r['name'] ?? '').isEmpty) return;
    final payload = {
      'name': r['name'],
      'every_km': num.tryParse(r['km'] ?? ''),
      'every_months': int.tryParse(r['months'] ?? ''),
      'last_km': num.tryParse(r['last'] ?? ''),
      'last_date': s?['last_date'] ?? DateFormat('yyyy-MM-dd').format(DateTime.now()),
    };
    try {
      if (s == null) {
        await fleetDb.from('fleet_services').insert({...payload, 'org_id': _v!['org_id'], 'vehicle_id': _v!['id']});
      } else {
        await fleetDb.from('fleet_services').update(payload).eq('id', s['id']);
      }
      _changed();
    } catch (e) {
      _snack(friendlyError('Could not save', e));
    }
  }

  Future<void> _addTask() async {
    String kind = 'repair';
    final title = TextEditingController(), shop = TextEditingController(), est = TextEditingController(), note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Add repair or task'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'repair', label: Text('Repair')), ButtonSegment(value: 'task', label: Text('Task'))],
              selected: {kind},
              onSelectionChanged: (v) => setS(() => kind = v.first),
            ),
            const SizedBox(height: 12),
            TextField(controller: title, decoration: const InputDecoration(labelText: 'What (e.g. Clutch plate)', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: shop, decoration: const InputDecoration(labelText: 'Workshop (optional)', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: est, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Estimated cost (optional)', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)', isDense: true, border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      )),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    try {
      final me = await fleetDb.rpc('fleet_my_name', params: {'p_org': _v!['org_id']}).catchError((_) => null);
      await fleetDb.from('fleet_tasks').insert({
        'org_id': _v!['org_id'], 'vehicle_id': _v!['id'], 'kind': kind, 'title': title.text.trim(),
        'workshop': shop.text.trim().isEmpty ? null : shop.text.trim(),
        'est_cost': num.tryParse(est.text.trim()),
        'note': note.text.trim().isEmpty ? null : note.text.trim(),
        'opened_by_name': me is String ? me : null,
      });
      _changed();
    } catch (e) {
      _snack(friendlyError('Could not add', e));
    }
  }

  Future<void> _closeTask(Map<String, dynamic> t) async {
    final r = await _form('Close: ${t['title']}', [
      ('cost', 'Actual cost (Rs, optional)', '', true),
      ('note', 'Note (optional)', '${t['note'] ?? ''}', false),
    ], ok: 'Close');
    if (r == null) return;
    try {
      final me = await fleetDb.rpc('fleet_my_name', params: {'p_org': _v!['org_id']}).catchError((_) => null);
      await fleetDb.from('fleet_tasks').update({
        'status': 'closed',
        'actual_cost': num.tryParse(r['cost'] ?? ''),
        'note': (r['note'] ?? '').isEmpty ? null : r['note'],
        'closed_at': DateTime.now().toUtc().toIso8601String(),
        'closed_by_name': me is String ? me : null,
      }).eq('id', t['id']);
      _changed();
    } catch (e) {
      _snack(friendlyError('Could not close', e));
    }
  }

  Future<void> _addReading() async {
    final r = await _form('Odometer reading', [
      ('km', 'Reading on the meter (km)', '', true),
      ('note', 'Note (optional)', '', false),
    ]);
    final val = num.tryParse(r?['km'] ?? '');
    if (r == null || val == null) return;
    try {
      await fleetDb.rpc('fleet_add_reading', params: {
        'p_vehicle': _v!['id'],
        'p_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'p_reading': val,
        'p_note': r['note'],
      });
      _changed();
    } catch (e) {
      _snack(friendlyError('Could not save', e));
    }
  }

  void _print() {
    final v = _v!;
    final b = StringBuffer()
      ..write('<h1>${esc(v['reg_no'])}</h1>')
      ..write('<div class="meta">${esc(vehicleTitle(v))}${_drivers.isNotEmpty ? ' · Driver: ${esc(_drivers)}' : ''}</div>');
    if (_photos.isNotEmpty) {
      b.write('<div class="photos">');
      for (final p in _photos) { b.write('<img src="${esc(p)}">'); }
      b.write('</div>');
    }
    b.write('<table><tr><th>Odometer</th><th>Started at</th><th>Colour</th><th>Fuel</th><th>Engine no.</th><th>Chassis no.</th></tr>'
        '<tr><td>${esc(km(_odo))}</td><td>${esc(km(v['start_odometer'] as num?))} on ${esc(fdate(v['start_date']))}</td>'
        '<td>${esc(v['colour'])}</td><td>${esc(v['fuel'])}</td><td>${esc(v['engine_no'])}</td><td>${esc(v['chassis_no'])}</td></tr></table>');
    b.write('<h2>Service plan</h2><table><tr><th>Service</th><th>Every</th><th>Last done</th><th>Status</th></tr>');
    for (final s in _services) {
      final st = serviceState(s, _odo, _lead);
      b.write('<tr><td>${esc(s['name'])}</td><td>${esc([
        if (((s['every_km'] as num?) ?? 0) > 0) km(s['every_km'] as num),
        if (((s['every_months'] as num?) ?? 0) > 0) '${s['every_months']} months',
      ].join(' or '))}</td><td>${esc([if (s['last_km'] != null) km(s['last_km'] as num), fdate(s['last_date'])].where((x) => x.isNotEmpty).join(' · '))}</td>'
          '<td class="${st.state}">${esc(st.label)}</td></tr>');
    }
    b.write('</table><h2>Repairs & tasks</h2><table><tr><th>Opened</th><th>What</th><th>Workshop</th><th class="num">Cost</th><th>Status</th></tr>');
    for (final t in _tasks) {
      final c = (t['actual_cost'] ?? t['est_cost']) as num?;
      b.write('<tr><td>${esc(fdate(t['opened_at']))}</td><td>${esc(t['title'])}</td><td>${esc(t['workshop'])}</td>'
          '<td class="num">${c == null ? '' : esc(rs(c))}</td><td>${t['status'] == 'open' ? 'Ongoing' : 'Closed ${esc(fdate(t['closed_at']))}'}</td></tr>');
    }
    b.write('</table><h2>Service history</h2><table><tr><th>Date</th><th>Service</th><th class="num">Odometer</th><th class="num">Cost</th><th>Note</th></tr>');
    for (final l in _log) {
      b.write('<tr><td>${esc(fdate(l['done_date']))}</td><td>${esc(l['service_name'])}</td>'
          '<td class="num">${l['odometer'] == null ? '' : esc(km(l['odometer'] as num))}</td>'
          '<td class="num">${l['cost'] == null ? '' : esc(rs(l['cost'] as num))}</td><td>${esc(l['note'])}</td></tr>');
    }
    b.write('</table><h2>Mileage log</h2><table><tr><th>Date</th><th class="num">Added</th><th class="num">Odometer</th><th>From</th></tr>');
    for (final m in _miles.take(60)) {
      b.write('<tr><td>${esc(fdate(m['log_date']))}</td><td class="num">${esc(km(m['km'] as num?))}</td>'
          '<td class="num">${esc(km(m['odometer_after'] as num?))}</td>'
          '<td>${m['source'] == 'reading' ? 'Odometer reading${(m['by_name'] ?? '') != '' ? ' by ${esc(m['by_name'])}' : ''}' : 'Trips & deliveries'}</td></tr>');
    }
    b.write('</table>');
    openPrint('Vehicle ${v['reg_no']}', b.toString());
  }
}
