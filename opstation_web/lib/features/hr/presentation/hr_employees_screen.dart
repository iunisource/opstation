// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../../core/widgets/adaptive_master_detail.dart';
import '../../auth/auth_controller.dart';
import 'employee_history_section.dart';
import '../../../core/permissions/access_control.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:http/http.dart' as http;
import 'package:barcode/barcode.dart';
import 'package:opstation_web/core/pdf/pdf_output.dart';

class HrEmployeesScreen extends ConsumerStatefulWidget {
  const HrEmployeesScreen({super.key, this.focusId});
  // When set (e.g. opened from the Attendance Board), auto-select this employee
  // once the list has loaded.
  final String? focusId;
  @override
  ConsumerState<HrEmployeesScreen> createState() => _State();
}

class _State extends ConsumerState<HrEmployeesScreen> {
  bool _loading = true;
  bool _drawerOpen = true;
  String _listSearch = '';

  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _departments = [];   // {id, name, is_active}
  List<Map<String, dynamic>> _designations = [];   // {id, name, is_active}
  List<Map<String, dynamic>> _branches = [];       // {id, name}
  Map<String, String> _deptName = {}, _desigName = {}, _branchName = {};

  Map<String, dynamic>? _current;
  bool _saving = false;
  bool _canWrite = false;

