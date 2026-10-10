import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/permissions/access_control.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// HR ▸ HR Setup — Departments, Designations and Shifts (with the company
/// weekly rest day and payroll defaults). Moved here from the Employee
/// Directory header. Permission: doc.hr_setup (registry).
class HrSetupScreen extends ConsumerStatefulWidget {
  final String? initialTab; // departments | designations | shifts
  const HrSetupScreen({super.key, this.initialTab});
  @override
  ConsumerState<HrSetupScreen> createState() => _HrSetupScreenState();
}

class _HrSetupScreenState extends ConsumerState<HrSetupScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: switch (widget.initialTab) { 'designations' => 1, 'shifts' => 2, _ => 0 },
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(accessSyncProvider);
    final canEdit = (access?.canEditDoc('hr_setup') ?? false) || (access?.canAddDoc('hr_setup') ?? false);
    final orgId = ref.watch(currentUserProvider)?.orgId;
    final narrow = MediaQuery.of(context).size.width < 700;
    if (orgId == null) return const Center(child: Text('No organization on this session.'));
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 12 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('HR Setup',
                style: TextStyle(fontSize: narrow ? 20 : 24, fontWeight: FontWeight.w800)),
          ),
          if (!canEdit)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(6)),
              child: const Text('View only', style: TextStyle(fontSize: 11)),
            ),
        ]),
        const SizedBox(height: 4),
        const Text('Departments, designations and shifts used in employee profiles, attendance and payroll.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
          child: TabBar(
            controller: _tabs,
            isScrollable: narrow,
            labelColor: AppTheme.primary,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.primary,
            tabs: const [
              Tab(icon: Icon(Icons.apartment_outlined, size: 18), text: 'Departments'),
              Tab(icon: Icon(Icons.work_outline, size: 18), text: 'Designations'),
              Tab(icon: Icon(Icons.schedule_outlined, size: 18), text: 'Shifts'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TabBarView(controller: _tabs, children: [
            _LookupTab(orgId: orgId, table: 'hr_departments', idPrefix: 'dept_', noun: 'department', fk: 'department_id', canEdit: canEdit),
            _LookupTab(orgId: orgId, table: 'hr_designations', idPrefix: 'desig_', noun: 'designation', fk: 'designation_id', canEdit: canEdit),
            _ShiftsTab(orgId: orgId, canEdit: canEdit),
          ]),
        ),
      ]),
    );
  }
}

void _snack(BuildContext context, String m) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));
}

// ── Departments / Designations ─────────────────────────────────────────────
class _LookupTab extends StatefulWidget {
  final String orgId, table, idPrefix, noun, fk;
  final bool canEdit;
  const _LookupTab({required this.orgId, required this.table, required this.idPrefix, required this.noun, required this.fk, required this.canEdit});
  @override
  State<_LookupTab> createState() => _LookupTabState();
}

