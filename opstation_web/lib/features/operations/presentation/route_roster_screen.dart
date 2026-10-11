import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart' show PdfGoogleFonts;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/pdf/pdf_output.dart';
import '../../../core/permissions/access_control.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Operations ▸ Route Roster (SQL 344).
///
/// A weekly planner: salespersons down the side, Mon–Sun across, each cell the
/// route(s) that person covers that day plus an optional note. Standalone — it
/// does not change route assignments, trips or anything else.
/// Permission "Route Roster": Edit = make changes; Add (view) = view & print.
class RouteRosterScreen extends ConsumerStatefulWidget {
  const RouteRosterScreen({super.key});
  @override
  ConsumerState<RouteRosterScreen> createState() => _RouteRosterScreenState();
}

class _Cell {
  List<String> routes;
  String note;
  String? by;
  _Cell(this.routes, this.note, [this.by]);
  bool get isEmpty => routes.isEmpty && note.trim().isEmpty;
}

class _RouteRosterScreenState extends ConsumerState<RouteRosterScreen> {
  static const _rowH = 66.0;
  static const _nameW = 190.0;
  static const _dayW = 168.0;
  static const _quickNotes = ['Leave', 'Off', 'Office', 'Training', 'Recovery'];

  bool _loading = true;
  String? _error;
  late DateTime _weekStart = _monday(DateTime.now());
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _routes = [];
  final Map<String, Map<String, dynamic>> _routeById = {};
  final Map<String, _Cell> _cells = {}; // '$userId|yyyy-MM-dd'
  int? _restDay; // 0 = Sunday … 6 = Saturday
  String _q = '';

  SupabaseClient get _db => Supabase.instance.client;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  static DateTime _monday(DateTime d) {
    final x = DateTime(d.year, d.month, d.day);
    return x.subtract(Duration(days: x.weekday - DateTime.monday));
  }

  List<DateTime> get _days => [for (var i = 0; i < 7; i++) _weekStart.add(Duration(days: i))];
  static String _ds(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  static String _key(String uid, DateTime d) => '$uid|${_ds(d)}';

  @override
  void initState() {
    super.initState();
    _loadBase().then((_) => _loadWeek());
  }

  Future<void> _loadBase() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final people = await _db
          .from('users')
          .select('id, name, phone, is_active, role')
          .eq('org_id', orgId)
          .eq('role', 'salesperson')
          .order('name');
      final routes = await _db.from('sales_routes').select('id, name, kind, is_active').eq('org_id', orgId).order('name');
      int? rest;
      try {
        final c = await _db.from('app_config').select('value').eq('org_id', orgId).eq('key', 'org.weekly_rest_day').maybeSingle();
        rest = int.tryParse('${c?['value'] ?? ''}');
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _people = List<Map<String, dynamic>>.from(people).where((p) => p['is_active'] != false).toList();
        _routes = List<Map<String, dynamic>>.from(routes);
        _routeById
          ..clear()
          ..addAll({for (final r in _routes) '${r['id']}': r});
        _restDay = rest;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load salespersons / routes: $e');
    }
  }

