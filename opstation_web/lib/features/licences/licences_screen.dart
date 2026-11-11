// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../auth/auth_controller.dart';
import '../../core/layout/main_layout.dart' show complianceDueCountProvider;
import '../fleet/fleet_common.dart' show openPrint, esc;

SupabaseClient get _db => Supabase.instance.client;

const _categories = <(String, String, String)>[
  ('fire', 'Fire & safety', '🔥'),
  ('licence', 'Licence', '📜'),
  ('tax', 'Tax', '🧾'),
  ('labour', 'Labour', '👷'),
  ('insurance', 'Insurance', '🛡'),
  ('environment', 'Environment', '🌿'),
  ('building', 'Building', '🏢'),
  ('other', 'Other', '📌'),
];
const _repeats = <(String, String)>[
  ('none', 'One-off'),
  ('monthly', 'Monthly'),
  ('quarterly', 'Quarterly'),
  ('yearly', 'Yearly'),
  ('years', 'Every … years'),
];

String _catLabel(String? k) {
  for (final c in _categories) {
    if (c.$1 == k) return '${c.$3} ${c.$2}';
  }
  return '📌 Other';
}

String _fd(dynamic v) {
  final d = DateTime.tryParse('${v ?? ''}');
  return d == null ? '—' : DateFormat('d MMM yyyy').format(d);
}

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// ok | due | expired | renewal — mirrors _compliance_state in SQL 465.
String complianceState(Map c) {
  final e = DateTime.tryParse('${c['expires_on'] ?? ''}');
  if (e == null) return 'ok';
  final t = _today();
  if (e.isBefore(t)) return 'expired';
  if (c['in_renewal_since'] != null) return 'renewal';
  if (!e.isAfter(t.add(Duration(days: (c['remind_days'] as num?)?.toInt() ?? 30)))) return 'due';
  return 'ok';
}

(String, Color, Color) _statePill(String s) => switch (s) {
      'expired' => ('Expired', const Color(0xFFB91C1C), const Color(0xFFFEF2F2)),
      'due' => ('Due soon', const Color(0xFFB45309), const Color(0xFFFFFBEB)),
      'renewal' => ('In renewal', const Color(0xFF1D4ED8), const Color(0xFFEFF6FF)),
      _ => ('Valid', const Color(0xFF047857), const Color(0xFFECFDF5)),
    };

String _whenLabel(Map c) {
  final e = DateTime.tryParse('${c['expires_on'] ?? ''}');
  if (e == null) return 'No expiry';
  final d = e.difference(_today()).inDays;
  if (d < 0) return '${-d} day${d == -1 ? '' : 's'} ago';
  if (d == 0) return 'today';
  if (d < 60) return 'in $d days';
  final m = (d / 30).round();
  return 'in $m month${m == 1 ? '' : 's'}';
}

DateTime? _nextExpiry(Map c) {
  final e = DateTime.tryParse('${c['expires_on'] ?? ''}') ?? _today();
  switch (c['repeat']) {
    case 'monthly': return DateTime(e.year, e.month + 1, e.day);
    case 'quarterly': return DateTime(e.year, e.month + 3, e.day);
    case 'yearly': return DateTime(e.year + 1, e.month, e.day);
    case 'years': return DateTime(e.year + ((c['repeat_years'] as num?)?.toInt() ?? 1), e.month, e.day);
    default: return null;
  }
}

/// Management → Licences & Compliance (SQL 465).
class LicencesScreen extends ConsumerStatefulWidget {
  final String? openId;
  const LicencesScreen({super.key, this.openId});
  @override
  ConsumerState<LicencesScreen> createState() => _LicencesScreenState();
}

class _LicencesScreenState extends ConsumerState<LicencesScreen> {
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _schedules = [];
  bool _loading = true;
  bool _missing = false;
  String _q = '';
  String _fBranch = 'all';
  String _fCat = 'all';
  String _fState = 'all';
  bool _openedLink = false;

