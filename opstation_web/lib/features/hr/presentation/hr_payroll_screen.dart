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
  const HrPayrollScreen({super.key});
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
    _load();
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
          .select('id, full_name, employee_code, department_id, designation_id, branch_id, basic_salary, bank_name, bank_account, join_date, photo_url')
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
          const Text('Basic ÷ calendar days. Absent + penalty days (½ for half-days) are deducted; leave, holidays and rest days are paid. Existing allowances/deductions you entered are preserved.',
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
          .select('id, full_name, branch_id, basic_salary')
          .eq('org_id', orgId).eq('status', 'active').eq('approval_status', 'approved').eq('is_voided', false);
      final emps = List<Map<String, dynamic>>.from(empRows);

      // attendance for the month
      final attRows = await client.from('hr_attendance')
          .select('employee_id, att_date, status, check_in, is_penalty')
          .eq('org_id', orgId).gte('att_date', _fmt(monthStart)).lte('att_date', _fmt(monthEnd));
      final att = <String, Map<String, Map<String, dynamic>>>{};
      for (final r in List<Map<String, dynamic>>.from(attRows)) {
        final e = r['employee_id'] as String?; final d = r['att_date'] as String?;
        if (e == null || d == null) continue;
        (att[e] ??= {})[d] = r;
      }

      // run row (create or reuse)
      final runId = existing?['id'] as String? ?? 'pr_${DateTime.now().microsecondsSinceEpoch}';
      final nowIso = DateTime.now().toIso8601String();
      if (existing == null) {
        await client.from('hr_payroll_runs').insert({
          'id': runId, 'org_id': orgId, 'period': period, 'status': 'draft',
          'generated_at': nowIso, 'generated_by': _userId, 'generated_by_name': _userName,
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

        double present = 0, absent = 0, penalty = 0, leave = 0, half = 0, holiday = 0, rest = 0;
        for (var d = monthStart; !d.isAfter(lastCount); d = d.add(const Duration(days: 1))) {
          if (_isRest(d)) { rest++; continue; }
          final row = att[empId]?[_fmt(d)];
          final st = row?['status'] as String?;
          if (st == 'present') { present++; }
          else if (st == 'half_day') { half++; }
          else if (st == 'leave') { leave++; }
          else if (st == 'holiday') { holiday++; }
          else if (st == 'rest_day') { rest++; }
          else if (st == 'absent') { if (row?['is_penalty'] == true) { penalty++; } else { absent++; } }
          else { absent++; } // no record on a past working day = absent
        }
        final unpaid = absent + penalty + 0.5 * half;
        final absenceDeduction = (perDay * unpaid);

        final prev = prevByEmp[empId];
        final allowances = (prev?['allowances'] as num?)?.toDouble() ?? 0;
        final bonus = (prev?['bonus'] as num?)?.toDouble() ?? 0;
        final otherDed = (prev?['other_deduction'] as num?)?.toDouble() ?? 0;
        final advance = (prev?['advance'] as num?)?.toDouble() ?? 0;
        final remarks = prev?['remarks'] as String?;

        final gross = basic + allowances + bonus;
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

  // ── status transitions ──────────────────────────────────────────────────────
  Future<void> _setStatus(String status) async {
    final run = _run; final orgId = _orgId;
    if (run == null || orgId == null) return;
    setState(() => _busy = true);
    try {
      final now = DateTime.now().toIso8601String();
      final upd = <String, dynamic>{'status': status, 'updated_at': now};
      if (status == 'finalized') upd['finalized_at'] = now;
      if (status == 'paid') upd['paid_at'] = now;
      await Supabase.instance.client.from('hr_payroll_runs').update(upd).eq('id', run['id'] as String);
      run['status'] = status;
      final runs = await Supabase.instance.client.from('hr_payroll_runs').select().eq('org_id', orgId).order('period', ascending: false);
      _runs = List<Map<String, dynamic>>.from(runs);
      _snack('Marked ${_periodLabel(run['period'] as String)} as $status.');
    } catch (e) { _snack('Failed: $e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  bool get _isDraft => (_run?['status'] as String? ?? 'draft') == 'draft';

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

    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      double n(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;
      final gross = basic + n(allowCtrl) + n(bonusCtrl);
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
      final gross = basic + allow + bonus;
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
      const Divider(height: 1),
      Expanded(child: _items.isEmpty
          ? const Center(child: Text('No payslips — press Regenerate', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _itemTile(_items[i]),
            )),
    ]);
  }

  double _sum(String key) { double t = 0; for (final it in _items) t += (it[key] as num?)?.toDouble() ?? 0; return t; }

  Widget _itemTile(Map<String, dynamic> item) {
    final emp = _empById[item['employee_id']];
    final name = emp?['full_name'] as String? ?? '(removed)';
    final code = emp?['employee_code'] as String? ?? '';
    final absent = (item['absent_days'] as num?)?.toDouble() ?? 0;
    final penalty = (item['penalty_days'] as num?)?.toDouble() ?? 0;
    final half = (item['half_days'] as num?)?.toDouble() ?? 0;
    final net = (item['net'] as num?)?.toDouble() ?? 0;
    return InkWell(
      onTap: () => _editItem(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            Text([if (code.isNotEmpty) code, 'Absent ${_nf2.format(absent + penalty)}${half > 0 ? ' · ½ ${_nf2.format(half)}' : ''}${penalty > 0 ? ' (incl. ${_nf2.format(penalty)} penalty)' : ''}'].join('  ·  '),
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ])),
          Expanded(flex: 2, child: Text(_nf.format((item['basic'] as num?)?.toDouble() ?? 0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
          Expanded(flex: 2, child: Text('- ${_nf.format((item['total_deduction'] as num?)?.toDouble() ?? 0)}', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: Colors.red.shade600))),
          Expanded(flex: 2, child: Text(_nf.format(net), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
          const SizedBox(width: 6),
          IconButton(icon: const Icon(Icons.receipt_long_outlined, size: 18), tooltip: 'Payslip PDF', onPressed: () => _printPayslip(item)),
        ]),
      ),
    );
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
</style></head><body>
<div class="org">${_esc(_orgName)}</div>
<h1>Payslip</h1>
<div class="sub">Pay period: <b>${_esc(_periodLabel(run['period'] as String))}</b> &nbsp;·&nbsp; Status: ${_esc((run['status'] as String? ?? 'draft'))}</div>
<div class="grid">
  <div class="card"><h3>Employee</h3><div class="meta"><b>$name</b><br>${[if (code.isNotEmpty) code, if (dept.isNotEmpty) dept].join(' · ')}${(bank.isNotEmpty || acct.isNotEmpty) ? '<br>Bank: $bank $acct' : ''}</div></div>
  <div class="card"><h3>Attendance</h3><div class="meta">
    Calendar days: ${v('calendar_days').toInt()}<br>
    Present: ${_nf2.format(v('present_days'))} · Half: ${_nf2.format(v('half_days'))} · Leave: ${_nf2.format(v('leave_days'))}<br>
    Absent: ${_nf2.format(v('absent_days'))} · Penalty: ${_nf2.format(v('penalty_days'))} · Holiday/Rest: ${_nf2.format(v('holiday_days') + v('restday_days'))}<br>
    Unpaid days: <b>${_nf2.format(v('unpaid_days'))}</b> · Per-day: ${_nf2.format(v('per_day'))}
  </div></div>
</div>
<div class="two">
  <div style="flex:1"><table><thead><tr><th>Earnings</th><th style="text-align:right">Amount</th></tr></thead><tbody>
    ${row('Basic', v('basic'))}
    ${row('Allowances', v('allowances'))}
    ${row('Bonus', v('bonus'))}
    ${row('Gross', v('gross'), bold: true)}
  </tbody></table></div>
  <div style="flex:1"><table><thead><tr><th>Deductions</th><th style="text-align:right">Amount</th></tr></thead><tbody>
    ${row('Absence (${_nf2.format(v('unpaid_days'))} days)', v('absence_deduction'), ded: true)}
    ${row('Other deduction', v('other_deduction'), ded: true)}
    ${row('Advance / loan', v('advance'), ded: true)}
    ${row('Total deductions', v('total_deduction'), ded: true, bold: true)}
  </tbody></table></div>
</div>
<div class="net"><span>NET PAY</span><span>${_nf2.format(v('net'))}</span></div>
${(item['remarks'] != null && (item['remarks'] as String).isNotEmpty) ? '<div style="margin-top:10px;font-size:11px"><b>Remarks:</b> ${_esc(item['remarks'] as String?)}</div>' : ''}
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
          '<td style="text-align:right">${_nf.format(col(it, 'bonus'))}</td>'
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
</style></head><body>
<div class="org">${_esc(_orgName)}</div>
<h1>Payroll Register — ${_esc(_periodLabel(run['period'] as String))}</h1>
<div class="sub">${_items.length} employees · Status: ${_esc((run['status'] as String? ?? 'draft'))}</div>
<table>
<thead><tr><th>Code</th><th>Employee</th><th style="text-align:right">Basic</th><th style="text-align:right">Unpaid d</th><th style="text-align:right">Absence ded</th><th style="text-align:right">Allow.</th><th style="text-align:right">Bonus</th><th style="text-align:right">Other/Adv</th><th style="text-align:right">Net</th></tr></thead>
<tbody>$rows</tbody>
<tfoot><tr><td colspan="2">Total</td>
<td style="text-align:right">${_nf.format(_sum('basic'))}</td><td></td>
<td style="text-align:right">${_nf.format(_sum('absence_deduction'))}</td>
<td style="text-align:right">${_nf.format(_sum('allowances'))}</td>
<td style="text-align:right">${_nf.format(_sum('bonus'))}</td>
<td style="text-align:right">${_nf.format(_sum('other_deduction') + _sum('advance'))}</td>
<td style="text-align:right">${_nf.format(_sum('net'))}</td></tr></tfoot>
</table>
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
