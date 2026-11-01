import 'dart:convert';
import 'dart:html' as html;

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';

/// Super admin → Lead Generation: distributors across Pakistan (SQL 438),
/// filterable by industry, city and principal. Seeded from public web
/// sources; kept up to date here or by CSV.
class LeadsScreen extends StatefulWidget {
  const LeadsScreen({super.key});
  @override
  State<LeadsScreen> createState() => _LeadsScreenState();
}

const _statuses = <String, String>{
  'new': 'New',
  'contacted': 'Contacted',
  'interested': 'Interested',
  'not_interested': 'Not interested',
  'customer': 'Customer',
};

const _industryOptions = [
  'FMCG & consumer goods',
  'Food & beverage',
  'Pharmaceuticals',
  'Building materials',
  'Auto parts',
  'Electronics & hardware',
  'Textiles & apparel',
  'Chemicals',
  'Agri inputs',
  'Wholesale & trading',
];

const _cityOptions = [
  'Lahore', 'Karachi', 'Islamabad', 'Rawalpindi', 'Faisalabad', 'Multan',
  'Peshawar', 'Quetta', 'Gujranwala', 'Sialkot', 'Hyderabad', 'Sukkur',
  'Bahawalpur', 'Sargodha', 'Abbottabad', 'Nationwide', 'Other',
];

const _csvCols = [
  'id', 'name', 'industries', 'city', 'address', 'phone', 'email', 'website',
  'principals', 'notes', 'sources', 'status', 'follow_up',
];

