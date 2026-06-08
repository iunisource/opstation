// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class HrAttendanceScreen extends ConsumerStatefulWidget {
  const HrAttendanceScreen({super.key});
  @override
  ConsumerState<HrAttendanceScreen> createState() => _State();
}

class _State extends ConsumerState<HrAttendanceScreen> {
  bool _loading = true;
  bool _savingAll = false;
  DateTime _date = DateTime.now();
  String _branchFilter = '__all__';
  String _search = '';

  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _branches = [];
  Map<String, String> _branchName = {};
  Map<String, String> _deptName = {};
  Map<String, String> _empName = {};
  Map<String, Map<String, dynamic>> _shiftById = {};

  final List<_Row> _rows = [];
  List<Map<String, dynamic>> _audit = [];

  static const _statuses = [
    {'v': 'present', 'l': 'Present'}, {'v': 'absent', 'l': 'Absent'}, {'v': 'leave', 'l': 'Leave'},
    {'v': 'half_day', 'l': 'Half day'}, {'v': 'holiday', 'l': 'Holiday'}, {'v': 'rest_day', 'l': 'Rest day'},
  ];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;
  String get _userName => ref.read(currentUserProvider)?.name ?? ref.read(currentUserProvider)?.id ?? '-';
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.admin || r == WebUserRole.masterAdmin; }
  DateTime _d0(DateTime d) => DateTime(d.year, d.month, d.day);
  bool get _canNext => _d0(_date).isBefore(_d0(DateTime.now()));

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => _init()); }

  @override
  void dispose() { for (final r in _rows) r.remarks.dispose(); super.dispose(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }
  String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  int? _min(String? hhmm) { if (hhmm == null || hhmm.isEmpty) return null; final p = hhmm.split(':'); if (p.length != 2) return null; final h = int.tryParse(p[0]), m = int.tryParse(p[1]); if (h == null || m == null) return null; return h * 60 + m; }
  double? _hours(String? cin, String? cout) { final a = _min(cin), b = _min(cout); if (a == null || b == null) return null; var diff = b - a; if (diff <= 0) diff += 1440; return (diff / 60.0 * 100).roundToDouble() / 100; }
  Map<String, dynamic>? _shiftFor(String? shiftId) => shiftId != null ? _shiftById[shiftId] : null;

  Future<void> _init() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _init(); return; }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final br = await client.from('branches').select('id, name').eq('org_id', orgId).order('name');
      _branches = List<Map<String, dynamic>>.from(br);
      _branchName = {for (final b in _branches) b['id'] as String: b['name'] as String};
      final dp = await client.from('hr_departments').select('id, name').eq('org_id', orgId);
      _deptName = {for (final d in (dp as List)) d['id'] as String: d['name'] as String};
      final sh = await client.from('hr_shifts').select().eq('org_id', orgId);
      _shiftById = {for (final s in (sh as List)) s['id'] as String: Map<String, dynamic>.from(s)};
      final emps = await client.from('hr_employees')
          .select('id, full_name, employee_code, branch_id, department_id, shift_id, status')
          .eq('org_id', orgId).eq('status', 'active').order('full_name');
      _employees = List<Map<String, dynamic>>.from(emps);
      _empName = {for (final e in _employees) e['id'] as String: e['full_name'] as String? ?? ''};
      await _loadForDate();
      await _loadAudit();
    } catch (e) { _snack('Load error: $e'); }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadForDate() async {
    final orgId = _orgId; if (orgId == null) return;
    final dateStr = _fmt(_date);
    Map<String, Map<String, dynamic>> existing = {};
    try {
      final rows = await Supabase.instance.client.from('hr_attendance').select().eq('org_id', orgId).eq('att_date', dateStr);
      for (final r in (rows as List)) existing[r['employee_id'] as String] = Map<String, dynamic>.from(r);
    } catch (_) {}
    for (final r in _rows) r.remarks.dispose();
    _rows.clear();
    for (final e in _employees) {
      final rec = existing[e['id']];
      final row = _Row(
        empId: e['id'] as String, label: e['full_name'] as String? ?? '', code: e['employee_code'] as String? ?? '',
        branchId: e['branch_id'] as String?, deptName: _deptName[e['department_id']] ?? '', shiftId: e['shift_id'] as String?,
        recordId: rec?['id'] as String?, status: rec?['status'] as String? ?? 'present',
        checkIn: rec?['check_in'] as String?, checkOut: rec?['check_out'] as String?,
      );
      row.remarks.text = rec?['remarks'] as String? ?? '';
      row.snapshot();
      _rows.add(row);
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadAudit() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('hr_attendance_audit')
          .select().eq('org_id', orgId).eq('att_date', _fmt(_date)).order('changed_at', ascending: false).limit(200);
      if (mounted) setState(() => _audit = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  String? _effectiveBranch() {
    if (_isAdmin) return _branchFilter == '__all__' ? null : _branchFilter;
    return ref.read(selectedBranchProvider)?['id'] as String?;
  }

  List<_Row> get _visible {
    final eff = _effectiveBranch();
    return _rows.where((r) {
      if (eff != null && r.branchId != eff) return false;
      if (_search.isNotEmpty) { final q = _search.toLowerCase(); if (!r.label.toLowerCase().contains(q) && !r.code.toLowerCase().contains(q)) return false; }
      return true;
    }).toList();
  }

  Future<void> _pickTime(_Row r, bool isIn) async {
    final cur = isIn ? r.checkIn : r.checkOut;
    TimeOfDay initial = const TimeOfDay(hour: 9, minute: 0);
    final m = _min(cur); if (m != null) initial = TimeOfDay(hour: m ~/ 60, minute: m % 60);
    final t = await showTimePicker(context: context, initialTime: initial);
    if (t == null) return;
    final s = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() { if (isIn) r.checkIn = s; else r.checkOut = s; });
  }

  void _stampNow(_Row r, bool isIn) {
    final now = DateTime.now();
    final s = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    setState(() { if (isIn) r.checkIn = s; else r.checkOut = s; if (r.status == 'absent' || r.status == 'leave') r.status = 'present'; });
    _saveRow(r);
  }

  String? _diff(_Row r) {
    final parts = <String>[];
    if (r.origStatus != r.status) parts.add('status ${r.origStatus}\u2192${r.status}');
    if ((r.origIn ?? '') != (r.checkIn ?? '')) parts.add('in ${r.origIn ?? '\u2014'}\u2192${r.checkIn ?? '\u2014'}');
    if ((r.origOut ?? '') != (r.checkOut ?? '')) parts.add('out ${r.origOut ?? '\u2014'}\u2192${r.checkOut ?? '\u2014'}');
    if (r.origRemarks != r.remarks.text) parts.add('remarks edited');
    return parts.isEmpty ? null : parts.join(', ');
  }

  Future<void> _saveRow(_Row r, {bool silent = false}) async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    setState(() => r.saving = true);
    try {
      final client = Supabase.instance.client;
      final dateStr = _fmt(_date);
      final isNew = r.recordId == null;
      final changes = isNew ? 'Created (${r.status}${r.checkIn != null ? ', in ${r.checkIn}' : ''}${r.checkOut != null ? ', out ${r.checkOut}' : ''})' : _diff(r);
      if (!isNew && changes == null) { setState(() => r.saving = false); if (!silent) _snack('No changes for ${r.label}'); return; }
      final id = r.recordId ?? 'att_${DateTime.now().microsecondsSinceEpoch}_${r.empId}';
      final payload = {
        'id': id, 'org_id': orgId, 'employee_id': r.empId, 'branch_id': r.branchId, 'att_date': dateStr,
        'status': r.status, 'check_in': r.checkIn, 'check_out': r.checkOut, 'work_hours': _hours(r.checkIn, r.checkOut),
        'remarks': r.remarks.text.trim().isEmpty ? null : r.remarks.text.trim(), 'updated_at': DateTime.now().toIso8601String(),
      };
      await client.from('hr_attendance').upsert(payload, onConflict: 'org_id,employee_id,att_date');
      await client.from('hr_attendance_audit').insert({
        'id': 'aud_${DateTime.now().microsecondsSinceEpoch}_${r.empId}', 'org_id': orgId, 'attendance_id': id,
        'employee_id': r.empId, 'att_date': dateStr, 'action': isNew ? 'created' : 'updated', 'changes': changes,
        'changed_by': _userId, 'changed_by_name': _userName,
      });
      r.recordId = id; r.snapshot();
      await _loadAudit();
      if (!silent) _snack('Saved ${r.label}');
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => r.saving = false);
  }

  Future<void> _saveAll() async {
    final vis = _visible; if (vis.isEmpty) return;
    setState(() => _savingAll = true);
    int n = 0;
    for (final r in vis) {
      final isNew = r.recordId == null;
      if (isNew || _diff(r) != null) { await _saveRow(r, silent: true); n++; }
    }
    if (mounted) setState(() => _savingAll = false);
    _snack(n == 0 ? 'Nothing to save' : 'Saved $n row(s)');
  }

  void _markAll(String status) => setState(() { for (final r in _visible) r.status = status; });

  Color _statusColor(String s) {
    switch (s) {
      case 'present': return Colors.green; case 'absent': return Colors.red; case 'leave': return Colors.orange;
      case 'half_day': return Colors.amber.shade700; case 'holiday': return Colors.blue; case 'rest_day': return Colors.blueGrey;
      default: return AppTheme.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final vis = _visible;
    final counts = <String, int>{};
    for (final r in vis) counts[r.status] = (counts[r.status] ?? 0) + 1;

    return Container(color: AppTheme.background, child: Column(children: [
      Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          const Text('Attendance', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(width: 12),
          OutlinedButton.icon(icon: const Icon(Icons.calendar_today_outlined, size: 15),
            label: Text(DateFormat('EEE, d MMM yyyy').format(_date), style: const TextStyle(fontSize: 12)),
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime.now());
              if (d != null) { setState(() => _date = d); await _loadForDate(); await _loadAudit(); }
            }),
          const SizedBox(width: 6),
          IconButton(icon: const Icon(Icons.chevron_left, size: 20), tooltip: 'Previous day', onPressed: () async { setState(() => _date = _date.subtract(const Duration(days: 1))); await _loadForDate(); await _loadAudit(); }),
          if (_canNext) IconButton(icon: const Icon(Icons.chevron_right, size: 20), tooltip: 'Next day', onPressed: () async { setState(() => _date = _date.add(const Duration(days: 1))); await _loadForDate(); await _loadAudit(); }),
          const SizedBox(width: 8),
          if (_isAdmin) _branchDropdown(),
          const Spacer(),
          SizedBox(width: 170, child: TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true, border: OutlineInputBorder()), onChanged: (v) => setState(() => _search = v))),
          const SizedBox(width: 8),
          OutlinedButton.icon(icon: const Icon(Icons.print_outlined, size: 15), label: const Text('Print register', style: TextStyle(fontSize: 12)), onPressed: _printDialog),
          const SizedBox(width: 8),
          PopupMenuButton<String>(tooltip: 'Mark all', onSelected: _markAll,
            itemBuilder: (_) => _statuses.map((s) => PopupMenuItem(value: s['v'], child: Text('Mark all ${s['l']}'))).toList(),
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.done_all, size: 15), SizedBox(width: 5), Text('Mark all', style: TextStyle(fontSize: 12)), Icon(Icons.arrow_drop_down, size: 16)]))),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: _savingAll ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined, size: 16),
            label: const Text('Save all'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            onPressed: _savingAll ? null : _saveAll),
        ])),
      if (!_loading) Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Text('${vis.length} employees', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 14),
          for (final s in _statuses) if ((counts[s['v']] ?? 0) > 0) Container(margin: const EdgeInsets.only(right: 10), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: _statusColor(s['v']!).withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
            child: Text('${s['l']}: ${counts[s['v']]}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _statusColor(s['v']!)))),
          if (!_isAdmin && _effectiveBranch() != null) ...[const Spacer(), Text('Branch: ${_branchName[_effectiveBranch()] ?? ''}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))],
        ])),
      Expanded(child: _loading
        ? const Center(child: CircularProgressIndicator())
        : vis.isEmpty
          ? const Center(child: Text('No active employees for this branch. Add employees in the Employee Directory first.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)))
          : ListView(padding: const EdgeInsets.all(20), children: [
              Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)), child: Column(children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
                  child: Row(children: const [
                    Expanded(flex: 3, child: Text('Employee', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 132, child: Text('Status', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 150, child: Text('Check-in', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 150, child: Text('Check-out', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 56, child: Text('Worked', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 50, child: Text('Shift', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 12),
                    Expanded(flex: 2, child: Text('Remarks', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 40),
                  ])),
                for (var i = 0; i < vis.length; i++) _rowWidget(vis[i], i == vis.length - 1),
              ])),
              const SizedBox(height: 20),
              _auditSection(),
              const SizedBox(height: 30),
            ])),
    ]));
  }

  Widget _rowWidget(_Row r, bool last) {
    final worked = _hours(r.checkIn, r.checkOut);
    final shift = _shiftFor(r.shiftId);
    final total = (shift?['work_hours'] as num?)?.toDouble();
    final timesEnabled = r.status == 'present' || r.status == 'half_day';
    final dirty = r.recordId == null || _diff(r) != null;
    return Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.5)))),
      child: Row(children: [
        Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          Text('${r.code}${r.deptName.isNotEmpty ? '  \u00b7  ${r.deptName}' : ''}${shift != null ? '  \u00b7  ${shift['name']}' : ''}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
        ])),
        SizedBox(width: 132, child: DropdownButtonFormField<String>(
          value: r.status, isDense: true, isExpanded: true,
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: TextStyle(fontSize: 12, color: _statusColor(r.status), fontWeight: FontWeight.w600),
          items: _statuses.map((s) => DropdownMenuItem(value: s['v'], child: Text(s['l'] ?? '', style: TextStyle(fontSize: 12, color: _statusColor(s['v']!), fontWeight: FontWeight.w600)))).toList(),
          onChanged: (v) => setState(() => r.status = v ?? 'present'))),
        const SizedBox(width: 8),
        SizedBox(width: 142, child: _timeCell(r.checkIn, timesEnabled, () => _stampNow(r, true), () => _pickTime(r, true), () => setState(() => r.checkIn = null), 'In')),
        const SizedBox(width: 8),
        SizedBox(width: 142, child: _timeCell(r.checkOut, timesEnabled && r.checkIn != null, () => _stampNow(r, false), () => _pickTime(r, false), () => setState(() => r.checkOut = null), 'Out')),
        const SizedBox(width: 8),
        SizedBox(width: 52, child: Text(worked != null ? worked.toString() : '\u2014', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        SizedBox(width: 50, child: Text(total != null ? total.toString() : '\u2014', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: TextField(controller: r.remarks,
          decoration: const InputDecoration(hintText: 'Optional', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12), onChanged: (_) => setState(() {}))),
        SizedBox(width: 40, child: r.saving
          ? const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
          : IconButton(icon: Icon(Icons.save_outlined, size: 18, color: dirty ? AppTheme.primary : AppTheme.border), tooltip: 'Save row', onPressed: dirty ? () => _saveRow(r) : null)),
      ]));
  }

  Widget _timeCell(String? value, bool enabled, VoidCallback onStamp, VoidCallback onPick, VoidCallback onClear, String label) {
    if (value == null) {
      return OutlinedButton.icon(
        onPressed: enabled ? onStamp : null,
        icon: const Icon(Icons.touch_app_outlined, size: 14),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        label: Text(label == 'In' ? 'Check in' : 'Check out', style: const TextStyle(fontSize: 11)));
    }
    return Container(padding: const EdgeInsets.only(left: 8), decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
      child: Row(children: [
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        InkWell(onTap: enabled ? onPick : null, child: const Padding(padding: EdgeInsets.all(5), child: Icon(Icons.edit_outlined, size: 13, color: AppTheme.textSecondary))),
        InkWell(onTap: enabled ? onClear : null, child: const Padding(padding: EdgeInsets.all(5), child: Icon(Icons.close, size: 13, color: AppTheme.textSecondary))),
      ]));
  }

  Widget _auditSection() {
    if (_audit.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Edit trail (this date)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: Column(children: [
          for (var i = 0; i < _audit.length; i++) Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(border: i == _audit.length - 1 ? null : Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.5)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(margin: const EdgeInsets.only(top: 2, right: 8), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: (_audit[i]['action'] == 'created' ? Colors.green : Colors.orange).withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                child: Text(_audit[i]['action'] as String? ?? '', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: _audit[i]['action'] == 'created' ? Colors.green.shade700 : Colors.orange.shade800))),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_empName[_audit[i]['employee_id']] ?? _audit[i]['employee_id'] ?? ''} \u2014 ${_audit[i]['changes'] ?? ''}', style: const TextStyle(fontSize: 12)),
                Text('${_audit[i]['changed_by_name'] ?? ''}  \u00b7  ${_audit[i]['changed_at'] != null ? DateFormat('d MMM HH:mm').format(DateTime.parse(_audit[i]['changed_at'] as String).toLocal()) : ''}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
              ])),
            ])),
        ])),
    ]);
  }

  Widget _branchDropdown() => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.border)),
    child: DropdownButtonHideUnderline(child: DropdownButton<String>(
      value: _branchFilter, isDense: true, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
      items: [const DropdownMenuItem(value: '__all__', child: Text('All branches', style: TextStyle(fontSize: 12))),
        ..._branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '', style: const TextStyle(fontSize: 12))))],
      onChanged: (v) => setState(() => _branchFilter = v ?? '__all__'))));

  // ---------- PDF / print register over a date range ----------
  Future<void> _printDialog() async {
    DateTime from = DateTime(_date.year, _date.month, 1);
    DateTime to = _date;
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
      title: const Text('Print attendance register'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () async { final d = await showDatePicker(context: ctx, initialDate: from, firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setLocal(() => from = d); }, child: Text('From: ${DateFormat('d MMM yyyy').format(from)}', style: const TextStyle(fontSize: 12)))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () async { final d = await showDatePicker(context: ctx, initialDate: to, firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setLocal(() => to = d); }, child: Text('To: ${DateFormat('d MMM yyyy').format(to)}', style: const TextStyle(fontSize: 12)))),
        ]),
        const SizedBox(height: 8),
        Text(_isAdmin ? (_branchFilter == '__all__' ? 'All branches' : 'Branch: ${_branchName[_branchFilter]}') : 'Branch: ${_branchName[_effectiveBranch()] ?? 'current'}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () { Navigator.pop(ctx); _generateRegister(from, to); }, style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Generate'))],
    )));
  }

  Future<void> _generateRegister(DateTime from, DateTime to) async {
    final orgId = _orgId; if (orgId == null) return;
    final eff = _effectiveBranch();
    try {
      final client = Supabase.instance.client;
      final attRows = List<Map<String, dynamic>>.from(
        await client.from('hr_attendance').select().eq('org_id', orgId).gte('att_date', _fmt(from)).lte('att_date', _fmt(to)).order('att_date'));
      final aud = List<Map<String, dynamic>>.from(
        await client.from('hr_attendance_audit').select().eq('org_id', orgId).gte('att_date', _fmt(from)).lte('att_date', _fmt(to)).order('changed_at', ascending: false).limit(300));

      // index attendance: empId -> dateStr -> record
      final byEmpDate = <String, Map<String, Map<String, dynamic>>>{};
      for (final a in attRows) {
        if (eff != null && a['branch_id'] != eff) continue;
        ((byEmpDate[a['employee_id'] as String] ??= <String, Map<String, dynamic>>{}))[a['att_date'] as String] = a;
      }
      final emps = _employees.where((e) => eff == null || e['branch_id'] == eff).toList();

      final days = <DateTime>[];
      for (var d = _d0(from); !d.isAfter(_d0(to)); d = d.add(const Duration(days: 1))) days.add(d);
      final single = days.length <= 1;

      String esc(String? s) => (s ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      String code(String? st) { switch (st) { case 'present': return 'P'; case 'absent': return 'A'; case 'leave': return 'L'; case 'half_day': return '&frac12;'; case 'holiday': return 'H'; case 'rest_day': return 'R'; default: return ''; } }
      String varText(int? actual, int? ref) { if (actual == null || ref == null) return '-'; final d = actual - ref; if (d == 0) return 'on time'; return d > 0 ? '+${d}m' : '${d}m'; }
      String trimNum(double v) { final r = (v * 100).roundToDouble() / 100; return r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toString(); }

      String body;
      if (single) {
        final ds = _fmt(days.isEmpty ? from : days.first);
        String rows = '';
        for (final e in emps) {
          final rec = byEmpDate[e['id']]?[ds];
          final shift = _shiftFor(e['shift_id'] as String?);
          final sStart = _min(shift?['start_time'] as String?), sEnd = _min(shift?['end_time'] as String?);
          final stdHrs = (shift?['work_hours'] as num?)?.toDouble();
          final cin = rec?['check_in'] as String?, cout = rec?['check_out'] as String?;
          final wh = _hours(cin, cout);
          rows += '<tr><td class="emp">${esc(e['full_name'] as String?)}<span class="code">${esc(e['employee_code'] as String?)}</span></td>'
              '<td>${rec?['status'] ?? '-'}</td><td>${cin ?? '-'}</td><td>${cout ?? '-'}</td>'
              '<td class="r">${wh?.toStringAsFixed(2) ?? '-'}</td><td class="r">${stdHrs?.toStringAsFixed(2) ?? '-'}</td>'
              '<td class="c">${varText(_min(cin), sStart)}</td><td class="c">${varText(_min(cout), sEnd)}</td>'
              '<td>${esc(rec?['remarks'] as String?)}</td></tr>';
        }
        body = '<table><thead><tr><th class="emp">Employee</th><th>Status</th><th>In</th><th>Out</th><th>Worked</th><th>Shift</th><th>In var</th><th>Out var</th><th>Remarks</th></tr></thead><tbody>'
            '${rows.isEmpty ? '<tr><td colspan="9">No employees.</td></tr>' : rows}</tbody></table>';
      } else {
        String head = '<th class="emp">Employee</th>';
        for (final d in days) head += '<th class="day">${d.day}</th>';
        head += '<th class="r">Hrs var</th><th class="r">Days</th>';
        String rows = '';
        for (final e in emps) {
          final shift = _shiftFor(e['shift_id'] as String?);
          final stdHrs = (shift?['work_hours'] as num?)?.toDouble() ?? 0;
          double worked = 0, expected = 0, daysWorked = 0;
          String cells = '';
          for (final d in days) {
            final rec = byEmpDate[e['id']]?[_fmt(d)];
            final st = rec?['status'] as String?;
            cells += '<td class="day">${code(st)}</td>';
            if (st == 'present' || st == 'half_day') {
              final wh = _hours(rec?['check_in'] as String?, rec?['check_out'] as String?);
              if (wh != null) worked += wh;
              if (st == 'present') { daysWorked += 1; expected += stdHrs; } else { daysWorked += 0.5; expected += stdHrs / 2; }
            }
          }
          final variance = worked - expected;
          final vStr = (worked == 0 && expected == 0) ? '-' : (variance.abs() < 0.05 ? '0' : (variance > 0 ? '+${trimNum(variance)}' : trimNum(variance)));
          rows += '<tr><td class="emp">${esc(e['full_name'] as String?)}<span class="code">${esc(e['employee_code'] as String?)}</span></td>$cells'
              '<td class="r">$vStr</td><td class="r">${trimNum(daysWorked)}</td></tr>';
        }
        body = '<table class="matrix"><thead><tr>$head</tr></thead><tbody>'
            '${rows.isEmpty ? '<tr><td>No employees.</td></tr>' : rows}</tbody></table>'
            '<div class="legend">P = Present &nbsp; A = Absent &nbsp; L = Leave &nbsp; &frac12; = Half day &nbsp; H = Holiday &nbsp; R = Rest day &nbsp;&nbsp;|&nbsp;&nbsp; Hrs var = worked hours minus expected shift hours (+ surplus / - short)</div>';
      }

      String auditRows = '';
      for (final a in aud) {
        auditRows += '<tr><td>${a['att_date'] ?? ''}</td><td>${esc(_empName[a['employee_id']] ?? a['employee_id'] as String?)}</td>'
            '<td>${a['action'] ?? ''}</td><td>${esc(a['changes'] as String?)}</td><td>${esc(a['changed_by_name'] as String?)}</td>'
            '<td>${a['changed_at'] != null ? DateFormat('d MMM HH:mm').format(DateTime.parse(a['changed_at'] as String).toLocal()) : ''}</td></tr>';
      }
      final auditHtml = auditRows.isEmpty ? '' : '<h2>Edit trail</h2><table class="trail"><thead><tr><th>Date</th><th>Employee</th><th>Action</th><th>Change</th><th>By</th><th>When</th></tr></thead><tbody>$auditRows</tbody></table>';

      final branchLabel = esc(eff != null ? (_branchName[eff] ?? '') : 'All branches');
      final headerDate = single ? DateFormat('EEE, d MMM yyyy').format(days.isEmpty ? from : days.first)
          : '${DateFormat('d MMM').format(from)} &ndash; ${DateFormat('d MMM yyyy').format(to)}';
      final fontSize = (!single && days.length > 20) ? 8 : (!single ? 9 : 11);
      final htmlContent = '''<!DOCTYPE html><html><head><meta charset="utf-8"><title>Attendance Register</title>
<style>
*{box-sizing:border-box}
body{font-family:Arial,Helvetica,sans-serif;padding:18px;color:#000}
h1{font-size:18px;margin:0 0 2px}
h2{font-size:13px;margin:18px 0 6px}
.meta{color:#555;font-size:11px;margin-bottom:12px}
table{width:100%;border-collapse:collapse;font-size:${fontSize}px}
th,td{border:1px solid #999;padding:3px 5px;text-align:left;vertical-align:top}
th{background:#eee;font-weight:700}
td.r,th.r{text-align:right}
td.c{text-align:center}
td.emp,th.emp{text-align:left;white-space:nowrap}
td.emp .code{display:block;color:#777;font-size:0.85em;font-weight:400}
table.matrix th.day,table.matrix td.day{text-align:center;padding:3px 2px;width:18px}
table.trail{font-size:10px;margin-top:6px}
.legend{font-size:10px;color:#555;margin-top:8px}
@media print{body{padding:6px}@page{size:landscape;margin:8mm}}
</style></head><body>
<h1>Attendance Register</h1>
<div class="meta">$headerDate &nbsp;|&nbsp; $branchLabel &nbsp;|&nbsp; Generated ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())}</div>
$body
$auditHtml
<script>window.onload=function(){window.print();}</script>
</body></html>''';
      final blob = html.Blob([htmlContent], 'text/html;charset=utf-8');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.window.open(url, '_blank');
    } catch (e) { _snack('Register failed: ' + e.toString()); }
  }
}

class _Row {
  final String empId, label, code, deptName;
  final String? branchId, shiftId;
  String? recordId;
  String status;
  String? checkIn, checkOut;
  final TextEditingController remarks = TextEditingController();
  String origStatus = 'present'; String? origIn, origOut; String origRemarks = '';
  bool saving = false;
  _Row({required this.empId, required this.label, required this.code, required this.deptName, this.branchId, this.shiftId, this.recordId, required this.status, this.checkIn, this.checkOut});
  void snapshot() { origStatus = status; origIn = checkIn; origOut = checkOut; origRemarks = remarks.text; }
}