  Future<void> _loadWeek() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final rows = await _db
          .from('route_roster')
          .select('user_id, day, route_ids, note, updated_by_name')
          .eq('org_id', orgId)
          .gte('day', _ds(_weekStart))
          .lte('day', _ds(_weekStart.add(const Duration(days: 6))));
      _cells.clear();
      for (final r in rows as List) {
        _cells['${r['user_id']}|${r['day']}'] = _Cell(
            List<String>.from((r['route_ids'] as List?) ?? const []),
            (r['note'] as String?) ?? '',
            r['updated_by_name'] as String?);
      }
      if (mounted) setState(() { _loading = false; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().contains('route_roster')
            ? 'Route Roster needs the database update — run 344_route_roster.sql.'
            : 'Could not load the roster: $e';
      });
    }
  }

  void _goWeek(int delta) {
    setState(() => _weekStart = _weekStart.add(Duration(days: 7 * delta)));
    _loadWeek();
  }

  String _routeName(String id) => (_routeById[id]?['name'] as String?) ?? '(removed route)';

  /// Routes given to more than one salesperson on the same day.
  Set<String> _clashes(DateTime d) {
    final seen = <String, int>{};
    for (final p in _people) {
      final c = _cells[_key('${p['id']}', d)];
      if (c == null) continue;
      for (final r in c.routes) {
        seen[r] = (seen[r] ?? 0) + 1;
      }
    }
    return {for (final e in seen.entries) if (e.value > 1) e.key};
  }

  List<Map<String, dynamic>> _uncovered(DateTime d) {
    final covered = <String>{};
    for (final p in _people) {
      covered.addAll(_cells[_key('${p['id']}', d)]?.routes ?? const []);
    }
    return _routes.where((r) => r['is_active'] != false && !covered.contains('${r['id']}')).toList();
  }

  // ── saving ──────────────────────────────────────────────────────────────
  Future<void> _saveCells(String uid, List<DateTime> days, List<String> routes, String note) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final me = ref.read(currentUserProvider);
    final empty = routes.isEmpty && note.trim().isEmpty;
    try {
      if (empty) {
        await _db.from('route_roster').delete().eq('org_id', orgId).eq('user_id', uid).inFilter('day', [for (final d in days) _ds(d)]);
      } else {
        await _db.from('route_roster').upsert([
          for (final d in days)
            {
              'org_id': orgId,
              'user_id': uid,
              'day': _ds(d),
              'route_ids': routes,
              'note': note.trim().isEmpty ? null : note.trim(),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
              'updated_by': me?.id,
              'updated_by_name': me?.name,
            }
        ], onConflict: 'org_id,user_id,day');
      }
      setState(() {
        for (final d in days) {
          if (empty) {
            _cells.remove(_key(uid, d));
          } else {
            _cells[_key(uid, d)] = _Cell(List.of(routes), note.trim(), me?.name);
          }
        }
      });
    } catch (e) {
      _snack('Could not save: $e');
    }
  }

  Future<void> _copyPreviousWeek() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final prevStart = _weekStart.subtract(const Duration(days: 7));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copy previous week?'),
        content: Text(
            'Fills this week from ${DateFormat('d MMM').format(prevStart)} – '
            '${DateFormat('d MMM').format(prevStart.add(const Duration(days: 6)))}, day for day. '
            'Cells you have already filled this week are left as they are.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Copy')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final prev = await _db
          .from('route_roster')
          .select('user_id, day, route_ids, note')
          .eq('org_id', orgId)
          .gte('day', _ds(prevStart))
          .lte('day', _ds(prevStart.add(const Duration(days: 6))));
      final me = ref.read(currentUserProvider);
      final rows = <Map<String, dynamic>>[];
      for (final r in prev as List) {
        final d = DateTime.parse('${r['day']}').add(const Duration(days: 7));
        if (_cells.containsKey(_key('${r['user_id']}', d))) continue; // keep what's there
        rows.add({
          'org_id': orgId,
          'user_id': r['user_id'],
          'day': _ds(d),
          'route_ids': r['route_ids'] ?? const [],
          'note': r['note'],
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'updated_by': me?.id,
          'updated_by_name': me?.name,
        });
      }
      if (rows.isEmpty) {
        _snack('Nothing to copy — last week is empty or this week is already filled.');
        return;
      }
      await _db.from('route_roster').upsert(rows, onConflict: 'org_id,user_id,day');
      await _loadWeek();
      _snack('Copied ${rows.length} cell${rows.length == 1 ? '' : 's'} from last week.');
    } catch (e) {
      _snack('Could not copy: $e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ── cell editor ─────────────────────────────────────────────────────────
  Future<void> _editCell(Map<String, dynamic> person, DateTime day) async {
    final uid = '${person['id']}';
    final cur = _cells[_key(uid, day)];
    final picked = <String>{...?cur?.routes};
    final noteCtrl = TextEditingController(text: cur?.note ?? '');
    final alsoDays = <DateTime>{};
    var search = '';
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final terms = search.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
        final list = _routes.where((r) {
          final id = '${r['id']}';
          if (r['is_active'] == false && !picked.contains(id)) return false;
          if (terms.isEmpty) return true;
          final hay = '${r['name'] ?? ''} ${r['kind'] ?? ''}'.toLowerCase();
          return terms.every(hay.contains);
        }).toList()
          ..sort((a, b) {
            final pa = picked.contains('${a['id']}') ? 0 : 1, pb = picked.contains('${b['id']}') ? 0 : 1;
            return pa != pb ? pa - pb : '${a['name']}'.compareTo('${b['name']}');
          });
        // Who else has each route that day (to avoid double-booking).
        final takenBy = <String, String>{};
        for (final p in _people) {
          if ('${p['id']}' == uid) continue;
          for (final r in _cells[_key('${p['id']}', day)]?.routes ?? const <String>[]) {
            takenBy[r] = '${p['name'] ?? ''}';
          }
        }
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
          contentPadding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          title: Text('${person['name'] ?? ''} · ${DateFormat('EEE d MMM').format(day)}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 520,
            height: 520,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                autofocus: true,
                onChanged: (v) => setD(() => search = v.trim()),
                decoration: const InputDecoration(
                    hintText: 'Search routes…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
              ),
              const SizedBox(height: 6),
              Text('${picked.length} selected', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('No routes match', style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final r = list[i];
                          final id = '${r['id']}';
                          final other = takenBy[id];
                          return CheckboxListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: picked.contains(id),
                            onChanged: (v) => setD(() => v == true ? picked.add(id) : picked.remove(id)),
                            title: Text('${r['name']}${r['is_active'] == false ? ' (inactive)' : ''}', style: const TextStyle(fontSize: 13)),
                            subtitle: other == null
                                ? null
                                : Text('Also planned for $other this day',
                                    style: const TextStyle(fontSize: 11, color: Color(0xFFB45309))),
                          );
                        },
                      ),
              ),
              const Divider(height: 12),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: 'Note (optional)', isDense: true, border: OutlineInputBorder()),
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final n in _quickNotes)
                  ActionChip(
                    label: Text(n, style: const TextStyle(fontSize: 11.5)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setD(() => noteCtrl.text = n),
                  ),
              ]),
              const SizedBox(height: 8),
              const Text('Also apply to', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final d in _days)
                  if (d != day)
                    FilterChip(
                      label: Text(DateFormat('EEE').format(d), style: const TextStyle(fontSize: 11.5)),
                      visualDensity: VisualDensity.compact,
                      selected: alsoDays.contains(d),
                      onSelected: (v) => setD(() => v ? alsoDays.add(d) : alsoDays.remove(d)),
                    ),
              ]),
              const SizedBox(height: 6),
            ]),
          ),
          actions: [
            if (cur != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'clear'),
                style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
                child: const Text('Clear'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
          ],
        );
      }),
    );
    final note = noteCtrl.text;
    noteCtrl.dispose();
    if (res == null) return;
    final days = [day, ...alsoDays];
    if (res == 'clear') {
      await _saveCells(uid, days, const [], '');
    } else {
      await _saveCells(uid, days, picked.toList(), note);
    }
  }

  // ── PDF ─────────────────────────────────────────────────────────────────
  Future<void> _print() async {
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final days = _days;
    final people = _shownPeople;
    pw.ThemeData? theme;
    try {
      theme = pw.ThemeData.withFont(base: await PdfGoogleFonts.notoSansRegular(), bold: await PdfGoogleFonts.notoSansBold());
    } catch (_) {}
    final doc = pw.Document(theme: theme);
    const head = PdfColor.fromInt(0xFF1E293B);
    const rest = PdfColor.fromInt(0xFFF1F5F9);
    String cellText(String uid, DateTime d) {
      final c = _cells[_key(uid, d)];
      if (c == null) return '';
      return [
        if (c.routes.isNotEmpty) c.routes.map(_routeName).join(', '),
        if (c.note.trim().isNotEmpty) '(${c.note.trim()})',
      ].join('\n');
    }

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(22),
      header: (_) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(org.toUpperCase(), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, letterSpacing: 1)),
              pw.Text('Route Roster', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
              pw.Text('Week of ${DateFormat('d MMM').format(days.first)} – ${DateFormat('d MMM yyyy').format(days.last)}',
                  style: const pw.TextStyle(fontSize: 10)),
            ]),
          ),
          pw.Text('Printed ${DateFormat('d MMM yyyy, h:mm a').format(DateTime.now())}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        ]),
      ),
      build: (_) => [
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          columnWidths: {0: const pw.FlexColumnWidth(1.5), for (var i = 1; i <= 7; i++) i: const pw.FlexColumnWidth(1.2)},
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: head),
              children: [
                pw.Padding(
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Text('Salesperson', style: pw.TextStyle(color: PdfColors.white, fontSize: 9, fontWeight: pw.FontWeight.bold))),
                for (final d in days)
                  pw.Padding(
                      padding: const pw.EdgeInsets.all(5),
                      child: pw.Text(DateFormat('EEE d MMM').format(d),
                          style: pw.TextStyle(color: PdfColors.white, fontSize: 9, fontWeight: pw.FontWeight.bold))),
              ],
            ),
            for (final p in people)
              pw.TableRow(children: [
                pw.Padding(
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Text('${p['name'] ?? ''}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                for (final d in days)
                  pw.Container(
                    color: _isRest(d) ? rest : null,
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Text(cellText('${p['id']}', d), style: const pw.TextStyle(fontSize: 8.5)),
                  ),
              ]),
          ],
        ),
      ],
    ));
    await outputPdf(await doc.save(), 'Route Roster ${DateFormat('d MMM').format(days.first)}', date: days.first);
  }

  bool _isRest(DateTime d) => _restDay != null && d.weekday % 7 == _restDay;

  List<Map<String, dynamic>> get _shownPeople {
    if (_q.isEmpty) return _people;
    final t = _q.toLowerCase();
    return _people.where((p) => '${p['name'] ?? ''} ${p['phone'] ?? ''}'.toLowerCase().contains(t)).toList();
  }

  // ── UI ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final access = ref.watch(accessSyncProvider);
    final canEdit = access?.canEditDoc('route_roster') ?? false;
    final narrow = MediaQuery.of(context).size.width < 700;
    final days = _days;
    final today = DateTime.now();
    final isThisWeek = _weekStart == _monday(today);
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 12 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Route Roster', style: TextStyle(fontSize: narrow ? 20 : 24, fontWeight: FontWeight.w800)),
          if (!canEdit)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(6)),
              child: const Text('View only', style: TextStyle(fontSize: 11)),
            ),
        ]),
        const SizedBox(height: 4),
        Text(canEdit
                ? 'Plan which salesperson covers which routes each day. Tap a cell to edit.'
                : 'Weekly plan of salespersons and routes.',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(onPressed: () => _goWeek(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Previous week'),
          InkWell(
            onTap: () async {
              final d = await showDatePicker(
                  context: context, initialDate: _weekStart, firstDate: DateTime(2024), lastDate: DateTime(today.year + 2));
              if (d != null) {
                setState(() => _weekStart = _monday(d));
                _loadWeek();
              }
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.calendar_month_outlined, size: 16, color: AppTheme.textSecondary),
                const SizedBox(width: 8),
                Text('${DateFormat('d MMM').format(days.first)} – ${DateFormat('d MMM yyyy').format(days.last)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          IconButton(onPressed: () => _goWeek(1), icon: const Icon(Icons.chevron_right), tooltip: 'Next week'),
          if (!isThisWeek)
            TextButton(
              onPressed: () {
                setState(() => _weekStart = _monday(today));
                _loadWeek();
              },
              child: const Text('This week'),
            ),
          SizedBox(
            width: 220,
            child: TextField(
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: const InputDecoration(
                  hintText: 'Search salesperson', prefixIcon: Icon(Icons.search, size: 18), isDense: true,
                  filled: true, fillColor: Colors.white, border: OutlineInputBorder()),
            ),
          ),
          if (canEdit)
            OutlinedButton.icon(
              onPressed: _loading ? null : _copyPreviousWeek,
              icon: const Icon(Icons.content_copy_outlined, size: 16),
              label: const Text('Copy previous week'),
            ),
          ElevatedButton.icon(
            onPressed: _loading || _people.isEmpty ? null : _print,
            icon: const Icon(Icons.print_outlined, size: 16),
            label: const Text('PDF / Print'),
          ),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.danger)))
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _people.isEmpty
                      ? const Center(
                          child: Text('No active salespersons. Add them in Operations ▸ Team.',
                              style: TextStyle(color: AppTheme.textSecondary)))
                      : _grid(canEdit),
        ),
      ]),
    );
  }

  Widget _grid(bool canEdit) {
    final days = _days;
    final people = _shownPeople;
    final clashes = {for (final d in days) _ds(d): _clashes(d)};
    final todayS = _ds(DateTime.now());
    const line = BorderSide(color: AppTheme.border);

    Widget headCell(DateTime d) {
      final isToday = _ds(d) == todayS;
      return Container(
        width: _dayW,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isToday ? AppTheme.primary.withOpacity(0.10) : (_isRest(d) ? const Color(0xFFF1F5F9) : AppTheme.background),
          border: const Border(left: line, bottom: line),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(DateFormat('EEEE').format(d),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isToday ? AppTheme.primary : AppTheme.textPrimary)),
          Text('${DateFormat('d MMM').format(d)}${_isRest(d) ? ' · rest day' : ''}',
              style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        ]),
      );
    }

    Widget cell(Map<String, dynamic> p, DateTime d) {
      final c = _cells[_key('${p['id']}', d)];
      final clash = c != null && c.routes.any(clashes[_ds(d)]!.contains);
      final names = c?.routes.map(_routeName).toList() ?? const <String>[];
      final child = Container(
        width: _dayW,
        height: _rowH,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: clash
              ? const Color(0xFFFFF7E6)
              : (_isRest(d) ? const Color(0xFFF8FAFC) : Colors.white),
          border: Border(
            left: line,
            bottom: line,
            top: clash ? const BorderSide(color: Color(0xFFF5C26B)) : BorderSide.none,
          ),
        ),
        child: c == null
            ? (canEdit ? const Center(child: Icon(Icons.add, size: 16, color: Color(0xFFCBD5E1))) : const SizedBox.shrink())
            : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                if (names.isNotEmpty)
                  Text(names.join(', '),
                      maxLines: c.note.trim().isEmpty ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.25)),
                if (c.note.trim().isNotEmpty)
                  Text(c.note.trim(),
                      maxLines: names.isEmpty ? 3 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: names.isEmpty ? const Color(0xFF7C3AED) : AppTheme.textSecondary)),
              ]),
      );
      final tip = clash ? 'A route here is also planned for another salesperson this day' : null;
      final w = canEdit ? InkWell(onTap: () => _editCell(p, d), child: child) : child;
      return tip == null ? w : Tooltip(message: tip, child: w);
    }

    Widget footCell(DateTime d) {
      final un = _uncovered(d);
      final active = _routes.where((r) => r['is_active'] != false).length;
      return InkWell(
        onTap: un.isEmpty
            ? null
            : () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Not planned · ${DateFormat('EEE d MMM').format(d)}', style: const TextStyle(fontSize: 15)),
                    content: SizedBox(
                      width: 360,
                      height: 360,
                      child: ListView(children: [
                        for (final r in un) ListTile(dense: true, leading: const Icon(Icons.route_outlined, size: 18), title: Text('${r['name']}')),
                      ]),
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                  ),
                ),
        child: Container(
          width: _dayW,
          height: 40,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: AppTheme.background, border: Border(left: line)),
          child: Text('${active - un.length}/$active routes planned',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: un.isEmpty ? AppTheme.success : AppTheme.textSecondary,
                  decoration: un.isEmpty ? null : TextDecoration.underline)),
        ),
      );
    }

    final nameCol = Column(children: [
      Container(
        width: _nameW,
        height: 44,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(color: AppTheme.background, border: Border(bottom: line)),
        child: Text('Salesperson (${people.length})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ),
      for (final p in people)
        Container(
          width: _nameW,
          height: _rowH,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: line)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            if ((p['phone'] as String?)?.isNotEmpty == true)
              Text('${p['phone']}', style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
          ]),
        ),
      Container(
        width: _nameW,
        height: 40,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: AppTheme.background,
        child: const Text('Coverage', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
      ),
    ]);

    final daysCols = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final d in days)
        Column(children: [
          headCell(d),
          for (final p in people) cell(p, d),
          footCell(d),
        ]),
    ]);

    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          nameCol,
          Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: daysCols)),
        ]),
      ),
    );
  }
}
