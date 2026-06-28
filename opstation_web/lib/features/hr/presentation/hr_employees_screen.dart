// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/permissions/access_control.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:http/http.dart' as http;
import 'package:barcode/barcode.dart';

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
  final _notes = TextEditingController();
  final _notifyEmail = TextEditingController();
  bool _notifyPunch = false;
  // form state
  String? _deptId, _desigId, _branchId, _gender, _empType;
  DateTime? _dob, _joinDate;
  String _status = 'active';
  String? _shiftId;
  String? _photoUrl;
  bool _photoUploading = false;
  List<Map<String, dynamic>> _shifts = [];
  Map<String, String> _shiftName = {};
  List<Map<String, dynamic>> _docs = [];
  bool _docUploading = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;
  bool get _isAdmin { final r = ref.read(currentUserProvider)?.role; return r == WebUserRole.admin || r == WebUserRole.masterAdmin; }
  bool get _pending => _current != null && (_current!['approval_status'] as String? ?? 'approved') == 'pending';
  bool get _voided => _current != null && _current!['is_voided'] == true;
  int? _min(String? hhmm) { if (hhmm == null || hhmm.isEmpty) return null; final p = hhmm.split(':'); if (p.length != 2) return null; final h = int.tryParse(p[0]), m = int.tryParse(p[1]); if (h == null || m == null) return null; return h * 60 + m; }

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
    for (final c in [_code, _name, _father, _cnic, _phone, _email, _address, _emergency, _salary, _bankName, _bankAcct, _notes, _notifyEmail]) c.dispose();
    super.dispose();
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadAll() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _loadAll(); return; }
    setState(() => _loading = true);
    try {
      await Future.wait([_loadDepts(), _loadDesignations(), _loadBranches(), _loadShifts()]);
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

  Future<void> _loadShifts() async {
    final orgId = _orgId; if (orgId == null) return;
    final rows = await Supabase.instance.client.from('hr_shifts').select().eq('org_id', orgId).order('name');
    if (mounted) setState(() { _shifts = List<Map<String, dynamic>>.from(rows); _shiftName = {for (final s in _shifts) s['id'] as String: s['name'] as String}; });
  }

  List<Map<String, dynamic>> get _activeDepts => _departments.where((d) => d['is_active'] != false).toList();
  List<Map<String, dynamic>> get _activeDesigs => _designations.where((d) => d['is_active'] != false).toList();

  void _newEmployee() {
    setState(() {
      _current = null; _status = 'active';
      for (final c in [_code, _name, _father, _cnic, _phone, _email, _address, _emergency, _salary, _bankName, _bankAcct, _notes, _notifyEmail]) c.clear();
      _deptId = null; _desigId = null; _gender = null; _empType = null;
      _branchId = _branches.isNotEmpty ? _branches.first['id'] as String : null;
      _dob = null; _joinDate = null;
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
      _empType = e['employment_type'] as String?;
      _status = e['status'] as String? ?? 'active';
      _dob = e['date_of_birth'] != null ? DateTime.tryParse(e['date_of_birth'] as String) : null;
      _joinDate = e['join_date'] != null ? DateTime.tryParse(e['join_date'] as String) : null;
      _shiftId = e['shift_id'] as String?;
      _photoUrl = e['photo_url'] as String?;
      _notifyPunch = e['notify_punch'] == true;
      _notifyEmail.text = e['notify_email'] as String? ?? '';
    });
    _loadDocs();
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
    if (!_canWrite) { _snack('You do not have edit access for employees'); return; }
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
        'shift_id': _shiftId, 'photo_url': _photoUrl,
        'notify_punch': _notifyPunch, 'notify_email': _t(_notifyEmail),
        'approval_status': _isAdmin ? 'approved' : 'pending',
        'bank_name': _t(_bankName), 'bank_account': _t(_bankAcct), 'notes': _t(_notes),
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (_isAdmin) { payload['approved_by'] = userId; payload['approved_at'] = DateTime.now().toIso8601String(); }
      else { payload['approved_by'] = null; payload['approved_at'] = null; }
      if (_current == null) {
        payload['id'] = id; payload['created_by'] = userId; payload['created_at'] = DateTime.now().toIso8601String();
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
      final now = DateTime.now().toIso8601String();
      await client.from('hr_employees').update({'approval_status': 'approved', 'approved_by': _userId, 'approved_at': now, 'updated_at': now}).eq('id', id);
      final updated = await client.from('hr_employees').select().eq('id', id).single();
      if (mounted) setState(() => _current = updated);
      await _loadEmployees();
      _snack('Profile approved \u2014 now visible in Attendance');
    } catch (e) { _snack('Approve failed: $e'); }
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
      final now = DateTime.now().toIso8601String();
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
      await client.from('hr_employees').update({'is_voided': false, 'voided_by': null, 'voided_at': null, 'updated_at': DateTime.now().toIso8601String()}).eq('id', id);
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
      build: (ctx) {
        return pw.Container(
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
        );
      },
    ));
    await Printing.layoutPdf(onLayout: (PdfPageFormat f) async => doc.save(), name: 'employee-card-' + code + '.pdf');
  }

  void _printProfile() {
    final e = _current; if (e == null) return;
    String esc(String? s) => (s ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    String row(String k, String? v) => (v == null || v.isEmpty) ? '' : '<tr><td class="k">$k</td><td>${esc(v)}</td></tr>';
    final dept = _deptName[e['department_id']] ?? '';
    final desig = _desigName[e['designation_id']] ?? '';
    final branch = _branchName[e['branch_id']] ?? '';
    final shift = _shiftName[e['shift_id']] ?? '';
    final sal = (e['basic_salary'] as num?);
    final photo = (e['photo_url'] as String?);
    final status = (e['is_voided'] == true) ? 'Voided' : (((e['approval_status'] ?? 'approved') == 'pending') ? 'Review Pending' : 'Approved');
    final notes = e['notes'] as String?;
    final docsHtml = _docs.isEmpty ? '' : '<h3>Documents</h3><ul>' + _docs.map((d) => '<li>${esc(d['name'] as String?)}</li>').join('') + '</ul>';
    final bankHtml = (e['bank_name'] != null || e['bank_account'] != null)
        ? '<h3>Bank</h3><table>' + row('Bank', e['bank_name'] as String?) + row('Account', e['bank_account'] as String?) + '</table>'
        : '';
    final notesHtml = (notes != null && notes.isNotEmpty) ? '<h3>Notes</h3><div style="font-size:12px">' + esc(notes) + '</div>' : '';
    final content = '''<!DOCTYPE html><html><head><meta charset="utf-8"><title>${esc(e['full_name'] as String?)}</title>
<style>
*{box-sizing:border-box}body{font-family:Arial,Helvetica,sans-serif;color:#000;padding:24px;max-width:760px;margin:0 auto}
.head{display:flex;align-items:center;gap:16px;border-bottom:2px solid #333;padding-bottom:14px;margin-bottom:8px}
.photo{width:88px;height:88px;border-radius:50%;object-fit:cover;border:1px solid #999}
.ph{width:88px;height:88px;border-radius:50%;background:#eee;display:flex;align-items:center;justify-content:center;color:#999;font-size:30px}
h1{font-size:20px;margin:0 0 2px}.sub{color:#555;font-size:13px}
.tag{display:inline-block;font-size:11px;padding:2px 8px;border-radius:10px;border:1px solid #999;margin-top:4px}
h3{font-size:13px;margin:18px 0 6px;border-bottom:1px solid #ddd;padding-bottom:3px}
table{width:100%;border-collapse:collapse;font-size:12px}
td{padding:4px 6px;border-bottom:1px solid #f0f0f0;vertical-align:top}
td.k{color:#666;width:170px}
ul{font-size:12px;margin:4px 0 0 18px}
@media print{body{padding:8px}}
</style></head><body>
<div class="head">
${photo != null && photo.isNotEmpty ? '<img class="photo" src="${esc(photo)}"/>' : '<div class="ph">&#128100;</div>'}
<div><h1>${esc(e['full_name'] as String?)}</h1>
<div class="sub">${esc(e['employee_code'] as String?)}${desig.isNotEmpty ? ' &middot; ' + esc(desig) : ''}${dept.isNotEmpty ? ' &middot; ' + esc(dept) : ''}</div>
<div class="tag">$status</div></div>
</div>
<h3>Employment</h3><table>
${row('Branch', branch)}${row('Designation', desig)}${row('Department', dept)}${row('Employment type', e['employment_type'] as String?)}${row('Shift', shift)}${row('Join date', e['join_date'] as String?)}${row('Status', e['status'] as String?)}${(sal != null && sal > 0) ? row('Basic salary', sal.toString()) : ''}
</table>
<h3>Personal</h3><table>
${row('Father name', e['father_name'] as String?)}${row('CNIC', e['cnic'] as String?)}${row('Gender', e['gender'] as String?)}${row('Date of birth', e['date_of_birth'] as String?)}${row('Phone', e['phone'] as String?)}${row('Email', e['email'] as String?)}${row('Emergency contact', e['emergency_contact'] as String?)}${row('Address', e['address'] as String?)}
</table>
$bankHtml
$notesHtml
$docsHtml
<div style="margin-top:20px;font-size:10px;color:#888">Generated ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())}</div>
<script>window.onload=function(){window.print();}</script>
</body></html>''';
    final blob = html.Blob([content], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  Widget _statusChip() {
    final voided = _voided;
    final pending = _pending;
    final label = voided ? 'Voided' : (pending ? 'Review Pending' : 'Approved');
    final MaterialColor c = voided ? Colors.grey : (pending ? Colors.orange : Colors.green);
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withOpacity(0.4))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(voided ? Icons.block : (pending ? Icons.hourglass_top : Icons.verified), size: 13, color: c.shade700),
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
                final voided = e['is_voided'] == true;
                final pending = (e['approval_status'] as String? ?? 'approved') == 'pending';
                final String tag = voided ? 'Voided' : (pending ? 'Review Pending' : (active ? 'Active' : 'Inactive'));
                final MaterialColor tagColor = voided ? Colors.grey : (pending ? Colors.orange : (active ? Colors.green : Colors.grey));
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
        ])),

      Expanded(child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            IconButton(icon: Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, size: 18), onPressed: () => setState(() => _drawerOpen = !_drawerOpen), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            const SizedBox(width: 8),
            Expanded(child: Text(_current == null ? 'New Employee' : (_name.text.isEmpty ? 'Employee' : _name.text), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
            if (_canWrite) TextButton.icon(icon: const Icon(Icons.apartment_outlined, size: 15), label: const Text('Departments', style: TextStyle(fontSize: 12)), onPressed: () => _manageList('hr_departments', 'departments')),
            if (_canWrite) TextButton.icon(icon: const Icon(Icons.work_outline, size: 15), label: const Text('Designations', style: TextStyle(fontSize: 12)), onPressed: () => _manageList('hr_designations', 'designations')),
            if (_isAdmin) TextButton.icon(icon: const Icon(Icons.schedule_outlined, size: 15), label: const Text('Shifts', style: TextStyle(fontSize: 12)), onPressed: _manageShifts),
            if (_current != null) _statusChip(),
            if (_current != null) const SizedBox(width: 6),
            if (_current != null) IconButton(icon: const Icon(Icons.print_outlined, size: 19), tooltip: 'Print / PDF', onPressed: _printProfile),
            if (_current != null) IconButton(icon: const Icon(Icons.badge_outlined, size: 19), tooltip: 'Employee Card (PDF)', onPressed: _printCard),
            if (_isAdmin && _pending && !_voided)
              Padding(padding: const EdgeInsets.only(left: 2), child: ElevatedButton.icon(
                icon: const Icon(Icons.verified_outlined, size: 15), label: const Text('Approve', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), minimumSize: Size.zero),
                onPressed: _approve)),
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
              child: Text('Voided \u2014 restore to edit', style: TextStyle(fontSize: 11, color: Colors.grey.shade700))),
          ])),
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _photoSection(),
            const SizedBox(height: 16),
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
                const SizedBox(width: 12),
                Expanded(child: _labeled('Shift', _shiftDropdown())),
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
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _labeled('Bank name', _tf(_bankName))),
                const SizedBox(width: 12),
                Expanded(child: _labeled('Bank account', _tf(_bankAcct))),
              ]),
              const SizedBox(height: 12),
              _labeled('Notes', _tf(_notes, lines: 2)),
            ]),
            const SizedBox(height: 16),
            _docsSection(),
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
    controller: c, minLines: lines, maxLines: lines, enabled: _canWrite,
    keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : null,
    inputFormatters: numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))] : null,
    decoration: InputDecoration(hintText: hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))), enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
    style: const TextStyle(fontSize: 12));

  Widget _statusToggle() => IgnorePointer(ignoring: !_canWrite, child: Container(
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
        if (_isAdmin) const DropdownMenuItem(value: '__manage__', child: Text('Manage shifts\u2026', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600))),
      ],
      onChanged: !_canWrite ? null : (v) async { if (v == '__manage__') { await _manageShifts(); } else setState(() => _shiftId = v); });
  }

  Future<void> _manageShifts() async {
    await showDialog(context: context, builder: (ctx) {
      final nameCtrl = TextEditingController();
      final graceCtrl = TextEditingController(text: '0');
      String? editId; String? sStart; String? sEnd;
      return StatefulBuilder(builder: (ctx, setLocal) {
        Future<void> refresh() async { await _loadShifts(); setLocal(() {}); }
        double? calc() { final a = _min(sStart), b = _min(sEnd); if (a == null || b == null) return null; var d = b - a; if (d <= 0) d += 1440; return (d / 60 * 100).round() / 100; }
        Future<void> pick(bool isStart) async {
          final t = await showTimePicker(context: ctx, initialTime: const TimeOfDay(hour: 9, minute: 0));
          if (t != null) setLocal(() { final s = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'; if (isStart) sStart = s; else sEnd = s; });
        }
        Future<void> saveShift() async {
          final orgId = _orgId; if (orgId == null) return;
          if (nameCtrl.text.trim().isEmpty) { _snack('Shift name required'); return; }
          final payload = {'org_id': orgId, 'name': nameCtrl.text.trim(), 'start_time': sStart, 'end_time': sEnd, 'work_hours': calc(), 'grace_minutes': int.tryParse(graceCtrl.text) ?? 0, 'is_active': true};
          try {
            if (editId == null) { payload['id'] = 'shift_' + DateTime.now().millisecondsSinceEpoch.toString(); await Supabase.instance.client.from('hr_shifts').insert(payload); }
            else { await Supabase.instance.client.from('hr_shifts').update(payload).eq('id', editId!); }
            setLocal(() { nameCtrl.clear(); graceCtrl.text = '0'; sStart = null; sEnd = null; editId = null; });
            await refresh();
          } catch (e) { _snack('Save failed: $e'); }
        }
        return AlertDialog(
          title: Text(editId == null ? 'Shifts' : 'Edit shift'),
          content: SizedBox(width: 470, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(hintText: 'Shift name (e.g. Morning 9-5)', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => pick(true), child: Text(sStart ?? 'Start time', style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: () => pick(false), child: Text(sEnd ?? 'End time', style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 8),
              SizedBox(width: 96, child: TextField(controller: graceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Grace min', isDense: true, border: OutlineInputBorder()))),
            ]),
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerLeft, child: Text('Standard hours: ${calc()?.toString() ?? '\u2014'}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            const SizedBox(height: 8),
            Row(children: [
              if (editId != null) TextButton(onPressed: () => setLocal(() { editId = null; nameCtrl.clear(); graceCtrl.text = '0'; sStart = null; sEnd = null; }), child: const Text('Cancel edit')),
              const Spacer(),
              ElevatedButton(onPressed: saveShift, style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: Text(editId == null ? 'Add shift' : 'Update')),
            ]),
            const Divider(),
            SizedBox(height: 220, width: 470, child: _shifts.isEmpty
              ? const Center(child: Text('No shifts yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
              : ListView.separated(itemCount: _shifts.length, separatorBuilder: (_, __) => const Divider(height: 1), itemBuilder: (_, i) {
                  final s = _shifts[i]; final active = s['is_active'] != false;
                  return ListTile(dense: true,
                    title: Text(s['name'] as String? ?? '', style: TextStyle(fontSize: 13, decoration: active ? null : TextDecoration.lineThrough)),
                    subtitle: Text('${s['start_time'] ?? '\u2014'} \u2013 ${s['end_time'] ?? '\u2014'}  \u00b7  ${s['work_hours'] ?? '\u2014'}h  \u00b7  grace ${s['grace_minutes'] ?? 0}m', style: const TextStyle(fontSize: 11)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: const Icon(Icons.edit_outlined, size: 16), onPressed: () => setLocal(() { editId = s['id'] as String; nameCtrl.text = s['name'] as String? ?? ''; sStart = s['start_time'] as String?; sEnd = s['end_time'] as String?; graceCtrl.text = (s['grace_minutes'] ?? 0).toString(); })),
                      Switch(value: active, onChanged: (v) async { try { await Supabase.instance.client.from('hr_shifts').update({'is_active': v}).eq('id', s['id'] as String); await refresh(); } catch (e) { _snack('Update failed: $e'); } }),
                    ]));
                })),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        );
      });
    });
    if (mounted) setState(() {});
  }
}