class _LeadsScreenState extends State<LeadsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  String _search = '';
  String? _industry;
  String? _city;
  String? _principal;
  String? _status;

  SupabaseClient get _c => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  static List<String> _list(dynamic v) =>
      v is List ? [for (final x in v) if ('$x'.trim().isNotEmpty) '$x'.trim()] : <String>[];

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final out = <Map<String, dynamic>>[];
      // Page through in 1000s (PostgREST cap).
      for (var from = 0;; from += 1000) {
        final page = await _c.from('lead_distributors').select('*').order('name').range(from, from + 999);
        out.addAll(List<Map<String, dynamic>>.from(page));
        if ((page as List).length < 1000) break;
      }
      if (!mounted) return;
      setState(() {
        _rows = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(friendlyError('Could not load leads', e));
    }
  }

  // ── filtering ──────────────────────────────────────────────────────────────
  List<String> get _allPrincipals {
    final m = <String, String>{};
    for (final r in _rows) {
      for (final p in _list(r['principals'])) {
        m.putIfAbsent(p.toLowerCase(), () => p);
      }
    }
    final l = m.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return l;
  }

  List<String> get _allIndustries {
    final s = <String>{..._industryOptions};
    for (final r in _rows) {
      s.addAll(_list(r['industries']));
    }
    return s.toList()..sort();
  }

  List<String> get _allCities {
    final s = <String>{};
    for (final r in _rows) {
      final c = '${r['city'] ?? ''}'.trim();
      if (c.isNotEmpty) s.add(c);
    }
    return s.toList()..sort();
  }

  List<Map<String, dynamic>> get _visible {
    final q = _search.trim().toLowerCase();
    return _rows.where((r) {
      if (_industry != null && !_list(r['industries']).contains(_industry)) return false;
      if (_city != null && r['city'] != _city) return false;
      if (_status != null && r['status'] != _status) return false;
      if (_principal != null &&
          !_list(r['principals']).any((p) => p.toLowerCase() == _principal!.toLowerCase())) {
        return false;
      }
      if (q.isEmpty) return true;
      final hay = [
        r['name'], r['city'], r['address'], r['phone'], r['email'], r['website'], r['notes'],
        _list(r['principals']).join(' '), _list(r['industries']).join(' '),
      ].map((v) => '${v ?? ''}').join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  bool get _filtered => _industry != null || _city != null || _principal != null || _status != null || _search.isNotEmpty;

  // ── actions ────────────────────────────────────────────────────────────────
  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      _snack('Could not open');
    }
  }

  String _waDigits(String phone) {
    var d = phone.split(RegExp(r'[,/;]')).first.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('00')) d = d.substring(2);
    if (d.startsWith('0')) d = '92${d.substring(1)}';
    return d;
  }

  String _site(String w) => w.startsWith('http') ? w : 'https://$w';

  Future<void> _update(Map<String, dynamic> r, Map<String, dynamic> patch) async {
    final old = {for (final k in patch.keys) k: r[k]};
    setState(() => r.addAll(patch));
    try {
      await _c.from('lead_distributors').update(patch).eq('id', r['id'] as String);
    } catch (e) {
      if (!mounted) return;
      setState(() => r.addAll(old));
      _snack(friendlyError('Could not save', e));
    }
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete lead?'),
        content: Text('Remove ${r['name']} from the list?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _c.from('lead_distributors').delete().eq('id', r['id'] as String);
      if (!mounted) return;
      setState(() => _rows.removeWhere((x) => x['id'] == r['id']));
    } catch (e) {
      _snack(friendlyError('Could not delete', e));
    }
  }

  Future<void> _edit([Map<String, dynamic>? r]) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LeadEditor(lead: r, industries: _allIndustries),
    );
    if (res == null) return;
    try {
      if (r == null) {
        final saved = await _c.from('lead_distributors').insert(res).select().single();
        if (!mounted) return;
        setState(() => _rows.add(Map<String, dynamic>.from(saved)));
        _snack('Lead added');
      } else {
        await _c.from('lead_distributors').update(res).eq('id', r['id'] as String);
        if (!mounted) return;
        setState(() => r.addAll(res));
        _snack('Lead saved');
      }
    } catch (e) {
      _snack(friendlyError('Could not save', e));
    }
  }

  Future<void> _editFollowUp(Map<String, dynamic> r) async {
    final ctrl = TextEditingController(text: '${r['follow_up'] ?? ''}');
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Follow-up notes · ${r['name']}'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: ctrl, maxLines: 5, autofocus: true,
            decoration: const InputDecoration(hintText: 'Who you spoke to, outcome, next call date…', border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (saved != null) await _update(r, {'follow_up': saved});
  }

  // ── CSV ────────────────────────────────────────────────────────────────────
  void _exportCsv() {
    final rows = <List<dynamic>>[_csvCols];
    for (final r in _visible) {
      rows.add([
        r['id'], r['name'], _list(r['industries']).join('; '), r['city'], r['address'],
        r['phone'], r['email'], r['website'], _list(r['principals']).join('; '),
        r['notes'], _list(r['sources']).join('; '), r['status'], r['follow_up'],
      ].map((v) => v ?? '').toList());
    }
    final csv = const ListToCsvConverter().convert(rows);
    final bytes = utf8.encode('﻿$csv');
    final blob = html.Blob([bytes], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', 'leads_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  Future<void> _importCsv() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv'], withData: true);
    if (res == null || res.files.isEmpty || res.files.single.bytes == null) return;
    List<List<String>> rows;
    try {
      var text = utf8.decode(res.files.single.bytes!, allowMalformed: true);
      if (text.startsWith('﻿')) text = text.substring(1);
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      rows = [
        for (final r in const CsvToListConverter(shouldParseNumbers: false, eol: '\n').convert(text))
          [for (final c in r) (c?.toString() ?? '').trim()]
      ].where((r) => r.any((c) => c.isNotEmpty)).toList();
    } catch (e) {
      _snack(friendlyError('Could not read the file', e));
      return;
    }
    if (rows.length < 2) {
      _snack('The file has no data rows.');
      return;
    }
    final head = [for (final h in rows.first) h.toLowerCase().replaceAll(' ', '_')];
    final ix = {for (var i = 0; i < head.length; i++) head[i]: i};
    if (!ix.containsKey('name')) {
      _snack('The file needs at least a "name" column. Export first to get the right columns.');
      return;
    }
    String cell(List<String> r, String k) {
      final i = ix[k];
      return (i == null || i >= r.length) ? '' : r[i];
    }
    List<String> split(String s) => [for (final x in s.split(RegExp(r'[;|]'))) if (x.trim().isNotEmpty) x.trim()];

    final byId = {for (final r in _rows) r['id'] as String: r};
    final byNameCity = {
      for (final r in _rows) '${'${r['name']}'.toLowerCase()}|${'${r['city']}'.toLowerCase()}': r
    };
    final inserts = <Map<String, dynamic>>[];
    final updates = <String, Map<String, dynamic>>{};
    var skipped = 0;
    for (final r in rows.skip(1)) {
      final name = cell(r, 'name');
      if (name.isEmpty) { skipped++; continue; }
      final city = cell(r, 'city').isEmpty ? 'Other' : cell(r, 'city');
      final rec = <String, dynamic>{'name': name, 'city': city};
      // Only columns present in the file are written, so a partial file
      // never blanks out other details.
      for (final k in ['address', 'phone', 'email', 'website', 'notes', 'follow_up']) {
        if (ix.containsKey(k)) rec[k] = cell(r, k);
      }
      for (final k in ['industries', 'principals', 'sources']) {
        if (ix.containsKey(k)) rec[k] = split(cell(r, k));
      }
      if (ix.containsKey('status')) {
        final s = cell(r, 'status').toLowerCase().replaceAll(' ', '_');
        if (_statuses.containsKey(s)) rec['status'] = s;
      }
      final id = cell(r, 'id');
      final existing = (id.isNotEmpty ? byId[id] : null) ??
          byNameCity['${name.toLowerCase()}|${city.toLowerCase()}'];
      if (existing != null) {
        updates[existing['id'] as String] = rec;
      } else {
        inserts.add(rec);
      }
    }
    if (inserts.isEmpty && updates.isEmpty) {
      _snack('Nothing to import.');
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import leads'),
        content: Text('${inserts.length} new, ${updates.length} to update'
            '${skipped > 0 ? ', $skipped rows without a name skipped' : ''}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Import')),
        ],
      ),
    );
    if (go != true) return;
    var failed = 0;
    try {
      for (var i = 0; i < inserts.length; i += 200) {
        await _c.from('lead_distributors').insert(inserts.sublist(i, i + 200 > inserts.length ? inserts.length : i + 200));
      }
    } catch (e) {
      _snack(friendlyError('Import stopped', e));
      await _load();
      return;
    }
    for (final e in updates.entries) {
      try {
        await _c.from('lead_distributors').update(e.value).eq('id', e.key);
      } catch (_) {
        failed++;
      }
    }
    await _load();
    if (!mounted) return;
    _snack('Imported: ${inserts.length} new, ${updates.length - failed} updated'
        '${failed > 0 ? ', $failed failed' : ''}.');
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final list = _visible;
    final narrow = MediaQuery.of(context).size.width < 700;
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(narrow ? 14 : 20, 18, narrow ? 14 : 20, 6),
          child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.spaceBetween, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              const Text('Lead Generation', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              Text(_loading ? 'Loading…' : '${_rows.length} distributors across Pakistan · ${list.length} shown',
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: _loading ? null : _importCsv, icon: const Icon(Icons.upload_file, size: 18), label: const Text('Import CSV')),
              OutlinedButton.icon(onPressed: _loading ? null : _exportCsv, icon: const Icon(Icons.download, size: 18), label: const Text('Export CSV')),
              FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add, size: 18), label: const Text('Add lead')),
            ]),
          ]),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(narrow ? 14 : 20, 8, narrow ? 14 : 20, 4),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: narrow ? double.infinity : 260,
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: const InputDecoration(
                  isDense: true, prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search name, number, address…', border: OutlineInputBorder(),
                ),
              ),
            ),
            _dropdown('Industry', _industry, _allIndustries, (v) => setState(() => _industry = v)),
            _dropdown('City', _city, _allCities, (v) => setState(() => _city = v)),
            _principalPicker(),
            _dropdown('Status', _status, _statuses.keys.toList(), (v) => setState(() => _status = v), labels: _statuses),
            if (_filtered)
              TextButton.icon(
                onPressed: () => setState(() { _industry = null; _city = null; _principal = null; _status = null; }),
                icon: const Icon(Icons.filter_alt_off_outlined, size: 18), label: const Text('Clear filters'),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? const Center(child: Text('No distributors match these filters.', style: TextStyle(color: AppTheme.textSecondary)))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: EdgeInsets.fromLTRB(narrow ? 14 : 20, 6, narrow ? 14 : 20, 28),
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _card(list[i]),
                      ),
                    ),
        ),
      ]),
    );
  }

  Widget _dropdown(String label, String? value, List<String> options, ValueChanged<String?> onChanged,
      {Map<String, String>? labels}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: value != null ? AppTheme.primary : AppTheme.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: options.contains(value) ? value : null,
          hint: Text(label, style: const TextStyle(fontSize: 13)),
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text('All ${label.toLowerCase()}')),
            for (final o in options) DropdownMenuItem<String?>(value: o, child: Text(labels?[o] ?? o)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _principalPicker() {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        side: BorderSide(color: _principal != null ? AppTheme.primary : AppTheme.border),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      onPressed: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (_) => _PrincipalPicker(options: _allPrincipals, rows: _rows),
        );
        if (picked == null) return;
        setState(() => _principal = picked.isEmpty ? null : picked);
      },
      icon: const Icon(Icons.business_center_outlined, size: 18),
      label: Text(_principal == null ? 'Principal' : 'Principal: $_principal',
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final phone = '${r['phone'] ?? ''}'.trim();
    final email = '${r['email'] ?? ''}'.trim();
    final website = '${r['website'] ?? ''}'.trim();
    final address = '${r['address'] ?? ''}'.trim();
    final notes = '${r['notes'] ?? ''}'.trim();
    final follow = '${r['follow_up'] ?? ''}'.trim();
    final principals = _list(r['principals']);
    final industries = _list(r['industries']);
    final sources = _list(r['sources']);
    final status = '${r['status'] ?? 'new'}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _tag(Icons.place_outlined, '${r['city']}'),
                for (final i in industries) _tag(Icons.category_outlined, i),
              ]),
            ]),
          ),
          _statusMenu(r, status),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'edit') _edit(r);
              if (v == 'delete') _delete(r);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit details')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ]),
        if (principals.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Principals', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in principals)
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(p, style: const TextStyle(fontSize: 12)),
                backgroundColor: p.toLowerCase() == _principal?.toLowerCase() ? AppTheme.primary.withOpacity(0.12) : null,
                tooltip: 'Show distributors of $p',
                onPressed: () => setState(() => _principal = p),
              ),
          ]),
        ],
        if (address.isNotEmpty || phone.isNotEmpty || email.isNotEmpty || website.isNotEmpty) ...[
          const SizedBox(height: 10),
          if (address.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.location_on_outlined, size: 16, color: AppTheme.textSecondary),
                const SizedBox(width: 6),
                Expanded(child: SelectableText(address, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
              ]),
            ),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (phone.isNotEmpty) ...[
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: phone));
                  _snack('Number copied');
                },
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.phone_outlined, size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  Text(phone, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                ]),
              ),
              OutlinedButton.icon(
                onPressed: () => _open('tel:${phone.split(RegExp(r'[,/;]')).first.replaceAll(RegExp(r'[^0-9+]'), '')}'),
                icon: const Icon(Icons.call, size: 16), label: const Text('Call'),
              ),
              OutlinedButton.icon(
                onPressed: () => _open('https://wa.me/${_waDigits(phone)}'),
                icon: const Icon(Icons.chat_outlined, size: 16), label: const Text('WhatsApp'),
              ),
            ],
            if (email.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _open('mailto:${email.split(RegExp(r'[,;/ ]')).first}'),
                icon: const Icon(Icons.mail_outline, size: 16), label: Text(email, overflow: TextOverflow.ellipsis),
              ),
            if (website.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _open(_site(website)),
                icon: const Icon(Icons.language, size: 16), label: const Text('Website'),
              ),
          ]),
        ],
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(notes, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.4)),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 4, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          TextButton.icon(
            onPressed: () => _editFollowUp(r),
            icon: const Icon(Icons.edit_note, size: 18),
            label: Text(follow.isEmpty ? 'Add follow-up notes' : 'Follow-up notes'),
          ),
          for (var i = 0; i < sources.length; i++)
            TextButton.icon(
              onPressed: () => _open(sources[i]),
              icon: const Icon(Icons.link, size: 16),
              label: Text(sources.length == 1 ? 'Source' : 'Source ${i + 1}'),
            ),
        ]),
        if (follow.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8)),
            child: Text(follow, style: const TextStyle(fontSize: 12.5, color: AppTheme.textPrimary)),
          ),
      ]),
    );
  }

  Widget _tag(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        ]),
      );

  Widget _statusMenu(Map<String, dynamic> r, String status) {
    final color = switch (status) {
      'contacted' => Colors.orange.shade700,
      'interested' => Colors.purple.shade600,
      'customer' => Colors.green.shade700,
      'not_interested' => AppTheme.textSecondary,
      _ => AppTheme.primary,
    };
    return PopupMenuButton<String>(
      tooltip: 'Change status',
      onSelected: (v) => _update(r, {'status': v}),
      itemBuilder: (_) => [for (final e in _statuses.entries) PopupMenuItem(value: e.key, child: Text(e.value))],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(_statuses[status] ?? status, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
          Icon(Icons.arrow_drop_down, size: 16, color: color),
        ]),
      ),
    );
  }
}

