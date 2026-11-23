// Bulk restore from a backup zip (Drive or uploaded). Master admins only.
// Default mode adds back MISSING rows only; a brand-new company is fully loaded.
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';

Future<void> showRestoreBackupDialog(BuildContext context, {required String orgId}) =>
    showDialog(context: context, barrierDismissible: false, builder: (_) => _RestoreDialog(orgId: orgId));

/// Minimal RFC-4180 CSV reader (quotes, doubled quotes, newlines inside quotes).
List<List<String>> _parseCsv(String s) {
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var inQ = false, any = false;
  final n = s.length;
  var i = 0;
  while (i < n) {
    final c = s.codeUnitAt(i);
    if (inQ) {
      if (c == 34) {
        if (i + 1 < n && s.codeUnitAt(i + 1) == 34) { f.writeCharCode(34); i += 2; continue; }
        inQ = false; i++; continue;
      }
      f.writeCharCode(c); i++; continue;
    }
    if (c == 34) { inQ = true; any = true; i++; }
    else if (c == 44) { row.add(f.toString()); f.clear(); any = true; i++; }
    else if (c == 13) { i++; }
    else if (c == 10) {
      if (any || f.isNotEmpty || row.isNotEmpty) { row.add(f.toString()); rows.add(row); }
      row = <String>[]; f.clear(); any = false; i++;
    } else { f.writeCharCode(c); i++; }
  }
  if (any || f.isNotEmpty || row.isNotEmpty) { row.add(f.toString()); rows.add(row); }
  return rows;
}

class _Prev {
  int inBackup = 0, existing = 0, toAdd = 0, live = 0;
  String? note;
}

class _RestoreDialog extends StatefulWidget {
  final String orgId;
  const _RestoreDialog({required this.orgId});
  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _client = Supabase.instance.client;
  String _phase = 'source'; // source | tables | preview | run | done
  bool _busy = false;
  String _status = '';
  String? _error;

  List<Map<String, dynamic>>? _driveFiles;
  String _sourceName = '';
  Map<String, ArchiveFile> _csv = {};
  String _manifest = '';
  bool _isNew = false;
  final Set<String> _sel = {};
  String _filter = '';
  final Map<String, _Prev> _prev = {};
  Map<String, dynamic> _info = {};
  final List<Map<String, dynamic>> _results = [];

  String get _mode => _isNew ? 'replace' : 'missing';

  Future<dynamic> _rpc(String fn, Map<String, dynamic> p) async => await _client.rpc(fn, params: p);

