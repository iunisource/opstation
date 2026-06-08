import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class HrAttendanceScreen extends ConsumerStatefulWidget {
  const HrAttendanceScreen({super.key});
  @override
  ConsumerState<HrAttendanceScreen> createState() => _State();
}

class _State extends ConsumerState<HrAttendanceScreen> {
  bool _loading = true;
  bool _saving = false;
  DateTime _date = DateTime.now();
  String _branchFilter = '__all__';
  String _search = '';

  List<Map<String, dynamic>> _employees = [];     // active
  List<Map<String, dynamic>> _branches = [];
  Map<String, String> _branchName = {};
  Map<String, String> _deptName = {};

  // per-employee editable row state
  final List<_Row> _rows = [];

  static const _statuses = [
    {'v': 'present', 'l': 'Present'}, {'v': 'absent', 'l': 'Absent'}, {'v': 'leave', 'l': 'Leave'},
    {'v': 'half_day', 'l': 'Half day'}, {'v': 'holiday', 'l': 'Holiday'}, {'v': 'rest_day', 'l': 'Rest day'},
  ];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() { for (final r in _rows) r.remarks.dispose(); super.dispose(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

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
      final emps = await client.from('hr_employees')
          .select('id, full_name, employee_code, branch_id, department_id, status')
          .eq('org_id', orgId).eq('status', 'active').order('full_name');
      _employees = List<Map<String, dynamic>>.from(emps);
      await _loadForDate();
    } catch (e) { _snack('Load error: $e'); }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadForDate() async {
    final orgId = _orgId; if (orgId == null) return;
    final dateStr = DateFormat('yyyy-MM-dd').format(_date);
    Map<String, Map<String, dynamic>> existing = {};
    try {
      final rows = await Supabase.instance.client.from('hr_attendance')
          .select().eq('org_id', orgId).eq('att_date', dateStr);
      for (final r in (rows as List)) existing[r['employee_id'] as String] = Map<String, dynamic>.from(r);
    } catch (_) {}
    for (final r in _rows) r.remarks.dispose();
    _rows.clear();
    for (final e in _employees) {
      final rec = existing[e['id']];
      final row = _Row(
        empId: e['id'] as String,
        label: e['full_name'] as String? ?? '',
        code: e['employee_code'] as String? ?? '',
        branchId: e['branch_id'] as String?,
        deptName: _deptName[e['department_id']] ?? '',
        recordId: rec?['id'] as String?,
        status: rec?['status'] as String? ?? 'present',
        checkIn: rec?['check_in'] as String?,
        checkOut: rec?['check_out'] as String?,
      );
      row.remarks.text = rec?['remarks'] as String? ?? '';
      _rows.add(row);
    }
    if (mounted) setState(() {});
  }

  List<_Row> get _visible {
    return _rows.where((r) {
      if (_branchFilter != '__all__' && r.branchId != _branchFilter) return false;
      if (_search.isNotEmpty) {
        final q = _search.toLowerCase();
        if (!r.label.toLowerCase().contains(q) && !r.code.toLowerCase().contains(q)) return false;
      }
      return true;
    }).toList();
  }

  double? _hours(String? cin, String? cout) {
    final a = _toMin(cin), b = _toMin(cout);
    if (a == null || b == null) return null;
    final diff = b - a;
    if (diff <= 0) return null;
    return (diff / 60.0 * 100).roundToDouble() / 100;
  }

  int? _toMin(String? hhmm) {
    if (hhmm == null || hhmm.isEmpty) return null;
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  Future<void> _pickTime(_Row r, bool isIn) async {
    final cur = isIn ? r.checkIn : r.checkOut;
    TimeOfDay initial = const TimeOfDay(hour: 9, minute: 0);
    final m = _toMin(cur);
    if (m != null) initial = TimeOfDay(hour: m ~/ 60, minute: m % 60);
    final t = await showTimePicker(context: context, initialTime: initial);
    if (t == null) return;
    final s = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() { if (isIn) r.checkIn = s; else r.checkOut = s; });
  }

  void _markAll(String status) => setState(() { for (final r in _visible) r.status = status; });

  Future<void> _save() async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    final vis = _visible;
    if (vis.isEmpty) { _snack('No employees to save'); return; }
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final now = DateTime.now().toIso8601String();
      final payload = vis.map((r) => {
        'id': r.recordId ?? ('att_${DateTime.now().microsecondsSinceEpoch}_${r.empId}'),
        'org_id': orgId, 'employee_id': r.empId, 'branch_id': r.branchId, 'att_date': dateStr,
        'status': r.status, 'check_in': r.checkIn, 'check_out': r.checkOut,
        'work_hours': _hours(r.checkIn, r.checkOut),
        'remarks': r.remarks.text.trim().isEmpty ? null : r.remarks.text.trim(),
        'updated_at': now,
      }).toList();
      await client.from('hr_attendance').upsert(payload, onConflict: 'org_id,employee_id,att_date');
      _snack('Attendance saved for $dateStr (${vis.length})');
      await _loadForDate();
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'present': return Colors.green;
      case 'absent': return Colors.red;
      case 'leave': return Colors.orange;
      case 'half_day': return Colors.amber.shade700;
      case 'holiday': return Colors.blue;
      case 'rest_day': return Colors.blueGrey;
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
              final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) { setState(() => _date = d); await _loadForDate(); }
            }),
          const SizedBox(width: 6),
          IconButton(icon: const Icon(Icons.chevron_left, size: 20), tooltip: 'Previous day', onPressed: () async { setState(() => _date = _date.subtract(const Duration(days: 1))); await _loadForDate(); }),
          IconButton(icon: const Icon(Icons.chevron_right, size: 20), tooltip: 'Next day', onPressed: () async { setState(() => _date = _date.add(const Duration(days: 1))); await _loadForDate(); }),
          const SizedBox(width: 8),
          _branchDropdown(),
          const Spacer(),
          SizedBox(width: 200, child: TextField(decoration: const InputDecoration(hintText: 'Search employee...', prefixIcon: Icon(Icons.search, size: 15), isDense: true, border: OutlineInputBorder()), onChanged: (v) => setState(() => _search = v))),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: 'Mark all',
            onSelected: _markAll,
            itemBuilder: (_) => _statuses.map((s) => PopupMenuItem(value: s['v'], child: Text('Mark all ${s['l']}'))).toList(),
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.done_all, size: 15), SizedBox(width: 5), Text('Mark all', style: TextStyle(fontSize: 12)), Icon(Icons.arrow_drop_down, size: 16)])),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined, size: 16),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            onPressed: _saving ? null : _save),
        ])),
      // summary chips
      if (!_loading) Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Text('${vis.length} employees', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 14),
          for (final s in _statuses) if ((counts[s['v']] ?? 0) > 0) ...[
            Container(margin: const EdgeInsets.only(right: 10), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: _statusColor(s['v']!).withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
              child: Text('${s['l']}: ${counts[s['v']]}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _statusColor(s['v']!)))),
          ],
        ])),
      Expanded(child: _loading
        ? const Center(child: CircularProgressIndicator())
        : vis.isEmpty
          ? const Center(child: Text('No active employees. Add employees in the Employee Directory first.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)))
          : ListView(padding: const EdgeInsets.all(20), children: [
              Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)), child: Column(children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
                  child: Row(children: const [
                    Expanded(flex: 3, child: Text('Employee', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 150, child: Text('Status', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 90, child: Text('Check-in', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 90, child: Text('Check-out', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 60, child: Text('Hours', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                    SizedBox(width: 16),
                    Expanded(flex: 2, child: Text('Remarks', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
                  ])),
                for (var i = 0; i < vis.length; i++) _rowWidget(vis[i], i == vis.length - 1),
              ])),
              const SizedBox(height: 30),
            ])),
    ]));
  }

  Widget _rowWidget(_Row r, bool last) {
    final hrs = _hours(r.checkIn, r.checkOut);
    final timesEnabled = r.status == 'present' || r.status == 'half_day';
    return Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.5)))),
      child: Row(children: [
        Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          Text('${r.code}${r.deptName.isNotEmpty ? '  \u00b7  ${r.deptName}' : ''}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
        ])),
        SizedBox(width: 150, child: DropdownButtonFormField<String>(
          value: r.status, isDense: true, isExpanded: true,
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: TextStyle(fontSize: 12, color: _statusColor(r.status), fontWeight: FontWeight.w600),
          items: _statuses.map((s) => DropdownMenuItem(value: s['v'], child: Text(s['l'] ?? '', style: TextStyle(fontSize: 12, color: _statusColor(s['v']!), fontWeight: FontWeight.w600)))).toList(),
          onChanged: (v) => setState(() => r.status = v ?? 'present'))),
        const SizedBox(width: 8),
        SizedBox(width: 82, child: _timeBox(r.checkIn, timesEnabled ? () => _pickTime(r, true) : null, timesEnabled ? () => setState(() => r.checkIn = null) : null)),
        const SizedBox(width: 8),
        SizedBox(width: 82, child: _timeBox(r.checkOut, timesEnabled ? () => _pickTime(r, false) : null, timesEnabled ? () => setState(() => r.checkOut = null) : null)),
        const SizedBox(width: 8),
        SizedBox(width: 56, child: Text(hrs != null ? hrs.toString() : '\u2014', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        const SizedBox(width: 16),
        Expanded(flex: 2, child: TextField(controller: r.remarks,
          decoration: const InputDecoration(hintText: 'Optional', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12))),
      ]));
  }

  Widget _timeBox(String? value, VoidCallback? onTap, VoidCallback? onClear) => InkWell(
    onTap: onTap,
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0)), color: onTap == null ? AppTheme.background : null),
      child: Row(children: [
        Expanded(child: Text(value ?? '\u2014', style: TextStyle(fontSize: 12, color: value != null ? AppTheme.textPrimary : AppTheme.textSecondary))),
        if (value != null && onClear != null) GestureDetector(onTap: onClear, child: const Icon(Icons.close, size: 12, color: AppTheme.textSecondary))
        else if (onTap != null) const Icon(Icons.access_time, size: 12, color: AppTheme.textSecondary),
      ])));

  Widget _branchDropdown() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.border)),
    child: DropdownButtonHideUnderline(child: DropdownButton<String>(
      value: _branchFilter, isDense: true, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
      items: [
        const DropdownMenuItem(value: '__all__', child: Text('All branches', style: TextStyle(fontSize: 12))),
        ..._branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '', style: const TextStyle(fontSize: 12)))),
      ],
      onChanged: (v) => setState(() => _branchFilter = v ?? '__all__'))));
}

class _Row {
  final String empId, label, code, deptName;
  final String? branchId;
  String? recordId;
  String status;
  String? checkIn, checkOut;
  final TextEditingController remarks = TextEditingController();
  _Row({required this.empId, required this.label, required this.code, required this.deptName, this.branchId, this.recordId, required this.status, this.checkIn, this.checkOut});
}
