import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';

/// Employee profile ▸ History (SQL 342).
///
/// Every change to the profile, one line per field (old → new), grouped by
/// save, newest first, with who made it. Salary / bank / CNIC / advance rows
/// are returned by the database to admins only.
class EmployeeHistorySection extends StatefulWidget {
  final String employeeId;
  final bool isAdmin;
  final Map<String, String> deptName, desigName, branchName, shiftName, accountName;
  const EmployeeHistorySection({
    super.key,
    required this.employeeId,
    required this.isAdmin,
    this.deptName = const {},
    this.desigName = const {},
    this.branchName = const {},
    this.shiftName = const {},
    this.accountName = const {},
  });

  @override
  State<EmployeeHistorySection> createState() => _EmployeeHistorySectionState();
}

class _Group {
  final DateTime at;
  final String type; // baseline | created | updated | deleted
  final String who;
  final List<Map<String, dynamic>> rows = [];
  _Group(this.at, this.type, this.who);
}

class _EmployeeHistorySectionState extends State<EmployeeHistorySection> {
  bool _loading = true;
  String? _error;
  List<_Group> _groups = [];
  bool _expanded = false;

  static const _labels = <String, String>{
    'employee_code': 'Employee code',
    'full_name': 'Name',
    'father_name': 'Father name',
    'cnic': 'CNIC',
    'gender': 'Gender',
    'date_of_birth': 'Date of birth',
    'phone': 'Phone',
    'email': 'Email',
    'address': 'Address',
    'emergency_contact': 'Emergency contact',
    'department_id': 'Department',
    'designation_id': 'Designation',
    'branch_id': 'Branch',
    'employment_type': 'Employment type',
    'join_date': 'Join date',
    'left_on': 'Left on',
    'left_reason': 'Reason for leaving',
    'left_note': 'Leaving note',
    'left_card_uid': 'Card (at leaving)',
    'status': 'Status',
    'basic_salary': 'Basic salary',
    'shift_id': 'Shift',
    'photo_url': 'Photo',
    'notify_punch': 'Punch notifications',
    'notify_email': 'Notification email',
    'approval_status': 'Approval',
    'bank_name': 'Bank name',
    'bank_account': 'Bank account',
    'notes': 'Notes',
    'card_uid': 'Card UID',
    'advance_account_id': 'Advance account',
    'advance_installment': 'Advance installment',
    'paid_leave_days': 'Paid leave days / month',
    'is_voided': 'Voided',
    'rest_day': 'Weekly rest day',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = List<Map<String, dynamic>>.from(await Supabase.instance.client
          .from('hr_employee_history')
          .select('event_type, field, old_value, new_value, sensitive, changed_at, changed_by_name')
          .eq('employee_id', widget.employeeId)
          .order('changed_at', ascending: false)
          .order('id', ascending: true)
          .limit(1000));
      final groups = <_Group>[];
      for (final r in rows) {
        final at = DateTime.tryParse('${r['changed_at']}')?.toLocal() ?? DateTime(2000);
        final type = '${r['event_type']}';
        final who = (r['changed_by_name'] as String?) ?? '—';
        final last = groups.isEmpty ? null : groups.last;
        // One save = same second, same person, same kind of event.
        if (last != null &&
            last.type == type &&
            last.who == who &&
            last.at.difference(at).inSeconds.abs() <= 2) {
          last.rows.add(r);
        } else {
          groups.add(_Group(at, type, who)..rows.add(r));
        }
      }
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().contains('hr_employee_history')
            ? 'History needs the database update — run 342_employee_history.sql.'
            : 'Could not load history: $e';
      });
    }
  }

  String _label(String f) =>
      _labels[f] ?? (f.isEmpty ? f : (f[0].toUpperCase() + f.substring(1)).replaceAll('_', ' '));

  String _value(String field, String? v) {
    if (v == null || v.trim().isEmpty) return '—';
    switch (field) {
      case 'department_id': return widget.deptName[v] ?? v;
      case 'designation_id': return widget.desigName[v] ?? v;
      case 'branch_id': return widget.branchName[v] ?? v;
      case 'shift_id': return widget.shiftName[v] ?? v;
      case 'advance_account_id': return widget.accountName[v] ?? v;
      case 'photo_url': return 'set';
      case 'basic_salary':
      case 'advance_installment':
        final n = num.tryParse(v);
        return n == null ? v : NumberFormat(n % 1 == 0 ? '#,##0' : '#,##0.00').format(n);
      case 'rest_day':
        const d = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
        final i = int.tryParse(v);
        return i != null && i >= 0 && i < 7 ? d[i] : v;
    }
    if (v == 'true') return 'Yes';
    if (v == 'false') return 'No';
    if (RegExp(r'^[a-z_]+$').hasMatch(v) && v.length < 24) {
      return (v[0].toUpperCase() + v.substring(1)).replaceAll('_', ' ');
    }
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final edits = _groups.where((g) => g.type != 'baseline').length;
    return Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.vertical(
                    top: const Radius.circular(10),
                    bottom: Radius.circular(_expanded ? 0 : 10))),
            child: Row(children: [
              const Icon(Icons.history, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    _loading
                        ? 'Profile history'
                        : 'Profile history · ${edits == 0 ? 'no changes yet' : '$edits change${edits == 1 ? '' : 's'}'}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
            ]),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.all(14),
            child: _loading
                ? const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
                : _error != null
                    ? Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (!widget.isAdmin)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 10),
                            child: Text('Salary, bank, CNIC and advance changes are visible to admins only.',
                                style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                          ),
                        if (_groups.isEmpty)
                          const Text('No history recorded yet.',
                              style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                        for (final g in _groups) _groupTile(g),
                      ]),
          ),
      ]),
    );
  }

  Widget _groupTile(_Group g) {
    final when = DateFormat('d MMM yyyy, HH:mm').format(g.at);
    final (IconData icon, Color color, String title) = switch (g.type) {
      'baseline' => (Icons.flag_outlined, AppTheme.textSecondary, 'Profile on record when history started'),
      'created' => (Icons.person_add_alt, AppTheme.success, 'Employee created'),
      'deleted' => (Icons.delete_outline, AppTheme.danger, 'Employee deleted'),
      _ => (Icons.edit_outlined, AppTheme.primary, '${g.rows.length} field${g.rows.length == 1 ? '' : 's'} changed'),
    };
    final lines = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final r in g.rows)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: '${_label('${r['field']}')}: ',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              if (g.type == 'updated') ...[
                TextSpan(
                    text: _value('${r['field']}', r['old_value'] as String?),
                    style: const TextStyle(color: AppTheme.textSecondary, decoration: TextDecoration.lineThrough)),
                const TextSpan(text: '  →  '),
              ],
              TextSpan(
                  text: _value('${r['field']}',
                      (g.type == 'deleted' ? r['old_value'] : r['new_value']) as String?)),
              if (r['sensitive'] == true)
                const WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(Icons.lock_outline, size: 12, color: AppTheme.textSecondary),
                    )),
            ]),
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
    ]);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: color.withOpacity(0.5), width: 3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text('$title · $when${g.type == 'baseline' ? '' : ' · ${g.who}'}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
        if (g.type == 'baseline')
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 6),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              dense: true,
              title: Text('Show ${g.rows.length} fields',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              children: [lines],
            ),
          )
        else
          lines,
      ]),
    );
  }
}
