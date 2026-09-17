import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Count of unreviewed absences (no punch + no approved leave, on working days)
/// over the last 7 days ending yesterday. Drives the pendency badge on the
/// Attendance Review menu item and the HR nav group. Mirrors the review
/// screen's own pending detection.
final attendanceReviewPendingCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    String fmt(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final to = today.subtract(const Duration(days: 1)); // yesterday
    final from = to.subtract(const Duration(days: 6));   // last 7 days
    int? restDay;
    try {
      final c = await client.from('app_config').select('value')
          .eq('org_id', user.orgId!).eq('key', 'org.weekly_rest_day').maybeSingle();
      final v = c?['value'] as String?;
      restDay = (v != null && v.isNotEmpty) ? int.tryParse(v) : null;
    } catch (_) {}
    final emps = await client.from('hr_employees').select('id')
        .eq('org_id', user.orgId!).eq('status', 'active').eq('approval_status', 'approved').eq('is_voided', false);
    final empIds = [for (final e in (emps as List)) e['id'] as String];
    if (empIds.isEmpty) return 0;
    final att = await client.from('hr_attendance')
        .select('employee_id, att_date, status, check_in, is_penalty, review_status')
        .eq('org_id', user.orgId!).gte('att_date', fmt(from)).lte('att_date', fmt(to));
    final map = <String, Map<String, Map<String, dynamic>>>{};
    for (final r in (att as List)) {
      final e = r['employee_id'] as String?; final d = r['att_date'] as String?;
      if (e == null || d == null) continue;
      (map[e] ??= {})[d] = Map<String, dynamic>.from(r);
    }
    int count = 0;
    for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1))) {
      if (restDay != null && (d.weekday % 7) == restDay) continue;
      final ds = fmt(d);
      for (final empId in empIds) {
        final row = map[empId]?[ds];
        final st = row?['status'] as String?;
        final ci = row?['check_in'] as String?;
        final reviewed = row?['review_status'] as String?;
        if (st == 'present' || st == 'half_day') continue;
        if (st == 'leave' || st == 'holiday' || st == 'rest_day') continue;
        if (ci != null && ci.isNotEmpty) continue;
        if (row?['is_penalty'] == true) continue;
        if (reviewed == 'excused' || reviewed == 'unapproved') continue;
        count++;
      }
    }
    return count;
  } catch (_) {
    return 0;
  }
});

/// Attendance Review — the "pendency" workspace.
///
/// Lists every UNREVIEWED absence (no punch + no approved leave, on a working
/// day) over a date range, and lets HR decide, per person per day, whether the
/// leave was Approved (excused → marked Leave) or Unapproved (→ absence stands
/// and, per the employee's shift policy, extra penalty absents are added on the
/// following working day(s), even if the employee later showed up — their punch
/// times are preserved on the record but the day reports as Absent).
class HrAttendanceReviewScreen extends ConsumerStatefulWidget {
  const HrAttendanceReviewScreen({super.key});
  @override
  ConsumerState<HrAttendanceReviewScreen> createState() => _State();
}

class _Pending {
  final Map<String, dynamic> emp;
  final DateTime date;
  final String dateStr;
  final Map<String, dynamic>? shift;
  final int penaltyDays; // extra absents this shift adds for an unapproved absence
  _Pending(this.emp, this.date, this.dateStr, this.shift, this.penaltyDays);
}

class _State extends ConsumerState<HrAttendanceReviewScreen> {
  bool _loading = true;
  bool _working = false;
  String? _error;

  List<Map<String, dynamic>> _employees = [];
  Map<String, Map<String, dynamic>> _shiftById = {};
  Map<String, String> _deptName = {};
  int? _orgRestDay; // 0=Sunday … 6=Saturday

  // att[empId][yyyy-mm-dd] = row
  final Map<String, Map<String, Map<String, dynamic>>> _att = {};

  List<_Pending> _pending = [];

