import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class HrEmployeesScreen extends ConsumerStatefulWidget {
  const HrEmployeesScreen({super.key});
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
  final _notes = TextEditingController();
  // form state
  String? _deptId, _desigId, _branchId, _gender, _empType;
  DateTime? _dob, _joinDate;
  String _status = 'active';

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  static const _genders = [
    {'v': 'male', 'l': 'Male'}, {'v': 'female', 'l': 'Female'}, {'v': 'other', 'l': 'Other'},
  ];
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
    for (final c in [_code, _name, _father, _cnic, _phone, _email, _address, _emergency, _salary, _bankName, _bankAcct, _notes]) c.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadAll() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _loadAll(); return; }
    setState(() => _loading = true);
    try {
      await Future.wait([_loadDepts(), _loadDesignations(), _loadBranches()]);
      await _loadEmployees();
    } catch (e) { _snack('Load error: $e'); }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadEmployees() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_employees').select().eq('org_id', orgId).order('full_name');
    if (mounted) setState(() => _employees = List<Map<String, dynamic>>.from(rows));
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
    final rows = await Supabase.instance.client.from('branches').select('id, name').eq('org_id', orgId).order('name');
    if (mounted) setState(() { _branches = List<Map<String, dynamic>>.from(rows); _branchName = {for (final b in _branches) b['id'] as String: b['name'] as String}; });
  }

  List<Map<String, dynamic>> get _activeDepts => _departments.where((d) => d['is_active'] != false).toList();
  List<Map<String, dynamic>> get _activeDesigs => _designations.where((d) => d['is_active'] != false).toList();

  void _newEmployee() {
    setState(() {
      _current = null; _status = 'active';
      for (final c in [_code, _name, _father, _cnic, _phone, _email, _address, _emergency, _salary, _bankName, _bankAcct, _notes]) c.clear();
      _deptId = null; _desigId = null; _gender = null; _empType = null;
      _branchId = _branches.isNotEmpty ? _branches.first['id'] as String : null;
      _dob = null; _joinDate = null;
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
      _empType = e['employment_type'] as String?;
      _status = e['status'] as String? ?? 'active';
      _dob = e['date_of_birth'] != null ? DateTime.tryParse(e['date_of_birth'] as String) : null;
      _joinDate = e['join_date'] != null ? DateTime.tryParse(e['join_date'] as String) : null;
    });
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

  Future<void> _manageList(String table, String title) async {
    await showDialog(context: context, builder: (ctx) {
      final addCtrl = TextEditingController();
      return StatefulBuilder(builder: (ctx, setLocal) {
        final list = table == 'hr_departments' ? _departments : _designations;
        Future<void> refresh() async { if (table == 'hr_departments') { await _loadDepts(); } else { await _loadDesignations(); } setLocal(() {}); }
        return AlertDialog(
          title: Text('Manage $title'),
          content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: addCtrl, decoration: InputDecoration(hintText: 'New $title', isDense: true, border: const OutlineInputBorder()))),
              const SizedBox(width: 8),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
                onPressed: () async { if (addCtrl.text.trim().isEmpty) return; await _createListItem(table, addCtrl.text); addCtrl.clear(); await refresh(); }, child: const Text('Add')),
            ]),
            const SizedBox(height: 12),
            SizedBox(height: 280, width: 420, child: list.isEmpty
              ? Center(child: Text('No $title yet', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
              : ListView.separated(itemCount: list.length, separatorBuilder: (_, __) => const Divider(height: 1), itemBuilder: (_, i) {
                  final r = list[i]; final active = r['is_active'] != false;
                  return ListTile(dense: true,
                    title: Text(r['name'] as String? ?? '', style: TextStyle(fontSize: 13, color: active ? AppTheme.textPrimary : AppTheme.textSecondary, decoration: active ? null : TextDecoration.lineThrough)),
                    trailing: Switch(value: active, onChanged: (val) async { try { await Supabase.instance.client.from(table).update({'is_active': val}).eq('id', r['id'] as String); await refresh(); } catch (e) { _snack('Update failed: $e'); } }));
                })),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        );
      });
    });
    if (mounted) setState(() {});
  }

  // ---- save / delete ----
  Future<void> _save() async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    if (_name.text.trim().isEmpty) { _snack('Employee name is required'); return; }
    final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      String code = _code.text.trim();
      String id;
      if (_current == null) {
        if (code.isEmpty) {
          final cnt = await client.from('hr_employees').select('id').eq('org_id', orgId);
          code = 'EMP-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        }
        id = 'emp_' + DateTime.now().millisecondsSinceEpoch.toString();
      } else {
        id = _current!['id'] as String;
        if (code.isEmpty) code = _current!['employee_code'] as String? ?? '';
      }
      final payload = {
        'org_id': orgId, 'employee_code': code, 'full_name': _name.text.trim(),
        'father_name': _t(_father), 'cnic': _t(_cnic), 'gender': _gender,
        'date_of_birth': _dob != null ? DateFormat('yyyy-MM-dd').format(_dob!) : null,
        'phone': _t(_phone), 'email': _t(_email), 'address': _t(_address), 'emergency_contact': _t(_emergency),
        'department_id': _deptId, 'designation_id': _desigId, 'branch_id': _branchId,
        'employment_type': _empType,
        'join_date': _joinDate != null ? DateFormat('yyyy-MM-dd').format(_joinDate!) : null,
        'status': _status, 'basic_salary': double.tryParse(_salary.text) ?? 0,
        'bank_name': _t(_bankName), 'bank_account': _t(_bankAcct), 'notes': _t(_notes),
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (_current == null) {
        payload['id'] = id; payload['created_by'] = userId; payload['created_at'] = DateTime.now().toIso8601String();
        await client.from('hr_employees').insert(payload);
      } else {
        await client.from('hr_employees').update(payload).eq('id', id);
      }
      final updated = await client.from('hr_employees').select().eq('id', id).single();
      if (mounted) setState(() => _current = updated);
      await _loadEmployees();
      _snack('Employee $code saved');
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
  }

  String? _t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

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

  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _employees : _employees.where((e) {
      final q = _listSearch.toLowerCase();
      return (e['full_name'] as String? ?? '').toLowerCase().contains(q)
        || (e['employee_code'] as String? ?? '').toLowerCase().contains(q)
        || (e['phone'] as String? ?? '').toLowerCase().contains(q)
        || (e['cnic'] as String? ?? '').toLowerCase().contains(q);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 300,
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
            ])),
          Expanded(child: _loading ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : filtered.isEmpty ? const Center(child: Text('No employees', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final e = filtered[i]; final sel = _current?['id'] == e['id'];
                final active = (e['status'] as String? ?? 'active') == 'active';
                return InkWell(onTap: () => _loadEmployee(e), child: Container(
                  color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(e['full_name'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary), overflow: TextOverflow.ellipsis)),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: (active ? Colors.green : Colors.grey).withOpacity(0.13), borderRadius: BorderRadius.circular(3)),
                        child: Text(active ? 'Active' : 'Inactive', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: active ? Colors.green.shade700 : Colors.grey.shade700))),
                    ]),
                    const SizedBox(height: 2),
                    Text('${e['employee_code'] ?? ''}  \u00b7  ${_desigName[e['designation_id']] ?? '\u2014'}', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    Text(_deptName[e['department_id']] ?? '', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
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
            Expanded(child: Text(_current == null ? 'New Employee' : (_name.text.isEmpty ? 'Employee' : _name.text), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
            TextButton.icon(icon: const Icon(Icons.apartment_outlined, size: 15), label: const Text('Departments', style: TextStyle(fontSize: 12)), onPressed: () => _manageList('hr_departments', 'departments')),
            TextButton.icon(icon: const Icon(Icons.work_outline, size: 15), label: const Text('Designations', style: TextStyle(fontSize: 12)), onPressed: () => _manageList('hr_designations', 'designations')),
            if (_current != null) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: _delete, tooltip: 'Delete employee'),
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
            _card('Employment', [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('Employee code', _tf(_code, hint: 'Auto if blank'))),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: _labeled('Full name *', _tf(_name))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Status', _statusToggle())),
              ]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('Department', _dropdown(_deptId, _activeDepts, (v) => setState(() => _deptId = v), addLabel: 'department', addTable: 'hr_departments', onAdd: (id) => setState(() => _deptId = id)))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Designation', _dropdown(_desigId, _activeDesigs, (v) => setState(() => _desigId = v), addLabel: 'designation', addTable: 'hr_designations', onAdd: (id) => setState(() => _desigId = id)))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Branch', _branchDropdown())),
              ]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('Employment type', _simpleDropdown(_empType, _empTypes, (v) => setState(() => _empType = v)))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Join date', _dateField(_joinDate, (d) => setState(() => _joinDate = d)))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Basic salary', _tf(_salary, numeric: true))),
              ]),
            ]),
            const SizedBox(height: 16),
            _card('Personal', [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('Father name', _tf(_father))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('CNIC', _tf(_cnic, hint: 'xxxxx-xxxxxxx-x'))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Gender', _simpleDropdown(_gender, _genders, (v) => setState(() => _gender = v)))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Date of birth', _dateField(_dob, (d) => setState(() => _dob = d)))),
              ]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('Phone', _tf(_phone))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Email', _tf(_email))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Emergency contact', _tf(_emergency))),
              ]),
              const SizedBox(height: 12),
              _labeled('Address', _tf(_address, lines: 2)),
            ]),
            const SizedBox(height: 16),
            _card('Bank & notes', [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('Bank name', _tf(_bankName))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Bank account', _tf(_bankAcct))),
              ]),
              const SizedBox(height: 12),
              _labeled('Notes', _tf(_notes, lines: 2)),
            ]),
            const SizedBox(height: 30),
          ]))),
      ])),
    ]));
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

  Widget _tf(TextEditingController c, {String hint = '', bool numeric = false, int lines = 1}) => TextField(
    controller: c, minLines: lines, maxLines: lines,
    keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : null,
    inputFormatters: numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))] : null,
    decoration: InputDecoration(hintText: hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
    style: const TextStyle(fontSize: 12));

  Widget _statusToggle() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
    child: Row(children: [
      Expanded(child: _segBtn('Active', _status == 'active', () => setState(() => _status = 'active'), Colors.green)),
      Expanded(child: _segBtn('Inactive', _status == 'inactive', () => setState(() => _status = 'inactive'), Colors.grey)),
    ]));

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
      onChanged: (v) async { if (v == '__add__') { final id = await _quickAddDialog(addTable, addLabel); if (id != null) onAdd(id); } else onChanged(v); });
  }

  Widget _simpleDropdown(String? value, List<Map<String, String>> opts, void Function(String?) onChanged) => DropdownButtonFormField<String>(
    value: value, isDense: true, isExpanded: true,
    hint: const Text('Select', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
    items: opts.map((o) => DropdownMenuItem(value: o['v'], child: Text(o['l'] ?? ''))).toList(),
    onChanged: onChanged);

  Widget _branchDropdown() => DropdownButtonFormField<String>(
    value: _branchId != null && _branches.any((b) => b['id'] == _branchId) ? _branchId : null, isDense: true, isExpanded: true,
    hint: const Text('Select', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
    items: _branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '', overflow: TextOverflow.ellipsis))).toList(),
    onChanged: (v) => setState(() => _branchId = v));

  Widget _dateField(DateTime? value, void Function(DateTime) onPick) => InkWell(
    onTap: () async {
      final d = await showDatePicker(context: context, initialDate: value ?? DateTime(2000), firstDate: DateTime(1950), lastDate: DateTime(2100));
      if (d != null) onPick(d);
    },
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFE0E0E0))),
      child: Row(children: [
        Expanded(child: Text(value != null ? DateFormat('yyyy-MM-dd').format(value) : 'Select', style: TextStyle(fontSize: 12, color: value != null ? AppTheme.textPrimary : AppTheme.textSecondary))),
        const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
      ])));
}