  // form controllers
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _father = TextEditingController();
  final _cnic = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _emergency = TextEditingController();
  final _salary = TextEditingController();
  final _bankName = TextEditingController();
  final _bankAcct = TextEditingController();
  // Salary advances: the GL account the employee's advances are booked to, and
  // an optional fixed monthly recovery (blank = recover the full balance).
  String? _advAcctId;
  final _advInst = TextEditingController();
  // Paid leave days per month for this employee (blank = company default).
  final _plDays = TextEditingController();
  double? _advBal; // outstanding balance of that account, today
  List<Map<String, dynamic>> _assetAccounts = []; // {id, code, name}
  final _notes = TextEditingController();
  final _notifyEmail = TextEditingController();
  final _cardUid = TextEditingController();
  bool _notifyPunch = false;
  // form state
  String? _deptId, _desigId, _branchId, _gender, _empType;
  String? _bloodGroup;
  String _bloodFilter = 'all'; // directory list filter: all | none | A+ …
  DateTime? _dob, _joinDate, _leftOn;
  String _status = 'active';
  String? _shiftId;
  String? _photoUrl;
  bool _photoUploading = false;
  List<Map<String, dynamic>> _shifts = [];
  int? _orgRestDay; // org-wide weekly rest day: 0=Sunday … 6=Saturday
  Map<String, String> _shiftName = {};
  List<Map<String, dynamic>> _docs = [];
  bool _docUploading = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.admin || r == WebUserRole.masterAdmin; }
  bool get _canHrSetup {
    final a = ref.read(accessSyncProvider);
    return (a?.canEditDoc('hr_setup') ?? false) || (a?.canAddDoc('hr_setup') ?? false);
  }
  bool get _pending => _current != null && (_current!['approval_status'] as String? ?? 'approved') == 'pending';
  bool get _voided => _current != null && _current!['is_voided'] == true;
  bool get _left => _current != null && _current!['status'] == 'left';
  bool _showLeft = false; // directory list: show employees who have left
  int? _min(String? hhmm) { if (hhmm == null || hhmm.isEmpty) return null; final p = hhmm.split(':'); if (p.length != 2) return null; final h = int.tryParse(p[0]), m = int.tryParse(p[1]); if (h == null || m == null) return null; return h * 60 + m; }

  static const _genders = [
    {'v': 'male', 'l': 'Male'}, {'v': 'female', 'l': 'Female'}, {'v': 'other', 'l': 'Other'},
  ];
  static const _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

  static const _empTypes = [
    {'v': 'permanent', 'l': 'Permanent'}, {'v': 'contract', 'l': 'Contract'}, {'v': 'daily_wager', 'l': 'Daily wager'},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _father, _cnic, _phone, _email, _address, _emergency, _salary, _bankName, _bankAcct, _notes, _notifyEmail, _cardUid, _advInst, _plDays]) c.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadAll() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _loadAll(); return; }
    setState(() => _loading = true);
    try {
      await Future.wait([_loadDepts(), _loadDesignations(), _loadBranches(), _loadShifts(), _loadAssetAccounts()]);
      await _loadEmployees();
    } catch (e) { _snack('Load error: $e'); }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadEmployees() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_employees').select().eq('org_id', orgId).order('full_name');
    if (mounted) setState(() => _employees = List<Map<String, dynamic>>.from(rows));
    // Auto-select the employee passed in (e.g. tapped on the Attendance Board),
    // once, after the list is available.
    final fid = widget.focusId;
    if (fid != null && fid.isNotEmpty && _current == null) {
      final match = _employees.where((e) => e['id'] == fid).toList();
      if (match.isNotEmpty) _loadEmployee(match.first);
    }
  }


  Future<void> _loadDepts() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_departments').select('id, name, is_active').eq('org_id', orgId).order('name');
    if (mounted) setState(() { _departments = List<Map<String, dynamic>>.from(rows); _deptName = {for (final d in _departments) d['id'] as String: d['name'] as String}; });
  }

  Future<void> _loadDesignations() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_designations').select('id, name, is_active').eq('org_id', orgId).order('name');
    if (mounted) setState(() { _designations = List<Map<String, dynamic>>.from(rows); _desigName = {for (final d in _designations) d['id'] as String: d['name'] as String}; });
  }

  Future<void> _loadBranches() async {
    final orgId = _orgId; if (orgId == null) return;
    // Exclude processor / off-site virtual locations (branches.is_virtual) —
    // an employee works at a physical branch, not a processor location.
    final rows = await Supabase.instance.client.from('branches').select('id, name').eq('org_id', orgId).not('is_virtual', 'is', true).order('name');
    if (mounted) setState(() { _branches = List<Map<String, dynamic>>.from(rows); _branchName = {for (final b in _branches) b['id'] as String: b['name'] as String}; });
  }

  Future<void> _loadAssetAccounts() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('chart_of_accounts')
          .select('id, code, name').eq('org_id', orgId).eq('account_type', 'asset').order('code');
      final list = List<Map<String, dynamic>>.from(rows);
      // Advance accounts first, then everything else.
      bool adv(Map a) => '${a['name']}'.toLowerCase().contains('advance');
      list.sort((a, b) {
        final c = (adv(a) ? 0 : 1).compareTo(adv(b) ? 0 : 1);
        return c != 0 ? c : '${a['code']}'.compareTo('${b['code']}');
      });
      if (mounted) setState(() => _assetAccounts = list);
    } catch (_) {}
  }

  String _acctLabel(String? id) {
    if (id == null) return '';
    for (final a in _assetAccounts) {
      if (a['id'] == id) return '${a['code'] ?? ''} — ${a['name'] ?? ''}';
    }
    return '(account not found)';
  }

  Future<void> _loadAdvBalance() async {
    final orgId = _orgId; final acct = _advAcctId;
    if (orgId == null || acct == null) { if (mounted) setState(() => _advBal = null); return; }
    try {
      final tomorrow = DateFormat('yyyy-MM-dd').format(DateTime.now().add(const Duration(days: 1)));
      final b = await Supabase.instance.client.rpc('rpc_account_opening', params: {
        'p_org_id': orgId, 'p_account_id': acct, 'p_date_from': tomorrow, 'p_branch_id': null,
      });
      if (mounted && _advAcctId == acct) setState(() => _advBal = (b as num?)?.toDouble() ?? 0);
    } catch (_) {
      if (mounted) setState(() => _advBal = null);
    }
  }

  Future<void> _pickAdvAccount() async {
    final q = TextEditingController();
    final picked = await showDialog<String>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      final t = q.text.trim().toLowerCase();
      final list = _assetAccounts.where((a) =>
          t.isEmpty || '${a['code']} ${a['name']}'.toLowerCase().contains(t)).take(200).toList();
      return AlertDialog(
        title: const Text('Advance account', style: TextStyle(fontSize: 16)),
        content: SizedBox(width: 420, height: 420, child: Column(children: [
          TextField(controller: q, autofocus: true, onChanged: (_) => setLocal(() {}),
              decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search account code or name', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          Expanded(child: list.isEmpty
              ? const Center(child: Text('No matching asset accounts', style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.builder(itemCount: list.length, itemBuilder: (_, i) {
                  final a = list[i];
                  final sel = a['id'] == _advAcctId;
                  return ListTile(
                    dense: true,
                    selected: sel,
                    title: Text('${a['name'] ?? ''}', style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${a['code'] ?? ''}', style: const TextStyle(fontSize: 11)),
                    trailing: sel ? const Icon(Icons.check, size: 18, color: AppTheme.primary) : null,
                    onTap: () => Navigator.pop(ctx, a['id'] as String),
                  );
                })),
        ])),
        actions: [
          if (_advAcctId != null) TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove link')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      );
    }));
    if (picked == null) return;
    setState(() { _advAcctId = picked.isEmpty ? null : picked; _advBal = null; });
    _loadAdvBalance();
  }

  Widget _advancesCard() {
    final bal = _advBal;
    final inst = double.tryParse(_advInst.text.trim());
    return _card('Salary advances', [
      _labeled('Advance account', InkWell(
        onTap: _canWrite ? _pickAdvAccount : null,
        child: InputDecorator(
          decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
              suffixIcon: Icon(Icons.arrow_drop_down)),
          child: Text(_advAcctId == null ? 'Not linked — tap to choose (e.g. "Advances to Staff - …")' : _acctLabel(_advAcctId),
              style: TextStyle(fontSize: 13, color: _advAcctId == null ? AppTheme.textSecondary : AppTheme.textPrimary)),
        ),
      )),
      const SizedBox(height: 12),
      _labeled('Monthly recovery (optional)', _tf(_advInst, hint: 'Blank = recover the full outstanding balance each month', numeric: true)),
      const SizedBox(height: 8),
      if (_advAcctId != null)
        Text(
          bal == null
              ? 'Checking balance…'
              : 'Outstanding today: ${NumberFormat('#,##0').format(bal)}'
                '${bal > 0 ? ' · next payroll deducts ${NumberFormat('#,##0').format(inst != null && inst > 0 && inst < bal ? inst : bal)}' : ''}',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: (bal ?? 0) > 0 ? Colors.orange.shade800 : AppTheme.textSecondary),
        ),
      const SizedBox(height: 4),
      const Text('Payroll reads this account\'s balance at month end and fills the "Advance / loan" deduction on the payslip (never more than the net pay). '
          'You can still change it on the payslip. Book the recovery in your salary JV as usual.',
          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    ]);
  }

  Future<void> _loadShifts() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_shifts').select().eq('org_id', orgId).order('name');
    int? rest;
    try {
      final c = await Supabase.instance.client.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.weekly_rest_day').maybeSingle();
      rest = int.tryParse('${c?['value'] ?? ''}');
    } catch (_) {}
    if (mounted) setState(() { _shifts = List<Map<String, dynamic>>.from(rows); _shiftName = {for (final s in _shifts) s['id'] as String: s['name'] as String}; _orgRestDay = rest; });
  }

  List<Map<String, dynamic>> get _activeDepts => _departments.where((d) => d['is_active'] != false).toList();
  List<Map<String, dynamic>> get _activeDesigs => _designations.where((d) => d['is_active'] != false).toList();

  void _newEmployee() {
    setState(() {
      _current = null; _status = 'active';
      for (final c in [_code, _name, _father, _cnic, _phone, _email, _address, _emergency, _salary, _bankName, _bankAcct, _notes, _notifyEmail, _cardUid, _advInst, _plDays]) c.clear();
      _advAcctId = null; _advBal = null;
      _deptId = null; _desigId = null; _gender = null; _empType = null; _bloodGroup = null;
      _branchId = _branches.isNotEmpty ? _branches.first['id'] as String : null;
      _dob = null; _joinDate = null; _leftOn = null;
      _shiftId = null; _photoUrl = null; _notifyPunch = false;
      _docs = [];
    });
  }

  void _loadEmployee(Map<String, dynamic> e) {
    setState(() {
      _current = e;
      _code.text = e['employee_code'] as String? ?? '';
      _name.text = e['full_name'] as String? ?? '';
      _father.text = e['father_name'] as String? ?? '';
      _cnic.text = e['cnic'] as String? ?? '';
      _phone.text = e['phone'] as String? ?? '';
      _email.text = e['email'] as String? ?? '';
      _address.text = e['address'] as String? ?? '';
      _emergency.text = e['emergency_contact'] as String? ?? '';
      _salary.text = (e['basic_salary'] as num?) != null ? (e['basic_salary'] as num).toString() : '';
      _bankName.text = e['bank_name'] as String? ?? '';
      _bankAcct.text = e['bank_account'] as String? ?? '';
      _notes.text = e['notes'] as String? ?? '';
      _deptId = e['department_id'] as String?;
      _desigId = e['designation_id'] as String?;
      _branchId = e['branch_id'] as String?;
      _gender = e['gender'] as String?;
      _bloodGroup = (e['blood_group'] as String?)?.trim().isEmpty == true ? null : e['blood_group'] as String?;
      _empType = e['employment_type'] as String?;
      _status = e['status'] as String? ?? 'active';
      _dob = e['date_of_birth'] != null ? DateTime.tryParse(e['date_of_birth'] as String) : null;
      _joinDate = e['join_date'] != null ? DateTime.tryParse(e['join_date'] as String) : null;
      _leftOn = e['left_on'] != null ? DateTime.tryParse(e['left_on'] as String) : null;
      _shiftId = e['shift_id'] as String?;
      _photoUrl = e['photo_url'] as String?;
      _notifyPunch = e['notify_punch'] == true;
      _notifyEmail.text = e['notify_email'] as String? ?? '';
      _cardUid.text = e['card_uid'] as String? ?? '';
      _advAcctId = e['advance_account_id'] as String?;
      final inst = (e['advance_installment'] as num?)?.toDouble();
      _advInst.text = inst == null || inst == 0 ? '' : (inst == inst.roundToDouble() ? inst.toInt().toString() : inst.toString());
      _advBal = null;
      final pl = (e['paid_leave_days'] as num?)?.toDouble();
      _plDays.text = pl == null ? '' : (pl == pl.roundToDouble() ? pl.toInt().toString() : pl.toString());
    });
    _loadDocs();
    _loadAdvBalance();
  }

  // ---- department / designation management ----
  Future<String?> _createListItem(String table, String name) async {
    final orgId = _orgId; if (orgId == null) return null;
    final t = name.trim(); if (t.isEmpty) return null;
    final src = table == 'hr_departments' ? _departments : _designations;
    final existing = src.firstWhere((r) => (r['name'] as String).toLowerCase() == t.toLowerCase(), orElse: () => {});
    if (existing.isNotEmpty) return existing['id'] as String;
    final id = (table == 'hr_departments' ? 'dept_' : 'desig_') + DateTime.now().millisecondsSinceEpoch.toString();
    try {
      await Supabase.instance.client.from(table).insert({'id': id, 'org_id': orgId, 'name': t, 'is_active': true});
      if (table == 'hr_departments') { await _loadDepts(); } else { await _loadDesignations(); }
      return id;
    } catch (e) { _snack('Add failed: $e'); return null; }
  }

  Future<String?> _quickAddDialog(String table, String title) async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Add $title'),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder()), onSubmitted: (x) => Navigator.pop(ctx, x)),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Add'))],
    ));
    ctrl.dispose();
    if (v == null || v.trim().isEmpty) return null;
    return _createListItem(table, v);
  }

  // ---- save / delete ----
  Future<void> _save() async {
    if (!_canWrite) { _snack('You do not have edit access for employees'); return; }
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    if (_name.text.trim().isEmpty) { _snack('Employee name is required'); return; }
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      // Guard: a card number must be unique across ALL companies, because the
      // kiosk resolves a card org-agnostically. Block a duplicate before saving.
      final card = _cardUid.text.trim();
      if (card.isNotEmpty) {
        final chk = await client.rpc('hr_card_in_use', params: {
          'p_card': card, 'p_org': orgId, 'p_exclude': _current?['id'],
        });
        final m = chk is Map ? chk : null;
        if (m != null && m['in_use'] == true) {
          final sameOrg = m['same_org'] == true;
          final who = (m['employee_name'] as String?) ?? 'another employee';
          final org = (m['org_name'] as String?) ?? 'another company';
          _snack(sameOrg
              ? 'This card is already assigned to $who in your company. Use a different card.'
              : 'This card is already used by another organization ($org). Card numbers must be unique — use a different card.');
          if (mounted) setState(() => _saving = false);
          return;
        }
      }
      String code = _code.text.trim();
      String id;
      if (_current == null) {
        if (code.isEmpty) {
          final ex = await client.from('hr_employees').select('employee_code').eq('org_id', orgId)
              .like('employee_code', 'EMP-%');
          int mx = 0;
          for (final r in (ex as List)) {
            final n = int.tryParse((r['employee_code'] as String? ?? '').split('-').last) ?? 0;
            if (n > mx) mx = n;
          }
          code = 'EMP-' + (mx + 1).toString().padLeft(4, '0');
        }
        id = 'emp_' + DateTime.now().millisecondsSinceEpoch.toString();
      } else {
        id = _current!['id'] as String;
        if (code.isEmpty) code = _current!['employee_code'] as String? ?? '';
      }
      final payload = {
        'org_id': orgId, 'employee_code': code, 'full_name': _name.text.trim(),
        'father_name': _t(_father), 'cnic': _t(_cnic), 'gender': _gender, 'blood_group': _bloodGroup,
        'date_of_birth': _dob != null ? DateFormat('yyyy-MM-dd').format(_dob!) : null,
        'phone': _t(_phone), 'email': _t(_email), 'address': _t(_address), 'emergency_contact': _t(_emergency),
        'department_id': _deptId, 'designation_id': _desigId, 'branch_id': _branchId,
        'employment_type': _empType,
        'join_date': _joinDate != null ? DateFormat('yyyy-MM-dd').format(_joinDate!) : null,
        'left_on': _leftOn != null ? DateFormat('yyyy-MM-dd').format(_leftOn!) : null,
        'status': _status, 'basic_salary': double.tryParse(_salary.text) ?? 0,
        'shift_id': _shiftId, 'photo_url': _photoUrl,
        'notify_punch': _notifyPunch, 'notify_email': _t(_notifyEmail),
        'approval_status': _isAdmin ? 'approved' : 'pending',
        'bank_name': _t(_bankName), 'bank_account': _t(_bankAcct), 'notes': _t(_notes),
        'card_uid': _t(_cardUid),
        'advance_account_id': _advAcctId,
        'advance_installment': double.tryParse(_advInst.text.trim()),
        'paid_leave_days': double.tryParse(_plDays.text.trim()),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (_isAdmin) { payload['approved_by'] = userId; payload['approved_at'] = DateTime.now().toUtc().toIso8601String(); }
      else { payload['approved_by'] = null; payload['approved_at'] = null; }
      if (_current == null) {
        payload['id'] = id; payload['created_by'] = userId; payload['created_at'] = DateTime.now().toUtc().toIso8601String();
        await client.from('hr_employees').insert(payload);
      } else {
        await client.from('hr_employees').update(payload).eq('id', id);
      }
      final updated = await client.from('hr_employees').select().eq('id', id).single();
      if (mounted) setState(() => _current = updated);
      await _loadEmployees();
      _snack(_isAdmin ? 'Employee $code saved & approved' : 'Employee $code saved \u2014 sent for admin review');
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
  }

  String? _t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  // Capture an RFID card in a focused dialog: the keyboard-wedge reader types
  // the card UID (+ Enter) into the field. Whatever it emits is stored verbatim
  // as card_uid, so enrollment and the kiosk match on the identical value.
  Future<void> _enrollCardScan() async {
    final ctrl = TextEditingController();
    final uid = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tap RFID card'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Hold the card on the reader now. Its number will appear below.'),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl, autofocus: true,
            decoration: const InputDecoration(hintText: 'Waiting for card…', border: OutlineInputBorder()),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Use')),
        ],
      ),
    );
    if (uid != null && uid.isNotEmpty && mounted) setState(() => _cardUid.text = uid);
  }

  Future<void> _delete() async {
    final id = _current?['id'] as String?; if (id == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete employee?'),
      content: const Text('This permanently deletes the employee and all their attendance records. This cannot be undone. To keep history, set the employee to Inactive instead.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('hr_employees').delete().eq('id', id);
      _snack('Employee deleted'); _newEmployee(); await _loadEmployees();
    } catch (e) { _snack('Delete failed: $e'); }
  }

  // ---- approval / void ----
  Future<void> _approve() async {
    final id = _current?['id'] as String?; if (id == null) return;
    try {
      final client = Supabase.instance.client;
      final now = DateTime.now().toUtc().toIso8601String();
      await client.from('hr_employees').update({'approval_status': 'approved', 'approved_by': _userId, 'approved_at': now, 'updated_at': now}).eq('id', id);
      final updated = await client.from('hr_employees').select().eq('id', id).single();
      if (mounted) setState(() => _current = updated);
      await _loadEmployees();
      _snack('Profile approved \u2014 now visible in Attendance');
    } catch (e) { _snack('Approve failed: $e'); }
  }

  // ── Leaving ───────────────────────────────────────────────────────────────
  /// Employee leaves (resigned / terminated / retired …). Kept in the directory
  /// as a record; gone from attendance, the kiosk, leave, boards and payroll
  /// (payroll still pays the final month up to the last working day).
  Future<void> _markLeft() async {
    if (!_canWrite) return;
    final e = _current; if (e == null) return;
    DateTime day = DateTime.now();
    String reason = 'Resigned';
    final note = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
      title: Text('Mark ${e['full_name'] ?? 'employee'} as left'),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Last working day', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today_outlined, size: 14),
          label: Text(DateFormat('d MMM yyyy').format(day)),
          onPressed: () async {
            final d = await showDatePicker(context: ctx, initialDate: day, firstDate: DateTime(2015), lastDate: DateTime(2100));
            if (d != null) setLocal(() => day = d);
          }),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: reason, isDense: true,
          decoration: const InputDecoration(labelText: 'Reason', isDense: true, border: OutlineInputBorder()),
          items: const ['Resigned', 'Terminated', 'Retired', 'Contract ended', 'Absconded', 'Other']
              .map((r) => DropdownMenuItem(value: r, child: Text(r, style: TextStyle(fontSize: 13)))).toList(),
          onChanged: (v) => setLocal(() => reason = v ?? reason)),
        const SizedBox(height: 10),
        TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 10),
        const Text('After this date the employee no longer appears in attendance, the kiosk, leave, boards, reviews or payroll. '
            'The last month is still paid up to this day. The profile stays in the directory as a record (prints carry a LEFT watermark). '
            'Their attendance card is released so it can be given to someone else.',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white),
          child: const Text('Mark as left')),
      ],
    )));
    if (ok != true) return;
    try {
      final client = Supabase.instance.client;
      final now = DateTime.now().toUtc().toIso8601String();
      await client.from('hr_employees').update({
        'status': 'left',
        'left_on': DateFormat('yyyy-MM-dd').format(day),
        'left_reason': reason,
        'left_note': note.text.trim().isEmpty ? null : note.text.trim(),
        'left_marked_by': _userId, 'left_marked_at': now,
        'left_card_uid': e['card_uid'], 'card_uid': null,
        'notify_punch': false,
        'updated_at': now,
      }).eq('id', e['id'] as String);
      final updated = await client.from('hr_employees').select().eq('id', e['id'] as String).single();
      if (mounted) _loadEmployee(updated);
      await _loadEmployees();
      _snack('${e['full_name']} marked as left on ${DateFormat('d MMM yyyy').format(day)}.');
    } catch (err) { _snack('Could not mark as left: $err'); }
  }

  Future<void> _rejoin() async {
    final e = _current; if (e == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Rejoin employee?'),
      content: Text('${e['full_name']} becomes active again and reappears in attendance and payroll. '
          'Set a new join date on the profile if they are rejoining after a gap.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rejoin'))],
    ));
    if (ok != true) return;
    try {
      final client = Supabase.instance.client;
      await client.from('hr_employees').update({
        'status': 'active', 'left_on': null, 'left_reason': null, 'left_note': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', e['id'] as String);
      final updated = await client.from('hr_employees').select().eq('id', e['id'] as String).single();
      if (mounted) _loadEmployee(updated);
      await _loadEmployees();
      _snack('${e['full_name']} is active again.');
    } catch (err) { _snack('Could not rejoin: $err'); }
  }

  Future<void> _void() async {
    if (!_canWrite) return;
    final id = _current?['id'] as String?; if (id == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Void employee?'),
      content: const Text('The profile and its history are kept, but the employee is removed from Attendance and active lists. An admin can restore it later.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800), child: const Text('Void'))],
    ));
    if (ok != true) return;
    try {
      final client = Supabase.instance.client;
      final now = DateTime.now().toUtc().toIso8601String();
      await client.from('hr_employees').update({'is_voided': true, 'voided_by': _userId, 'voided_at': now, 'updated_at': now}).eq('id', id);
      final updated = await client.from('hr_employees').select().eq('id', id).single();
      if (mounted) setState(() => _current = updated);
      await _loadEmployees();
      _snack('Profile voided (kept for records)');
    } catch (e) { _snack('Void failed: $e'); }
  }

  Future<void> _unvoid() async {
    final id = _current?['id'] as String?; if (id == null) return;
    try {
      final client = Supabase.instance.client;
      await client.from('hr_employees').update({'is_voided': false, 'voided_by': null, 'voided_at': null, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);
      final updated = await client.from('hr_employees').select().eq('id', id).single();
      if (mounted) setState(() => _current = updated);
      await _loadEmployees();
      _snack('Profile restored');
    } catch (e) { _snack('Restore failed: $e'); }
  }

  // ---- documents ----
  Future<Uint8List> _compressImage(html.File file) async {
    final objUrl = html.Url.createObjectUrlFromBlob(file);
    final img = html.ImageElement();
    img.src = objUrl;
    await img.onLoad.first;
    var w = img.naturalWidth ?? 0, h = img.naturalHeight ?? 0;
    if (w == 0 || h == 0) { html.Url.revokeObjectUrl(objUrl); throw 'Could not read image dimensions'; }
    const maxDim = 1400;
    if (w > maxDim || h > maxDim) {
      if (w >= h) { h = (h * maxDim / w).round(); w = maxDim; }
      else { w = (w * maxDim / h).round(); h = maxDim; }
    }
    final canvas = html.CanvasElement(width: w, height: h);
    canvas.context2D.drawImageScaled(img, 0, 0, w, h);
    html.Url.revokeObjectUrl(objUrl);
    final dataUrl = canvas.toDataUrl('image/jpeg', 0.82);
    return base64Decode(dataUrl.split(',').last);
  }

  Future<void> _loadDocs() async {
    final id = _current?['id'] as String?;
    if (id == null) { if (mounted) setState(() => _docs = []); return; }
    try {
      final rows = await Supabase.instance.client.from('hr_employee_documents').select().eq('employee_id', id).order('uploaded_at', ascending: false);
      if (mounted) setState(() => _docs = List<Map<String, dynamic>>.from(rows));
    } catch (_) { /* table may not exist yet */ }
  }

  Future<void> _uploadDoc() async {
    if (!_canWrite) { _snack('You do not have edit access'); return; }
    if (_current == null) { _snack('Save the employee first, then attach documents'); return; }
    final orgId = _orgId; if (orgId == null) return;
    final input = html.FileUploadInputElement()..accept = 'image/*,application/pdf';
    input.style.display = 'none';
    html.document.body?.append(input);
    input.click();
    await input.onChange.first;
    final files = input.files;
    input.remove();
    if (files == null || files.isEmpty) return;
    final file = files.first;
    setState(() => _docUploading = true);
    try {
      Uint8List bytes; String ct; String ext;
      if (file.type.startsWith('image/')) {
        bytes = await _compressImage(file); ct = 'image/jpeg'; ext = 'jpg';
      } else {
        final r = html.FileReader(); r.readAsArrayBuffer(file); await r.onLoadEnd.first;
        final res = r.result;
        bytes = res is Uint8List ? res : (res as ByteBuffer).asUint8List();
        ct = file.type.isNotEmpty ? file.type : 'application/octet-stream';
        ext = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : 'bin';
      }
      if (bytes.isEmpty) { _snack('Selected file is empty'); setState(() => _docUploading = false); return; }
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '$orgId/docs/${_current!['id']}_$ts.$ext';
      final client = Supabase.instance.client;
      await client.storage.from('hr-photos').uploadBinary(path, bytes, fileOptions: FileOptions(upsert: true, contentType: ct));
      final url = client.storage.from('hr-photos').getPublicUrl(path);
      await client.from('hr_employee_documents').insert({
        'id': 'doc_$ts', 'org_id': orgId, 'employee_id': _current!['id'],
        'name': file.name, 'url': url, 'file_type': ct, 'size_bytes': bytes.length, 'uploaded_by': _userId,
      });
      await _loadDocs();
      _snack('Document uploaded');
    } catch (e) { _snack('Upload failed: $e'); }
    if (mounted) setState(() => _docUploading = false);
  }

  Future<void> _deleteDoc(Map<String, dynamic> d) async {
    if (!_canWrite) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Remove document?'),
      content: Text('Remove "${d['name'] ?? 'document'}" from this employee?'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Remove'))],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('hr_employee_documents').delete().eq('id', d['id'] as String);
      await _loadDocs();
    } catch (e) { _snack('Remove failed: $e'); }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  // ---- print profile ----
  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  // Print-ready employee ID card at standard CR80 size (85.6 x 54 mm).
  // The QR encodes the employee_code, so the printed card is the kiosk credential.
  Future<void> _printCard() async {
    final e = _current;
    if (e == null) return;
    final code = (e['employee_code'] as String?) ?? '';
    if (code.isEmpty) { _snack('Employee has no code yet \u2014 save a code first'); return; }
    final name = (e['full_name'] as String?) ?? '';
    final father = (e['father_name'] as String?) ?? '';
    final dept = _deptName[e['department_id'] as String?] ?? '';
    final org = ref.read(currentUserProvider)?.orgName ?? '';

    Uint8List? photoBytes;
    final purl = e['photo_url'] as String?;
    if (purl != null && purl.isNotEmpty) {
      try {
        final r = await http.get(Uri.parse(purl));
        if (r.statusCode == 200) photoBytes = r.bodyBytes;
      } catch (_) { }
    }

    final brand = PdfColor.fromInt(0xFF244C97);
    final doc = pw.Document();
    final cardW = 85.6 * PdfPageFormat.mm;
    final cardH = 54.0 * PdfPageFormat.mm;
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(cardW, cardH, marginAll: 0),
      build: (ctx) => pw.Stack(children: [
        pw.Container(
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: brand, width: 0.8),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Container(
                color: brand,
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: pw.Text(org.isEmpty ? 'EMPLOYEE CARD' : org.toUpperCase(),
                    style: pw.TextStyle(color: PdfColors.white, fontSize: 9, fontWeight: pw.FontWeight.bold)),
              ),
              pw.Expanded(child: pw.Padding(
                padding: const pw.EdgeInsets.all(8),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Container(
                      width: 56, height: 70,
                      decoration: pw.BoxDecoration(
                        color: PdfColors.grey200,
                        borderRadius: pw.BorderRadius.circular(4),
                        image: photoBytes != null ? pw.DecorationImage(image: pw.MemoryImage(photoBytes), fit: pw.BoxFit.cover) : null,
                      ),
                      child: photoBytes == null ? pw.Center(child: pw.Text(_initials(name), style: pw.TextStyle(fontSize: 18, color: PdfColors.grey500))) : null,
                    ),
                    pw.SizedBox(width: 8),
                    pw.Expanded(child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      mainAxisAlignment: pw.MainAxisAlignment.center,
                      children: [
                        pw.Text(name, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold), maxLines: 2),
                        if (father.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 1),
                            child: pw.Text('S/O ' + father, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700))),
                        if (dept.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 2),
                            child: pw.Text(dept, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700))),
                        pw.SizedBox(height: 4),
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: pw.BoxDecoration(color: brand, borderRadius: pw.BorderRadius.circular(3)),
                          child: pw.Text(code, style: pw.TextStyle(fontSize: 9, color: PdfColors.white, fontWeight: pw.FontWeight.bold)),
                        ),
                      ],
                    )),
                    pw.SizedBox(width: 6),
                    pw.Container(
                      width: 58, height: 58,
                      child: pw.BarcodeWidget(
                        barcode: Barcode.qrCode(),
                        data: code,
                        drawText: false,
                        color: PdfColors.black,
                      ),
                    ),
                  ],
                ),
              )),
            ],
          ),
        ),
        // Employee has left: the card is no longer valid.
        if (e['status'] == 'left')
          pw.Positioned.fill(child: pw.Center(child: pw.Transform.rotate(
            angle: 0.35,
            child: pw.Text('LEFT', style: pw.TextStyle(fontSize: 44, fontWeight: pw.FontWeight.bold,
                color: PdfColor.fromInt(0x55C62828), letterSpacing: 6)),
          ))),
      ]),
    ));
    await outputPdf(await doc.save(), 'Employee Card - ' + code);
  }

  // Professional A4 employee profile (PDF): letterhead, photo + identity
  // block with QR, key-facts strip, sectioned two-column details, documents,
  // confidential footer with page numbers.
  Future<void> _printProfile() async {
    final e = _current;
    if (e == null) return;
    final me = ref.read(currentUserProvider);
    final org = me?.orgName ?? '';
    final orgId = _orgId;
    String t(dynamic v) => (v == null) ? '' : '$v'.trim();
    String nice(dynamic v) {
      final x = t(v).replaceAll('_', ' ');
      return x.isEmpty ? '' : x[0].toUpperCase() + x.substring(1);
    }
    String dt(dynamic v) {
      final d = DateTime.tryParse(t(v));
      return d == null ? t(v) : DateFormat('d MMM yyyy').format(d);
    }
    String tenure(String? join, String? until) {
      final a = DateTime.tryParse(join ?? '');
      if (a == null) return '';
      final b = DateTime.tryParse(until ?? '') ?? DateTime.now();
      var months = (b.year - a.year) * 12 + b.month - a.month - (b.day < a.day ? 1 : 0);
      if (months < 0) return '';
      final y = months ~/ 12, m = months % 12;
      return [if (y > 0) '$y yr${y == 1 ? '' : 's'}', if (m > 0 || y == 0) '$m mo'].join(' ');
    }

    final name = t(e['full_name']);
    final code = t(e['employee_code']);
    final dept = _deptName[e['department_id']] ?? '';
    final desig = _desigName[e['designation_id']] ?? '';
    final branch = _branchName[e['branch_id']] ?? '';
    final shift = _shiftName[e['shift_id']] ?? '';
    final sal = (e['basic_salary'] as num?);
    final left = e['status'] == 'left';
    final voided = e['is_voided'] == true;
    final pending = (e['approval_status'] ?? 'approved') == 'pending';
    final statusLabel = voided ? 'VOIDED' : left ? 'LEFT' : pending ? 'REVIEW PENDING' : (e['status'] == 'inactive' ? 'INACTIVE' : 'ACTIVE');
    final statusColor = voided || left
        ? const PdfColor.fromInt(0xFFB91C1C)
        : pending
            ? const PdfColor.fromInt(0xFFB45309)
            : (e['status'] == 'inactive' ? PdfColors.grey700 : const PdfColor.fromInt(0xFF15803D));

    // images (photo + org logo) — never let a failed image block the print
    pw.ImageProvider? photo, logo;
    final purl = t(e['photo_url']);
    if (purl.isNotEmpty) {
      try { photo = await networkImage(purl); } catch (_) {}
    }
    if (orgId != null) {
      try {
        final r = await Supabase.instance.client.from('app_config').select('value')
            .eq('org_id', orgId).eq('key', 'org.logo_url').maybeSingle();
        final lu = t(r?['value']);
        if (lu.isNotEmpty) logo = await networkImage(lu);
      } catch (_) {}
    }
    pw.ThemeData? theme;
    try {
      theme = pw.ThemeData.withFont(base: await PdfGoogleFonts.notoSansRegular(), bold: await PdfGoogleFonts.notoSansBold());
    } catch (_) {}

    const brand = PdfColor.fromInt(0xFF1E3A6E);
    const ink = PdfColor.fromInt(0xFF111827);
    const muted = PdfColor.fromInt(0xFF6B7280);
    const rule = PdfColor.fromInt(0xFFE5E7EB);
    const band = PdfColor.fromInt(0xFFF3F6FB);

    pw.Widget section(String title, List<(String, String)> items) {
      final rows = items.where((x) => x.$2.trim().isNotEmpty).toList();
      if (rows.isEmpty) return pw.SizedBox();
      final half = (rows.length + 1) ~/ 2;
      pw.Widget col(List<(String, String)> part) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final r in part)
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(vertical: 3.8),
                  decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: rule, width: 0.6))),
                  child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                    pw.SizedBox(width: 86, child: pw.Text(r.$1, style: const pw.TextStyle(fontSize: 7.8, color: muted))),
                    pw.Expanded(child: pw.Text(r.$2, style: pw.TextStyle(fontSize: 8.6, color: ink, fontWeight: pw.FontWeight.bold))),
                  ]),
                ),
            ],
          );
      return pw.Padding(
        padding: const pw.EdgeInsets.only(top: 14),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Row(children: [
            pw.Container(width: 3, height: 11, color: brand),
            pw.SizedBox(width: 6),
            pw.Text(title.toUpperCase(),
                style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: brand, letterSpacing: 1.2)),
          ]),
          pw.SizedBox(height: 4),
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(child: col(rows.sublist(0, half))),
            pw.SizedBox(width: 18),
            pw.Expanded(child: col(rows.sublist(half))),
          ]),
        ]),
      );
    }

    pw.Widget fact(String label, String value, [String sub = '']) => pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: const pw.BoxDecoration(border: pw.Border(left: pw.BorderSide(color: rule, width: 0.8))),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(label.toUpperCase(), style: const pw.TextStyle(fontSize: 7, color: muted, letterSpacing: 0.8)),
              pw.SizedBox(height: 2),
              pw.Text(value.isEmpty ? '—' : value, maxLines: 1,
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: ink)),
              if (sub.isNotEmpty) pw.Text(sub, style: const pw.TextStyle(fontSize: 7.5, color: muted)),
            ]),
          ),
        );

    final money = NumberFormat('#,##0');
    // Salary-advance outstanding as of today (fresh read of the advance account).
    if (_advAcctId != null) await _loadAdvBalance();
    final advBal = _advBal;
    String advAcctName = '';
    for (final a in _assetAccounts) {
      if (a['id'] == _advAcctId) { advAcctName = '${a['code'] ?? ''} ${a['name'] ?? ''}'.trim(); break; }
    }
    String outstanding() {
      if (_advAcctId == null || advBal == null) return '';
      final asOf = 'as of ${DateFormat('d MMM yyyy').format(DateTime.now())}';
      if (advBal.abs() < 0.5) return 'Nil ($asOf)';
      return advBal > 0
          ? 'Rs ${money.format(advBal)} ($asOf)'
          : 'Rs ${money.format(-advBal)} in credit ($asOf)';
    }
    final doc = pw.Document(theme: theme, title: 'Employee Profile - $name', author: org);
    final pageTheme = pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(34, 30, 34, 30),
      theme: theme,
      // LEFT / VOIDED watermark on every page
      buildBackground: (left || voided)
          ? (ctx) => pw.FullPage(
                ignoreMargins: true,
                child: pw.Center(
                  child: pw.Transform.rotate(
                    angle: 0.5,
                    child: pw.Text(voided ? 'VOIDED' : 'LEFT',
                        style: pw.TextStyle(
                            fontSize: 120,
                            fontWeight: pw.FontWeight.bold,
                            color: const PdfColor(0.78, 0.16, 0.16, 0.10),
                            letterSpacing: 10)),
                  ),
                ),
              )
          : null,
    );
    doc.addPage(pw.MultiPage(
      pageTheme: pageTheme,
      header: (ctx) => pw.Column(children: [
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          if (logo != null) ...[pw.SizedBox(height: 28, width: 28, child: pw.Image(logo!, fit: pw.BoxFit.contain)), pw.SizedBox(width: 10)],
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(org.toUpperCase(), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: brand, letterSpacing: 1.2)),
              pw.Text('Human Resources', style: const pw.TextStyle(fontSize: 6.5, color: muted)),
            ]),
          ),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('EMPLOYEE PROFILE', style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold, color: ink, letterSpacing: 1.5)),
            pw.Text(code.isEmpty ? '' : 'Ref: $code', style: const pw.TextStyle(fontSize: 6.5, color: muted)),
          ]),
        ]),
        pw.SizedBox(height: 8),
        pw.Container(height: 2, color: brand),
        pw.SizedBox(height: 2),
        pw.Container(height: 0.6, color: rule),
      ]),
      footer: (ctx) => pw.Container(
        padding: const pw.EdgeInsets.only(top: 6),
        decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: rule, width: 0.6))),
        child: pw.Row(children: [
          pw.Expanded(
            child: pw.Text('Confidential — for internal HR use only.  Generated by ${me?.name ?? '—'} on ${DateFormat('d MMM yyyy, h:mm a').format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 7.5, color: muted)),
          ),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 7.5, color: muted)),
        ]),
      ),
      build: (ctx) => [
        // ── identity block ──
        pw.Container(
          margin: const pw.EdgeInsets.only(top: 10),
          padding: const pw.EdgeInsets.all(11),
          decoration: pw.BoxDecoration(color: band, borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
            pw.Container(
              width: 68, height: 80,
              decoration: pw.BoxDecoration(
                color: PdfColors.white,
                borderRadius: pw.BorderRadius.circular(4),
                border: pw.Border.all(color: rule, width: 1),
                image: photo != null ? pw.DecorationImage(image: photo!, fit: pw.BoxFit.cover) : null,
              ),
              child: photo == null
                  ? pw.Center(child: pw.Text(_initials(name), style: pw.TextStyle(fontSize: 21, color: PdfColors.grey400, fontWeight: pw.FontWeight.bold)))
                  : null,
            ),
            pw.SizedBox(width: 13),
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(name, style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: ink)),
                if (t(e['father_name']).isNotEmpty)
                  pw.Text('S/O ${t(e['father_name'])}', style: const pw.TextStyle(fontSize: 7.5, color: muted)),
                pw.SizedBox(height: 4),
                pw.Text([desig, dept].where((x) => x.isNotEmpty).join('  ·  '),
                    style: pw.TextStyle(fontSize: 8.5, color: brand, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 5),
                pw.Row(children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: pw.BoxDecoration(border: pw.Border.all(color: statusColor, width: 0.9), borderRadius: pw.BorderRadius.circular(3)),
                    child: pw.Text(statusLabel, style: pw.TextStyle(fontSize: 6.5, color: statusColor, fontWeight: pw.FontWeight.bold, letterSpacing: 1)),
                  ),
                  if (code.isNotEmpty) ...[
                    pw.SizedBox(width: 8),
                    pw.Text('Employee ID  ', style: const pw.TextStyle(fontSize: 6.5, color: muted)),
                    pw.Text(code, style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: ink)),
                  ],
                ]),
              ]),
            ),
            if (code.isNotEmpty)
              pw.Column(children: [
                pw.Container(
                  padding: const pw.EdgeInsets.all(4),
                  color: PdfColors.white,
                  child: pw.BarcodeWidget(barcode: Barcode.qrCode(), data: code, width: 50, height: 50, drawText: false),
                ),
                pw.SizedBox(height: 2),
                pw.Text('Kiosk ID', style: const pw.TextStyle(fontSize: 5.5, color: muted)),
              ]),
          ]),
        ),
        // ── key facts ──
        pw.Container(
          margin: const pw.EdgeInsets.only(top: 10),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: rule, width: 0.8), borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Row(children: [
            fact('Joined', dt(e['join_date']), tenure(t(e['join_date']), left ? t(e['left_on']) : null).isEmpty ? '' : 'Service: ${tenure(t(e['join_date']), left ? t(e['left_on']) : null)}'),
            fact('Branch', branch),
            fact('Shift', shift),
            fact('Employment', nice(e['employment_type'])),
          ]),
        ),
        section('Employment', [
          ('Designation', desig),
          ('Department', dept),
          ('Branch', branch),
          ('Employment type', nice(e['employment_type'])),
          ('Shift', shift),
          ('Join date', dt(e['join_date'])),
          ('Status', nice(e['status'])),
          ('Card / kiosk ID', t(e['card_uid'])),
        ]),
        section('Personal', [
          ('Father name', t(e['father_name'])),
          ('CNIC', t(e['cnic'])),
          ('Gender', nice(e['gender'])),
          ('Date of birth', dt(e['date_of_birth'])),
          ('Blood group', t(e['blood_group'])),
        ]),
        section('Contact', [
          ('Phone', t(e['phone'])),
          ('Email', t(e['email'])),
          ('Emergency contact', t(e['emergency_contact'])),
          ('Address', t(e['address'])),
        ]),
        section('Payroll & bank', [
          ('Basic salary', (sal != null && sal > 0) ? 'Rs ${money.format(sal)}' : ''),
          ('Paid leave / month', t(e['paid_leave_days'])),
          ('Advance outstanding', outstanding()),
          ('Advance installment', (e['advance_installment'] as num?) != null
              ? 'Rs ${money.format(e['advance_installment'] as num)} / month'
              : (_advAcctId != null && (advBal ?? 0) > 0.5 ? 'Full balance' : '')),
          ('Advance account', advAcctName),
          ('Bank', t(e['bank_name'])),
          ('Account', t(e['bank_account'])),
        ]),
        if (left)
          section('Separation', [
            ('Left on', dt(e['left_on'])),
            ('Reason', nice(e['left_reason'])),
            ('Note', t(e['left_note'])),
            ('Length of service', tenure(t(e['join_date']), t(e['left_on']))),
          ]),
        if (t(e['notes']).isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 14),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Row(children: [
                pw.Container(width: 3, height: 11, color: brand),
                pw.SizedBox(width: 6),
                pw.Text('NOTES', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: brand, letterSpacing: 1.2)),
              ]),
              pw.SizedBox(height: 5),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(color: band, borderRadius: pw.BorderRadius.circular(4)),
                child: pw.Text(t(e['notes']), style: const pw.TextStyle(fontSize: 9, color: ink, lineSpacing: 2)),
              ),
            ]),
          ),
        if (_docs.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 14),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Row(children: [
                pw.Container(width: 3, height: 11, color: brand),
                pw.SizedBox(width: 6),
                pw.Text('DOCUMENTS ON FILE (${_docs.length})',
                    style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: brand, letterSpacing: 1.2)),
              ]),
              pw.SizedBox(height: 4),
              for (var i = 0; i < _docs.length; i++)
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(vertical: 3.5),
                  decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: rule, width: 0.6))),
                  child: pw.Row(children: [
                    pw.SizedBox(width: 18, child: pw.Text('${i + 1}.', style: const pw.TextStyle(fontSize: 8.5, color: muted))),
                    pw.Expanded(child: pw.Text(t(_docs[i]['name']), style: const pw.TextStyle(fontSize: 9, color: ink))),
                    pw.Text(dt(_docs[i]['uploaded_at']), style: const pw.TextStyle(fontSize: 8, color: muted)),
                  ]),
                ),
            ]),
          ),
        // ── record ──
        pw.SizedBox(height: 16),
        pw.Text(
            'Record: created ${dt(e['created_at'])}'
            '${e['approved_at'] != null ? ' · approved ${dt(e['approved_at'])}' : ''}'
            '${e['updated_at'] != null ? ' · last updated ${dt(e['updated_at'])}' : ''}',
            style: const pw.TextStyle(fontSize: 7.5, color: muted)),
      ],
    ));

    final bytes = await doc.save();
    await outputPdf(bytes, 'Employee Profile - ${name.isEmpty ? code : name}');
  }

  Widget _statusChip() {
    final voided = _voided;
    final pending = _pending;
    final label = voided ? 'Voided' : (_left ? 'Left' : (pending ? 'Review Pending' : 'Approved'));
    final MaterialColor c = voided ? Colors.grey : (_left ? Colors.red : (pending ? Colors.orange : Colors.green));
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withOpacity(0.4))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(voided ? Icons.block : (_left ? Icons.logout : (pending ? Icons.hourglass_top : Icons.verified)), size: 13, color: c.shade700),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.shade700)),
      ]));
  }

  Widget _docsSection() {
    return _card('Supporting documents', [
      if (_current == null)
        const Text('Save the employee profile first, then attach documents (CNIC, contract, certificates).', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
      else ...[
        Row(children: [
          OutlinedButton.icon(
            icon: _docUploading ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.attach_file, size: 15),
            label: const Text('Upload document', style: TextStyle(fontSize: 12)),
            onPressed: (!_canWrite || _docUploading) ? null : _uploadDoc),
          const SizedBox(width: 10),
          const Expanded(child: Text('Images are compressed automatically. PDFs upload as-is.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary))),
        ]),
        const SizedBox(height: 10),
        if (_docs.isEmpty)
          const Text('No documents attached.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
        else
          Column(children: _docs.map((d) {
            final isImg = (d['file_type'] as String? ?? '').startsWith('image/');
            final size = (d['size_bytes'] as num?)?.toInt();
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
              child: Row(children: [
                Icon(isImg ? Icons.image_outlined : Icons.picture_as_pdf_outlined, size: 18, color: AppTheme.textSecondary),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d['name'] as String? ?? 'document', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  if (size != null) Text(_fmtSize(size), style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                ])),
                IconButton(icon: const Icon(Icons.open_in_new, size: 16), tooltip: 'Open', onPressed: () { final u = d['url'] as String?; if (u != null) html.window.open(u, '_blank'); }, visualDensity: VisualDensity.compact),
                if (_canWrite) IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red), tooltip: 'Remove', onPressed: () => _deleteDoc(d), visualDensity: VisualDensity.compact),
              ]),
            );
          }).toList()),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(accessSyncProvider);
    final canAdd = access?.canAddDoc('hr_employees') ?? false;
    final canEdit = access?.canEditDoc('hr_employees') ?? false;
    _canWrite = _current == null ? canAdd : canEdit;
    final leftCount = _employees.where((e) => e['status'] == 'left').length;
    // Blood group counts (current employees — not those who left, not voided).
    final bgCount = <String, int>{};
    var bgNone = 0;
    for (final e in _employees) {
      if (e['status'] == 'left' || e['is_voided'] == true) continue;
      final g = (e['blood_group'] as String?)?.trim() ?? '';
      if (g.isEmpty) { bgNone++; } else { bgCount[g] = (bgCount[g] ?? 0) + 1; }
    }
    final filtered = _employees.where((e) {
      if (!_showLeft && e['status'] == 'left' && _current?['id'] != e['id']) return false;
      if (_bloodFilter != 'all') {
        final g = (e['blood_group'] as String?)?.trim() ?? '';
        if (_bloodFilter == 'none' ? g.isNotEmpty : g != _bloodFilter) return false;
      }
      if (_listSearch.isEmpty) return true;
      return matchesQuery(
        '${e['full_name'] ?? ''} ${e['employee_code'] ?? ''} ${e['phone'] ?? ''} ${e['cnic'] ?? ''} ${e['blood_group'] ?? ''}',
        _listSearch);
    }).toList();

    // Desktop: list + detail side by side. Mobile: the list fills the screen and
    // selecting an employee pushes the detail as its own route with a back button.
    final listPane = Container(
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Employees', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero), onPressed: _newEmployee),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search name, code, phone, CNIC...', prefixIcon: Icon(Icons.search, size: 15), isDense: true, border: OutlineInputBorder()), onChanged: (v) => setState(() => _listSearch = v)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _bloodFilter, isDense: true, isExpanded: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.bloodtype_outlined, size: 15), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8), border: OutlineInputBorder()),
                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('All blood groups')),
                  for (final g in {..._bloodGroups, ...bgCount.keys})
                    DropdownMenuItem(value: g, child: Text('$g  ·  ${bgCount[g] ?? 0}')),
                  DropdownMenuItem(value: 'none', child: Text('Not recorded  ·  $bgNone')),
                ],
                onChanged: (v) => setState(() => _bloodFilter = v ?? 'all'),
              ),
              if (leftCount > 0)
                InkWell(
                  onTap: () => setState(() => _showLeft = !_showLeft),
                  child: Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
                    Icon(_showLeft ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    Text('Show employees who left ($leftCount)', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ])),
                ),
            ])),
          Expanded(child: _loading ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No employees', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final e = filtered[i]; final sel = _current?['id'] == e['id'];
                final active = (e['status'] as String? ?? 'active') == 'active';
                final voided = e['is_voided'] == true;
                final pending = (e['approval_status'] as String? ?? 'approved') == 'pending';
                final left = e['status'] == 'left';
                final String tag = voided ? 'Voided' : (pending ? 'Review Pending' : (left ? 'Left' : (active ? 'Active' : 'Inactive')));
                final MaterialColor tagColor = voided ? Colors.grey : (pending ? Colors.orange : (left ? Colors.red : (active ? Colors.green : Colors.grey)));
                return InkWell(onTap: () => _loadEmployee(e), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(e['full_name'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary), overflow: TextOverflow.ellipsis)),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: tagColor.withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                        child: Text(tag, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: tagColor.shade700))),
                    ]),
                    const SizedBox(height: 2),
                    Text('${e['employee_code'] ?? ''}  \u00b7  ${_desigName[e['designation_id']] ?? '\u2014'}', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    Text(_deptName[e['department_id']] ?? '', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                  ]),
                ));
              })),
        ]));

    final detailPane = Column(children: [
        _detailHeader(),
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _photoSection(),
            const SizedBox(height: 16),
            _card('Employment', [
              _fieldRow([
                _labeled('Employee code', _tf(_code, hint: 'Auto if blank')),
                _labeled('Full name *', _tf(_name)),
                _labeled('Status', _statusToggle()),
              ], flex: const [1, 2, 1]),
              const SizedBox(height: 12),
              isNarrow(context)
                ? _labeled('RFID card', Row(children: [
                    Expanded(child: _tf(_cardUid, hint: 'Tap card or type UID — blank to unassign')),
                    const SizedBox(width: 6),
                    IconButton(icon: const Icon(Icons.nfc, size: 20), tooltip: 'Tap card to capture', onPressed: _enrollCardScan),
                  ]))
                : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _labeled('RFID card', Row(children: [
                      Expanded(child: _tf(_cardUid, hint: 'Tap card or type UID — blank to unassign')),
                      const SizedBox(width: 6),
                      IconButton(icon: const Icon(Icons.nfc, size: 20), tooltip: 'Tap card to capture', onPressed: _enrollCardScan),
                    ]))),
                    const SizedBox(width: 12),
                    const Expanded(flex: 2, child: SizedBox()),
                  ]),
              const SizedBox(height: 12),
              _fieldRow([
                _labeled('Department', _dropdown(_deptId, _activeDepts, (v) => setState(() => _deptId = v), addLabel: 'department', addTable: 'hr_departments', onAdd: (id) => setState(() => _deptId = id))),
                _labeled('Designation', _dropdown(_desigId, _activeDesigs, (v) => setState(() => _desigId = v), addLabel: 'designation', addTable: 'hr_designations', onAdd: (id) => setState(() => _desigId = id))),
                _labeled('Branch', _branchDropdown()),
              ]),
              const SizedBox(height: 12),
              _fieldRow([
                _labeled('Employment type', _simpleDropdown(_empType, _empTypes, (v) => setState(() => _empType = v))),
                _labeled('Join date', _dateField(_joinDate, (d) => setState(() => _joinDate = d))),
                _labeled('Basic salary', _tf(_salary, numeric: true)),
                _labeled('Shift', _shiftDropdown()),
              ]),
              const SizedBox(height: 12),
              _fieldRow([
                _labeled('Paid leave days / month', _tf(_plDays, hint: 'Blank = shift / company default', numeric: true)),
                _labeled('Left on (last working day)', Row(children: [
                  Expanded(child: _dateField(_leftOn, (d) => setState(() => _leftOn = d))),
                  if (_leftOn != null && _canWrite)
                    IconButton(icon: const Icon(Icons.close, size: 16), tooltip: 'Clear', onPressed: () => setState(() => _leftOn = null)),
                ])),
                const SizedBox.shrink(),
              ], flex: const [1, 1, 2]),
            ]),
            const SizedBox(height: 16),
            _card('Personal', [
              _fieldRow([
                _labeled('Father name', _tf(_father)),
                _labeled('CNIC', _tf(_cnic, hint: 'xxxxx-xxxxxxx-x')),
                _labeled('Gender', _simpleDropdown(_gender, _genders, (v) => setState(() => _gender = v))),
                _labeled('Date of birth', _dateField(_dob, (d) => setState(() => _dob = d))),
                _labeled('Blood group', _simpleDropdown(_bloodGroup, [
                  {'v': '', 'l': 'Not known'},
                  for (final g in _bloodGroups) {'v': g, 'l': g},
                  if (_bloodGroup != null && !_bloodGroups.contains(_bloodGroup)) {'v': _bloodGroup!, 'l': _bloodGroup!},
                ], (v) => setState(() => _bloodGroup = (v == null || v.isEmpty) ? null : v))),
              ]),
              const SizedBox(height: 12),
              _fieldRow([
                _labeled('Phone', _tf(_phone)),
                _labeled('Email', _tf(_email)),
                _labeled('Emergency contact', _tf(_emergency)),
              ]),
              const SizedBox(height: 12),
              _labeled('Address', _tf(_address, lines: 2)),
              const SizedBox(height: 12),
              _labeled('Punch notifications', Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Switch(value: _notifyPunch, onChanged: _canWrite ? (v) => setState(() => _notifyPunch = v) : null),
                const SizedBox(width: 8),
                const Expanded(child: Text('Email an admin whenever this employee punches in or out at the kiosk', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
              ])),
              if (_notifyPunch) ...[
                const SizedBox(height: 8),
                _labeled('Notification email', _tf(_notifyEmail, hint: 'admin@company.com')),
              ],
            ]),
            const SizedBox(height: 16),
            _card('Bank & notes', [
              _fieldRow([
                _labeled('Bank name', _tf(_bankName)),
                _labeled('Bank account', _tf(_bankAcct)),
              ]),
              const SizedBox(height: 12),
              _labeled('Notes', _tf(_notes, lines: 2)),
            ]),
            const SizedBox(height: 16),
            _advancesCard(),
            const SizedBox(height: 16),
            _docsSection(),
            if (_current != null && _current!['id'] != null) ...[
              const SizedBox(height: 16),
              EmployeeHistorySection(
                key: ValueKey('emp_hist_${_current!['id']}_${_current!['updated_at']}_${_current!['status']}_${_current!['is_voided']}'),
                employeeId: _current!['id'] as String,
                isAdmin: _isAdmin || ref.read(currentUserProvider)?.role == WebUserRole.superAdmin,
                deptName: _deptName,
                desigName: _desigName,
                branchName: _branchName,
                shiftName: _shiftName,
                accountName: {
                  for (final a in _assetAccounts)
                    '${a['id']}': '${a['code'] ?? ''} ${a['name'] ?? ''}'.trim(),
                },
              ),
            ],
            const SizedBox(height: 30),
          ]))),
      ]);

    return AdaptiveMasterDetail(
      selected: _current?['id'],
      detailTitle: (_current?['full_name'] as String?) ?? 'Employee',
      list: listPane,
      detail: detailPane,
    );
  }

  // ---- form widgets ----
  Widget _card(String title, List<Widget> children) => Container(
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
        child: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
      Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children)),
    ]),
  );

  Widget _labeled(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
    const SizedBox(height: 4), child,
  ]);

  // A row of form fields that lays them side by side on desktop (each wrapped in
  // Expanded with the given flex) but stacks them vertically on phone widths, so
  // three or four fields don't get crushed to a few pixels each.
  Widget _fieldRow(List<Widget> children, {List<int>? flex}) {
    if (isNarrow(context)) {
      final out = <Widget>[];
      for (var i = 0; i < children.length; i++) {
        out.add(children[i]);
        if (i < children.length - 1) out.add(const SizedBox(height: 12));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: out);
    }
    final out = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      out.add(Expanded(flex: flex != null && i < flex.length ? flex[i] : 1, child: children[i]));
      if (i < children.length - 1) out.add(const SizedBox(width: 12));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: out);
  }

  // The detail-pane toolbar. On desktop it stays a single Row exactly as before;
  // on phone widths the title sits on its own line and the action buttons flow in
  // a Wrap so they never overflow.
  Widget _detailHeader() {
    final narrow = isNarrow(context);
    final leading = IconButton(icon: Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, size: 18), onPressed: () => setState(() => _drawerOpen = !_drawerOpen), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact);
    final title = Expanded(child: Text(_current == null ? 'New Employee' : (_name.text.isEmpty ? 'Employee' : _name.text), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis));
    final actions = <Widget>[
      if (_current != null) TextButton.icon(icon: const Icon(Icons.event_available_outlined, size: 15), label: const Text('Attendance record', style: TextStyle(fontSize: 12)), onPressed: () { final id = _current?['id'] as String?; if (id != null) context.push('/hr/employee-attendance?emp=$id'); }),
      if (_current != null) _statusChip(),
      if (_current != null) const SizedBox(width: 6),
      if (_current != null) IconButton(icon: const Icon(Icons.print_outlined, size: 19), tooltip: 'Print / PDF', onPressed: _printProfile),
      if (_current != null) IconButton(icon: const Icon(Icons.badge_outlined, size: 19), tooltip: 'Employee Card (PDF)', onPressed: _printCard),
      if (_isAdmin && _pending && !_voided)
        Padding(padding: const EdgeInsets.only(left: 2), child: ElevatedButton.icon(
          icon: const Icon(Icons.verified_outlined, size: 15), label: const Text('Approve', style: TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), minimumSize: Size.zero),
          onPressed: _approve)),
      if (_current != null && !_voided && !_left && !_pending && _canWrite)
        TextButton.icon(icon: Icon(Icons.logout, size: 16, color: Colors.red.shade700), label: Text('Mark as left', style: TextStyle(fontSize: 12, color: Colors.red.shade700)), onPressed: _markLeft),
      if (_current != null && _left && _isAdmin)
        TextButton.icon(icon: const Icon(Icons.undo, size: 16), label: const Text('Rejoin', style: TextStyle(fontSize: 12)), onPressed: _rejoin),
      if (_current != null && !_voided && _canWrite)
        TextButton.icon(icon: Icon(Icons.block, size: 16, color: Colors.orange.shade800), label: Text('Void', style: TextStyle(fontSize: 12, color: Colors.orange.shade800)), onPressed: _void),
      if (_isAdmin && _voided)
        TextButton.icon(icon: const Icon(Icons.restore, size: 16), label: const Text('Restore', style: TextStyle(fontSize: 12)), onPressed: _unvoid),
      if (_isAdmin && _current != null)
        IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete permanently (admin)'),
      const SizedBox(width: 8),
      if (!_voided && _canWrite) ElevatedButton.icon(
        icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined, size: 16),
        label: const Text('Save'),
        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
        onPressed: _saving ? null : _save),
      if (!_canWrite && !_voided) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline, size: 13, color: Colors.grey.shade700),
          const SizedBox(width: 5),
          Text('View only', style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
        ])),
      if (_voided) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(6)),
        child: Text('Voided — restore to edit', style: TextStyle(fontSize: 11, color: Colors.grey.shade700))),
    ];
    return Container(
      padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 16, vertical: 10),
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
      child: narrow
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [leading, const SizedBox(width: 8), title]),
            const SizedBox(height: 6),
            Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
          ])
        : Row(children: [leading, const SizedBox(width: 8), title, ...actions]),
    );
  }

  Widget _tf(TextEditingController c, {String hint = '', bool numeric = false, int lines = 1}) => TextField(
    controller: c, minLines: lines, maxLines: lines, enabled: _canWrite,
    keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : null,
    inputFormatters: numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))] : null,
    decoration: InputDecoration(hintText: hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
    style: const TextStyle(fontSize: 12));

  Widget _statusToggle() => _status == 'left'
      ? Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(color: Colors.red.withOpacity(0.07), borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.red.withOpacity(0.3))),
          child: Text('Left${_current?['left_on'] != null ? ' on ${_current!['left_on']}' : ''}${(_current?['left_reason'] as String?)?.isNotEmpty == true ? ' · ${_current!['left_reason']}' : ''}',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.red.shade700)))
      : IgnorePointer(ignoring: !_canWrite, child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
    child: Row(children: [
      Expanded(child: _segBtn('Active', _status == 'active', () => setState(() => _status = 'active'), Colors.green)),
      Expanded(child: _segBtn('Inactive', _status == 'inactive', () => setState(() => _status = 'inactive'), Colors.grey)),
    ])));

  Widget _segBtn(String label, bool sel, VoidCallback onTap, Color color) => InkWell(onTap: onTap, child: Container(
    alignment: Alignment.center, padding: const EdgeInsets.symmetric(vertical: 7),
    decoration: BoxDecoration(color: sel ? color.withOpacity(0.15) : null, borderRadius: BorderRadius.circular(3)),
    child: Text(label, style: TextStyle(fontSize: 11, fontWeight: sel ? FontWeight.w700 : FontWeight.w400, color: sel ? color : AppTheme.textSecondary))));

  Widget _dropdown(String? value, List<Map<String, dynamic>> items, void Function(String?) onChanged, {required String addLabel, required String addTable, required void Function(String) onAdd}) {
    final valid = value != null && items.any((i) => i['id'] == value) ? value : null;
    return DropdownButtonFormField<String>(
      value: valid, isDense: true, isExpanded: true,
      hint: const Text('Select', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
      style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
      items: [
        ...items.map((i) => DropdownMenuItem(value: i['id'] as String, child: Text(i['name'] as String? ?? '', overflow: TextOverflow.ellipsis))),
        DropdownMenuItem(value: '__add__', child: Text('+ Add $addLabel\u2026', style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600))),
      ],
      onChanged: !_canWrite ? null : (v) async { if (v == '__add__') { final id = await _quickAddDialog(addTable, addLabel); if (id != null) onAdd(id); } else onChanged(v); });
  }

  Widget _simpleDropdown(String? value, List<Map<String, String>> opts, void Function(String?) onChanged) => DropdownButtonFormField<String>(
    value: value, isDense: true, isExpanded: true,
    hint: const Text('Select', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
    items: opts.map((o) => DropdownMenuItem(value: o['v'], child: Text(o['l'] ?? ''))).toList(),
    onChanged: _canWrite ? onChanged : null);

  Widget _branchDropdown() => DropdownButtonFormField<String>(
    value: _branchId != null && _branches.any((b) => b['id'] == _branchId) ? _branchId : null, isDense: true, isExpanded: true,
    hint: const Text('Select', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
    items: _branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '', overflow: TextOverflow.ellipsis))).toList(),
    onChanged: _canWrite ? (v) => setState(() => _branchId = v) : null);

  Widget _dateField(DateTime? value, void Function(DateTime) onPick) => InkWell(
    onTap: !_canWrite ? null : () async {
      final d = await showDatePicker(context: context, initialDate: value ?? DateTime(2000), firstDate: DateTime(1950), lastDate: DateTime(2100));
      if (d != null) onPick(d);
    },
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
      child: Row(children: [
        Expanded(child: Text(value != null ? DateFormat('yyyy-MM-dd').format(value) : 'Select', style: TextStyle(fontSize: 12, color: value != null ? AppTheme.textPrimary : AppTheme.textSecondary))),
        const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
      ])));

  Widget _photoSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Row(children: [
        Container(width: 64, height: 64,
          decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.background, border: Border.all(color: AppTheme.border),
            image: _photoUrl != null && _photoUrl!.isNotEmpty ? DecorationImage(image: NetworkImage(_photoUrl!), fit: BoxFit.cover) : null),
          alignment: Alignment.center,
          child: (_photoUrl == null || _photoUrl!.isEmpty) ? const Icon(Icons.person_outline, size: 30, color: AppTheme.textSecondary) : null),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          const Text('Photo', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(children: [
            OutlinedButton.icon(
              icon: _photoUploading ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_outlined, size: 15),
              label: Text(_photoUrl != null && _photoUrl!.isNotEmpty ? 'Change' : 'Upload', style: const TextStyle(fontSize: 12)),
              onPressed: (!_canWrite || _photoUploading) ? null : _uploadPhoto),
            if (_canWrite && _photoUrl != null && _photoUrl!.isNotEmpty) ...[
              const SizedBox(width: 8),
              TextButton.icon(icon: const Icon(Icons.delete_outline, size: 15, color: Colors.red), label: const Text('Remove', style: TextStyle(fontSize: 12, color: Colors.red)), onPressed: () => setState(() => _photoUrl = null)),
            ],
          ]),
          const Text('JPG/PNG. Saved with the employee.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ]),
      ]),
    );
  }

  Future<void> _uploadPhoto() async {
    if (!_canWrite) return;
    final orgId = _orgId; if (orgId == null) return;
    final input = html.FileUploadInputElement()..accept = 'image/*';
    // Safari/Firefox need the input attached to the DOM for click()+onChange to fire.
    input.style.display = 'none';
    html.document.body?.append(input);
    input.click();
    await input.onChange.first;
    final files = input.files;
    input.remove();
    if (files == null || files.isEmpty) return;
    final file = files.first;
    setState(() => _photoUploading = true);
    Uint8List bytes;
    String contentType = 'image/jpeg';
    String ext = 'jpg';
    try {
      if (file.type.startsWith('image/')) {
        bytes = await _compressImage(file);
      } else {
        final reader = html.FileReader();
        reader.readAsArrayBuffer(file);
        await reader.onLoadEnd.first;
        final result = reader.result;
        if (result == null) { _snack('Could not read the image file'); setState(() => _photoUploading = false); return; }
        bytes = result is Uint8List ? result : (result as ByteBuffer).asUint8List();
        contentType = file.type.isNotEmpty ? file.type : 'image/jpeg';
        ext = (file.name.contains('.') ? file.name.split('.').last : 'jpg').toLowerCase();
      }
    } catch (e) { _snack('Could not process image: $e'); setState(() => _photoUploading = false); return; }
    if (bytes.isEmpty) { _snack('Selected file is empty'); setState(() => _photoUploading = false); return; }
    final path = '$orgId/${_current?['id'] ?? 'new'}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    try {
      await Supabase.instance.client.storage.from('hr-photos').uploadBinary(path, bytes,
        fileOptions: FileOptions(upsert: true, contentType: contentType));
      final url = Supabase.instance.client.storage.from('hr-photos').getPublicUrl(path);
      if (mounted) setState(() => _photoUrl = url);
      _snack('Photo uploaded \u2014 remember to Save');
    } catch (e) { _snack('Upload failed: $e'); }
    if (mounted) setState(() => _photoUploading = false);
  }

  Widget _shiftDropdown() {
    final items = _shifts.where((s) => s['is_active'] != false || s['id'] == _shiftId).toList();
    return DropdownButtonFormField<String>(
      value: items.any((s) => s['id'] == _shiftId) ? _shiftId : null, isDense: true, isExpanded: true,
      hint: const Text('Select', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
      style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
      items: [
        ...items.map((s) => DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}${s['start_time'] != null ? ' (${s['start_time']}\u2013${s['end_time'] ?? ''})' : ''}', overflow: TextOverflow.ellipsis))),
        if (_canHrSetup) const DropdownMenuItem(value: '__manage__', child: Text('Manage shifts\u2026', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600))),
      ],
      onChanged: !_canWrite ? null : (v) async {
        if (v == '__manage__') {
          // Shifts now live on HR \u25B8 HR Setup; reload them when coming back.
          await context.push('/hr/setup?tab=shifts');
          await _loadShifts();
        } else {
          setState(() => _shiftId = v);
        }
      });
  }
}