  // ── Step 1: source ────────────────────────────────────────────────────────
  Future<void> _loadDriveList() async {
    setState(() { _busy = true; _error = null; _status = 'Reading your Google Drive folder…'; });
    try {
      final res = await _client.functions.invoke('drive-backups', body: {'action': 'list', 'org_id': widget.orgId});
      final d = res.data;
      if (d is! Map || d['ok'] != true) throw (d is Map ? d['error'] : null) ?? 'Could not read Drive';
      _driveFiles = [for (final f in (d['files'] as List)) Map<String, dynamic>.from(f as Map)];
    } catch (e) {
      _error = _msg(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickDrive(Map<String, dynamic> f) async {
    setState(() { _busy = true; _error = null; _status = 'Downloading ${f['name']}…'; });
    try {
      final res = await _client.functions.invoke('drive-backups',
          body: {'action': 'download', 'org_id': widget.orgId, 'file_id': f['id']});
      final d = res.data;
      if (d is! Map || d['ok'] != true) throw (d is Map ? d['error'] : null) ?? 'Download failed';
      await _openZip(base64Decode('${d['data']}'), '${f['name']}');
    } catch (e) {
      _error = _msg(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _pickUpload() {
    final input = html.FileUploadInputElement()..accept = '.zip';
    input.onChange.listen((_) {
      final file = input.files?.first;
      if (file == null) return;
      setState(() { _busy = true; _error = null; _status = 'Reading ${file.name}…'; });
      final reader = html.FileReader();
      reader.onLoadEnd.listen((_) async {
        try {
          final buf = reader.result;
          final bytes = buf is ByteBuffer ? Uint8List.view(buf) : Uint8List.fromList(buf as List<int>);
          await _openZip(bytes, file.name);
        } catch (e) {
          _error = _msg(e);
        }
        if (mounted) setState(() => _busy = false);
      });
      reader.readAsArrayBuffer(file);
    });
    input.click();
  }

  Future<void> _openZip(Uint8List bytes, String name) async {
    final arc = ZipDecoder().decodeBytes(bytes);
    final csv = <String, ArchiveFile>{};
    var manifest = '';
    for (final f in arc.files) {
      if (!f.isFile) continue;
      final base = f.name.split('/').last;
      if (base.endsWith('.csv')) csv[base.substring(0, base.length - 4)] = f;
      if (base == '_manifest.txt') manifest = utf8.decode(f.content as List<int>, allowMalformed: true);
    }
    if (csv.isEmpty) throw 'That zip has no backup tables in it.';
    // The zip must belong to this company.
    final org = RegExp(r'Organization:\s*(.*)').firstMatch(manifest)?.group(1) ?? '';
    if (org.isNotEmpty && !org.contains(widget.orgId)) {
      throw 'This backup is for a different company ($org). It can only be restored into the company it came from.';
    }
    final isNew = await _rpc('restore_org_is_new', {'p_org': widget.orgId});
    if (!mounted) return;
    setState(() {
      _csv = csv; _manifest = manifest; _sourceName = name; _isNew = isNew == true;
      _sel.clear(); _prev.clear(); _phase = 'tables';
    });
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  List<List<String>> _rowsOf(String table) {
    final text = utf8.decode(_csv[table]!.content as List<int>, allowMalformed: true);
    return _parseCsv(text);
  }

  static String _msg(Object e) {
    if (e is FunctionException) {
      final d = e.details;
      if (d is Map && d['error'] != null) return '${d['error']}';
      return 'Server error ${e.status}';
    }
    if (e is PostgrestException) return e.message;
    return '$e'.replaceFirst('Exception: ', '');
  }

  List<String> get _selected => _sel.toList()..sort();

  // ── Step 3: preview ───────────────────────────────────────────────────────
  Future<void> _runPreview() async {
    setState(() { _busy = true; _error = null; _prev.clear(); });
    try {
      final tables = _selected;
      _info = Map<String, dynamic>.from(await _rpc('restore_tables_info', {'p_org': widget.orgId, 'p_tables': tables}) as Map);
      for (var i = 0; i < tables.length; i++) {
        final t = tables[i];
        if (mounted) setState(() => _status = 'Checking $t (${i + 1}/${tables.length})…');
        final p = _Prev();
        final info = _info[t] as Map?;
        if (info == null) { p.note = 'Not a restorable table'; _prev[t] = p; continue; }
        p.live = (info['live'] as num).toInt();
        final rows = _rowsOf(t);
        if (rows.isEmpty) { _prev[t] = p; continue; }
        final head = rows.first;
        final idx = {for (var k = 0; k < head.length; k++) head[k]: k};
        final oi = idx['org_id'];
        final mine = <List<String>>[];
        if (oi != null) {
          for (var r = 1; r < rows.length; r++) {
            if (rows[r].length > oi && rows[r][oi] == widget.orgId) mine.add(rows[r]);
          }
        }
        p.inBackup = mine.length;
        if (_mode == 'replace') {
          p.toAdd = p.inBackup;
        } else {
          final pk = [for (final c in (info['pk'] as List)) '$c'];
          if (pk.isEmpty || pk.any((c) => !idx.containsKey(c))) {
            p.note = 'No primary key - cannot be safely added';
          } else {
            var existing = 0;
            for (var s = 0; s < mine.length; s += 2000) {
              final chunk = mine.sublist(s, s + 2000 > mine.length ? mine.length : s + 2000);
              final keys = [for (final r in chunk) [for (final c in pk) r[idx[c]!]]];
              final n = await _rpc('restore_preview_existing', {'p_org': widget.orgId, 'p_table': t, 'p_keys': keys});
              existing += (n as num).toInt();
            }
            p.existing = existing;
            p.toAdd = p.inBackup - existing;
          }
        }
        _prev[t] = p;
      }
      if (mounted) setState(() => _phase = 'preview');
    } catch (e) {
      _error = _msg(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  // ── Step 4: restore ───────────────────────────────────────────────────────
  Map<String, dynamic> _clean(List<String> head, List<String> r, List cols) {
    final idx = {for (var k = 0; k < head.length; k++) head[k]: k};
    final o = <String, dynamic>{};
    for (final c in cols) {
      final name = '${c['name']}';
      final k = idx[name];
      if (k == null || k >= r.length) continue;
      final v = r[k];
      final base = '${c['base']}';
      final isText = base == 'text' || base == 'varchar' || base == 'bpchar' || base == 'citext' || base == 'name';
      if (v.isEmpty) {
        o[name] = (isText && c['nullable'] == false) ? '' : null;
      } else if (base == 'json' || base == 'jsonb') {
        try { o[name] = jsonDecode(v); } catch (_) { o[name] = v; }
      } else {
        o[name] = v;
      }
    }
    return o;
  }

  Future<bool> _confirm() async {
    final c = TextEditingController();
    final adds = _prev.values.fold<int>(0, (a, p) => a + p.toAdd);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
        title: Text(_isNew ? 'Load this backup into the new company?' : 'Restore missing data?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_isNew
              ? 'The selected tables will be replaced with the backup ($adds rows).'
              : 'About $adds missing rows from ${_sel.length} table(s) will be added back. Nothing existing is changed or deleted. '
                'A fresh backup is taken first.'),
          const SizedBox(height: 12),
          const Text('Type RESTORE to continue:'),
          const SizedBox(height: 6),
          TextField(controller: c, autofocus: true, onChanged: (_) => set(() {}),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: c.text.trim() == 'RESTORE' ? () => Navigator.of(ctx, rootNavigator: true).pop(true) : null,
              child: const Text('Restore')),
        ],
      )),
    );
    return ok == true;
  }

  Future<void> _runRestore() async {
    if (!await _confirm()) return;
    setState(() { _busy = true; _error = null; _phase = 'run'; _results.clear(); });
    try {
      // Safety net: a fresh backup first (not needed for a brand-new company).
      if (!_isNew) {
        setState(() => _status = 'Taking a safety backup first…');
        final res = await _client.functions.invoke('daily-backup', body: {'org_id': widget.orgId});
        final d = res.data;
        final r = (d is Map && d['results'] is List && (d['results'] as List).isNotEmpty) ? (d['results'] as List).first as Map : null;
        final st = '${r?['status']}';
        final drive = '${r?['drive'] ?? ''}';
        final safe = (st == 'sent') || (st == 'drive' && drive.startsWith('ok')) || (drive.startsWith('ok'));
        if (!safe) {
          throw 'The safety backup did not complete, so nothing was restored. '
              'Check Google Drive / email under Daily data backup and try again.';
        }
      }
      final order = List<String>.from(await _rpc('restore_order', {'p_tables': _selected}) as List);
      final sid = await _rpc('restore_begin', {'p_org': widget.orgId, 'p_mode': _mode, 'p_source': _sourceName});
      for (var i = 0; i < order.length; i++) {
        final t = order[i];
        final p = _prev[t];
        final res = <String, dynamic>{'table': t, 'inserted': 0};
        if (p == null || p.note != null || (_mode == 'missing' && p.toAdd <= 0)) {
          res['skipped'] = p?.note ?? 'nothing to add';
          _results.add(res);
          continue;
        }
        if (mounted) setState(() => _status = 'Restoring $t (${i + 1}/${order.length})…');
        try {
          final rows = _rowsOf(t);
          final head = rows.first;
          final oi = head.indexOf('org_id');
          final cols = (_info[t] as Map)['columns'] as List;
          final mine = <Map<String, dynamic>>[];
          for (var r = 1; r < rows.length; r++) {
            if (oi >= 0 && rows[r].length > oi && rows[r][oi] == widget.orgId) mine.add(_clean(head, rows[r], cols));
          }
          var ins = 0;
          if (mine.isEmpty && _mode == 'replace') {
            await _rpc('restore_apply', {'p_session': sid, 'p_table': t, 'p_rows': [], 'p_first': true});
          }
          for (var s = 0; s < mine.length; s += 300) {
            final chunk = mine.sublist(s, s + 300 > mine.length ? mine.length : s + 300);
            final out = await _rpc('restore_apply', {'p_session': sid, 'p_table': t, 'p_rows': chunk, 'p_first': s == 0});
            ins += ((out as Map)['inserted'] as num).toInt();
          }
          res['inserted'] = ins;
        } catch (e) {
          res['error'] = _msg(e);
        }
        _results.add(res);
      }
      await _rpc('restore_finish', {'p_session': sid, 'p_log': _results});
      if (mounted) setState(() => _phase = 'done');
    } catch (e) {
      _error = _msg(e);
      if (mounted) setState(() => _phase = _results.isEmpty ? 'preview' : 'done');
    }
    if (mounted) setState(() => _busy = false);
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Restore from backup'),
      content: SizedBox(width: 680, height: 460, child: _body()),
      actions: _actions(),
    );
  }

  List<Widget> _actions() {
    void close() => Navigator.of(context, rootNavigator: true).pop();
    switch (_phase) {
      case 'source':
        return [TextButton(onPressed: _busy ? null : close, child: const Text('Close'))];
      case 'tables':
        return [
          TextButton(onPressed: _busy ? null : () => setState(() { _phase = 'source'; _error = null; }), child: const Text('Back')),
          ElevatedButton(onPressed: _busy || _sel.isEmpty ? null : _runPreview, child: Text('Preview (${_sel.length})')),
        ];
      case 'preview':
        final adds = _prev.values.fold<int>(0, (a, p) => a + p.toAdd);
        return [
          TextButton(onPressed: _busy ? null : () => setState(() { _phase = 'tables'; _error = null; }), child: const Text('Back')),
          ElevatedButton(
              onPressed: _busy || (adds <= 0 && !_isNew) ? null : _runRestore,
              child: Text(_isNew ? 'Load backup' : 'Restore $adds missing rows')),
        ];
      case 'run':
        return [const TextButton(onPressed: null, child: Text('Working…'))];
      default:
        return [ElevatedButton(onPressed: close, child: const Text('Done'))];
    }
  }

  Widget _body() {
    if (_busy) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(), const SizedBox(height: 14),
        Text(_status, textAlign: TextAlign.center),
        if (_phase == 'run') const Padding(padding: EdgeInsets.only(top: 8),
            child: Text('Keep this window open.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
      ]));
    }
    final err = _error == null ? const SizedBox.shrink()
        : Padding(padding: const EdgeInsets.only(bottom: 10),
            child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)));
    switch (_phase) {
      case 'source': return _sourceView(err);
      case 'tables': return _tablesView(err);
      case 'preview': return _previewView(err);
      default: return _doneView(err);
    }
  }

  Widget _sourceView(Widget err) {
    final fmt = (String? s) => s == null ? '' : (s.length >= 10 ? s.substring(0, 10) : s);
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      err,
      const Text('Choose the backup to restore from.', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      Wrap(spacing: 10, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: _loadDriveList, icon: const Icon(Icons.cloud_outlined, size: 18), label: const Text('From Google Drive')),
        OutlinedButton.icon(onPressed: _pickUpload, icon: const Icon(Icons.upload_file, size: 18), label: const Text('Upload a backup zip')),
      ]),
      if (_driveFiles != null) ...[
        const SizedBox(height: 12),
        if (_driveFiles!.isEmpty) const Text('No backups found in the Drive folder.'),
        for (final f in _driveFiles!)
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.archive_outlined),
            title: Text('${f['name']}'),
            subtitle: Text('${fmt(f['createdTime'] as String?)}  ·  ${((int.tryParse('${f['size']}') ?? 0) / 1048576).toStringAsFixed(1)} MB'),
            onTap: () => _pickDrive(f),
          ),
      ],
    ]));
  }

  Widget _tablesView(Widget err) {
    final names = _csv.keys.where((t) => _filter.isEmpty || t.contains(_filter.toLowerCase())).toList()..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      err,
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: _isNew ? Colors.orange.withOpacity(.12) : Colors.green.withOpacity(.10), borderRadius: BorderRadius.circular(6)),
        child: Text(_isNew
            ? 'This company is new (no transactions yet), so the selected tables will be loaded from the backup, replacing what is there.'
            : 'Only rows that are missing will be added back. Existing data is never changed or deleted.',
            style: const TextStyle(fontSize: 12.5)),
      ),
      const SizedBox(height: 4),
      Text('Source: $_sourceName', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      Row(children: [
        Expanded(child: TextField(
            decoration: const InputDecoration(isDense: true, hintText: 'Search tables', prefixIcon: Icon(Icons.search, size: 18)),
            onChanged: (v) => setState(() => _filter = v))),
        TextButton(onPressed: () => setState(() => _sel.addAll(names)), child: const Text('Select all')),
        TextButton(onPressed: () => setState(_sel.clear), child: const Text('None')),
      ]),
      Expanded(child: ListView(children: [
        for (final t in names)
          CheckboxListTile(
            dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
            value: _sel.contains(t), title: Text(t),
            subtitle: Text('${(_csv[t]!.size / 1024).toStringAsFixed(1)} KB', style: const TextStyle(fontSize: 11)),
            onChanged: (v) => setState(() => v == true ? _sel.add(t) : _sel.remove(t)),
          ),
      ])),
    ]);
  }

  Widget _previewView(Widget err) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      err,
      Text(_isNew ? 'Nothing has been changed yet. These tables will be loaded:' : 'Nothing has been changed yet. This is what would be added back:',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Expanded(child: ListView(children: [
        for (final t in _selected)
          if (_prev[t] != null)
            ListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              title: Text(t),
              subtitle: Text(_prev[t]!.note ??
                  'In backup ${_prev[t]!.inBackup}  ·  live now ${_prev[t]!.live}' + (_isNew ? '' : '  ·  already there ${_prev[t]!.existing}')),
              trailing: Text(_prev[t]!.note != null ? '-' : (_isNew ? '${_prev[t]!.toAdd}' : '+${_prev[t]!.toAdd}'),
                  style: TextStyle(fontWeight: FontWeight.w700, color: _prev[t]!.toAdd > 0 ? Colors.green.shade700 : AppTheme.textSecondary)),
            ),
      ])),
    ]);
  }

  Widget _doneView(Widget err) {
    final total = _results.fold<int>(0, (a, r) => a + (r['inserted'] as int));
    final errs = _results.where((r) => r['error'] != null).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      err,
      Text(errs == 0 ? 'Restore finished: $total rows loaded.' : 'Restore finished with $errs table(s) failing: $total rows loaded.',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Expanded(child: ListView(children: [
        for (final r in _results)
          ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(r['error'] != null ? Icons.error_outline : Icons.check_circle_outline, size: 18,
                color: r['error'] != null ? Colors.red : Colors.green),
            title: Text('${r['table']}'),
            subtitle: r['error'] != null ? Text('${r['error']}', style: const TextStyle(color: Colors.red, fontSize: 12))
                : r['skipped'] != null ? Text('${r['skipped']}') : null,
            trailing: Text('${r['inserted']}'),
          ),
      ])),
    ]);
  }
}