  String? get _org => ref.read(currentUserProvider)?.orgId;
  Map<String, String> get _branchNames => {for (final b in _branches) '${b['id']}': '${b['name']}'};
  Map<String, String> get _userNames => {for (final u in _users) '${u['id']}': '${u['name']}'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final org = _org;
    if (org == null) return;
    try {
      final r = await Future.wait([
        _db.from('compliance_items').select().eq('org_id', org).eq('is_active', true).order('expires_on'),
        _db.from('branches').select('id, name, is_virtual').eq('org_id', org).eq('is_active', true).order('name'),
        _db.from('users').select('id, name').eq('org_id', org).or('role.is.null,role.neq.retailer').order('name'),
      ]);
      List<Map<String, dynamic>> sch = [];
      try {
        sch = List<Map<String, dynamic>>.from(await _db.from('facility_schedules').select('id, title, branch_id, frequency').eq('org_id', org));
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _items = List<Map<String, dynamic>>.from(r[0] as List);
        _branches = List<Map<String, dynamic>>.from(r[1] as List).where((b) => b['is_virtual'] != true).toList();
        _users = List<Map<String, dynamic>>.from(r[2] as List);
        _schedules = sch;
        _loading = false;
        _missing = false;
      });
      ref.invalidate(complianceDueCountProvider);
      if (!_openedLink && widget.openId != null) {
        _openedLink = true;
        final it = _items.where((x) => x['id'] == widget.openId).firstOrNull;
        if (it != null) _openItem(it);
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _missing = true; });
    }
  }

  Future<String?> _myName(String org) async {
    try {
      final r = await _db.rpc('compliance_my_name', params: {'p_org': org});
      return r is String ? r : null;
    } catch (_) {
      return null;
    }
  }

  void _snack(String m) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));

  List<Map<String, dynamic>> get _shown => _items.where((c) {
        if (_fBranch != 'all' && (c['branch_id'] ?? 'all_branches') != _fBranch) return false;
        if (_fCat != 'all' && c['category'] != _fCat) return false;
        if (_fState != 'all' && complianceState(c) != _fState) return false;
        if (_q.isNotEmpty) {
          final s = '${c['title']} ${c['reference_no'] ?? ''} ${c['authority'] ?? ''} ${_userNames[c['responsible_user_id']] ?? ''}'.toLowerCase();
          if (!s.contains(_q.toLowerCase())) return false;
        }
        return true;
      }).toList()
        ..sort((a, b) {
          int rank(String s) => s == 'expired' ? 0 : s == 'due' ? 1 : s == 'renewal' ? 2 : 3;
          final r = rank(complianceState(a)).compareTo(rank(complianceState(b)));
          if (r != 0) return r;
          return '${a['expires_on'] ?? '9999'}'.compareTo('${b['expires_on'] ?? '9999'}');
        });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final states = _items.map(complianceState).toList();
    int n(String s) => states.where((x) => x == s).length;
    final list = _shown;
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(wide ? 24 : 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Licences & Compliance', style: TextStyle(fontSize: wide ? 24 : 20, fontWeight: FontWeight.w800)),
          const SizedBox(width: 4),
          _chip('${_items.length}', 'items', AppTheme.primary, 'all'),
          _chip('${n('ok')}', 'valid', const Color(0xFF047857), 'ok'),
          if (n('due') > 0) _chip('${n('due')}', 'due soon', const Color(0xFFB45309), 'due'),
          if (n('expired') > 0) _chip('${n('expired')}', 'expired', const Color(0xFFB91C1C), 'expired'),
          if (n('renewal') > 0) _chip('${n('renewal')}', 'in renewal', const Color(0xFF1D4ED8), 'renewal'),
          const SizedBox(width: 8),
          OutlinedButton.icon(onPressed: _items.isEmpty ? null : _printList, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
          ElevatedButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add, size: 16), label: const Text('Add item')),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 230,
            child: TextField(
              decoration: const InputDecoration(isDense: true, hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 18)),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
          ),
          _dd('Branch', _fBranch, [('all', 'All branches'), ('all_branches', 'Company-wide'), for (final b in _branches) ('${b['id']}', '${b['name']}')], (v) => setState(() => _fBranch = v)),
          _dd('Category', _fCat, [('all', 'All categories'), for (final c in _categories) (c.$1, '${c.$3} ${c.$2}')], (v) => setState(() => _fCat = v)),
          _dd('Status', _fState, const [('all', 'All statuses'), ('expired', 'Expired'), ('due', 'Due soon'), ('renewal', 'In renewal'), ('ok', 'Valid')], (v) => setState(() => _fState = v)),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _missing
                  ? const Center(child: Text('Run SQL 465 to set up Licences & Compliance.', style: TextStyle(color: AppTheme.textSecondary)))
                  : list.isEmpty
                      ? Center(child: Text(_items.isEmpty ? 'Nothing added yet. Add your licences, certificates and filings.' : 'Nothing matches the filters.',
                          style: const TextStyle(color: AppTheme.textSecondary)))
                      : ListView(children: [for (final c in list) _row(c, wide)]),
        ),
      ]),
    );
  }

  Widget _chip(String v, String l, Color c, String state) => InkWell(
        onTap: () => setState(() => _fState = state),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.withOpacity(_fState == state ? 0.16 : 0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.withOpacity(0.3)),
          ),
          child: Text.rich(TextSpan(style: TextStyle(fontSize: 12, color: c), children: [
            TextSpan(text: v, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            TextSpan(text: '  $l'),
          ])),
        ),
      );

  Widget _dd(String label, String value, List<(String, String)> opts, void Function(String) on) => SizedBox(
        width: 190,
        child: DropdownButtonFormField<String>(
          value: opts.any((o) => o.$1 == value) ? value : opts.first.$1,
          isExpanded: true,
          decoration: InputDecoration(isDense: true, labelText: label, border: const OutlineInputBorder()),
          items: [for (final o in opts) DropdownMenuItem(value: o.$1, child: Text(o.$2, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => on(v ?? opts.first.$1),
        ),
      );

  Widget _pill(String st) {
    final p = _statePill(st);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: p.$3, borderRadius: BorderRadius.circular(999)),
      child: Text(p.$1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.$2)),
    );
  }

  Widget _row(Map<String, dynamic> c, bool wide) {
    final st = complianceState(c);
    final sch = _schedules.where((s) => s['id'] == c['facility_schedule_id']).firstOrNull;
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${c['title']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
      if ((c['reference_no'] ?? '') != '' || sch != null)
        Text([
          if ((c['reference_no'] ?? '') != '') '${c['reference_no']}',
          if (sch != null) 'Facility: ${sch['title']}',
        ].join(' · '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
    ]);
    final exp = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(st == 'expired' ? 'Expired ${_fd(c['expires_on'])}' : _fd(c['expires_on']), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
      Text(_whenLabel(c), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
    ]);
    final branch = c['branch_id'] == null ? 'All branches' : (_branchNames[c['branch_id']] ?? '—');
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppTheme.border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openItem(c),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: wide
              ? Row(children: [
                  Expanded(flex: 4, child: title),
                  Expanded(flex: 2, child: Text(_catLabel(c['category'] as String?), style: const TextStyle(fontSize: 12))),
                  Expanded(flex: 2, child: Text(branch, style: const TextStyle(fontSize: 12.5))),
                  Expanded(flex: 2, child: Text('${c['authority'] ?? '—'}', style: const TextStyle(fontSize: 12.5))),
                  Expanded(flex: 2, child: Text(_userNames[c['responsible_user_id']] ?? '—', style: const TextStyle(fontSize: 12.5))),
                  Expanded(flex: 2, child: exp),
                  SizedBox(width: 100, child: Align(alignment: Alignment.centerLeft, child: _pill(st))),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Expanded(child: title), _pill(st)]),
                  const SizedBox(height: 6),
                  Wrap(spacing: 14, runSpacing: 6, children: [
                    exp,
                    Text(_catLabel(c['category'] as String?), style: const TextStyle(fontSize: 12)),
                    Text(branch, style: const TextStyle(fontSize: 12)),
                    if (_userNames[c['responsible_user_id']] != null)
                      Text('Responsible: ${_userNames[c['responsible_user_id']]}', style: const TextStyle(fontSize: 12)),
                  ]),
                ]),
        ),
      ),
    );
  }

  // ── documents ─────────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _pickAndUpload(String folder) async {
    final org = _org!;
    final input = html.FileUploadInputElement()..accept = 'image/*,application/pdf'..multiple = true;
    input.style.display = 'none';
    html.document.body?.append(input);
    input.click();
    await input.onChange.first;
    final files = input.files ?? const [];
    input.remove();
    final me = await _myName(org);
    final out = <Map<String, dynamic>>[];
    for (final f in files) {
      try {
        final reader = html.FileReader()..readAsArrayBuffer(f);
        await reader.onLoadEnd.first;
        final res = reader.result;
        final bytes = res is Uint8List ? res : (res as ByteBuffer).asUint8List();
        final safe = f.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final path = '$org/$folder/${DateTime.now().millisecondsSinceEpoch}_$safe';
        await _db.storage.from('compliance-files').uploadBinary(path, bytes,
            fileOptions: FileOptions(upsert: true, contentType: f.type.isEmpty ? 'application/octet-stream' : f.type));
        out.add({
          'name': f.name,
          'url': _db.storage.from('compliance-files').getPublicUrl(path),
          'at': DateTime.now().toUtc().toIso8601String(),
          'by': me is String ? me : null,
        });
      } catch (e) {
        _snack(friendlyError('Upload failed', e));
      }
    }
    return out;
  }

  Widget _docList(List docs, {void Function(int)? onRemove}) => Column(children: [
        for (var i = 0; i < docs.length; i++)
          InkWell(
            onTap: () => launchUrl(Uri.parse('${docs[i]['url']}'), mode: LaunchMode.externalApplication),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Icon('${docs[i]['name']}'.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
                    size: 18, color: AppTheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text('${docs[i]['name']}', style: const TextStyle(fontSize: 12.5, color: AppTheme.primary), overflow: TextOverflow.ellipsis)),
                Text([if ((docs[i]['by'] ?? '') != '') '${docs[i]['by']}', _fd(docs[i]['at'])].join(' · '),
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                if (onRemove != null)
                  IconButton(visualDensity: VisualDensity.compact, onPressed: () => onRemove(i), icon: const Icon(Icons.close, size: 16)),
              ]),
            ),
          ),
      ]);

  // ── add / edit ────────────────────────────────────────────────────────────
  Future<void> _edit({Map<String, dynamic>? existing}) async {
    final org = _org;
    if (org == null) return;
    final e = existing ?? const <String, dynamic>{};
    final title = TextEditingController(text: '${e['title'] ?? ''}');
    final authority = TextEditingController(text: '${e['authority'] ?? ''}');
    final ref_ = TextEditingController(text: '${e['reference_no'] ?? ''}');
    final cost = TextEditingController(text: e['cost'] == null ? '' : '${e['cost']}');
    final remind = TextEditingController(text: '${e['remind_days'] ?? 30}');
    final years = TextEditingController(text: '${e['repeat_years'] ?? 2}');
    final notes = TextEditingController(text: '${e['notes'] ?? ''}');
    String cat = e['category'] as String? ?? 'fire';
    String? branch = e['branch_id'] as String?;
    String repeat = e['repeat'] as String? ?? 'yearly';
    String? resp = e['responsible_user_id'] as String?;
    String? sched = e['facility_schedule_id'] as String?;
    DateTime? issued = DateTime.tryParse('${e['issued_on'] ?? ''}');
    DateTime? expires = DateTime.tryParse('${e['expires_on'] ?? ''}');
    final docs = <Map<String, dynamic>>[for (final d in (e['documents'] as List? ?? const [])) Map<String, dynamic>.from(d as Map)];
    final folder = existing?['id'] ?? 'new_${DateTime.now().millisecondsSinceEpoch}';
    var saving = false, uploading = false;

    InputDecoration dec(String l) => InputDecoration(labelText: l, isDense: true, border: const OutlineInputBorder());
    Widget pair(Widget a, Widget b) => Row(children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)]);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> pickDate(bool isExpiry) async {
          final init = (isExpiry ? expires : issued) ?? DateTime.now();
          final p = await showDatePicker(context: ctx, initialDate: init, firstDate: DateTime(2000), lastDate: DateTime(2100));
          if (p == null) return;
          setS(() {
            if (isExpiry) {
              expires = p;
            } else {
              issued = p;
            }
          });
        }

        Future<void> save() async {
          if (title.text.trim().isEmpty) { _snack('Enter what it is'); return; }
          if (expires == null && repeat != 'none') { _snack('Enter the expiry date'); return; }
          setS(() => saving = true);
          try {
            final me = await _myName(org);
            final payload = {
              'title': title.text.trim(), 'category': cat, 'branch_id': branch,
              'authority': authority.text.trim().isEmpty ? null : authority.text.trim(),
              'reference_no': ref_.text.trim().isEmpty ? null : ref_.text.trim(),
              'issued_on': issued == null ? null : DateFormat('yyyy-MM-dd').format(issued!),
              'expires_on': expires == null ? null : DateFormat('yyyy-MM-dd').format(expires!),
              'repeat': repeat, 'repeat_years': repeat == 'years' ? int.tryParse(years.text.trim()) ?? 2 : null,
              'remind_days': int.tryParse(remind.text.trim()) ?? 30,
              'responsible_user_id': resp, 'cost': num.tryParse(cost.text.trim()),
              'facility_schedule_id': sched, 'documents': docs,
              'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            };
            if (existing == null) {
              await _db.from('compliance_items').insert({...payload, 'org_id': org, 'created_by_name': me is String ? me : null});
            } else {
              await _db.from('compliance_items').update(payload).eq('id', e['id']);
            }
            if (ctx.mounted) Navigator.pop(ctx);
            await _load();
            _snack(existing == null ? 'Added' : 'Saved');
          } catch (err) {
            setS(() => saving = false);
            _snack(friendlyError('Could not save', err));
          }
        }

        final schedOpts = _schedules.where((s) => branch == null || s['branch_id'] == null || s['branch_id'] == branch).toList();
        return AlertDialog(
          title: Text(existing == null ? 'Add compliance item' : 'Edit ${e['title']}'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: title, decoration: dec('What is it * (e.g. Fire Safety Certificate)')),
                const SizedBox(height: 10),
                pair(
                  DropdownButtonFormField<String>(value: cat, isExpanded: true, decoration: dec('Category'),
                      items: [for (final c in _categories) DropdownMenuItem(value: c.$1, child: Text('${c.$3} ${c.$2}'))],
                      onChanged: (v) => setS(() => cat = v ?? 'other')),
                  DropdownButtonFormField<String?>(value: _branches.any((b) => b['id'] == branch) ? branch : null, isExpanded: true, decoration: dec('Branch'),
                      items: [const DropdownMenuItem<String?>(value: null, child: Text('All branches')),
                        for (final b in _branches) DropdownMenuItem<String?>(value: b['id'] as String, child: Text('${b['name']}'))],
                      onChanged: (v) => setS(() => branch = v)),
                ),
                const SizedBox(height: 10),
                pair(TextField(controller: authority, decoration: dec('Issuing authority')),
                    TextField(controller: ref_, decoration: dec('Certificate / reference no.'))),
                const SizedBox(height: 10),
                pair(
                  InkWell(onTap: () => pickDate(false), child: InputDecorator(decoration: dec('Issued on'), child: Text(issued == null ? '—' : DateFormat('d MMM yyyy').format(issued!)))),
                  InkWell(onTap: () => pickDate(true), child: InputDecorator(decoration: dec('Expires on *'), child: Text(expires == null ? '—' : DateFormat('d MMM yyyy').format(expires!)))),
                ),
                const SizedBox(height: 10),
                pair(
                  Row(children: [
                    Expanded(child: DropdownButtonFormField<String>(value: repeat, isExpanded: true, decoration: dec('Repeats'),
                        items: [for (final r in _repeats) DropdownMenuItem(value: r.$1, child: Text(r.$2))],
                        onChanged: (v) => setS(() => repeat = v ?? 'yearly'))),
                    if (repeat == 'years') ...[
                      const SizedBox(width: 8),
                      SizedBox(width: 70, child: TextField(controller: years, keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: dec('Years'))),
                    ],
                  ]),
                  TextField(controller: remind, keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: dec('Remind before (days)')),
                ),
                const SizedBox(height: 10),
                pair(
                  DropdownButtonFormField<String?>(value: _users.any((u) => u['id'] == resp) ? resp : null, isExpanded: true, decoration: dec('Responsible person'),
                      items: [const DropdownMenuItem<String?>(value: null, child: Text('—')),
                        for (final u in _users) DropdownMenuItem<String?>(value: u['id'] as String, child: Text('${u['name']}', overflow: TextOverflow.ellipsis))],
                      onChanged: (v) => setS(() => resp = v)),
                  TextField(controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], decoration: dec('Cost (optional)')),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  value: schedOpts.any((s) => s['id'] == sched) ? sched : null, isExpanded: true,
                  decoration: dec('Link a Facility schedule (optional)'),
                  items: [const DropdownMenuItem<String?>(value: null, child: Text('— none —')),
                    for (final s in schedOpts) DropdownMenuItem<String?>(value: s['id'] as String,
                        child: Text('${s['title']}${s['branch_id'] != null ? ' — ${_branchNames[s['branch_id']] ?? ''}' : ''}', overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setS(() => sched = v),
                ),
                const SizedBox(height: 10),
                TextField(controller: notes, minLines: 1, maxLines: 3, decoration: dec('Notes (optional)')),
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerLeft, child: Text('Documents (${docs.length})', style: const TextStyle(fontWeight: FontWeight.w600))),
                _docList(docs, onRemove: (i) => setS(() => docs.removeAt(i))),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: uploading ? null : () async {
                      setS(() => uploading = true);
                      final added = await _pickAndUpload('$folder');
                      setS(() { docs.addAll(added); uploading = false; });
                    },
                    icon: uploading
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.attach_file, size: 16),
                    label: const Text('Add file (PDF or photo)'),
                  ),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(onPressed: saving || uploading ? null : save, child: Text(saving ? 'Saving…' : 'Save')),
          ],
        );
      }),
    );
  }

  // ── item page ─────────────────────────────────────────────────────────────
  Future<void> _openItem(Map<String, dynamic> c) async {
    List<Map<String, dynamic>> renewals = [];
    String? lastDone;
    try {
      renewals = List<Map<String, dynamic>>.from(
          await _db.from('compliance_renewals').select().eq('item_id', c['id']).order('created_at', ascending: false));
    } catch (_) {}
    if (c['facility_schedule_id'] != null) {
      try {
        final t = await _db.from('facility_tasks').select('completed_at').eq('schedule_id', c['facility_schedule_id'])
            .eq('status', 'done').order('completed_at', ascending: false).limit(1);
        if ((t as List).isNotEmpty) lastDone = '${t.first['completed_at']}';
      } catch (_) {}
    }
    if (!mounted) return;
    final st = complianceState(c);
    final sch = _schedules.where((s) => s['id'] == c['facility_schedule_id']).firstOrNull;
    final p = _statePill(st);
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760, maxHeight: MediaQuery.of(ctx).size.height * 0.9),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${c['title']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: p.$3, borderRadius: BorderRadius.circular(999)),
                  child: Text(st == 'expired' ? 'Expired ${_whenLabel(c)}' : '${p.$1} · ${_whenLabel(c)}',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: p.$2)),
                ),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(onPressed: () => _printItem(c, renewals, sch), icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print')),
                OutlinedButton.icon(onPressed: () { Navigator.pop(ctx); _edit(existing: c); }, icon: const Icon(Icons.edit_outlined, size: 16), label: const Text('Edit')),
                if (st != 'renewal' && c['expires_on'] != null)
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await _db.from('compliance_items').update({'in_renewal_since': DateFormat('yyyy-MM-dd').format(DateTime.now())}).eq('id', c['id']);
                        if (ctx.mounted) Navigator.pop(ctx);
                        await _load();
                        _snack('Marked as in renewal — "due" reminders pause until it is renewed');
                      } catch (e) {
                        _snack(friendlyError('Could not save', e));
                      }
                    },
                    icon: const Icon(Icons.hourglass_top, size: 16), label: const Text('Renewal applied')),
                ElevatedButton.icon(onPressed: () { Navigator.pop(ctx); _renew(c); }, icon: const Icon(Icons.autorenew, size: 16), label: const Text('Renew')),
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await showDialog<bool>(context: ctx, builder: (d) => AlertDialog(
                      title: const Text('Remove this item?'),
                      content: const Text('It will no longer be tracked or reminded. Its history is kept.'),
                      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                        ElevatedButton(onPressed: () => Navigator.pop(d, true), child: const Text('Remove'))],
                    ));
                    if (ok != true) return;
                    await _db.from('compliance_items').update({'is_active': false}).eq('id', c['id']);
                    if (ctx.mounted) Navigator.pop(ctx);
                    await _load();
                  },
                  style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
                  icon: const Icon(Icons.delete_outline, size: 16), label: const Text('Remove')),
              ]),
              const SizedBox(height: 14),
              _box(Wrap(spacing: 24, runSpacing: 10, children: [
                _kv('Category', _catLabel(c['category'] as String?)),
                _kv('Branch', c['branch_id'] == null ? 'All branches' : (_branchNames[c['branch_id']] ?? '—')),
                _kv('Authority', '${c['authority'] ?? '—'}'),
                _kv('Reference', '${c['reference_no'] ?? '—'}'),
                _kv('Issued', _fd(c['issued_on'])),
                _kv(st == 'expired' ? 'Expired' : 'Expires', _fd(c['expires_on'])),
                _kv('Repeats', c['repeat'] == 'years' ? 'Every ${c['repeat_years'] ?? '?'} years' : (_repeats.where((r) => r.$1 == c['repeat']).firstOrNull?.$2 ?? '—')),
                _kv('Remind before', '${c['remind_days'] ?? 30} days'),
                _kv('Responsible', _userNames[c['responsible_user_id']] ?? '—'),
                if (c['cost'] != null) _kv('Cost', 'Rs ${NumberFormat('#,##0').format(c['cost'])}'),
                if (c['in_renewal_since'] != null) _kv('Renewal applied', _fd(c['in_renewal_since'])),
              ])),
              if ((c['notes'] ?? '') != '') _box(Text('${c['notes']}', style: const TextStyle(fontSize: 13))),
              _box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Documents (${(c['documents'] as List? ?? const []).length})', style: const TextStyle(fontWeight: FontWeight.w700)),
                if ((c['documents'] as List? ?? const []).isEmpty)
                  const Padding(padding: EdgeInsets.only(top: 4), child: Text('No documents yet — add them with Edit.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                else
                  _docList(c['documents'] as List),
              ])),
              if (sch != null)
                _box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Linked Facility schedule', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('${sch['title']} · ${sch['frequency'] ?? ''}${lastDone != null ? ' · last done ${_fd(lastDone)}' : ''}',
                      style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                ])),
              _box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Renewal history', style: TextStyle(fontWeight: FontWeight.w700)),
                if (renewals.isEmpty)
                  const Padding(padding: EdgeInsets.only(top: 4), child: Text('Not renewed yet.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                for (final r in renewals)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${_fd(r['old_expiry'])} → ${_fd(r['new_expiry'])}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      Text([
                        'renewed ${_fd(r['created_at'])}',
                        if (r['cost'] != null) 'Rs ${NumberFormat('#,##0').format(r['cost'])}',
                        if ((r['by_name'] ?? '') != '') 'by ${r['by_name']}',
                        if ((r['note'] ?? '') != '') '${r['note']}',
                      ].join(' · '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                      if ((r['documents'] as List? ?? const []).isNotEmpty) _docList(r['documents'] as List),
                    ]),
                  ),
              ])),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _box(Widget child) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: child,
      );

  Widget _kv(String k, String v) => SizedBox(
        width: 190,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      );

  // ── renew ─────────────────────────────────────────────────────────────────
  Future<void> _renew(Map<String, dynamic> c) async {
    DateTime issued = _today();
    DateTime? expiry = _nextExpiry(c);
    final cost = TextEditingController(text: c['cost'] == null ? '' : '${c['cost']}');
    final note = TextEditingController();
    final docs = <Map<String, dynamic>>[];
    var busy = false, uploading = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: Text('Renew: ${c['title']}'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('The current certificate and dates move to the renewal history.', style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: InkWell(
                onTap: () async {
                  final p = await showDatePicker(context: ctx, initialDate: issued, firstDate: DateTime(2000), lastDate: DateTime(2100));
                  if (p != null) setS(() => issued = p);
                },
                child: InputDecorator(decoration: const InputDecoration(labelText: 'Issued on', isDense: true, border: OutlineInputBorder()),
                    child: Text(DateFormat('d MMM yyyy').format(issued))),
              )),
              const SizedBox(width: 10),
              Expanded(child: InkWell(
                onTap: () async {
                  final p = await showDatePicker(context: ctx, initialDate: expiry ?? _today().add(const Duration(days: 365)), firstDate: DateTime(2000), lastDate: DateTime(2100));
                  if (p != null) setS(() => expiry = p);
                },
                child: InputDecorator(decoration: const InputDecoration(labelText: 'New expiry *', isDense: true, border: OutlineInputBorder()),
                    child: Text(expiry == null ? '—' : DateFormat('d MMM yyyy').format(expiry!))),
              )),
            ]),
            const SizedBox(height: 10),
            TextField(controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Cost (optional)', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 10),
            _docList(docs, onRemove: (i) => setS(() => docs.removeAt(i))),
            TextButton.icon(
              onPressed: uploading ? null : () async {
                setS(() => uploading = true);
                final added = await _pickAndUpload('${c['id']}');
                setS(() { docs.addAll(added); uploading = false; });
              },
              icon: const Icon(Icons.attach_file, size: 16),
              label: const Text('Upload the new certificate'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: busy || uploading ? null : () async {
              if (expiry == null) { _snack('Enter the new expiry date'); return; }
              setS(() => busy = true);
              try {
                await _db.rpc('compliance_renew', params: {
                  'p_item': c['id'],
                  'p_new_issued': DateFormat('yyyy-MM-dd').format(issued),
                  'p_new_expiry': DateFormat('yyyy-MM-dd').format(expiry!),
                  'p_cost': num.tryParse(cost.text.trim()),
                  'p_note': note.text.trim(),
                  'p_documents': docs,
                });
                if (ctx.mounted) Navigator.pop(ctx);
                await _load();
                _snack('Renewed until ${DateFormat('d MMM yyyy').format(expiry!)}');
              } catch (e) {
                setS(() => busy = false);
                _snack(friendlyError('Could not renew', e));
              }
            },
            child: const Text('Save renewal'),
          ),
        ],
      )),
    );
  }

  // ── print ─────────────────────────────────────────────────────────────────
  void _printList() {
    final list = _shown;
    final b = StringBuffer()
      ..write('<h1>Licences & Compliance</h1><div class="meta">${list.length} items</div>')
      ..write('<table><tr><th>Item</th><th>Category</th><th>Branch</th><th>Authority</th><th>Reference</th><th>Responsible</th><th>Expires</th><th>Status</th></tr>');
    for (final c in list) {
      final st = complianceState(c);
      b.write('<tr><td><b>${esc(c['title'])}</b></td><td>${esc(_catLabel(c['category'] as String?))}</td>'
          '<td>${esc(c['branch_id'] == null ? 'All branches' : _branchNames[c['branch_id']])}</td><td>${esc(c['authority'])}</td>'
          '<td>${esc(c['reference_no'])}</td><td>${esc(_userNames[c['responsible_user_id']])}</td>'
          '<td>${esc(_fd(c['expires_on']))}</td><td class="${st == 'expired' ? 'overdue' : st == 'due' ? 'due' : 'ok'}">${esc(_statePill(st).$1)}</td></tr>');
    }
    b.write('</table>');
    openPrint('Licences & Compliance', b.toString());
  }

  void _printItem(Map c, List<Map<String, dynamic>> renewals, Map? sch) {
    final st = complianceState(c);
    final b = StringBuffer()
      ..write('<h1>${esc(c['title'])}</h1><div class="meta">${esc(_statePill(st).$1)} · ${esc(_whenLabel(c))}</div>')
      ..write('<table><tr><th>Category</th><th>Branch</th><th>Authority</th><th>Reference</th></tr>'
          '<tr><td>${esc(_catLabel(c['category'] as String?))}</td><td>${esc(c['branch_id'] == null ? 'All branches' : _branchNames[c['branch_id']])}</td>'
          '<td>${esc(c['authority'])}</td><td>${esc(c['reference_no'])}</td></tr>'
          '<tr><th>Issued</th><th>Expires</th><th>Responsible</th><th>Remind before</th></tr>'
          '<tr><td>${esc(_fd(c['issued_on']))}</td><td>${esc(_fd(c['expires_on']))}</td>'
          '<td>${esc(_userNames[c['responsible_user_id']])}</td><td>${esc('${c['remind_days'] ?? 30} days')}</td></tr></table>');
    if ((c['notes'] ?? '') != '') b.write('<h2>Notes</h2><div>${esc(c['notes'])}</div>');
    final docs = c['documents'] as List? ?? const [];
    if (docs.isNotEmpty) {
      b.write('<h2>Documents</h2><ul>');
      for (final d in docs) { b.write('<li>${esc(d['name'])}</li>'); }
      b.write('</ul>');
    }
    if (sch != null) b.write('<h2>Linked Facility schedule</h2><div>${esc(sch['title'])}</div>');
    b.write('<h2>Renewal history</h2><table><tr><th>Period</th><th>Renewed</th><th class="num">Cost</th><th>By</th><th>Note</th></tr>');
    for (final r in renewals) {
      b.write('<tr><td>${esc(_fd(r['old_expiry']))} → ${esc(_fd(r['new_expiry']))}</td><td>${esc(_fd(r['created_at']))}</td>'
          '<td class="num">${r['cost'] == null ? '' : esc(NumberFormat('#,##0').format(r['cost']))}</td><td>${esc(r['by_name'])}</td><td>${esc(r['note'])}</td></tr>');
    }
    b.write('</table>');
    openPrint('${c['title']}', b.toString());
  }
}