  late DateTime _from;
  late DateTime _to;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;
  String get _userName => ref.read(currentUserProvider)?.name ?? '';

  DateTime get _yesterday {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day).subtract(const Duration(days: 1));
  }

  @override
  void initState() {
    super.initState();
    _to = _yesterday;
    _from = _to.subtract(const Duration(days: 6)); // last 7 days ending yesterday
    _load();
  }

  String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  bool _isRestWeekday(DateTime d) => _orgRestDay != null && (d.weekday % 7) == _orgRestDay;

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() { _loading = false; _error = 'Not authenticated'; }); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final client = Supabase.instance.client;
      final emps = await client
          .from('hr_employees')
          .select('id, full_name, employee_code, branch_id, department_id, shift_id, photo_url')
          .eq('org_id', orgId).eq('status', 'active').eq('approval_status', 'approved').eq('is_voided', false)
          .order('full_name');
      _employees = List<Map<String, dynamic>>.from(emps);

      final shifts = await client.from('hr_shifts').select().eq('org_id', orgId);
      _shiftById = {for (final s in List<Map<String, dynamic>>.from(shifts)) s['id'] as String: Map<String, dynamic>.from(s)};

      final depts = await client.from('hr_departments').select('id, name').eq('org_id', orgId);
      _deptName = {for (final d in List<Map<String, dynamic>>.from(depts)) d['id'] as String: (d['name'] as String? ?? '')};

      try {
        final c = await client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.weekly_rest_day').maybeSingle();
        final v = c?['value'] as String?;
        _orgRestDay = (v != null && v.isNotEmpty) ? int.tryParse(v) : null;
      } catch (_) {}

      await _loadAtt();
      _rebuildPending();
    } catch (e) {
      setState(() { _loading = false; _error = 'Failed to load: $e'; });
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadAtt() async {
    final orgId = _orgId;
    if (orgId == null) return;
    _att.clear();
    final rows = await Supabase.instance.client
        .from('hr_attendance')
        .select('id, employee_id, att_date, status, check_in, check_out, is_penalty, review_status')
        .eq('org_id', orgId)
        .gte('att_date', _fmt(_from))
        .lte('att_date', _fmt(_to));
    for (final r in List<Map<String, dynamic>>.from(rows)) {
      final e = r['employee_id'] as String?;
      final d = r['att_date'] as String?;
      if (e == null || d == null) continue;
      (_att[e] ??= {})[d] = r;
    }
  }

  int _penaltyDaysFor(Map<String, dynamic>? shift) {
    if (shift == null) return 0;
    if (shift['penalize_unapproved_absence'] != true) return 0;
    final n = (shift['absence_penalty_days'] as num?)?.toInt() ?? 1;
    return n < 0 ? 0 : n;
  }

  // An absence is "pending review" when, on a working day, the employee neither
  // punched in nor is on approved leave/holiday/rest, and no reviewed decision
  // has been recorded yet.
  void _rebuildPending() {
    final out = <_Pending>[];
    // effective end = min(_to, yesterday) — never flag today or the future.
    DateTime end = _to.isAfter(_yesterday) ? _yesterday : _to;
    for (var d = _from; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
      if (_isRestWeekday(d)) continue;
      final ds = _fmt(d);
      for (final e in _employees) {
        final empId = e['id'] as String;
        final row = _att[empId]?[ds];
        final status = row?['status'] as String?;
        final ci = row?['check_in'] as String?;
        final reviewed = row?['review_status'] as String?; // excused / unapproved
        final isPenalty = row?['is_penalty'] == true;
        // Skip anything that is already accounted for.
        if (status == 'present' || status == 'half_day') continue;          // punched
        if (status == 'leave' || status == 'holiday' || status == 'rest_day') continue; // excused
        if (ci != null && ci.isNotEmpty) continue;                          // has a punch time
        if (isPenalty) continue;                                            // system-added penalty day
        if (reviewed == 'excused' || reviewed == 'unapproved') continue;    // already decided
        // Absent + unreviewed.
        final shift = _shiftById[e['shift_id']];
        out.add(_Pending(e, d, ds, shift, _penaltyDaysFor(shift)));
      }
    }
    out.sort((a, b) {
      final c = b.date.compareTo(a.date);
      if (c != 0) return c;
      return (a.emp['full_name'] as String? ?? '').compareTo(b.emp['full_name'] as String? ?? '');
    });
    _pending = out;
  }

  // Read the existing attendance row (if any) for an employee/date.
  Future<Map<String, dynamic>?> _rowFor(String empId, String ds) async {
    final orgId = _orgId;
    if (orgId == null) return null;
    final r = await Supabase.instance.client.from('hr_attendance')
        .select().eq('org_id', orgId).eq('employee_id', empId).eq('att_date', ds).maybeSingle();
    return r == null ? null : Map<String, dynamic>.from(r);
  }

  Future<void> _audit(String attId, String empId, String ds, String note) async {
    try {
      await Supabase.instance.client.from('hr_attendance_audit').insert({
        'id': 'aud_${DateTime.now().microsecondsSinceEpoch}_$empId', 'org_id': _orgId,
        'attendance_id': attId, 'employee_id': empId, 'att_date': ds, 'action': 'updated',
        'changes': note, 'changed_by': _userId, 'changed_by_name': _userName,
      });
    } catch (_) {/* audit is best-effort */}
  }

  // Approved leave → excuse the day (marks Leave, no penalty).
  Future<void> _excuse(_Pending p) async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _working = true);
    try {
      final client = Supabase.instance.client;
      final empId = p.emp['id'] as String;
      final existing = await _rowFor(empId, p.dateStr);
      final now = DateTime.now().toIso8601String();
      if (existing != null) {
        await client.from('hr_attendance').update({
          'status': 'leave', 'review_status': 'excused', 'is_penalty': false,
          'check_in': null, 'check_out': null, 'work_hours': 0,
          'remarks': 'Excused (approved leave)', 'updated_at': now,
        }).eq('id', existing['id'] as String);
        await _audit(existing['id'] as String, empId, p.dateStr, 'Absence excused as approved leave');
      } else {
        final id = 'att_${DateTime.now().microsecondsSinceEpoch}_$empId';
        await client.from('hr_attendance').insert({
          'id': id, 'org_id': orgId, 'employee_id': empId, 'branch_id': p.emp['branch_id'],
          'att_date': p.dateStr, 'status': 'leave', 'review_status': 'excused',
          'check_in': null, 'check_out': null, 'work_hours': 0,
          'remarks': 'Excused (approved leave)', 'updated_at': now,
        });
        await _audit(id, empId, p.dateStr, 'Absence excused as approved leave');
      }
      await _loadAtt();
      _rebuildPending();
      ref.invalidate(attendanceReviewPendingCountProvider);
      _snack('${p.emp['full_name']} — ${DateFormat('d MMM').format(p.date)} excused as approved leave.');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  // Unapproved → absence stands, and per shift policy add penalty absents on the
  // next working day(s), preserving any punch times but reporting Absent.
  Future<void> _unapproved(_Pending p) async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _working = true);
    try {
      final client = Supabase.instance.client;
      final empId = p.emp['id'] as String;
      final now = DateTime.now().toIso8601String();

      // 1) mark the actual absence as reviewed/unapproved
      final existing = await _rowFor(empId, p.dateStr);
      if (existing != null) {
        await client.from('hr_attendance').update({
          'status': 'absent', 'review_status': 'unapproved', 'is_penalty': false,
          'updated_at': now,
        }).eq('id', existing['id'] as String);
        await _audit(existing['id'] as String, empId, p.dateStr, 'Absence confirmed unapproved');
      } else {
        final id = 'att_${DateTime.now().microsecondsSinceEpoch}_$empId';
        await client.from('hr_attendance').insert({
          'id': id, 'org_id': orgId, 'employee_id': empId, 'branch_id': p.emp['branch_id'],
          'att_date': p.dateStr, 'status': 'absent', 'review_status': 'unapproved',
          'check_in': null, 'check_out': null, 'work_hours': 0,
          'updated_at': now,
        });
        await _audit(id, empId, p.dateStr, 'Absence confirmed unapproved');
      }

      // 2) add penalty absents on following working days
      final placed = <String>[];
      var d = p.date;
      var remaining = p.penaltyDays;
      var guard = 0;
      while (remaining > 0 && guard < 40) {
        guard++;
        d = d.add(const Duration(days: 1));
        if (_isRestWeekday(d)) continue;
        final ds = _fmt(d);
        final ex = await _rowFor(empId, ds);
        final exStatus = ex?['status'] as String?;
        // Don't overwrite a holiday / rest day / approved leave — jump ahead.
        if (exStatus == 'holiday' || exStatus == 'rest_day' || exStatus == 'leave') continue;
        if (ex != null) {
          // Preserve punch times; flip the day to a penalty absent.
          await client.from('hr_attendance').update({
            'status': 'absent', 'is_penalty': true, 'penalty_source_date': p.dateStr,
            'remarks': 'Penalty for unapproved absence on ${p.dateStr}', 'updated_at': now,
          }).eq('id', ex['id'] as String);
          await _audit(ex['id'] as String, empId, ds, 'Penalty absent (unapproved absence ${p.dateStr}); punch times kept');
        } else {
          final id = 'att_${DateTime.now().microsecondsSinceEpoch}_$empId';
          await client.from('hr_attendance').insert({
            'id': id, 'org_id': orgId, 'employee_id': empId, 'branch_id': p.emp['branch_id'],
            'att_date': ds, 'status': 'absent', 'is_penalty': true, 'penalty_source_date': p.dateStr,
            'check_in': null, 'check_out': null, 'work_hours': 0,
            'remarks': 'Penalty for unapproved absence on ${p.dateStr}', 'updated_at': now,
          });
          await _audit(id, empId, ds, 'Penalty absent (unapproved absence ${p.dateStr})');
        }
        placed.add(DateFormat('d MMM').format(d));
        remaining--;
      }

      await _loadAtt();
      _rebuildPending();
      ref.invalidate(attendanceReviewPendingCountProvider);
      final msg = placed.isEmpty
          ? '${p.emp['full_name']} — absence on ${DateFormat('d MMM').format(p.date)} marked unapproved.'
          : '${p.emp['full_name']} — unapproved. Penalty absent added on ${placed.join(', ')}.';
      _snack(msg);
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _pickDate(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: _yesterday,
    );
    if (picked == null) return;
    setState(() { if (isFrom) _from = picked; else _to = picked; });
    setState(() => _loading = true);
    try { await _loadAtt(); _rebuildPending(); } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _preset(int days) {
    setState(() { _to = _yesterday; _from = _to.subtract(Duration(days: days - 1)); _loading = true; });
    () async { try { await _loadAtt(); _rebuildPending(); } catch (_) {} if (mounted) setState(() => _loading = false); }();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Attendance Review', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(child: _counterBadge()),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.textSecondary)))
              : Column(children: [
                  _filterBar(),
                  const Divider(height: 1),
                  Expanded(child: _list()),
                  if (_working) const LinearProgressIndicator(minHeight: 2),
                ]),
    );
  }

  Widget _counterBadge() {
    final n = _pending.length;
    final color = n == 0 ? Colors.green : Colors.deepOrange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(20), border: Border.all(color: color.withOpacity(0.4))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(n == 0 ? Icons.check_circle_outline : Icons.pending_actions, size: 15, color: color),
        const SizedBox(width: 6),
        Text(n == 0 ? 'All clear' : '$n to review', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }

  Widget _filterBar() {
    return Container(
      color: AppTheme.card,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today_outlined, size: 15),
          label: Text('From  ${_fmt(_from)}', style: const TextStyle(fontSize: 12)),
          onPressed: () => _pickDate(true)),
        OutlinedButton.icon(
          icon: const Icon(Icons.event_outlined, size: 15),
          label: Text('To  ${_fmt(_to)}', style: const TextStyle(fontSize: 12)),
          onPressed: () => _pickDate(false)),
        ActionChip(label: const Text('Yesterday', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact, onPressed: () => _preset(1)),
        ActionChip(label: const Text('Last 7 days', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact, onPressed: () => _preset(7)),
        ActionChip(label: const Text('Last 30 days', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact, onPressed: () => _preset(30)),
      ]),
    );
  }

  Widget _list() {
    if (_pending.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.verified_outlined, size: 48, color: Colors.green),
        SizedBox(height: 10),
        Text('No pending absences in this range', style: TextStyle(color: AppTheme.textSecondary)),
      ]));
    }
    // group by date
    final byDate = <String, List<_Pending>>{};
    for (final p in _pending) { (byDate[p.dateStr] ??= []).add(p); }
    final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
    return ListView.builder(
      itemCount: dates.length,
      itemBuilder: (_, i) {
        final ds = dates[i];
        final items = byDate[ds]!;
        final d = DateTime.tryParse(ds) ?? DateTime.now();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: double.infinity,
            color: AppTheme.background,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('${DateFormat('EEEE, d MMM yyyy').format(d)}  ·  ${items.length} absent',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          ),
          ...items.map(_tile),
        ]);
      },
    );
  }

  Widget _tile(_Pending p) {
    final name = p.emp['full_name'] as String? ?? '';
    final code = p.emp['employee_code'] as String? ?? '';
    final dept = _deptName[p.emp['department_id']] ?? '';
    final photo = p.emp['photo_url'] as String?;
    final penaltyNote = p.penaltyDays > 0
        ? '+${p.penaltyDays} penalty absent${p.penaltyDays > 1 ? 's' : ''} on the next working day${p.penaltyDays > 1 ? 's' : ''}'
        : 'no penalty (shift policy off)';
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border, width: 0.5))),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        CircleAvatar(
          radius: 18, backgroundColor: AppTheme.background,
          backgroundImage: (photo != null && photo.isNotEmpty) ? NetworkImage(photo) : null,
          child: (photo == null || photo.isEmpty)
              ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary))
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          Text([if (code.isNotEmpty) code, if (dept.isNotEmpty) dept].join('  ·  '),
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton(
              onPressed: _working ? null : () => _excuse(p),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.green.shade700, visualDensity: VisualDensity.compact,
                side: BorderSide(color: Colors.green.withOpacity(0.5)),
              ),
              child: const Text('Approved leave', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _working ? null : () => _confirmUnapproved(p),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepOrange, foregroundColor: Colors.white, visualDensity: VisualDensity.compact,
              ),
              child: const Text('Unapproved', style: TextStyle(fontSize: 12)),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(penaltyNote, style: TextStyle(fontSize: 10, color: p.penaltyDays > 0 ? Colors.deepOrange : AppTheme.textSecondary)),
          ),
        ]),
      ]),
    );
  }

  Future<void> _confirmUnapproved(_Pending p) async {
    final name = p.emp['full_name'] as String? ?? 'this employee';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark unapproved absence?', style: TextStyle(fontSize: 16)),
        content: Text(
          p.penaltyDays > 0
              ? '$name will be recorded absent on ${DateFormat('d MMM').format(p.date)}, and ${p.penaltyDays} additional penalty absent${p.penaltyDays > 1 ? 's' : ''} will be added on the next working day${p.penaltyDays > 1 ? 's' : ''} — even if they were present (their punch times are kept, but the day reports as Absent).'
              : '$name will be recorded absent on ${DateFormat('d MMM').format(p.date)}. This shift has no penalty policy, so no extra days are added.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange, foregroundColor: Colors.white),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (ok == true) await _unapproved(p);
  }
}
