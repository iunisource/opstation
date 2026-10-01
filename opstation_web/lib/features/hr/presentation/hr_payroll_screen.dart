// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Payroll — generate monthly payroll from each employee's basic salary and
/// attendance, keep a record of past runs, edit per-employee allowances /
/// deductions, and print payslips + a monthly register.
///
/// Salary basis: per-day = basic ÷ calendar days in the month. Unpaid days
/// (absent + penalty absents + ½ × half-days) are deducted. Approved leave,
/// holidays and the weekly rest day are paid. Runs have a Draft → Finalized →
/// Paid lifecycle; recompute and edits are allowed only while Draft.
class HrPayrollScreen extends ConsumerStatefulWidget {
  const HrPayrollScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<HrPayrollScreen> createState() => _State();
}

class _State extends ConsumerState<HrPayrollScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;

  List<Map<String, dynamic>> _runs = [];
  Map<String, dynamic>? _run; // selected run
  List<Map<String, dynamic>> _items = [];

  Map<String, Map<String, dynamic>> _empById = {};
  Map<String, String> _deptName = {};

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;
  String get _userName => ref.read(currentUserProvider)?.name ?? '';
  String get _orgName => ref.read(currentUserProvider)?.orgName ?? '';

  final _nf = NumberFormat('#,##0');
  final _nf2 = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _load().then((_) => _openFocus());
  }

  String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  String _periodLabel(String period) {
    final p = DateTime.tryParse('$period-01');
    return p == null ? period : DateFormat('MMMM yyyy').format(p);
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() { _loading = false; _error = 'Not authenticated'; }); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final client = Supabase.instance.client;
      final emps = await client.from('hr_employees')
          .select()
          .eq('org_id', orgId);
      _empById = {for (final e in List<Map<String, dynamic>>.from(emps)) e['id'] as String: Map<String, dynamic>.from(e)};
      final depts = await client.from('hr_departments').select('id, name').eq('org_id', orgId);
      _deptName = {for (final d in List<Map<String, dynamic>>.from(depts)) d['id'] as String: (d['name'] as String? ?? '')};
      final runs = await client.from('hr_payroll_runs').select().eq('org_id', orgId).order('period', ascending: false);
      _runs = List<Map<String, dynamic>>.from(runs);
      if (_runs.isNotEmpty) { await _selectRun(_runs.first); }
    } catch (e) {
      setState(() { _loading = false; _error = 'Failed to load: $e'; });
      return;
    }
    if (mounted) setState(() => _loading = false);
  }


  String? _focusDone;
  @override
  void didUpdateWidget(covariant HrPayrollScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusId != oldWidget.focusId) _openFocus();
  }

  /// Deep link (?focus=<id>) from a notification / email: open that record.
  Future<void> _openFocus() async {
    final id = widget.focusId;
    if (id == null || id.isEmpty || id == _focusDone || !mounted) return;
    _focusDone = id;
    Map<String, dynamic>? r;
    for (final x in _runs) { if (x['id'] == id) { r = x; break; } }
    if (r != null && mounted) await _selectRun(r);
  }

  Future<void> _selectRun(Map<String, dynamic> run) async {
    setState(() { _run = run; _items = []; });
    try {
      final items = await Supabase.instance.client.from('hr_payroll_items')
          .select().eq('run_id', run['id'] as String).order('id');
      final list = List<Map<String, dynamic>>.from(items);
      list.sort((a, b) {
        final an = _empById[a['employee_id']]?['full_name'] as String? ?? '';
        final bn = _empById[b['employee_id']]?['full_name'] as String? ?? '';
        return an.compareTo(bn);
      });
      if (mounted) setState(() => _items = list);
    } catch (_) {}
  }

  // ── generation ──────────────────────────────────────────────────────────────
  int? _restDay;
  bool _isRest(DateTime d) => _restDay != null && (d.weekday % 7) == _restDay;

  Future<void> _generateDialog() async {
    final now = DateTime.now();
    DateTime month = DateTime(now.year, now.month, 1);
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      return AlertDialog(
        title: const Text('Generate payroll', style: TextStyle(fontSize: 16)),
        content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Select the month to generate or refresh.', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_month_outlined, size: 16),
              label: Text(DateFormat('MMMM yyyy').format(month), style: const TextStyle(fontSize: 13)),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: ctx, initialDate: month, firstDate: DateTime(2020), lastDate: DateTime(2100),
                  helpText: 'Pick any day in the target month');
                if (picked != null) setLocal(() => month = DateTime(picked.year, picked.month, 1));
              },
            )),
          ]),
          const SizedBox(height: 10),
          const Text('Basic ÷ calendar days. Absent, penalty and not-yet-joined days (½ for half-days) are deducted; holidays and rest days are paid. Unused paid-leave days are paid as a bonus. Existing allowances/deductions you entered are preserved.',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
            onPressed: () { Navigator.pop(ctx); _generate(month); },
            child: const Text('Generate'),
          ),
        ],
      );
    }));
  }

  Future<void> _generate(DateTime month) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final period = DateFormat('yyyy-MM').format(month);
    setState(() => _busy = true);
    try {
      final client = Supabase.instance.client;

      // Existing run?
      final existing = await client.from('hr_payroll_runs')
          .select().eq('org_id', orgId).eq('period', period).maybeSingle();
      if (existing != null && (existing['status'] as String?) != 'draft') {
        _snack('${_periodLabel(period)} is ${existing['status']} — reopen it to Draft before regenerating.');
        setState(() => _busy = false);
        return;
      }

      // rest day
      try {
        final c = await client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.weekly_rest_day').maybeSingle();
        final v = c?['value'] as String?;
        _restDay = (v != null && v.isNotEmpty) ? int.tryParse(v) : null;
      } catch (_) { _restDay = null; }

      final monthStart = DateTime(month.year, month.month, 1);
      final monthEnd = DateTime(month.year, month.month + 1, 0); // last day
      final calendarDays = monthEnd.day;
      final today = DateTime.now();
      final yesterday = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 1));
      final lastCount = monthEnd.isBefore(yesterday) ? monthEnd : yesterday;

      // active, approved employees
      final empRows = await client.from('hr_employees')
          .select()
          .eq('org_id', orgId).eq('status', 'active').eq('approval_status', 'approved').eq('is_voided', false);
      // Employees excluded from this run (kept on the run). A new month starts
      // with the same exclusions as the latest earlier run.
      Set<String> excluded = _excludedOf(existing);
      if (existing == null) {
        try {
          final prev = await client.from('hr_payroll_runs')
              .select('excluded_employee_ids').eq('org_id', orgId).lt('period', period)
              .order('period', ascending: false).limit(1).maybeSingle();
          excluded = _excludedOf(prev);
        } catch (_) {}
      }
      final emps = List<Map<String, dynamic>>.from(empRows)
          .where((e) => !excluded.contains(e['id'])).toList();

      // Outstanding advance per employee = balance of their linked advance
      // account (Employee directory) as of the last day of the month.
      final advBal = <String, double>{};
      final advAcct = <String, String>{};
      final nextDay = _fmt(monthEnd.add(const Duration(days: 1)));
      await Future.wait([
        for (final e in emps)
          if ((e['advance_account_id'] as String?)?.isNotEmpty == true)
            () async {
              try {
                final b = await client.rpc('rpc_account_opening', params: {
                  'p_org_id': orgId, 'p_account_id': e['advance_account_id'],
                  'p_date_from': nextDay, 'p_branch_id': null,
                });
                advBal[e['id'] as String] = (b as num?)?.toDouble() ?? 0;
                advAcct[e['id'] as String] = e['advance_account_id'] as String;
              } catch (_) {}
            }(),
      ]);

      // attendance for the month
      final attRows = await client.from('hr_attendance')
          .select('employee_id, att_date, status, check_in, is_penalty, review_status')
          .eq('org_id', orgId).gte('att_date', _fmt(monthStart)).lte('att_date', _fmt(monthEnd));
      final att = <String, Map<String, Map<String, dynamic>>>{};
      for (final r in List<Map<String, dynamic>>.from(attRows)) {
        final e = r['employee_id'] as String?; final d = r['att_date'] as String?;
        if (e == null || d == null) continue;
        (att[e] ??= {})[d] = r;
      }

      // Paid leave quota (company default; per-employee override in the directory).
      final orgPl = await _orgPaidLeaveDays();
      // Unapproved absences whose extra (penalty) day was never placed — e.g.
      // entered from an attendance sheet — count the extra day here instead.
      final penaltyFor = <String>{}; // "emp|yyyy-MM-dd" of source dates that HAVE a penalty row
      try {
        final pr = await client.from('hr_attendance')
            .select('employee_id, penalty_source_date')
            .eq('org_id', orgId).eq('is_penalty', true)
            .gte('penalty_source_date', _fmt(monthStart)).lte('penalty_source_date', _fmt(monthEnd));
        for (final r in List<Map<String, dynamic>>.from(pr)) {
          penaltyFor.add('${r['employee_id']}|${'${r['penalty_source_date']}'.substring(0, 10)}');
        }
      } catch (_) {}
      // Who already had attendance before this month (to spot mid-month joiners
      // that have no join date set).
      final hadEarlier = <String>{};
      try {
        final er = await client.from('hr_attendance').select('employee_id')
            .eq('org_id', orgId).lt('att_date', _fmt(monthStart))
            .gte('att_date', _fmt(monthStart.subtract(const Duration(days: 62))));
        for (final r in List<Map<String, dynamic>>.from(er)) { hadEarlier.add('${r['employee_id']}'); }
      } catch (_) {}

      // run row (create or reuse)
      final runId = existing?['id'] as String? ?? 'pr_${DateTime.now().microsecondsSinceEpoch}';
      final nowIso = DateTime.now().toIso8601String();
      if (existing == null) {
        await client.from('hr_payroll_runs').insert({
          'id': runId, 'org_id': orgId, 'period': period, 'status': 'draft',
          'generated_at': nowIso, 'generated_by': _userId, 'generated_by_name': _userName,
          if (excluded.isNotEmpty) 'excluded_employee_ids': excluded.toList(),
        });
      } else {
        await client.from('hr_payroll_runs').update({'generated_at': nowIso, 'generated_by': _userId, 'generated_by_name': _userName}).eq('id', runId);
      }

      // preserve manual fields from existing items
      final prevItems = await client.from('hr_payroll_items').select().eq('run_id', runId);
      final prevByEmp = {for (final it in List<Map<String, dynamic>>.from(prevItems)) it['employee_id'] as String: Map<String, dynamic>.from(it)};

      double totalNet = 0;
      final keptEmpIds = <String>{};
      for (final e in emps) {
        final empId = e['id'] as String;
        keptEmpIds.add(empId);
        final basic = (e['basic_salary'] as num?)?.toDouble() ?? 0;
        final perDay = calendarDays > 0 ? basic / calendarDays : 0;

        // First day of employment in this month: join date, or — for someone
        // with no join date and no earlier attendance — their first attendance day.
        DateTime start = monthStart;
        final jd = DateTime.tryParse('${e['join_date'] ?? ''}');
        if (jd != null) {
          if (jd.isAfter(monthStart)) start = DateTime(jd.year, jd.month, jd.day);
        } else if (!hadEarlier.contains(empId)) {
          final days = (att[empId]?.keys.toList() ?? <String>[])..sort();
          if (days.isNotEmpty) {
            final f = DateTime.parse(days.first);
            if (f.isAfter(monthStart)) start = f;
          }
        }

        double present = 0, absent = 0, penalty = 0, leave = 0, half = 0, holiday = 0, rest = 0, notJoined = 0;
        double used = 0; // unpaid days that use up the paid-leave quota
        double apprLeave = 0, unappr = 0; // breakdown of `absent` for the payslip label
        for (var d = monthStart; !d.isAfter(lastCount); d = d.add(const Duration(days: 1))) {
          final ds = _fmt(d);
          final row = att[empId]?[ds];
          final st = row?['status'] as String?;
          if (d.isBefore(start) && row == null) { notJoined++; continue; } // not employed yet — unpaid (rest days too)
          if (_isRest(d)) { rest++; continue; }
          if (st == 'present') { present++; }
          else if (st == 'half_day') { half++; used += 0.5; }
          else if (st == 'leave') { leave++; }
          else if (st == 'holiday') { holiday++; }
          else if (st == 'rest_day') { rest++; }
          else if (st == 'absent') {
            if (row?['is_penalty'] == true) { penalty++; used++; }
            else {
              absent++; used++;
              if (row?['review_status'] == 'excused') apprLeave++;
              if (row?['review_status'] == 'unapproved') unappr++;
              // Unapproved absence = 1 + 1. Add the extra day when no penalty
              // row was placed for it.
              if (row?['review_status'] == 'unapproved' && !penaltyFor.contains('$empId|$ds')) { penalty++; used++; }
            }
          }
          else { absent++; used++; } // no record on a past working day = absent
        }
        final unpaid = absent + penalty + notJoined + 0.5 * half;

        // Paid leave: the quota is paid every month. It covers leave days
        // (which are still listed under Absence) and whatever is left over is
        // the bonus for staying regular. Net effect on pay = quota − used.
        final plOverride = (e['paid_leave_days'] as num?)?.toDouble();
        final plQuota = plOverride ?? orgPl;
        double quota = plQuota;
        if (start.isAfter(monthStart)) {
          final worked = monthEnd.difference(start).inDays + 1;
          quota = worked < 10 ? 0.0 : (worked / 15).round().toDouble();
          if (quota > plQuota) quota = plQuota;
        }
        final bonusDays = quota > used ? quota - used : 0.0; // unused → extra pay
        final double leaveBonus = (perDay * quota).toDouble();  // whole quota is paid
        final absenceDeduction = (perDay * unpaid);

        final prev = prevByEmp[empId];
        final allowances = (prev?['allowances'] as num?)?.toDouble() ?? 0;
        final bonus = (prev?['bonus'] as num?)?.toDouble() ?? 0;
        final otherDed = (prev?['other_deduction'] as num?)?.toDouble() ?? 0;
        double advance = (prev?['advance'] as num?)?.toDouble() ?? 0;
        final remarks = prev?['remarks'] as String?;
        final bal = advBal[empId];
        // First time this payslip sees the advance account: recover the
        // outstanding balance (or the employee's monthly recovery amount, if
        // set), never more than what is left to pay. After that the amount is
        // whatever was saved on the payslip, so manual edits stick.
        final firstLook = prev == null || (prev['advance_balance'] == null && advance == 0);
        if (bal != null && firstLook) {
          final inst = (e['advance_installment'] as num?)?.toDouble();
          var want = bal > 0 ? bal : 0.0;
          if (inst != null && inst > 0 && inst < want) want = inst;
          final room = (basic + allowances + bonus + leaveBonus - absenceDeduction - otherDed).toDouble();
          if (want > room) want = room > 0 ? room : 0.0;
          advance = _r2(want);
        }

        final gross = basic + allowances + bonus + leaveBonus;
        final totalDed = absenceDeduction + otherDed + advance;
        final net = gross - totalDed;
        totalNet += net;

        final itemId = prev?['id'] as String? ?? 'pi_${DateTime.now().microsecondsSinceEpoch}_$empId';
        final payload = {
          'id': itemId, 'run_id': runId, 'org_id': orgId, 'employee_id': empId, 'period': period,
          'basic': basic, 'calendar_days': calendarDays, 'per_day': _r2(perDay.toDouble()),
          'present_days': present, 'absent_days': absent, 'penalty_days': penalty,
          'leave_days': leave, 'half_days': half, 'holiday_days': holiday, 'restday_days': rest,
          'unpaid_days': unpaid, 'paid_days': calendarDays - unpaid,
          'absence_deduction': _r2(absenceDeduction.toDouble()),
          'allowances': allowances, 'bonus': bonus, 'other_deduction': otherDed, 'advance': advance,
          'notjoined_days': notJoined, 'approved_leave_days': apprLeave, 'unapproved_days': unappr, 'paid_leave_quota': quota, 'paid_leave_used': used,
          'leave_bonus_days': bonusDays, 'leave_bonus': _r2(leaveBonus.toDouble()),
          if (bal != null) 'advance_balance': _r2(bal),
          if (bal != null) 'advance_account_id': advAcct[empId],
          'gross': _r2(gross), 'total_deduction': _r2(totalDed), 'net': _r2(net),
          'remarks': remarks, 'updated_at': nowIso,
        };
        await client.from('hr_payroll_items').upsert(payload, onConflict: 'run_id,employee_id');
      }

      // remove items for employees no longer active/approved
      final staleIds = prevByEmp.keys.where((k) => !keptEmpIds.contains(k)).toList();
      for (final k in staleIds) {
        await client.from('hr_payroll_items').delete().eq('run_id', runId).eq('employee_id', k);
      }

      await client.from('hr_payroll_runs').update({
        'employee_count': keptEmpIds.length, 'total_net': _r2(totalNet), 'updated_at': nowIso,
      }).eq('id', runId);

      // reload
      final runs = await client.from('hr_payroll_runs').select().eq('org_id', orgId).order('period', ascending: false);
      _runs = List<Map<String, dynamic>>.from(runs);
      final sel = _runs.firstWhere((r) => r['id'] == runId, orElse: () => _runs.first);
      await _selectRun(sel);
      _snack('${_periodLabel(period)} generated — ${keptEmpIds.length} employees, net ${_nf.format(totalNet)}.');
    } catch (e) {
      _snack('Generate failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  double _r2(double v) => (v * 100).roundToDouble() / 100;

  // ── paid leave quota ────────────────────────────────────────────────────────
  static const _plKey = 'hr.paid_leave_days';

  Future<double> _orgPaidLeaveDays() async {
    final orgId = _orgId; if (orgId == null) return 0;
    try {
      final c = await Supabase.instance.client.from('app_config').select('value')
          .eq('org_id', orgId).eq('key', _plKey).maybeSingle();
      return double.tryParse('${c?['value'] ?? ''}') ?? 0;
    } catch (_) { return 0; }
  }

  Future<void> _paidLeaveSettings() async {
    final orgId = _orgId; if (orgId == null) return;
    final cur = await _orgPaidLeaveDays();
    if (!mounted) return;
    final ctrl = TextEditingController(text: cur == 0 ? '' : _plain(cur));
    final v = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Paid leave days per month', style: TextStyle(fontSize: 16)),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: ctrl, autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Company default (days)', hintText: 'e.g. 2', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 10),
        const Text(
          'Each month, every unpaid day (absent, approved leave, the extra day of an unapproved absence, ½ per half day) '
          'is covered by these days, and whatever is left over is paid extra. On the payslip the days are paid as "Paid leave" and the absences stay under deductions. Nothing carries over.\n\n'
          'Joined mid-month: 1 day per 15 days worked, rounded; under 10 days, none.\n\n'
          'A different number for one employee can be set in the Employee directory. Regenerate draft runs to apply.',
          style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
      ],
    ));
    if (v == null) return;
    final d = double.tryParse(v) ?? 0;
    try {
      await Supabase.instance.client.from('app_config').upsert({
        'org_id': orgId, 'key': _plKey, 'value': d == 0 ? '' : _plain(d),
      }, onConflict: 'key,org_id,branch_id');
      _snack(d == 0 ? 'Paid leave bonus switched off.' : 'Paid leave: ${_plain(d)} days a month. Regenerate draft runs to apply.');
    } catch (e) { _snack('Could not save: $e'); }
  }

  // ── exclusions ──────────────────────────────────────────────────────────────
  static Set<String> _excludedOf(Map? run) =>
      ((run?['excluded_employee_ids'] as List?) ?? const []).map((e) => '$e').toSet();

  Set<String> get _excluded => _excludedOf(_run);

  Future<void> _saveExcluded(Set<String> ids) async {
    final run = _run; if (run == null) return;
    await Supabase.instance.client.from('hr_payroll_runs').update({
      'excluded_employee_ids': ids.toList(), 'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', run['id'] as String);
    run['excluded_employee_ids'] = ids.toList();
  }

  /// Take an employee out of this payroll run (draft only). Their payslip is
  /// removed and they stay out when the run is regenerated, until included again.
  Future<void> _exclude(Map<String, dynamic> item) async {
    if (!_isDraft) { _snack('Run is ${_run?['status']} — reopen to Draft to change it.'); return; }
    final empId = item['employee_id'] as String;
    final name = _empById[empId]?['full_name'] as String? ?? 'this employee';
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Exclude from payroll?', style: TextStyle(fontSize: 16)),
      content: Text('$name will be removed from ${_periodLabel(_run!['period'] as String)} payroll '
          '(no payslip, not in totals or the register). Allowances or deductions entered for them in this run are discarded.\n\n'
          'You can include them again from the "Excluded" list.', style: const TextStyle(fontSize: 13)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true), child: const Text('Exclude')),
      ],
    ));
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final client = Supabase.instance.client;
      final runId = _run!['id'] as String;
      await _saveExcluded({..._excluded, empId});
      await client.from('hr_payroll_items').delete().eq('run_id', runId).eq('employee_id', empId);
      _items.removeWhere((it) => it['employee_id'] == empId);
      double totalNet = 0; for (final it in _items) { totalNet += (it['net'] as num?)?.toDouble() ?? 0; }
      await client.from('hr_payroll_runs').update({
        'employee_count': _items.length, 'total_net': _r2(totalNet), 'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', runId);
      _run!['employee_count'] = _items.length; _run!['total_net'] = _r2(totalNet);
      _snack('$name excluded from this payroll.');
    } catch (e) {
      _snack(e.toString().contains('excluded_employee_ids')
          ? 'Run SQL 303 (payroll exclusions) first.' : 'Exclude failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Put an excluded employee back: clears the exclusion and regenerates the run.
  Future<void> _include(String empId) async {
    if (!_isDraft) { _snack('Run is ${_run?['status']} — reopen to Draft to change it.'); return; }
    setState(() => _busy = true);
    try {
      await _saveExcluded(_excluded..remove(empId));
    } catch (e) {
      _snack('Include failed: $e');
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (mounted) setState(() => _busy = false);
    await _generate(DateTime.parse('${_run!['period']}-01'));
  }

  Widget _excludedBar() {
    final ids = _excluded.toList()
      ..sort((a, b) => (_empById[a]?['full_name'] as String? ?? '').compareTo(_empById[b]?['full_name'] as String? ?? ''));
    if (ids.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.orange.withOpacity(0.06),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('Excluded (${ids.length}):', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        for (final id in ids)
          InputChip(
            visualDensity: VisualDensity.compact,
            label: Text(_empById[id]?['full_name'] as String? ?? '(removed)', style: const TextStyle(fontSize: 12)),
            deleteIcon: const Icon(Icons.undo, size: 15),
            deleteButtonTooltipMessage: 'Include again',
            onDeleted: _isDraft && !_busy ? () => _include(id) : null,
          ),
      ]),
    );
  }

  // ── status transitions ──────────────────────────────────────────────────────
  Future<void> _setStatus(String status) async {
    final run = _run; final orgId = _orgId;
    if (run == null || orgId == null) return;
    setState(() => _busy = true);
    try {
      final now = DateTime.now().toIso8601String();
      final upd = <String, dynamic>{'status': status, 'updated_at': now};
      if (status == 'finalized') {
        upd.addAll({'finalized_at': now, 'finalized_by': _userId, 'finalized_by_name': _userName,
          'finalized_signature_url': await _signatureOf(_userId)});
      }
      if (status == 'paid') {
        upd.addAll({'paid_at': now, 'paid_by': _userId, 'paid_by_name': _userName});
      }
      if (status == 'draft') {
        // Reopened: the approval no longer stands.
        upd.addAll({'finalized_at': null, 'finalized_by': null, 'finalized_by_name': null,
          'finalized_signature_url': null, 'paid_at': null, 'paid_by': null, 'paid_by_name': null});
      }
      await Supabase.instance.client.from('hr_payroll_runs').update(upd).eq('id', run['id'] as String);
      run.addAll(upd);
      final runs = await Supabase.instance.client.from('hr_payroll_runs').select().eq('org_id', orgId).order('period', ascending: false);
      _runs = List<Map<String, dynamic>>.from(runs);
      _snack('Marked ${_periodLabel(run['period'] as String)} as $status.');
    } catch (e) { _snack('Failed: $e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  bool get _isDraft => (_run?['status'] as String? ?? 'draft') == 'draft';

  // ── footprints (generated / approved / paid) ──────────────────────────────────
  final Map<String, String?> _sigCache = {};
  Future<String?> _signatureOf(String? userId) async {
    if (userId == null || userId.isEmpty) return null;
    if (_sigCache.containsKey(userId)) return _sigCache[userId];
    try {
      final u = await Supabase.instance.client.from('users').select('signature_url').eq('id', userId).maybeSingle();
      final v = (u?['signature_url'] as String?)?.trim();
      _sigCache[userId] = (v == null || v.isEmpty) ? null : v;
    } catch (_) { _sigCache[userId] = null; }
    return _sigCache[userId];
  }

  String _when(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null ? '—' : DateFormat('d MMM yyyy, HH:mm').format(d.toLocal());
  }

  /// Approver's signature: the one captured at approval, else their current one.
  String? _approvedSig(Map run) {
    final s = (run['finalized_signature_url'] as String?)?.trim();
    if (s != null && s.isNotEmpty) return s;
    return _sigCache[run['finalized_by']];
  }

  Widget _footprints(Map<String, dynamic> run) {
    final st = run['status'] as String? ?? 'draft';
    final approved = st == 'finalized' || st == 'paid';
    if (approved && run['finalized_by'] != null && !_sigCache.containsKey(run['finalized_by'])) {
      _signatureOf(run['finalized_by'] as String?).then((_) { if (mounted) setState(() {}); });
    }
    final vertical = MediaQuery.of(context).size.width < 600;
    Widget wrap(Widget c) => vertical ? Padding(padding: const EdgeInsets.only(bottom: 10), child: c) : Expanded(child: c);
    Widget foot(String label, String who, String when, {String? sig}) => wrap(Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 4),
        Text(who, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(when, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        if (sig != null && sig.isNotEmpty) ...[
          const SizedBox(height: 6),
          SizedBox(height: 44, width: 140, child: Image.network(sig, fit: BoxFit.contain, alignment: Alignment.centerLeft,
              errorBuilder: (_, __, ___) => const SizedBox.shrink())),
        ],
      ]));
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Flex(direction: vertical ? Axis.vertical : Axis.horizontal, crossAxisAlignment: CrossAxisAlignment.start, children: [
        foot('GENERATED BY', (run['generated_by_name'] as String?) ?? '—', _when(run['generated_at'])),
        foot('APPROVED BY', approved ? ((run['finalized_by_name'] as String?) ?? '—') : '—',
            approved ? _when(run['finalized_at']) : 'Awaiting approval (Finalize)',
            sig: approved ? _approvedSig(run) : null),
        if (st == 'paid') foot('PAID BY', (run['paid_by_name'] as String?) ?? '—', _when(run['paid_at'])),
      ]),
    );
  }

  /// Print: DRAFT watermark + footprint block (with approver's signature).
  String _printExtrasCss() => '''
.wm{position:fixed;top:40%;left:0;right:0;text-align:center;font-size:120px;font-weight:900;color:rgba(200,30,30,.10);transform:rotate(-30deg);z-index:0;pointer-events:none;letter-spacing:12px}
.fp{margin-top:22px;display:flex;gap:24px;font-size:11px}
.fp div{flex:1;border-top:1px solid #999;padding-top:4px;color:#444}
.fp b{display:block;color:#111;font-size:12px}
.fp img{height:40px;max-width:150px;object-fit:contain;display:block;margin-bottom:2px}
''';

  String _printWatermark(Map run) => (run['status'] as String? ?? 'draft') == 'draft' ? '<div class="wm">DRAFT</div>' : '';

  String _printFootprints(Map run) {
    final st = run['status'] as String? ?? 'draft';
    final approved = st == 'finalized' || st == 'paid';
    final sig = approved ? _approvedSig(run) : null;
    String cell(String label, String who, String when, {String? sig}) =>
        '<div>${sig != null && sig.isNotEmpty ? '<img src="${_esc(sig)}">' : ''}<b>${_esc(who)}</b>${_esc(label)}${when.isEmpty ? '' : ' · ${_esc(when)}'}</div>';
    return '<div class="fp">'
        '${cell('Generated by', (run['generated_by_name'] as String?) ?? '—', _when(run['generated_at']))}'
        '${approved ? cell('Approved by', (run['finalized_by_name'] as String?) ?? '—', _when(run['finalized_at']), sig: sig) : cell('Approved by', '—', 'awaiting approval')}'
        '${st == 'paid' ? cell('Paid by', (run['paid_by_name'] as String?) ?? '—', _when(run['paid_at'])) : ''}'
        '</div>';
  }

  // ── per-employee edit ─────────────────────────────────────────────────────────
  Future<void> _editItem(Map<String, dynamic> item) async {
    if (!_isDraft) { _snack('Run is ${_run?['status']} — reopen to Draft to edit.'); return; }
    final emp = _empById[item['employee_id']];
    final name = emp?['full_name'] as String? ?? 'Employee';
    final allowCtrl = TextEditingController(text: _plain(item['allowances']));
    final bonusCtrl = TextEditingController(text: _plain(item['bonus']));
    final otherCtrl = TextEditingController(text: _plain(item['other_deduction']));
    final advCtrl = TextEditingController(text: _plain(item['advance']));
    final remarksCtrl = TextEditingController(text: item['remarks'] as String? ?? '');
    final basic = (item['basic'] as num?)?.toDouble() ?? 0;
    final absenceDed = (item['absence_deduction'] as num?)?.toDouble() ?? 0;
    final leaveBonus = (item['leave_bonus'] as num?)?.toDouble() ?? 0;

    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      double n(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;
      final gross = basic + leaveBonus + n(allowCtrl) + n(bonusCtrl);
      final totalDed = absenceDed + n(otherCtrl) + n(advCtrl);
      final net = gross - totalDed;
      Widget field(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setLocal(() {}),
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder())),
      );
      return AlertDialog(
        title: Text('Payslip — $name', style: const TextStyle(fontSize: 15)),
        content: SizedBox(width: 380, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _kv('Basic', _nf2.format(basic)),
          _kv('Absence deduction', '- ${_nf2.format(absenceDed)}', color: Colors.red),
          if (leaveBonus > 0)
            _kv(_plLabel(item), '+ ${_nf2.format(leaveBonus)}', color: Colors.green.shade700),
          const Divider(),
          const Text('Earnings', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          field('Allowances', allowCtrl),
          field('Bonus', bonusCtrl),
          const SizedBox(height: 4),
          const Text('Deductions', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          field('Other deduction (fine/etc.)', otherCtrl),
          field('Advance / loan', advCtrl),
          if (item['advance_balance'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(child: Text(
                  'Outstanding advance: ${_nf2.format((item['advance_balance'] as num).toDouble())}'
                  ' · left after this: ${_nf2.format((item['advance_balance'] as num).toDouble() - n(advCtrl))}',
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
                TextButton(
                  onPressed: () => setLocal(() => advCtrl.text = _plain(item['advance_balance'])),
                  child: const Text('Recover all', style: TextStyle(fontSize: 12)),
                ),
              ]),
            ),
          TextField(controller: remarksCtrl, decoration: const InputDecoration(labelText: 'Remarks', isDense: true, border: OutlineInputBorder())),
          const Divider(height: 20),
          _kv('Gross', _nf2.format(gross)),
          _kv('Total deductions', '- ${_nf2.format(totalDed)}', color: Colors.red),
          _kv('Net pay', _nf2.format(net), bold: true),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
            onPressed: () async {
              await _saveItem(item, n(allowCtrl), n(bonusCtrl), n(otherCtrl), n(advCtrl), remarksCtrl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      );
    }));
  }

  String _plain(dynamic v) {
    final n = (v as num?)?.toDouble() ?? 0;
    if (n == 0) return '';
    return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  }

  Future<void> _saveItem(Map<String, dynamic> item, double allow, double bonus, double other, double adv, String remarks) async {
    setState(() => _busy = true);
    try {
      final basic = (item['basic'] as num?)?.toDouble() ?? 0;
      final absenceDed = (item['absence_deduction'] as num?)?.toDouble() ?? 0;
      final gross = basic + ((item['leave_bonus'] as num?)?.toDouble() ?? 0) + allow + bonus;
      final totalDed = absenceDed + other + adv;
      final net = gross - totalDed;
      await Supabase.instance.client.from('hr_payroll_items').update({
        'allowances': allow, 'bonus': bonus, 'other_deduction': other, 'advance': adv,
        'remarks': remarks, 'gross': _r2(gross), 'total_deduction': _r2(totalDed), 'net': _r2(net),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', item['id'] as String);
      // update local + run total
      item['allowances'] = allow; item['bonus'] = bonus; item['other_deduction'] = other; item['advance'] = adv;
      item['remarks'] = remarks; item['gross'] = _r2(gross); item['total_deduction'] = _r2(totalDed); item['net'] = _r2(net);
      double totalNet = 0; for (final it in _items) { totalNet += (it['net'] as num?)?.toDouble() ?? 0; }
      await Supabase.instance.client.from('hr_payroll_runs').update({'total_net': _r2(totalNet), 'updated_at': DateTime.now().toIso8601String()}).eq('id', _run!['id'] as String);
      _run!['total_net'] = _r2(totalNet);
      if (mounted) setState(() {});
    } catch (e) { _snack('Save failed: $e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  void _snack(String m) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m))); }

  // ── build ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Payroll', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.beach_access_outlined, size: 20),
            tooltip: 'Paid leave days (monthly bonus)',
            onPressed: _busy ? null : _paidLeaveSettings,
          ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Center(child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Generate'),
            onPressed: _busy ? null : _generateDialog,
          ))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.textSecondary)))
              : LayoutBuilder(builder: (ctx, cons) {
                  final wide = cons.maxWidth >= 820;
                  if (!wide) {
                    return _run == null ? _runList() : Column(children: [
                      _backBar(),
                      Expanded(child: _detail()),
                    ]);
                  }
                  return Row(children: [
                    SizedBox(width: 300, child: _runList()),
                    const VerticalDivider(width: 1),
                    Expanded(child: _detail()),
                  ]);
                }),
    );
  }

  Widget _backBar() => Container(
    color: AppTheme.card,
    child: Row(children: [
      IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _run = null)),
      Text(_run != null ? _periodLabel(_run!['period'] as String) : '', style: const TextStyle(fontWeight: FontWeight.w700)),
    ]),
  );

  Widget _runList() {
    if (_runs.isEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.payments_outlined, size: 46, color: AppTheme.textSecondary),
        const SizedBox(height: 10),
        const Text('No payroll runs yet', style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        ElevatedButton.icon(onPressed: _generateDialog, icon: const Icon(Icons.add), label: const Text('Generate first run'),
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white)),
      ])));
    }
    return ListView.separated(
      itemCount: _runs.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = _runs[i];
        final sel = _run != null && _run!['id'] == r['id'];
        final st = r['status'] as String? ?? 'draft';
        return Container(
          color: sel ? AppTheme.primary.withOpacity(0.08) : null,
          child: ListTile(
            title: Text(_periodLabel(r['period'] as String), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text('${r['employee_count'] ?? 0} staff · net ${_nf.format((r['total_net'] as num?)?.toDouble() ?? 0)}', style: const TextStyle(fontSize: 11)),
            trailing: _statusChip(st),
            onTap: () => _selectRun(r),
          ),
        );
      },
    );
  }

  Widget _statusChip(String st) {
    final c = st == 'paid' ? Colors.green : (st == 'finalized' ? Colors.blue : Colors.orange);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: c.withOpacity(0.4))),
      child: Text(st[0].toUpperCase() + st.substring(1), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _detail() {
    final run = _run;
    if (run == null) return const Center(child: Text('Select a payroll run', style: TextStyle(color: AppTheme.textSecondary)));
    final st = run['status'] as String? ?? 'draft';
    return Column(children: [
      Container(
        color: AppTheme.card,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(_periodLabel(run['period'] as String), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            _statusChip(st),
            const Spacer(),
            if (_busy) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
          ]),
          const SizedBox(height: 4),
          Text('${_items.length} employees  ·  Gross ${_nf.format(_sum('gross'))}  ·  Deductions ${_nf.format(_sum('total_deduction'))}  ·  Net ${_nf.format(_sum('net'))}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (_isDraft) OutlinedButton.icon(icon: const Icon(Icons.refresh, size: 16), label: const Text('Regenerate'), onPressed: _busy ? null : () => _generate(DateTime.parse('${run['period']}-01'))),
            OutlinedButton.icon(icon: const Icon(Icons.description_outlined, size: 16), label: const Text('Register PDF'), onPressed: _items.isEmpty ? null : _printRegister),
            if (st == 'draft') ElevatedButton.icon(icon: const Icon(Icons.lock_outline, size: 16), label: const Text('Finalize'), style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white), onPressed: _busy || _items.isEmpty ? null : () => _setStatus('finalized')),
            if (st == 'finalized') ElevatedButton.icon(icon: const Icon(Icons.check_circle_outline, size: 16), label: const Text('Mark paid'), style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white), onPressed: _busy ? null : () => _setStatus('paid')),
            if (st != 'draft') OutlinedButton.icon(icon: const Icon(Icons.lock_open_outlined, size: 16), label: const Text('Reopen to Draft'), onPressed: _busy ? null : () => _setStatus('draft')),
          ]),
        ]),
      ),
      _excludedBar(),
      const Divider(height: 1),
      Expanded(child: Stack(children: [
        _items.isEmpty
            ? const Center(child: Text('No payslips — press Regenerate', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: _items.length + 1,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => i == _items.length ? _footprints(run) : _itemTile(_items[i]),
              ),
        if (st == 'draft')
          Positioned.fill(child: IgnorePointer(child: Center(child: Transform.rotate(
            angle: -0.5,
            child: Text('DRAFT', style: TextStyle(fontSize: 120, fontWeight: FontWeight.w900,
                letterSpacing: 14, color: Colors.red.withOpacity(0.07))),
          )))),
      ])),
    ]);
  }

  double _sum(String key) { double t = 0; for (final it in _items) t += (it[key] as num?)?.toDouble() ?? 0; return t; }

  Widget _itemTile(Map<String, dynamic> item) {
    final emp = _empById[item['employee_id']];
    final name = emp?['full_name'] as String? ?? '(removed)';
    final code = emp?['employee_code'] as String? ?? '';
    final net = (item['net'] as num?)?.toDouble() ?? 0;
    return InkWell(
      onTap: () => _editItem(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            if (item['advance_balance'] != null && ((item['advance_balance'] as num?)?.toDouble() ?? 0) != 0)
              Text('Advance ${_nf.format((item['advance'] as num?)?.toDouble() ?? 0)} of ${_nf.format((item['advance_balance'] as num).toDouble())} outstanding',
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
            if (((item['leave_bonus'] as num?)?.toDouble() ?? 0) > 0)
              Text('${_plLabel(item)} · +${_nf.format((item['leave_bonus'] as num?)?.toDouble() ?? 0)}',
                  style: TextStyle(fontSize: 11, color: Colors.green.shade700)),
            Text([if (code.isNotEmpty) code, _deductionSummary(item)].join('  ·  '),
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ])),
          Expanded(flex: 2, child: Text(_nf.format((item['basic'] as num?)?.toDouble() ?? 0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
          Expanded(flex: 2, child: Text('- ${_nf.format((item['total_deduction'] as num?)?.toDouble() ?? 0)}', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: Colors.red.shade600))),
          Expanded(flex: 2, child: Text(_nf.format(net), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
          const SizedBox(width: 6),
          IconButton(icon: const Icon(Icons.receipt_long_outlined, size: 18), tooltip: 'Payslip PDF', onPressed: () => _printPayslip(item)),
          if (_isDraft)
            IconButton(
              icon: Icon(Icons.person_remove_outlined, size: 18, color: Colors.red.shade400),
              tooltip: 'Exclude from this payroll',
              onPressed: _busy ? null : () => _exclude(item),
            ),
        ]),
      ),
    );
  }

  /// "Paid leave (2 days: covers 1 absent, 1 unused)"
  String _plLabel(Map<String, dynamic> it) {
    double v(String k) => (it[k] as num?)?.toDouble() ?? 0;
    final q = v('paid_leave_quota'), used = v('paid_leave_used'), unused = v('leave_bonus_days');
    final covers = used < q ? used : q;
    final parts = <String>[
      if (covers > 0) 'covers ${_nf2.format(covers)} absent',
      if (unused > 0) '${_nf2.format(unused)} unused',
    ];
    return 'Paid leave (${_nf2.format(q)} days${parts.isEmpty ? '' : ': ${parts.join(', ')}'})';
  }

  /// "Leave 1 · Unapproved 2 · +2 extra = 5 days deducted"
  String _deductionSummary(Map<String, dynamic> it) {
    double v(String k) => (it[k] as num?)?.toDouble() ?? 0;
    final appr = v('approved_leave_days'), unappr = v('unapproved_days');
    final absent = v('absent_days'), penalty = v('penalty_days'), half = v('half_days'), nj = v('notjoined_days');
    final plain = absent - appr - unappr;
    final parts = <String>[
      if (appr > 0) 'Leave ${_nf2.format(appr)}',
      if (unappr > 0) 'Unapproved ${_nf2.format(unappr)}',
      if (penalty > 0) '+${_nf2.format(penalty)} extra',
      if (plain > 0) 'Absent ${_nf2.format(plain)}',
      if (half > 0) '½ day ${_nf2.format(half)}',
      if (nj > 0) 'Before joining ${_nf2.format(nj)}',
    ];
    final total = v('unpaid_days');
    if (parts.isEmpty) return 'No days deducted';
    return '${parts.join(' · ')} = ${_nf2.format(total)} day${total == 1 ? '' : 's'} deducted';
  }

  // ── printing ──────────────────────────────────────────────────────────────────
  String _esc(String? s) => (s ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  void _open(String content) {
    final blob = html.Blob([content], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  void _printPayslip(Map<String, dynamic> item) {
    final run = _run; if (run == null) return;
    final emp = _empById[item['employee_id']] ?? {};
    final name = _esc(emp['full_name'] as String?);
    final code = _esc(emp['employee_code'] as String?);
    final dept = _esc(_deptName[emp['department_id']] ?? '');
    final bank = _esc(emp['bank_name'] as String?);
    final acct = _esc(emp['bank_account'] as String?);
    double v(String k) => (item[k] as num?)?.toDouble() ?? 0;
    String row(String k, num val, {bool ded = false, bool bold = false}) =>
        '<tr><td>${_esc(k)}</td><td style="text-align:right${bold ? ';font-weight:700' : ''}">${ded ? '-' : ''}${_nf2.format(val)}</td></tr>';

    final content = '''<!DOCTYPE html><html><head><meta charset="utf-8"><title>Payslip — $name — ${run['period']}</title>
<style>@page{margin:16mm}*{box-sizing:border-box}body{font-family:Arial,Helvetica,sans-serif;color:#111;margin:0}
.org{font-size:12px;color:#244C97;font-weight:700;text-transform:uppercase;letter-spacing:.5px}
h1{font-size:20px;margin:2px 0 2px}
.sub{font-size:12px;color:#555;margin-bottom:12px}
.grid{display:flex;gap:24px;margin-bottom:14px}
.card{flex:1;border:1px solid #ddd;border-radius:8px;padding:10px}
.card h3{font-size:11px;margin:0 0 6px;color:#666;text-transform:uppercase}
.meta{font-size:12px;line-height:1.6}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;background:#f4f6fa;padding:5px 8px;border-bottom:1px solid #ccc;font-size:11px}
td{padding:5px 8px;border-bottom:1px solid #eee}
.two{display:flex;gap:24px}
.net{margin-top:14px;padding:10px 14px;background:#244C97;color:#fff;border-radius:8px;display:flex;justify-content:space-between;font-size:16px;font-weight:800}
.sign{margin-top:44px;display:flex;justify-content:space-between;font-size:11px;color:#444}
.sign div{border-top:1px solid #999;padding-top:4px;width:40%}
.foot{margin-top:16px;font-size:10px;color:#888}
${_printExtrasCss()}
</style></head><body>
${_printWatermark(run)}
<div class="org">${_esc(_orgName)}</div>
<h1>Payslip</h1>
<div class="sub">Pay period: <b>${_esc(_periodLabel(run['period'] as String))}</b> &nbsp;·&nbsp; Status: ${_esc((run['status'] as String? ?? 'draft'))}</div>
<div class="grid">
  <div class="card"><h3>Employee</h3><div class="meta"><b>$name</b><br>${[if (code.isNotEmpty) code, if (dept.isNotEmpty) dept].join(' · ')}${(bank.isNotEmpty || acct.isNotEmpty) ? '<br>Bank: $bank $acct' : ''}</div></div>
  <div class="card"><h3>Attendance</h3><div class="meta">
    Calendar days: ${v('calendar_days').toInt()}<br>
    Present: ${_nf2.format(v('present_days'))} · Half: ${_nf2.format(v('half_days'))} · Leave: ${_nf2.format(v('leave_days'))}<br>
    Absent: ${_nf2.format(v('absent_days'))} · Penalty: ${_nf2.format(v('penalty_days'))} · Holiday/Rest: ${_nf2.format(v('holiday_days') + v('restday_days'))}<br>
    ${v('notjoined_days') > 0 ? 'Before joining: ${_nf2.format(v('notjoined_days'))}<br>' : ''}Unpaid days: <b>${_nf2.format(v('unpaid_days'))}</b> · Per-day: ${_nf2.format(v('per_day'))}<br>
    <span style="color:#b91c1c">${_esc(_deductionSummary(item))}</span><br>
    Paid leave: ${_nf2.format(v('paid_leave_quota'))} days · covers ${_nf2.format(v('paid_leave_used') < v('paid_leave_quota') ? v('paid_leave_used') : v('paid_leave_quota'))} absent · unused ${_nf2.format(v('leave_bonus_days'))} paid extra
  </div></div>
</div>
<div class="two">
  <div style="flex:1"><table><thead><tr><th>Earnings</th><th style="text-align:right">Amount</th></tr></thead><tbody>
    ${row('Basic', v('basic'))}
    ${v('leave_bonus') > 0 ? row(_plLabel(item), v('leave_bonus')) : ''}
    ${row('Allowances', v('allowances'))}
    ${row('Bonus', v('bonus'))}
    ${row('Gross', v('gross'), bold: true)}
  </tbody></table></div>
  <div style="flex:1"><table><thead><tr><th>Deductions</th><th style="text-align:right">Amount</th></tr></thead><tbody>
    ${row('Absence (${_nf2.format(v('unpaid_days'))} days)', v('absence_deduction'), ded: true)}
    ${row('Other deduction', v('other_deduction'), ded: true)}
    ${row('Advance / loan', v('advance'), ded: true)}
    ${item['advance_balance'] != null ? '<tr><td colspan="2" style="font-size:10px;color:#666">Advance outstanding ${_nf2.format(v('advance_balance'))} · balance after this payslip ${_nf2.format(v('advance_balance') - v('advance'))}</td></tr>' : ''}
    ${row('Total deductions', v('total_deduction'), ded: true, bold: true)}
  </tbody></table></div>
</div>
<div class="net"><span>NET PAY</span><span>${_nf2.format(v('net'))}</span></div>
${(item['remarks'] != null && (item['remarks'] as String).isNotEmpty) ? '<div style="margin-top:10px;font-size:11px"><b>Remarks:</b> ${_esc(item['remarks'] as String?)}</div>' : ''}
${_printFootprints(run)}
<div class="sign"><div>Employee signature</div><div>Authorised signature</div></div>
<div class="foot">Generated ${_esc(DateFormat('d MMM yyyy HH:mm').format(DateTime.now()))} · ${_esc(_orgName)}</div>
<script>window.onload=function(){window.print();}</script>
</body></html>''';
    _open(content);
  }

  void _printRegister() {
    final run = _run; if (run == null) return;
    double col(Map m, String k) => (m[k] as num?)?.toDouble() ?? 0;
    final rows = _items.map((it) {
      final emp = _empById[it['employee_id']] ?? {};
      return '<tr>'
          '<td>${_esc(emp['employee_code'] as String?)}</td>'
          '<td>${_esc(emp['full_name'] as String?)}</td>'
          '<td style="text-align:right">${_nf.format(col(it, 'basic'))}</td>'
          '<td style="text-align:right">${_nf2.format(col(it, 'unpaid_days'))}</td>'
          '<td style="text-align:right">${_nf.format(col(it, 'absence_deduction'))}</td>'
          '<td style="text-align:right">${_nf.format(col(it, 'allowances'))}</td>'
          '<td style="text-align:right">${_nf.format(col(it, 'bonus') + col(it, 'leave_bonus'))}</td>'
          '<td style="text-align:right">${_nf.format(col(it, 'other_deduction') + col(it, 'advance'))}</td>'
          '<td style="text-align:right;font-weight:700">${_nf.format(col(it, 'net'))}</td>'
          '</tr>';
    }).join();
    final content = '''<!DOCTYPE html><html><head><meta charset="utf-8"><title>Payroll register — ${run['period']}</title>
<style>@page{margin:12mm landscape}*{box-sizing:border-box}body{font-family:Arial,Helvetica,sans-serif;color:#111;margin:0}
.org{font-size:12px;color:#244C97;font-weight:700;text-transform:uppercase}
h1{font-size:18px;margin:2px 0}
.sub{font-size:12px;color:#555;margin-bottom:12px}
table{width:100%;border-collapse:collapse;font-size:11px}
th{text-align:left;background:#f4f6fa;padding:5px 6px;border-bottom:1px solid #ccc;font-size:10px}
td{padding:4px 6px;border-bottom:1px solid #eee}
tr:nth-child(even) td{background:#fafbfc}
tfoot td{font-weight:800;border-top:2px solid #244C97;background:#fff}
.foot{margin-top:14px;font-size:10px;color:#888}
${_printExtrasCss()}
</style></head><body>
${_printWatermark(run)}
<div class="org">${_esc(_orgName)}</div>
<h1>Payroll Register — ${_esc(_periodLabel(run['period'] as String))}</h1>
<div class="sub">${_items.length} employees · Status: ${_esc((run['status'] as String? ?? 'draft'))}</div>
<table>
<thead><tr><th>Code</th><th>Employee</th><th style="text-align:right">Basic</th><th style="text-align:right">Unpaid d</th><th style="text-align:right">Absence ded</th><th style="text-align:right">Allow.</th><th style="text-align:right">Bonus (incl. paid leave)</th><th style="text-align:right">Other/Adv</th><th style="text-align:right">Net</th></tr></thead>
<tbody>$rows</tbody>
<tfoot><tr><td colspan="2">Total</td>
<td style="text-align:right">${_nf.format(_sum('basic'))}</td><td></td>
<td style="text-align:right">${_nf.format(_sum('absence_deduction'))}</td>
<td style="text-align:right">${_nf.format(_sum('allowances'))}</td>
<td style="text-align:right">${_nf.format(_sum('bonus') + _sum('leave_bonus'))}</td>
<td style="text-align:right">${_nf.format(_sum('other_deduction') + _sum('advance'))}</td>
<td style="text-align:right">${_nf.format(_sum('net'))}</td></tr></tfoot>
</table>
${_printFootprints(run)}
<div class="foot">Generated ${_esc(DateFormat('d MMM yyyy HH:mm').format(DateTime.now()))} · ${_esc(_orgName)}</div>
<script>window.onload=function(){window.print();}</script>
</body></html>''';
    _open(content);
  }

  Widget _kv(String k, String v, {bool bold = false, Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(k, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      Text(v, style: TextStyle(fontSize: bold ? 15 : 12, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color)),
    ]),
  );
}