/// Searchable principal list with distributor counts.
class _PrincipalPicker extends StatefulWidget {
  final List<String> options;
  final List<Map<String, dynamic>> rows;
  const _PrincipalPicker({required this.options, required this.rows});
  @override
  State<_PrincipalPicker> createState() => _PrincipalPickerState();
}

class _PrincipalPickerState extends State<_PrincipalPicker> {
  String _q = '';
  late final Map<String, int> _counts;

  @override
  void initState() {
    super.initState();
    _counts = {};
    for (final r in widget.rows) {
      final ps = r['principals'];
      if (ps is! List) continue;
      for (final p in ps) {
        final k = '$p'.trim().toLowerCase();
        if (k.isNotEmpty) _counts[k] = (_counts[k] ?? 0) + 1;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = widget.options.where((o) => q.isEmpty || o.toLowerCase().contains(q)).toList();
    return AlertDialog(
      title: const Text('Filter by principal'),
      content: SizedBox(
        width: 420,
        height: 440,
        child: Column(children: [
          TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _q = v),
            decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search brand / company', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('No principal matches.', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      title: Text(list[i]),
                      trailing: Text('${_counts[list[i].toLowerCase()] ?? 0}', style: const TextStyle(color: AppTheme.textSecondary)),
                      onTap: () => Navigator.pop(context, list[i]),
                    ),
                  ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Show all principals')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}

/// Add / edit a lead.
class _LeadEditor extends StatefulWidget {
  final Map<String, dynamic>? lead;
  final List<String> industries;
  const _LeadEditor({this.lead, required this.industries});
  @override
  State<_LeadEditor> createState() => _LeadEditorState();
}

class _LeadEditorState extends State<_LeadEditor> {
  late final TextEditingController _name, _address, _phone, _email, _website, _principals, _notes, _sources;
  late String _city;
  late Set<String> _inds;
  String? _err;

  static String _join(dynamic v) => v is List ? v.map((e) => '$e').join('; ') : '';

  @override
  void initState() {
    super.initState();
    final l = widget.lead ?? const <String, dynamic>{};
    _name = TextEditingController(text: '${l['name'] ?? ''}');
    _address = TextEditingController(text: '${l['address'] ?? ''}');
    _phone = TextEditingController(text: '${l['phone'] ?? ''}');
    _email = TextEditingController(text: '${l['email'] ?? ''}');
    _website = TextEditingController(text: '${l['website'] ?? ''}');
    _principals = TextEditingController(text: _join(l['principals']));
    _notes = TextEditingController(text: '${l['notes'] ?? ''}');
    _sources = TextEditingController(text: _join(l['sources']));
    final c = '${l['city'] ?? ''}';
    _city = _cityOptions.contains(c) ? c : (c.isEmpty ? 'Lahore' : c);
    _inds = {for (final i in (l['industries'] is List ? l['industries'] as List : const [])) '$i'};
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _phone, _email, _website, _principals, _notes, _sources]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _split(String s) => [for (final x in s.split(RegExp(r'[;\n]'))) if (x.trim().isNotEmpty) x.trim()];

  Widget _f(TextEditingController c, String label, {int lines = 1, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c, maxLines: lines,
          decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cities = {..._cityOptions, _city}.toList();
    return AlertDialog(
      title: Text(widget.lead == null ? 'Add lead' : 'Edit lead'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            _f(_name, 'Company name *'),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DropdownButtonFormField<String>(
                value: _city,
                decoration: const InputDecoration(labelText: 'City', isDense: true, border: OutlineInputBorder()),
                items: [for (final c in cities) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) => setState(() => _city = v ?? _city),
              ),
            ),
            const Text('Industries', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final i in widget.industries)
                FilterChip(
                  label: Text(i, style: const TextStyle(fontSize: 12)),
                  selected: _inds.contains(i),
                  onSelected: (v) => setState(() => v ? _inds.add(i) : _inds.remove(i)),
                ),
            ]),
            const SizedBox(height: 12),
            _f(_principals, 'Principals', hint: 'Separate with ;  e.g. Nestlé; Unilever'),
            _f(_address, 'Address', lines: 2),
            _f(_phone, 'Phone'),
            _f(_email, 'Email'),
            _f(_website, 'Website'),
            _f(_notes, 'Notes', lines: 3),
            _f(_sources, 'Source links', lines: 2, hint: 'Separate with ;'),
            if (_err != null) Text(_err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) {
              setState(() => _err = 'Enter the company name.');
              return;
            }
            Navigator.pop(context, <String, dynamic>{
              'name': name,
              'city': _city,
              'industries': _inds.toList(),
              'principals': _split(_principals.text),
              'address': _address.text.trim(),
              'phone': _phone.text.trim(),
              'email': _email.text.trim(),
              'website': _website.text.trim(),
              'notes': _notes.text.trim(),
              'sources': _split(_sources.text),
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
