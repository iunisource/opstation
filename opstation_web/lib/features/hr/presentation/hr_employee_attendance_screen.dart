// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Full-screen, filterable, printable attendance report for a single employee.
/// Opened from the employee profile "Attendance record" button
/// (route: /hr/employee-attendance?emp=<id>).
class HrEmployeeAttendanceScreen extends ConsumerStatefulWidget {
  const HrEmployeeAttendanceScreen({super.key, required this.empId});
  final String empId;
  @override
  ConsumerState<HrEmployeeAttendanceScreen> createState() => _State();
}

class _State extends ConsumerState<HrEmployeeAttendanceScreen> {
  static const _statuses = [
    {'v': 'present', 'l': 'Present'},
    {'v': 'absent', 'l': 'Absent'},
    {'v': 'leave', 'l': 'Leave'},
    {'v': 'half_day', 'l': 'Half day'},
    {'v': 'holiday', 'l': 'Holiday'},
    {'v': 'rest_day', 'l': 'Rest day'},
  ];

  bool _loading = true;
  String? _error;

  Map<String, dynamic>? _emp;
  Map<String, dynamic>? _shift;
  String _deptName = '', _desigName = '', _branchName = '', _shiftName = '';
  int? _orgRestDay; // 0=Sunday … 6=Saturday
  String _orgName = '';

  List<Map<String, dynamic>> _rows = []; // raw attendance rows in range