class _LookupTabState extends State<_LookupTab> with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  Map<String, int> _count = {};
  final _add = TextEditingController();
  String _q = '';

  @override
  bool get wantKeepAlive => true;

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await _db.from(widget.table).select('id, name, is_active').eq('org_id', widget.orgId).order('name');
      final emps = await _db.from('hr_employees').select('${widget.fk}, status').eq('org_id', widget.orgId);
      final c = <String, int>{};
      for (final e in emps as List) {
        if (e['status'] == 'left') continue;
        final k = e[widget.fk] as String?;
        if (k != null) c[k] = (c[k] ?? 0) + 1;
      }
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(rows);
        _count = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(context, 'Could not load ${widget.noun}s: $e');
    }
  }

  bool _exists(String name, {String? exceptId}) => _rows.any((r) =>
      r['id'] != exceptId && ((r['name'] as String?) ?? '').trim().toLowerCase() == name.trim().toLowerCase());

  Future<void> _create() async {
    final t = _add.text.trim();
    if (t.isEmpty) return;
    if (_exists(t)) {
      _snack(context, '"$t" already exists.');
      return;
    }
    try {
      await _db.from(widget.table).insert({
        'id': widget.idPrefix + DateTime.now().millisecondsSinceEpoch.toString(),
        'org_id': widget.orgId,
        'name': t,
        'is_active': true,
      });
      _add.clear();
      await _load();
    } catch (e) {
      _snack(context, 'Add failed: $e');
    }
  }

  Future<void> _rename(Map<String, dynamic> r) async {
    final ctrl = TextEditingController(text: r['name'] as String? ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rename ${widget.noun}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (x) => Navigator.pop(ctx, x),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    final t = v?.trim() ?? '';
    if (t.isEmpty || t == r['name']) return;
    if (_exists(t, exceptId: r['id'] as String?)) {
      _snack(context, '"$t" already exists.');
      return;
    }
    try {
      await _db.from(widget.table).update({'name': t}).eq('id', r['id'] as String);
      await _load();
    } catch (e) {
      _snack(context, 'Rename failed: $e');
    }
  }

  Future<void> _toggle(Map<String, dynamic> r, bool v) async {
    try {
      await _db.from(widget.table).update({'is_active': v}).eq('id', r['id'] as String);
      await _load();
    } catch (e) {
      _snack(context, 'Update failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final shown = _q.isEmpty
        ? _rows
        : _rows.where((r) => ((r['name'] as String?) ?? '').toLowerCase().contains(_q.toLowerCase())).toList();
    return Container(
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (widget.canEdit)
            SizedBox(
              width: 320,
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _add,
                    onSubmitted: (_) => _create(),
                    decoration: InputDecoration(
                        hintText: 'New ${widget.noun}', isDense: true, border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(onPressed: _create, icon: const Icon(Icons.add, size: 16), label: const Text('Add')),
              ]),
            ),
          SizedBox(
            width: 240,
            child: TextField(
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search', isDense: true, border: OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Text('${_rows.where((r) => r['is_active'] != false).length} active · ${_rows.length} total',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : shown.isEmpty
                  ? Center(
                      child: Text(_rows.isEmpty ? 'No ${widget.noun}s yet' : 'No match',
                          style: const TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: shown.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = shown[i];
                        final active = r['is_active'] != false;
                        final n = _count[r['id']] ?? 0;
                        return ListTile(
                          dense: true,
                          title: Text(r['name'] as String? ?? '',
                              style: TextStyle(
                                  fontSize: 13.5,
                                  color: active ? AppTheme.textPrimary : AppTheme.textSecondary,
                                  decoration: active ? null : TextDecoration.lineThrough)),
                          subtitle: Text('$n employee${n == 1 ? '' : 's'}${active ? '' : ' · inactive (hidden from new selections)'}',
                              style: const TextStyle(fontSize: 11)),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (widget.canEdit)
                              IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 17),
                                  tooltip: 'Rename',
                                  onPressed: () => _rename(r)),
                            Switch(value: active, onChanged: widget.canEdit ? (v) => _toggle(r, v) : null),
                          ]),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}

// ── Shifts (+ company rest day and payroll defaults) ───────────────────────
class _ShiftsTab extends StatefulWidget {
  final String orgId;
  final bool canEdit;
  const _ShiftsTab({required this.orgId, required this.canEdit});
  @override
  State<_ShiftsTab> createState() => _ShiftsTabState();
}

class _ShiftsTabState extends State<_ShiftsTab> with AutomaticKeepAliveClientMixin {
  static const _dayNames = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

  bool _loading = true;
  List<Map<String, dynamic>> _shifts = [];
  Map<String, int> _count = {};
  int? _restDay;
  final _defPl = TextEditingController();
  final _defRest = TextEditingController();

  // form
  String? _editId, _start, _end;
  final _name = TextEditingController();
  final _grace = TextEditingController(text: '0');
  final _half = TextEditingController();
  final _penDays = TextEditingController(text: '1');
  final _pl = TextEditingController();
  final _restMin = TextEditingController();
  bool _penalize = false;
  bool _saving = false;

  @override
  bool get wantKeepAlive => true;

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_defPl, _defRest, _name, _grace, _half, _penDays, _pl, _restMin]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await _db.from('hr_shifts').select().eq('org_id', widget.orgId).order('name');
      final cfg = await _db
          .from('app_config')
          .select('key, value')
          .eq('org_id', widget.orgId)
          .inFilter('key', ['org.weekly_rest_day', 'hr.paid_leave_days', 'hr.rest_day_min_days']);
      final emps = await _db.from('hr_employees').select('shift_id, status').eq('org_id', widget.orgId);
      final c = <String, int>{};
      for (final e in emps as List) {
        if (e['status'] == 'left') continue;
        final k = e['shift_id'] as String?;
        if (k != null) c[k] = (c[k] ?? 0) + 1;
      }
      int? rest;
      var pl = '', rmin = '';
      for (final r in cfg as List) {
        if (r['key'] == 'org.weekly_rest_day') rest = int.tryParse('${r['value'] ?? ''}');
        if (r['key'] == 'hr.paid_leave_days') pl = '${r['value'] ?? ''}';
        if (r['key'] == 'hr.rest_day_min_days') rmin = '${r['value'] ?? ''}';
      }
      if (!mounted) return;
      setState(() {
        _shifts = List<Map<String, dynamic>>.from(rows);
        _count = c;
        _restDay = rest;
        _defPl.text = pl;
        _defRest.text = rmin.isEmpty ? '3' : rmin;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(context, 'Could not load shifts: $e');
    }
  }

  Future<void> _saveRestDay(int? day) async {
    try {
      await _db.from('app_config').upsert({
        'org_id': widget.orgId,
        'key': 'org.weekly_rest_day',
        'value': day?.toString() ?? '',
      }, onConflict: 'key,org_id,branch_id');
      if (mounted) setState(() => _restDay = day);
    } catch (e) {
      _snack(context, 'Could not save rest day: $e');
    }
  }

  Future<void> _saveDefault(String key, String value) async {
    await _db.from('app_config').delete().eq('org_id', widget.orgId).eq('key', key);
    await _db.from('app_config').insert({'org_id': widget.orgId, 'key': key, 'value': value.trim()});
  }

  Future<void> _saveDefaults() async {
    try {
      await _saveDefault('hr.paid_leave_days', _defPl.text);
      await _saveDefault('hr.rest_day_min_days', _defRest.text);
      _snack(context, 'Saved. Regenerate draft payroll runs to apply.');
    } catch (e) {
      _snack(context, 'Could not save: $e');
    }
  }

  static int? _min(String? hhmm) {
    if (hhmm == null || hhmm.isEmpty) return null;
    final p = hhmm.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    return h == null || m == null ? null : h * 60 + m;
  }

  double? _hours() {
    final a = _min(_start), b = _min(_end);
    if (a == null || b == null) return null;
    var d = b - a;
    if (d <= 0) d += 1440;
    return (d / 60 * 100).round() / 100;
  }

  Future<void> _pick(bool isStart) async {
    final cur = _min(isStart ? _start : _end);
    final t = await showTimePicker(
        context: context,
        initialTime: cur == null ? const TimeOfDay(hour: 9, minute: 0) : TimeOfDay(hour: cur ~/ 60, minute: cur % 60));
    if (t == null) return;
    final s = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (isStart) {
        _start = s;
      } else {
        _end = s;
      }
    });
  }

  void _clearForm() {
    setState(() {
      _editId = null;
      _start = null;
      _end = null;
      _name.clear();
      _grace.text = '0';
      _half.clear();
      _penDays.text = '1';
      _pl.clear();
      _restMin.clear();
      _penalize = false;
    });
  }

  void _edit(Map<String, dynamic> s) {
    setState(() {
      _editId = s['id'] as String;
      _name.text = s['name'] as String? ?? '';
      _start = s['start_time'] as String?;
      _end = s['end_time'] as String?;
      _grace.text = (s['grace_minutes'] ?? 0).toString();
      _half.text = s['half_day_hours']?.toString() ?? '';
      _penalize = s['penalize_unapproved_absence'] == true;
      _penDays.text = (s['absence_penalty_days'] ?? 1).toString();
      _pl.text = s['paid_leave_days']?.toString() ?? '';
      _restMin.text = s['rest_day_min_days']?.toString() ?? '';
    });
  }

  Future<void> _saveShift() async {
    if (_name.text.trim().isEmpty) {
      _snack(context, 'Shift name required');
      return;
    }
    final half = double.tryParse(_half.text.trim());
    final penDays = int.tryParse(_penDays.text.trim()) ?? 1;
    final payload = <String, dynamic>{
      'org_id': widget.orgId,
      'name': _name.text.trim(),
      'start_time': _start,
      'end_time': _end,
      'work_hours': _hours(),
      'half_day_hours': (half != null && half > 0) ? half : null,
      'grace_minutes': int.tryParse(_grace.text) ?? 0,
      'penalize_unapproved_absence': _penalize,
      'absence_penalty_days': _penalize ? (penDays < 0 ? 0 : penDays) : 1,
      'paid_leave_days': double.tryParse(_pl.text.trim()),
      'rest_day_min_days': double.tryParse(_restMin.text.trim()),
    };
    setState(() => _saving = true);
    try {
      if (_editId == null) {
        payload['id'] = 'shift_${DateTime.now().millisecondsSinceEpoch}';
        payload['is_active'] = true;
        await _db.from('hr_shifts').insert(payload);
      } else {
        await _db.from('hr_shifts').update(payload).eq('id', _editId!);
      }
      _clearForm();
      await _load();
    } catch (e) {
      _snack(context, 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggle(Map<String, dynamic> s, bool v) async {
    try {
      await _db.from('hr_shifts').update({'is_active': v}).eq('id', s['id'] as String);
      await _load();
    } catch (e) {
      _snack(context, 'Update failed: $e');
    }
  }

  Widget _box({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: child,
      );

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      );

  Widget _companyCard() => _box(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _heading('Company settings'),
          Row(children: [
            const Icon(Icons.event_busy_outlined, size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            const Expanded(child: Text('Weekly rest day (whole company)', style: TextStyle(fontSize: 12.5))),
            DropdownButton<int?>(
              value: _restDay,
              underline: const SizedBox.shrink(),
              hint: const Text('None', style: TextStyle(fontSize: 12.5)),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('None', style: TextStyle(fontSize: 12.5))),
                for (var i = 0; i < 7; i++)
                  DropdownMenuItem<int?>(value: i, child: Text(_dayNames[i], style: const TextStyle(fontSize: 12.5))),
              ],
              onChanged: widget.canEdit ? _saveRestDay : null,
            ),
          ]),
          const Divider(height: 20),
          const Text('Payroll defaults (employees with no shift, or a shift that leaves these blank)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _defPl,
                enabled: widget.canEdit,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Paid leave days / month', isDense: true, border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _defRest,
                enabled: widget.canEdit,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Days worked to earn rest day', isDense: true, border: OutlineInputBorder()),
              ),
            ),
            if (widget.canEdit) ...[
              const SizedBox(width: 6),
              IconButton(icon: const Icon(Icons.save_outlined, size: 20), tooltip: 'Save defaults', onPressed: _saveDefaults),
            ],
          ]),
          const SizedBox(height: 6),
          const Text(
              'Rest day is paid only if the employee worked at least this many days (½ day counts ½) in the 6 days before it; '
              'otherwise it counts as an absent. 0 = always paid. Leave (L) is not a worked day.',
              style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        ]),
      );

  Widget _formCard() {
    final h = _hours();
    return _box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _heading(_editId == null ? 'Add shift' : 'Edit shift'),
        TextField(
            controller: _name,
            decoration: const InputDecoration(hintText: 'Shift name (e.g. Morning 9-5)', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => _pick(true), child: Text(_start ?? 'Start time', style: const TextStyle(fontSize: 12)))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () => _pick(false), child: Text(_end ?? 'End time', style: const TextStyle(fontSize: 12)))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(
            width: 120,
            child: TextField(
                controller: _grace,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Grace min', isDense: true, border: OutlineInputBorder())),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _half,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: 'Half-day hours',
                  hintText: 'auto ${h != null ? (h / 2).toStringAsFixed(2) : '—'}',
                  isDense: true,
                  border: const OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text('Standard hours: ${h?.toString() ?? '—'}  ·  worked ≤ half-day hours counts as ½ day',
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
              color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE0E0E0))),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.gavel_outlined, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              const Expanded(child: Text('Penalize unapproved absence', style: TextStyle(fontSize: 12))),
              Switch(value: _penalize, onChanged: (v) => setState(() => _penalize = v)),
            ]),
            if (_penalize)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                        controller: _penDays,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Extra absents', isDense: true, border: OutlineInputBorder())),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                        'Added on the next working day(s) after an unapproved absence. Punch times are kept but the day reports Absent.',
                        style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  ),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _pl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: 'Paid leave days / month',
                  hintText: 'default ${_defPl.text.isEmpty ? '0' : _defPl.text}',
                  isDense: true,
                  border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _restMin,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: 'Days to earn rest day',
                  hintText: 'default ${_defRest.text.isEmpty ? '3' : _defRest.text}',
                  isDense: true,
                  border: const OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          if (_editId != null) TextButton(onPressed: _clearForm, child: const Text('Cancel edit')),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _saving ? null : _saveShift,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: Text(_editId == null ? 'Add shift' : 'Update shift'),
          ),
        ]),
      ]),
    );
  }

  Widget _listCard({required bool fill}) {
    final list = _shifts.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: Text('No shifts yet', style: TextStyle(color: AppTheme.textSecondary))))
        : ListView.separated(
            shrinkWrap: !fill,
            physics: fill ? null : const NeverScrollableScrollPhysics(),
            itemCount: _shifts.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final s = _shifts[i];
              final active = s['is_active'] != false;
              final n = _count[s['id']] ?? 0;
              final wh = s['work_hours'] as num?;
              final halfH = s['half_day_hours'] ?? (wh != null ? (wh / 2).toStringAsFixed(2) : '—');
              return ListTile(
                dense: true,
                selected: _editId == s['id'],
                title: Text('${s['name'] ?? ''}  ·  $n employee${n == 1 ? '' : 's'}',
                    style: TextStyle(fontSize: 13.5, decoration: active ? null : TextDecoration.lineThrough)),
                subtitle: Text(
                    '${s['start_time'] ?? '—'} – ${s['end_time'] ?? '—'}  ·  ${wh ?? '—'}h  ·  ½ @ ${halfH}h  ·  grace ${s['grace_minutes'] ?? 0}m'
                    '${s['penalize_unapproved_absence'] == true ? '  ·  penalty +${s['absence_penalty_days'] ?? 1}' : ''}'
                    '${s['paid_leave_days'] != null ? '  ·  paid leave ${s['paid_leave_days']}' : ''}'
                    '${s['rest_day_min_days'] != null ? '  ·  rest day ≥${s['rest_day_min_days']}d' : ''}',
                    style: const TextStyle(fontSize: 11)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (widget.canEdit)
                    IconButton(icon: const Icon(Icons.edit_outlined, size: 17), tooltip: 'Edit', onPressed: () => _edit(s)),
                  Switch(value: active, onChanged: widget.canEdit ? (v) => _toggle(s, v) : null),
                ]),
              );
            },
          );
    return Container(
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 0), child: _heading('Shifts (${_shifts.length})')),
        if (fill) Expanded(child: list) else list,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final wide = MediaQuery.of(context).size.width >= 1000;
    final left = Column(children: [
      _companyCard(),
      if (widget.canEdit) ...[const SizedBox(height: 12), _formCard()],
    ]);
    if (wide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 470, child: SingleChildScrollView(child: left)),
        const SizedBox(width: 14),
        Expanded(child: _listCard(fill: true)),
      ]);
    }
    return SingleChildScrollView(
      child: Column(children: [
        left,
        const SizedBox(height: 12),
        _listCard(fill: false),
      ]),
    );
  }
}
