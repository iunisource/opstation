import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class HrLeaveScreen extends ConsumerStatefulWidget {
  const HrLeaveScreen({super.key});
  @override
  ConsumerState<HrLeaveScreen> createState() => _State();
}

class _State extends ConsumerState<HrLeaveScreen> {
  bool _loading = true;
  bool _drawerOpen = true;
  String _listSearch = '';
  String _statusFilter = 'all'; // all / pending / approved / rejected

  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _types = [];
  List<Map<String, dynamic>> _requests = [];
  Map<String, String> _empName = {};
  Map<String, Map<String, dynamic>> _empById = {};
  Map<String, Map<String, dynamic>> _typeById = {};

  Map<String, dynamic>? _current;
  bool _saving = false;

  // form
  String? _empId, _typeId;
  DateTime? _from, _to;
  bool _halfDay = false;
  final _reason = TextEditingController();

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;
  String? get _userName => ref.read(currentUserProvider)?.name;
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.admin || r == WebUserRole.masterAdmin; }

  String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  DateTime _d0(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll()); }
  @override
  void dispose() { _reason.dispose(); super.dispose(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadAll() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _loadAll(); return; }
    setState(() => _loading = true);
    try {
      await Future.wait([_loadEmployees(), _loadTypes()]);
      await _loadRequests();
    } catch (e) { _snack('Load error: $e'); }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadEmployees() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_employees')
        .select('id, full_name, employee_code, branch_id')
        .eq('org_id', orgId).eq('status', 'active').eq('approval_status', 'approved').eq('is_voided', false).order('full_name');
    if (mounted) setState(() {
      _employees = List<Map<String, dynamic>>.from(rows);
      _empName = {for (final e in _employees) e['id'] as String: e['full_name'] as String? ?? ''};
      _empById = {for (final e in _employees) e['id'] as String: e};
    });
  }

  Future<void> _loadTypes() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_leave_types').select().eq('org_id', orgId).order('name');
    if (mounted) setState(() {
      _types = List<Map<String, dynamic>>.from(rows);
      _typeById = {for (final t in _types) t['id'] as String: t};
    });
  }

  Future<void> _loadRequests() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_leave_requests').select().eq('org_id', orgId).order('from_date', ascending: false);
    if (mounted) setState(() => _requests = List<Map<String, dynamic>>.from(rows));
  }

  List<Map<String, dynamic>> get _activeTypes => _types.where((t) => t['is_active'] != false).toList();

  double _computeDays() {
    if (_from == null || _to == null) return 0;
    if (_to!.isBefore(_from!)) return 0;
    if (_halfDay && _fmt(_from!) == _fmt(_to!)) return 0.5;
    return _to!.difference(_d0(_from!)).inDays + 1.0;
  }

  String _dStr(double v) { final r = (v * 100).roundToDouble() / 100; return r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toString(); }

  void _newRequest() {
    setState(() { _current = null; _empId = null; _typeId = null; _from = null; _to = null; _halfDay = false; _reason.clear(); });
  }

  void _loadRequest(Map<String, dynamic> r) {
    setState(() {
      _current = r;
      _empId = r['employee_id'] as String?;
      _typeId = r['leave_type_id'] as String?;
      _from = r['from_date'] != null ? DateTime.tryParse(r['from_date'] as String) : null;
      _to = r['to_date'] != null ? DateTime.tryParse(r['to_date'] as String) : null;
      _halfDay = r['half_day'] == true;
      _reason.text = r['reason'] as String? ?? '';
    });
  }

  String get _status => _current?['status'] as String? ?? 'pending';
  bool get _isPending => _current != null && _status == 'pending';
  bool get _isApproved => _current != null && _status == 'approved';

  // ---- balances (current year) ----
  Map<String, double> _balanceFor(String empId, String typeId) {
    final year = DateTime.now().year;
    final quota = (_typeById[typeId]?['annual_quota'] as num?)?.toDouble() ?? 0;
    double used = 0, pending = 0;
    for (final r in _requests) {
      if (r['employee_id'] != empId || r['leave_type_id'] != typeId) continue;
      final fd = r['from_date'] != null ? DateTime.tryParse(r['from_date'] as String) : null;
      if (fd == null || fd.year != year) continue;
      if (_current != null && r['id'] == _current!['id']) continue; // exclude the one being edited
      final d = (r['days'] as num?)?.toDouble() ?? 0;
      if (r['status'] == 'approved') used += d;
      else if (r['status'] == 'pending') pending += d;
    }
    return {'quota': quota, 'used': used, 'pending': pending, 'remaining': quota - used};
  }

  // ---- save ----
  Future<void> _save() async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    if (_empId == null) { _snack('Select an employee'); return; }
    if (_typeId == null) { _snack('Select a leave type'); return; }
    if (_from == null || _to == null) { _snack('Select start and end dates'); return; }
    if (_to!.isBefore(_from!)) { _snack('End date is before start date'); return; }
    final days = _computeDays();
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final now = DateTime.now().toIso8601String();
      final payload = {
        'org_id': orgId, 'employee_id': _empId, 'leave_type_id': _typeId,
        'from_date': _fmt(_from!), 'to_date': _fmt(_to!), 'half_day': _halfDay,
        'days': days, 'reason': _reason.text.trim().isEmpty ? null : _reason.text.trim(),
        'updated_at': now,
      };
      String id;
      if (_current == null) {
        id = 'lv_' + DateTime.now().millisecondsSinceEpoch.toString();
        payload['id'] = id; payload['status'] = 'pending';
        payload['applied_by'] = _userId; payload['applied_at'] = now;
        await client.from('hr_leave_requests').insert(payload);
      } else {
        id = _current!['id'] as String;
        await client.from('hr_leave_requests').update(payload).eq('id', id);
      }
      final updated = await client.from('hr_leave_requests').select().eq('id', id).single();
      if (mounted) setState(() => _current = updated);
      await _loadRequests();
      _snack(_isAdmin ? 'Leave request saved' : 'Leave request saved \u2014 awaiting admin approval');
    } catch (e) { _snack('Save failed: $e'); }
    if (mounted) setState(() => _saving = false);
  }

  // ---- attendance sync ----
  Future<void> _writeAttendanceForLeave(Map<String, dynamic> req, {required bool add}) async {
    final orgId = _orgId; if (orgId == null) return;
    final client = Supabase.instance.client;
    final empId = req['employee_id'] as String?;
    final from = req['from_date'] != null ? DateTime.tryParse(req['from_date'] as String) : null;
    final to = req['to_date'] != null ? DateTime.tryParse(req['to_date'] as String) : null;
    if (empId == null || from == null || to == null) return;
    final branchId = _empById[empId]?['branch_id'] as String?;
    final typeName = _typeById[req['leave_type_id']]?['name'] as String? ?? 'Leave';
    for (var d = _d0(from); !d.isAfter(_d0(to)); d = d.add(const Duration(days: 1))) {
      final ds = _fmt(d);
      if (add) {
        final id = 'att_${DateTime.now().microsecondsSinceEpoch}_$empId';
        await client.from('hr_attendance').upsert({
          'id': id, 'org_id': orgId, 'employee_id': empId, 'branch_id': branchId, 'att_date': ds,
          'status': 'leave', 'check_in': null, 'check_out': null, 'work_hours': 0,
          'remarks': 'Leave: $typeName', 'updated_at': DateTime.now().toIso8601String(),
        }, onConflict: 'org_id,employee_id,att_date');
        await client.from('hr_attendance_audit').insert({
          'id': 'aud_${DateTime.now().microsecondsSinceEpoch}_$empId', 'org_id': orgId, 'attendance_id': id,
          'employee_id': empId, 'att_date': ds, 'action': 'updated', 'changes': 'Leave approved ($typeName)',
          'changed_by': _userId, 'changed_by_name': _userName,
        });
      } else {
        await client.from('hr_attendance').delete().eq('org_id', orgId).eq('employee_id', empId).eq('att_date', ds).eq('status', 'leave');
        await client.from('hr_attendance_audit').insert({
          'id': 'aud_${DateTime.now().microsecondsSinceEpoch}_$empId', 'org_id': orgId, 'attendance_id': '',
          'employee_id': empId, 'att_date': ds, 'action': 'updated', 'changes': 'Leave cancelled ($typeName)',
          'changed_by': _userId, 'changed_by_name': _userName,
        });
      }
    }
  }

  Future<void> _approve() async {
    final r = _current; if (r == null || !_isAdmin) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final now = DateTime.now().toIso8601String();
      await client.from('hr_leave_requests').update({'status': 'approved', 'decided_by': _userId, 'decided_at': now, 'updated_at': now}).eq('id', r['id'] as String);
      final updated = await client.from('hr_leave_requests').select().eq('id', r['id'] as String).single();
      await _writeAttendanceForLeave(updated, add: true);
      if (mounted) setState(() => _current = updated);
      await _loadRequests();
      _snack('Leave approved \u2014 marked on attendance');
    } catch (e) { _snack('Approve failed: $e'); }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _reject() async {
    final r = _current; if (r == null || !_isAdmin) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final now = DateTime.now().toIso8601String();
      if (r['status'] == 'approved') await _writeAttendanceForLeave(r, add: false);
      await client.from('hr_leave_requests').update({'status': 'rejected', 'decided_by': _userId, 'decided_at': now, 'updated_at': now}).eq('id', r['id'] as String);
      final updated = await client.from('hr_leave_requests').select().eq('id', r['id'] as String).single();
      if (mounted) setState(() => _current = updated);
      await _loadRequests();
      _snack('Leave rejected');
    } catch (e) { _snack('Reject failed: $e'); }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _deleteRequest() async {
    final r = _current; if (r == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete leave request?'),
      content: const Text('This removes the request. If it was approved, the leave marks are also removed from attendance.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      if (r['status'] == 'approved') await _writeAttendanceForLeave(r, add: false);
      await Supabase.instance.client.from('hr_leave_requests').delete().eq('id', r['id'] as String);
      _snack('Leave request deleted'); _newRequest(); await _loadRequests();
    } catch (e) { _snack('Delete failed: $e'); }
  }

  // ---- leave type management ----
  Future<void> _manageTypes() async {
    await showDialog(context: context, builder: (ctx) {
      final nameCtrl = TextEditingController();
      final quotaCtrl = TextEditingController();
      bool paid = true;
      return StatefulBuilder(builder: (ctx, setLocal) {
        Future<void> refresh() async { await _loadTypes(); setLocal(() {}); }
        return AlertDialog(
          title: const Text('Manage leave types'),
          content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(flex: 3, child: TextField(controller: nameCtrl, decoration: const InputDecoration(hintText: 'Type name (e.g. Annual)', isDense: true, border: OutlineInputBorder()))),
              const SizedBox(width: 6),
              Expanded(flex: 2, child: TextField(controller: quotaCtrl, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], decoration: const InputDecoration(hintText: 'Quota/yr', isDense: true, border: OutlineInputBorder()))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              FilterChip(label: const Text('Paid', style: TextStyle(fontSize: 12)), selected: paid, onSelected: (v) => setLocal(() => paid = v)),
              const Spacer(),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
                onPressed: () async {
                  final orgId = _orgId; if (orgId == null) return;
                  final nm = nameCtrl.text.trim(); if (nm.isEmpty) return;
                  try {
                    await Supabase.instance.client.from('hr_leave_types').insert({
                      'id': 'lvtype_${DateTime.now().millisecondsSinceEpoch}', 'org_id': orgId, 'name': nm,
                      'annual_quota': double.tryParse(quotaCtrl.text) ?? 0, 'is_paid': paid, 'is_active': true,
                    });
                    nameCtrl.clear(); quotaCtrl.clear(); await refresh();
                  } catch (e) { _snack('Add failed: $e'); }
                }, child: const Text('Add')),
            ]),
            const SizedBox(height: 12),
            SizedBox(height: 280, width: 460, child: _types.isEmpty
              ? const Center(child: Text('No leave types yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
              : ListView.separated(itemCount: _types.length, separatorBuilder: (_, __) => const Divider(height: 1), itemBuilder: (_, i) {
                  final t = _types[i]; final active = t['is_active'] != false;
                  return ListTile(dense: true,
                    title: Text(t['name'] as String? ?? '', style: TextStyle(fontSize: 13, color: active ? AppTheme.textPrimary : AppTheme.textSecondary, decoration: active ? null : TextDecoration.lineThrough)),
                    subtitle: Text('${_dStr((t['annual_quota'] as num?)?.toDouble() ?? 0)} days/yr \u00b7 ${(t['is_paid'] == false) ? 'Unpaid' : 'Paid'}', style: const TextStyle(fontSize: 11)),
                    trailing: Switch(value: active, onChanged: (val) async { try { await Supabase.instance.client.from('hr_leave_types').update({'is_active': val}).eq('id', t['id'] as String); await refresh(); } catch (e) { _snack('Update failed: $e'); } }));
                })),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        );
      });
    });
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _requests.where((r) {
      if (_statusFilter != 'all' && (r['status'] as String? ?? 'pending') != _statusFilter) return false;
      if (_listSearch.isEmpty) return true;
      final q = _listSearch.toLowerCase();
      final nm = (_empName[r['employee_id']] ?? '').toLowerCase();
      final tp = (_typeById[r['leave_type_id']]?['name'] as String? ?? '').toLowerCase();
      return nm.contains(q) || tp.contains(q);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 320,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Leave requests', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero), onPressed: _newRequest),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search employee or type...', prefixIcon: Icon(Icons.search, size: 15), isDense: true, border: OutlineInputBorder()), onChanged: (v) => setState(() => _listSearch = v)),
              const SizedBox(height: 8),
              Row(children: [
                for (final s in const ['all', 'pending', 'approved', 'rejected'])
                  Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(
                    label: Text(s[0].toUpperCase() + s.substring(1), style: const TextStyle(fontSize: 10)),
                    selected: _statusFilter == s, visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _statusFilter = s))),
              ]),
            ])),
          Expanded(child: _loading ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No requests', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final r = filtered[i]; final sel = _current?['id'] == r['id'];
                final st = r['status'] as String? ?? 'pending';
                final MaterialColor c = st == 'approved' ? Colors.green : (st == 'rejected' ? Colors.red : Colors.orange);
                final tp = _typeById[r['leave_type_id']]?['name'] as String? ?? 'Leave';
                return InkWell(onTap: () => _loadRequest(r), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(_empName[r['employee_id']] ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary), overflow: TextOverflow.ellipsis)),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: c.withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                        child: Text(st[0].toUpperCase() + st.substring(1), style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: c.shade700))),
                    ]),
                    const SizedBox(height: 2),
                    Text('$tp  \u00b7  ${_dStr((r['days'] as num?)?.toDouble() ?? 0)} day(s)', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary)),
                    Text('${r['from_date'] ?? ''}  \u2192  ${r['to_date'] ?? ''}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
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
            Expanded(child: Text(_current == null ? 'New Leave Request' : (_empName[_empId] ?? 'Leave Request'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
            if (_isAdmin) TextButton.icon(icon: const Icon(Icons.category_outlined, size: 15), label: const Text('Leave types', style: TextStyle(fontSize: 12)), onPressed: _manageTypes),
            if (_current != null) _statusChip(),
            if (_isAdmin && _isPending) Padding(padding: const EdgeInsets.only(left: 6), child: ElevatedButton.icon(
              icon: const Icon(Icons.check, size: 15), label: const Text('Approve', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), minimumSize: Size.zero),
              onPressed: _saving ? null : _approve)),
            if (_isAdmin && (_isPending || _isApproved)) TextButton.icon(icon: const Icon(Icons.close, size: 16, color: Colors.red), label: const Text('Reject', style: TextStyle(fontSize: 12, color: Colors.red)), onPressed: _saving ? null : _reject),
            if (_current != null && (_isAdmin || _isPending)) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), tooltip: 'Delete request', onPressed: _deleteRequest),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
              onPressed: _saving ? null : _save),
          ])),
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _card('Request', [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('Employee', _empDropdown())),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Leave type', _typeDropdown())),
              ]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('From', _dateField(_from, (d) => setState(() { _from = d; if (_to == null || _to!.isBefore(d)) _to = d; })))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('To', _dateField(_to, (d) => setState(() => _to = d)))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Days', Container(
                  height: 42, alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
                  child: Text(_dStr(_computeDays()), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))))),
              ]),
              if (_from != null && _to != null && _fmt(_from!) == _fmt(_to!)) ...[
                const SizedBox(height: 6),
                Row(children: [
                  Checkbox(value: _halfDay, visualDensity: VisualDensity.compact, onChanged: (v) => setState(() => _halfDay = v ?? false)),
                  const Text('Half day', style: TextStyle(fontSize: 12)),
                ]),
              ],
              const SizedBox(height: 12),
              _labeled('Reason', _tf(_reason, lines: 2, hint: 'Optional')),
            ]),
            const SizedBox(height: 16),
            if (_empId != null) _balancesCard(),
          ]))),
      ])),
    ]));
  }

  Widget _statusChip() {
    final st = _status;
    final label = st[0].toUpperCase() + st.substring(1);
    final MaterialColor c = st == 'approved' ? Colors.green : (st == 'rejected' ? Colors.red : Colors.orange);
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withOpacity(0.4))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(st == 'approved' ? Icons.check_circle : (st == 'rejected' ? Icons.cancel : Icons.hourglass_top), size: 13, color: c.shade700),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.shade700)),
      ]));
  }

  Widget _balancesCard() {
    final empId = _empId!;
    return _card('Balances ${DateTime.now().year} \u2014 ${_empName[empId] ?? ''}', [
      if (_activeTypes.isEmpty)
        const Text('No leave types defined yet.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
      else
        Column(children: [
          Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: const [
            Expanded(flex: 4, child: Text('Type', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Quota', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
            Expanded(flex: 2, child: Text('Used', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
            Expanded(flex: 2, child: Text('Pending', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
            Expanded(flex: 2, child: Text('Left', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          ])),
          ..._activeTypes.map((t) {
            final b = _balanceFor(empId, t['id'] as String);
            final left = b['remaining'] ?? 0;
            final unpaid = t['is_paid'] == false;
            return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
              Expanded(flex: 4, child: Text((t['name'] as String? ?? '') + (unpaid ? '  (unpaid)' : ''), style: const TextStyle(fontSize: 12))),
              Expanded(flex: 2, child: Text(_dStr(b['quota'] ?? 0), style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
              Expanded(flex: 2, child: Text(_dStr(b['used'] ?? 0), style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
              Expanded(flex: 2, child: Text(_dStr(b['pending'] ?? 0), style: const TextStyle(fontSize: 12, color: Colors.orange), textAlign: TextAlign.right)),
              Expanded(flex: 2, child: Text(_dStr(left), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: left < 0 ? Colors.red : AppTheme.textPrimary), textAlign: TextAlign.right)),
            ]));
          }),
          const SizedBox(height: 4),
          const Text('Used = approved days this year. Quota is per leave type. Unpaid types track usage but ignore quota.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ]),
    ]);
  }

  // ---- widgets ----
  Widget _empDropdown() {
    return DropdownButtonFormField<String>(
      value: _empById.containsKey(_empId) ? _empId : null, isDense: true, isExpanded: true,
      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
      hint: const Text('Select employee', style: TextStyle(fontSize: 13)),
      items: _employees.map((e) => DropdownMenuItem(value: e['id'] as String, child: Text('${e['full_name'] ?? ''} (${e['employee_code'] ?? ''})', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (v) => setState(() => _empId = v));
  }

  Widget _typeDropdown() {
    final items = _activeTypes.where((t) => true).toList();
    return DropdownButtonFormField<String>(
      value: items.any((t) => t['id'] == _typeId) ? _typeId : null, isDense: true, isExpanded: true,
      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
      hint: const Text('Select type', style: TextStyle(fontSize: 13)),
      items: [
        ...items.map((t) => DropdownMenuItem(value: t['id'] as String, child: Text(t['name'] as String? ?? '', style: const TextStyle(fontSize: 13)))),
        if (_isAdmin) const DropdownMenuItem(value: '__manage__', child: Text('+ Manage types...', style: TextStyle(fontSize: 13, color: AppTheme.primary))),
      ],
      onChanged: (v) async { if (v == '__manage__') { await _manageTypes(); } else { setState(() => _typeId = v); } });
  }

  Widget _dateField(DateTime? value, void Function(DateTime) onPick) {
    return InkWell(
      onTap: () async {
        final d = await showDatePicker(context: context, initialDate: value ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2035));
        if (d != null) onPick(_d0(d));
      },
      child: Container(height: 42, alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
        child: Row(children: [
          const Icon(Icons.calendar_today_outlined, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(value != null ? DateFormat('d MMM yyyy').format(value) : 'Select', style: TextStyle(fontSize: 13, color: value != null ? AppTheme.textPrimary : AppTheme.textSecondary)),
        ])));
  }

  Widget _card(String title, List<Widget> children) {
    return Container(width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(height: 14),
        ...children,
      ]));
  }

  Widget _labeled(String label, Widget child) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 5),
      child,
    ]);
  }

  Widget _tf(TextEditingController c, {int lines = 1, String? hint}) {
    return TextField(controller: c, maxLines: lines, style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(hintText: hint, isDense: true, border: const OutlineInputBorder(), contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)));
  }
}