  // filters
  late DateTime _from;
  late DateTime _to;
  final Set<String> _statusFilter = {}; // empty => all

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = DateTime(now.year, 1, 1); // this year by default
    _orgName = ref.read(currentUserProvider)?.orgName ?? '';
    _load();
  }

  String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  int? _min(String? t) {
    if (t == null || t.isEmpty) return null;
    final p = t.split(':');
    if (p.length < 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  double? _hours(String? cin, String? cout) {
    final a = _min(cin), b = _min(cout);
    if (a == null || b == null) return null;
    var diff = b - a;
    if (diff <= 0) diff += 1440;
    return (diff / 60.0 * 100).roundToDouble() / 100;
  }

  bool _isRestWeekday(DateTime d) => _orgRestDay != null && (d.weekday % 7) == _orgRestDay;

  double _halfDayHrs(Map? shift) {
    final h = (shift?['half_day_hours'] as num?)?.toDouble();
    if (h != null && h > 0) return h;
    return ((shift?['work_hours'] as num?)?.toDouble() ?? 0) / 2;
  }

  // Effective, report-ready status (applies rest-day calendar + half-day rule).
  String _effStatus(Map<String, dynamic>? rec, DateTime d) {
    final raw = rec?['status'] as String?;
    if (raw == 'absent' || raw == 'leave' || raw == 'holiday' || raw == 'rest_day') return raw!;
    final wh = _hours(rec?['check_in'] as String?, rec?['check_out'] as String?);
    final worked = wh != null && wh > 0;
    if (_isRestWeekday(d) && !worked) return 'rest_day';
    if (raw == null) return _isRestWeekday(d) ? 'rest_day' : 'absent';
    if (raw == 'present' && worked && wh! <= _halfDayHrs(_shift)) return 'half_day';
    return raw;
  }

  // Late = worked day where check-in is after shift start + grace.
  bool _isLate(Map<String, dynamic> rec) {
    final ci = _min(rec['check_in'] as String?);
    if (ci == null) return false;
    final start = _min(_shift?['start_time'] as String?);
    if (start == null) return false;
    final grace = (_shift?['grace_minutes'] as num?)?.toInt() ?? 0;
    return ci > start + grace;
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) {
      setState(() { _loading = false; _error = 'Not authenticated'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final client = Supabase.instance.client;
      final emp = await client
          .from('hr_employees')
          .select()
          .eq('org_id', orgId)
          .eq('id', widget.empId)
          .maybeSingle();
      if (emp == null) {
        setState(() { _loading = false; _error = 'Employee not found'; });
        return;
      }
      _emp = Map<String, dynamic>.from(emp);

      // lookups
      final deptId = _emp!['department_id'] as String?;
      final desigId = _emp!['designation_id'] as String?;
      final branchId = _emp!['branch_id'] as String?;
      final shiftId = _emp!['shift_id'] as String?;
      if (deptId != null) {
        final d = await client.from('hr_departments').select('name').eq('id', deptId).maybeSingle();
        _deptName = (d?['name'] as String?) ?? '';
      }
      if (desigId != null) {
        final d = await client.from('hr_designations').select('name').eq('id', desigId).maybeSingle();
        _desigName = (d?['name'] as String?) ?? '';
      }
      if (branchId != null) {
        final d = await client.from('branches').select('name').eq('id', branchId).maybeSingle();
        _branchName = (d?['name'] as String?) ?? '';
      }
      if (shiftId != null) {
        final d = await client.from('hr_shifts').select().eq('id', shiftId).maybeSingle();
        if (d != null) { _shift = Map<String, dynamic>.from(d); _shiftName = (d['name'] as String?) ?? ''; }
      }
      try {
        final c = await client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.weekly_rest_day').maybeSingle();
        final v = c?['value'] as String?;
        _orgRestDay = (v != null && v.isNotEmpty) ? int.tryParse(v) : null;
      } catch (_) {}

      // If join date is before default "from", keep default (this year) but
      // let the user widen via the All-time preset.
      await _loadRows();
    } catch (e) {
      setState(() { _loading = false; _error = 'Failed to load: $e'; });
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadRows() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final r = await Supabase.instance.client
        .from('hr_attendance')
        .select('att_date, status, check_in, check_out, work_hours, is_penalty')
        .eq('org_id', orgId)
        .eq('employee_id', widget.empId)
        .gte('att_date', _fmt(_from))
        .lte('att_date', _fmt(_to))
        .order('att_date', ascending: false);
    _rows = List<Map<String, dynamic>>.from(r);
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try { await _loadRows(); } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickDate(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() { if (isFrom) _from = picked; else _to = DateTime(picked.year, picked.month, picked.day); });
    await _reload();
  }

  void _preset(String p) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _to = today;
      switch (p) {
        case 'month': _from = DateTime(now.year, now.month, 1); break;
        case '30': _from = today.subtract(const Duration(days: 29)); break;
        case 'year': _from = DateTime(now.year, 1, 1); break;
        case 'all':
          final jd = _emp?['join_date'] as String?;
          _from = (jd != null && jd.isNotEmpty)
              ? (DateTime.tryParse(jd) ?? DateTime(2015)) : DateTime(2015);
          break;
      }
    });
    _reload();
  }

  // Rows after status filter, each enriched with effective status/late/hours.
  List<_Rec> get _filtered {
    final out = <_Rec>[];
    for (final a in _rows) {
      final dateStr = a['att_date'] as String? ?? '';
      final d = DateTime.tryParse(dateStr) ?? DateTime.now();
      final eff = _effStatus(a, d);
      if (_statusFilter.isNotEmpty && !_statusFilter.contains(eff)) continue;
      final wh = (a['work_hours'] as num?)?.toDouble() ?? _hours(a['check_in'] as String?, a['check_out'] as String?);
      out.add(_Rec(
        date: d,
        dateStr: dateStr,
        status: eff,
        checkIn: a['check_in'] as String?,
        checkOut: a['check_out'] as String?,
        hours: wh,
        late: (eff == 'present' || eff == 'half_day') && _isLate(a),
        penalty: a['is_penalty'] == true,
      ));
    }
    return out;
  }

  Map<String, int> _counts(List<_Rec> recs) {
    final c = <String, int>{};
    for (final r in recs) c[r.status] = (c[r.status] ?? 0) + 1;
    return c;
  }

  double _totalHours(List<_Rec> recs) {
    double t = 0;
    for (final r in recs) t += r.hours ?? 0;
    return (t * 100).roundToDouble() / 100;
  }

  int _lateCount(List<_Rec> recs) => recs.where((r) => r.late).length;

  Color _statusColor(String s) {
    switch (s) {
      case 'present': return Colors.green;
      case 'absent': return Colors.red;
      case 'leave': return Colors.orange;
      case 'half_day': return Colors.amber.shade700;
      case 'holiday': return Colors.blue;
      case 'rest_day': return Colors.blueGrey;
      default: return Colors.grey;
    }
  }

  String _statusLabel(String s) {
    for (final m in _statuses) { if (m['v'] == s) return m['l']!; }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final emp = _emp;
    final name = (emp?['full_name'] as String?) ?? 'Employee';
    final code = (emp?['employee_code'] as String?) ?? '';
    final recs = _filtered;
    final counts = _counts(recs);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () {
            if (context.canPop()) { context.pop(); } else { context.go('/hr/employees?focus=${widget.empId}'); }
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(
              [if (code.isNotEmpty) code, if (_desigName.isNotEmpty) _desigName, if (_deptName.isNotEmpty) _deptName].join('  ·  '),
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
          ],
        ),
        actions: [
          if (!_loading && _error == null)
            TextButton.icon(
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Print / PDF'),
              onPressed: _print,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.textSecondary)))
              : Column(
                  children: [
                    _filterBar(),
                    _summaryStrip(recs, counts),
                    const Divider(height: 1),
                    Expanded(child: _table(recs)),
                  ],
                ),
    );
  }

  Widget _filterBar() {
    return Container(
      color: AppTheme.card,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today_outlined, size: 15),
              label: Text('From  ${_fmt(_from)}', style: const TextStyle(fontSize: 12)),
              onPressed: () => _pickDate(true),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_outlined, size: 15),
              label: Text('To  ${_fmt(_to)}', style: const TextStyle(fontSize: 12)),
              onPressed: () => _pickDate(false),
            ),
            const SizedBox(width: 4),
            _presetChip('This month', 'month'),
            _presetChip('Last 30 days', '30'),
            _presetChip('This year', 'year'),
            _presetChip('All time', 'all'),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Status:', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            for (final s in _statuses)
              FilterChip(
                label: Text(s['l']!, style: const TextStyle(fontSize: 11)),
                selected: _statusFilter.contains(s['v']),
                visualDensity: VisualDensity.compact,
                selectedColor: _statusColor(s['v']!).withOpacity(0.18),
                checkmarkColor: _statusColor(s['v']!),
                onSelected: (sel) => setState(() {
                  if (sel) { _statusFilter.add(s['v']!); } else { _statusFilter.remove(s['v']!); }
                }),
              ),
            if (_statusFilter.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => _statusFilter.clear()),
                child: const Text('Clear', style: TextStyle(fontSize: 11)),
              ),
          ]),
        ],
      ),
    );
  }

  Widget _presetChip(String label, String key) => ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact,
        onPressed: () => _preset(key),
      );

  Widget _summaryStrip(List<_Rec> recs, Map<String, int> counts) {
    final present = counts['present'] ?? 0;
    final half = counts['half_day'] ?? 0;
    final absent = counts['absent'] ?? 0;
    final leave = counts['leave'] ?? 0;
    // Working days = everything except holiday/rest_day.
    final workingDays = recs.where((r) => r.status != 'holiday' && r.status != 'rest_day').length;
    final workedDays = present + half; // half counts as a worked day here
    final rate = workingDays > 0 ? (workedDays / workingDays * 100) : 0;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          _kpi('Records', recs.length.toString(), Colors.blueGrey),
          _kpi('Present', present.toString(), Colors.green),
          _kpi('Half days', half.toString(), Colors.amber.shade700),
          _kpi('Absent', absent.toString(), Colors.red),
          _kpi('Leave', leave.toString(), Colors.orange),
          _kpi('Late', _lateCount(recs).toString(), Colors.deepOrange),
          _kpi('Worked hrs', _totalHours(recs).toString(), Colors.indigo),
          _kpi('Attendance', '${rate.toStringAsFixed(0)}%', rate >= 90 ? Colors.green : (rate >= 75 ? Colors.amber.shade700 : Colors.red)),
        ]),
      ),
    );
  }

  Widget _kpi(String label, String value, Color color) => Container(
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
      );

  Widget _table(List<_Rec> recs) {
    if (recs.isEmpty) {
      return const Center(child: Text('No attendance records for this range', style: TextStyle(color: AppTheme.textSecondary)));
    }
    return Column(children: [
      Container(
        color: AppTheme.card,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: const [
          Expanded(flex: 3, child: Text('Date', style: _hStyle)),
          Expanded(flex: 2, child: Text('Day', style: _hStyle)),
          Expanded(flex: 2, child: Text('Status', style: _hStyle)),
          Expanded(flex: 2, child: Text('In', style: _hStyle)),
          Expanded(flex: 2, child: Text('Out', style: _hStyle)),
          Expanded(flex: 2, child: Text('Hours', style: _hStyle, textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text('Late', style: _hStyle, textAlign: TextAlign.center)),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.separated(
          itemCount: recs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final r = recs[i];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                Expanded(flex: 3, child: Text(DateFormat('d MMM yyyy').format(r.date), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                Expanded(flex: 2, child: Text(DateFormat('EEE').format(r.date), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 2, child: Text(r.penalty ? '${_statusLabel(r.status)} (penalty)' : _statusLabel(r.status), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _statusColor(r.status)))),
                Expanded(flex: 2, child: Text(r.checkIn ?? '—', style: const TextStyle(fontSize: 12))),
                Expanded(flex: 2, child: Text(r.checkOut ?? '—', style: const TextStyle(fontSize: 12))),
                Expanded(flex: 2, child: Text(r.hours != null ? r.hours!.toStringAsFixed(2) : '—', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                Expanded(flex: 2, child: Center(child: r.late
                    ? Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.deepOrange.withOpacity(0.12), borderRadius: BorderRadius.circular(8)), child: Text('Late', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.deepOrange.shade700)))
                    : const Text('—', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))),
              ]),
            );
          },
        ),
      ),
    ]);
  }

  void _print() {
    final emp = _emp;
    if (emp == null) return;
    final recs = _filtered;
    final counts = _counts(recs);
    String esc(String? s) => (s ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

    final present = counts['present'] ?? 0;
    final half = counts['half_day'] ?? 0;
    final absent = counts['absent'] ?? 0;
    final leave = counts['leave'] ?? 0;
    final holiday = counts['holiday'] ?? 0;
    final restDay = counts['rest_day'] ?? 0;
    final workingDays = recs.where((r) => r.status != 'holiday' && r.status != 'rest_day').length;
    final workedDays = present + half;
    final rate = workingDays > 0 ? (workedDays / workingDays * 100) : 0;
    final lateN = _lateCount(recs);
    final totalHrs = _totalHours(recs);

    final name = esc(emp['full_name'] as String?);
    final code = esc(emp['employee_code'] as String?);
    final statusList = _statusFilter.isEmpty ? 'All statuses' : _statusFilter.map(_statusLabel).join(', ');

    final rowsHtml = recs.map((r) {
      final lateTxt = r.late ? '<span style="color:#d84315;font-weight:700">Late</span>' : '';
      return '<tr>'
          '<td>${esc(DateFormat('d MMM yyyy').format(r.date))}</td>'
          '<td>${esc(DateFormat('EEE').format(r.date))}</td>'
          '<td>${esc(r.penalty ? _statusLabel(r.status) + ' (penalty)' : _statusLabel(r.status))}</td>'
          '<td>${esc(r.checkIn ?? '—')}</td>'
          '<td>${esc(r.checkOut ?? '—')}</td>'
          '<td style="text-align:right">${r.hours != null ? r.hours!.toStringAsFixed(2) : '—'}</td>'
          '<td style="text-align:center">$lateTxt</td>'
          '</tr>';
    }).join('');

    String kpi(String l, String v) => '<div class="kpi"><div class="v">$v</div><div class="l">$l</div></div>';

    final content = '''<!DOCTYPE html><html><head><meta charset="utf-8"><title>Attendance — $name</title>
<style>@page{margin:14mm}
*{box-sizing:border-box}body{font-family:Arial,Helvetica,sans-serif;color:#111;margin:0}
.head{border-bottom:2px solid #244C97;padding-bottom:10px;margin-bottom:12px}
.org{font-size:12px;color:#244C97;font-weight:700;letter-spacing:.5px;text-transform:uppercase}
h1{font-size:20px;margin:2px 0}
.meta{font-size:12px;color:#555}
.range{font-size:12px;color:#333;margin:8px 0 4px}
.kpis{display:flex;flex-wrap:wrap;gap:8px;margin:10px 0 14px}
.kpi{border:1px solid #ddd;border-radius:8px;padding:6px 12px;min-width:78px}
.kpi .v{font-size:16px;font-weight:800;color:#244C97}
.kpi .l{font-size:10px;color:#666}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;background:#f4f6fa;padding:6px 8px;border-bottom:1px solid #ccc;font-size:11px;color:#444}
td{padding:5px 8px;border-bottom:1px solid #eee}
tr:nth-child(even) td{background:#fafbfc}
.foot{margin-top:16px;font-size:10px;color:#888}
</style></head><body>
<div class="head">
<div class="org">${esc(_orgName)}</div>
<h1>Attendance Report — $name</h1>
<div class="meta">${[if (code.isNotEmpty) code, if (_desigName.isNotEmpty) esc(_desigName), if (_deptName.isNotEmpty) esc(_deptName), if (_branchName.isNotEmpty) esc(_branchName), if (_shiftName.isNotEmpty) 'Shift: ' + esc(_shiftName)].join('&nbsp;&middot;&nbsp;')}</div>
</div>
<div class="range"><b>Period:</b> ${esc(_fmt(_from))} to ${esc(_fmt(_to))} &nbsp;&middot;&nbsp; <b>Filter:</b> ${esc(statusList)}</div>
<div class="kpis">
${kpi('Records', recs.length.toString())}
${kpi('Present', present.toString())}
${kpi('Half days', half.toString())}
${kpi('Absent', absent.toString())}
${kpi('Leave', leave.toString())}
${kpi('Holiday', holiday.toString())}
${kpi('Rest day', restDay.toString())}
${kpi('Late', lateN.toString())}
${kpi('Worked hrs', totalHrs.toString())}
${kpi('Attendance', rate.toStringAsFixed(0) + '%')}
</div>
<table>
<thead><tr><th>Date</th><th>Day</th><th>Status</th><th>In</th><th>Out</th><th style="text-align:right">Hours</th><th style="text-align:center">Late</th></tr></thead>
<tbody>${rowsHtml.isEmpty ? '<tr><td colspan="7" style="text-align:center;color:#888;padding:16px">No records for this range</td></tr>' : rowsHtml}</tbody>
</table>
<div class="foot">Generated ${esc(DateFormat('d MMM yyyy HH:mm').format(DateTime.now()))}</div>
<script>window.onload=function(){window.print();}</script>
</body></html>''';

    final blob = html.Blob([content], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }
}

const _hStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);

class _Rec {
  final DateTime date;
  final String dateStr;
  final String status;
  final String? checkIn;
  final String? checkOut;
  final double? hours;
  final bool late;
  final bool penalty;
  _Rec({
    required this.date,
    required this.dateStr,
    required this.status,
    required this.checkIn,
    required this.checkOut,
    required this.hours,
    required this.late,
    this.penalty = false,
  });
}
