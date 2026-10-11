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
///
/// Auto-carry (org setting ops.route_roster_autocopy, ON by default): a cell
/// with nothing saved for that week shows the latest earlier plan for the same
/// salesperson and weekday. Editing a cell saves it for that week only (and
/// carries forward from there). Clearing saves an explicit blank so it does not
/// pick the old plan back up.
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
  bool _narrow = false;
  double get _rowH => _narrow ? 72.0 : 66.0;
  double get _nameW => _narrow ? 108.0 : 190.0;
  double get _dayW => _narrow ? 116.0 : 168.0;
  static const _quickNotes = ['Leave', 'Off', 'Office', 'Training', 'Recovery'];

  bool _loading = true;
  String? _error;
  late DateTime _weekStart = _monday(DateTime.now());
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _routes = [];
  final Map<String, Map<String, dynamic>> _routeById = {};
  final Map<String, _Cell> _cells = {};   // saved for this week: '$userId|yyyy-MM-dd'
  final Map<String, _Cell> _carried = {}; // carried over from an earlier week (auto-carry)
  bool _autoCopy = true;                  // org setting, ON unless turned off
  // Roster type (org setting ops.route_roster_mode): 'standing' = one plan per
  // weekday, no dates, valid until changed; 'dated' = week-by-week plan.
  String? _mode;
  bool get _standing => _mode == 'standing';
  DateTime? _standingFrom; // last change to the standing roster
  String? _standingBy;
  bool _askedMode = false;
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
  String _key(String uid, DateTime d) => '$uid|${_standing ? 'w${d.weekday}' : _ds(d)}';

  @override
  void initState() {
    super.initState();
    _loadBase().then((_) async {
      await _loadWeek();
      await _askModeIfUnset();
    });
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
      var auto = true;
      String? mode;
      try {
        final cfg = await _db.from('app_config').select('key, value').eq('org_id', orgId)
            .inFilter('key', ['org.weekly_rest_day', 'ops.route_roster_autocopy', 'ops.route_roster_mode']);
        for (final c in cfg as List) {
          if (c['key'] == 'ops.route_roster_mode') mode = '${c['value']}' == 'standing' ? 'standing' : 'dated';
          if (c['key'] == 'org.weekly_rest_day') rest = int.tryParse('${c['value'] ?? ''}');
          if (c['key'] == 'ops.route_roster_autocopy') auto = '${c['value']}' != 'false';
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _people = List<Map<String, dynamic>>.from(people).where((p) => p['is_active'] != false).toList();
        _routes = List<Map<String, dynamic>>.from(routes);
        _routeById
          ..clear()
          ..addAll({for (final r in _routes) '${r['id']}': r});
        _restDay = rest;
        _autoCopy = auto;
        _mode = mode;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load salespersons / routes: $e');
    }
  }

  Future<void> _loadWeek() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    if (_standing) {
      try {
        final rows = await _db
            .from('route_roster_standing')
            .select('user_id, weekday, route_ids, note, updated_at, updated_by_name')
            .eq('org_id', orgId);
        _cells.clear();
        _carried.clear();
        DateTime? last;
        String? lastBy;
        for (final r in rows as List) {
          _cells['${r['user_id']}|w${r['weekday']}'] = _Cell(
              List<String>.from((r['route_ids'] as List?) ?? const []),
              (r['note'] as String?) ?? '',
              r['updated_by_name'] as String?);
          final at = DateTime.tryParse('${r['updated_at']}');
          if (at != null && (last == null || at.isAfter(last))) {
            last = at;
            lastBy = r['updated_by_name'] as String?;
          }
        }
        // Clearing a cell deletes its row, so also look at the change log.
        try {
          final lg = await _db.from('route_roster_log').select('changed_at, changed_by_name')
              .eq('org_id', orgId).eq('kind', 'standing').order('changed_at', ascending: false).limit(1);
          if ((lg as List).isNotEmpty) {
            final at = DateTime.tryParse('${lg.first['changed_at']}');
            if (at != null && (last == null || at.isAfter(last))) {
              last = at;
              lastBy = lg.first['changed_by_name'] as String?;
            }
          }
        } catch (_) {}
        if (mounted) setState(() { _standingFrom = last?.toLocal(); _standingBy = lastBy; _loading = false; _error = null; });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = e.toString().contains('route_roster_standing')
              ? 'Standing roster needs the database update — run 345_route_roster_standing_log.sql.'
              : 'Could not load the roster: $e';
        });
      }
      return;
    }
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
      // Auto-carry: latest earlier saved plan per salesperson + weekday
      // (looks back up to 26 weeks).
      _carried.clear();
      if (_autoCopy) {
        final prev = await _db
            .from('route_roster')
            .select('user_id, day, route_ids, note')
            .eq('org_id', orgId)
            .lt('day', _ds(_weekStart))
            .gte('day', _ds(_weekStart.subtract(const Duration(days: 182))))
            .order('day', ascending: false);
        final seen = <String>{};
        for (final r in prev as List) {
          final d = DateTime.parse('${r['day']}');
          final slot = '${r['user_id']}|${d.weekday}';
          if (!seen.add(slot)) continue; // newest first — keep the latest only
          final c = _Cell(List<String>.from((r['route_ids'] as List?) ?? const []), (r['note'] as String?) ?? '');
          if (c.isEmpty) continue; // latest plan was an explicit blank
          final target = _weekStart.add(Duration(days: d.weekday - 1));
          _carried[_key('${r['user_id']}', target)] = c;
        }
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

  /// What the cell shows: saved for this week, else carried over.
  _Cell? _eff(String uid, DateTime d) {
    final k = _key(uid, d);
    final own = _cells[k];
    if (own != null) return own.isEmpty ? null : own;
    return (!_standing && _autoCopy) ? _carried[k] : null;
  }

  bool _isCarried(String uid, DateTime d) =>
      !_standing && !_cells.containsKey(_key(uid, d)) && _autoCopy && _carried.containsKey(_key(uid, d));

  Future<void> _setAutoCopy(bool v) async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      await _db.from('app_config').delete().eq('org_id', orgId).eq('key', 'ops.route_roster_autocopy');
      await _db.from('app_config').insert({'org_id': orgId, 'key': 'ops.route_roster_autocopy', 'value': v ? 'true' : 'false'});
      setState(() => _autoCopy = v);
      await _logSetting('Auto-carry to next weeks turned ${v ? 'on' : 'off'}');
      await _loadWeek();
      _snack(v ? 'Auto-carry on — weeks without changes follow the last plan.' : 'Auto-carry off — each week starts empty.');
    } catch (e) {
      _snack('Could not change the setting: $e');
    }
  }

  Future<void> _logSetting(String detail) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final me = ref.read(currentUserProvider);
    try {
      await _db.from('route_roster_log').insert({
        'org_id': orgId, 'kind': 'setting', 'action': 'setting', 'detail': detail,
        'changed_by': me?.id, 'changed_by_name': me?.name,
      });
    } catch (_) {}
  }

  bool get _canEdit => ref.read(accessSyncProvider)?.canEditDoc('route_roster') ?? false;

  /// First time an editor opens the roster: pick the roster type.
  Future<void> _askModeIfUnset() async {
    if (_mode != null || _askedMode || !_canEdit || !mounted) return;
    _askedMode = true;
    final m = await _chooseModeDialog(first: true);
    if (m != null) await _switchMode(m, confirm: false);
  }

  Future<String?> _chooseModeDialog({bool first = false}) => showDialog<String>(
        context: context,
        barrierDismissible: !first,
        builder: (ctx) => AlertDialog(
          title: Text(first ? 'How should this roster work?' : 'Roster type'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.push_pin_outlined, color: AppTheme.primary),
                title: const Text('Standing roster', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('One plan for Monday to Sunday, no dates. Stays valid until someone changes it. '
                    'Print shows "effective from" the last change.'),
                selected: _mode == 'standing',
                onTap: () => Navigator.pop(ctx, 'standing'),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.date_range_outlined, color: AppTheme.primary),
                title: const Text('Date-bound roster', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('A plan for each calendar week with dates. Weeks you don\'t change follow the '
                    'last plan (auto-carry), and you can adjust any specific week.'),
                selected: _mode == 'dated',
                onTap: () => Navigator.pop(ctx, 'dated'),
              ),
            ]),
          ),
          actions: [if (!first) TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        ),
      );

  /// Switch roster type. The new type starts from what is on screen now
  /// (standing ← this week's plan; date-bound ← the standing plan for this week),
  /// only where the new type has nothing yet.
  Future<void> _switchMode(String m, {bool confirm = true}) async {
    final orgId = _orgId;
    if (orgId == null || m == _mode) return;
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Switch to ${m == 'standing' ? 'Standing' : 'Date-bound'} roster?'),
          content: Text(m == 'standing'
              ? 'The roster becomes one Monday–Sunday plan with no dates. It starts from the plan shown for this week '
                  '(where the standing roster is empty). The date-bound plans are kept and come back if you switch again.'
              : 'The roster becomes week-by-week with dates. This week starts from the standing plan '
                  '(where this week is empty). The standing plan is kept and comes back if you switch again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Switch')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final me = ref.read(currentUserProvider);
    final now = DateTime.now().toUtc().toIso8601String();
    // what is on screen now, before switching
    final onScreen = <(String, int, _Cell)>[];
    for (final p in _people) {
      for (final d in _days) {
        final c = _eff('${p['id']}', d);
        if (c != null) onScreen.add(('${p['id']}', d.weekday, c));
      }
    }
    try {
      if (m == 'standing') {
        final have = await _db.from('route_roster_standing').select('user_id, weekday').eq('org_id', orgId);
        final taken = {for (final r in have as List) '${r['user_id']}|${r['weekday']}'};
        final rows = [
          for (final (uid, wd, c) in onScreen)
            if (!taken.contains('$uid|$wd'))
              {'org_id': orgId, 'user_id': uid, 'weekday': wd, 'route_ids': c.routes,
               'note': c.note.trim().isEmpty ? null : c.note.trim(),
               'updated_at': now, 'updated_by': me?.id, 'updated_by_name': me?.name},
        ];
        if (rows.isNotEmpty) await _db.from('route_roster_standing').upsert(rows, onConflict: 'org_id,user_id,weekday');
      } else if (_mode == 'standing') {
        final rows = [
          for (final (uid, wd, c) in onScreen)
              {'org_id': orgId, 'user_id': uid, 'day': _ds(_weekStart.add(Duration(days: wd - 1))), 'route_ids': c.routes,
               'note': c.note.trim().isEmpty ? null : c.note.trim(),
               'updated_at': now, 'updated_by': me?.id, 'updated_by_name': me?.name},
        ];
        if (rows.isNotEmpty) {
          // only where this week has nothing saved
          final have = await _db.from('route_roster').select('user_id, day').eq('org_id', orgId)
              .gte('day', _ds(_weekStart)).lte('day', _ds(_weekStart.add(const Duration(days: 6))));
          final taken = {for (final r in have as List) '${r['user_id']}|${r['day']}'};
          final fresh = rows.where((r) => !taken.contains('${r['user_id']}|${r['day']}')).toList();
          if (fresh.isNotEmpty) await _db.from('route_roster').upsert(fresh, onConflict: 'org_id,user_id,day');
        }
      }
      await _db.from('app_config').delete().eq('org_id', orgId).eq('key', 'ops.route_roster_mode');
      await _db.from('app_config').insert({'org_id': orgId, 'key': 'ops.route_roster_mode', 'value': m});
      await _logSetting('Roster type set to ${m == 'standing' ? 'Standing' : 'Date-bound'}');
      setState(() => _mode = m);
      await _loadWeek();
    } catch (e) {
      _snack(e.toString().contains('route_roster_standing')
          ? 'Standing roster needs the database update — run 345_route_roster_standing_log.sql.'
          : 'Could not switch: $e');
    }
  }

  /// Routes given to more than one salesperson on the same day.
  Set<String> _clashes(DateTime d) {
    final seen = <String, int>{};
    for (final p in _people) {
      final c = _eff('${p['id']}', d);
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
      covered.addAll(_eff('${p['id']}', d)?.routes ?? const []);
    }
    return _routes.where((r) => r['is_active'] != false && !covered.contains('${r['id']}')).toList();
  }

  // ── saving ──────────────────────────────────────────────────────────────
  /// [revert] removes this week's saved cell so it follows the carried plan again.
  Future<void> _saveCells(String uid, List<DateTime> days, List<String> routes, String note, {bool revert = false}) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final me = ref.read(currentUserProvider);
    // With auto-carry on, a cleared cell is saved as an explicit blank so it
    // doesn't pick last week's plan back up.
    final empty = revert || (routes.isEmpty && note.trim().isEmpty && (!_autoCopy || _standing));
    try {
      if (_standing) {
        final wds = {for (final d in days) d.weekday}.toList();
        if (empty) {
          await _db.from('route_roster_standing').delete().eq('org_id', orgId).eq('user_id', uid).inFilter('weekday', wds);
        } else {
          await _db.from('route_roster_standing').upsert([
            for (final wd in wds)
              {
                'org_id': orgId, 'user_id': uid, 'weekday': wd, 'route_ids': routes,
                'note': note.trim().isEmpty ? null : note.trim(),
                'updated_at': DateTime.now().toUtc().toIso8601String(),
                'updated_by': me?.id, 'updated_by_name': me?.name,
              }
          ], onConflict: 'org_id,user_id,weekday');
        }
        _standingFrom = DateTime.now();
        _standingBy = me?.name;
      } else if (empty) {
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
    final saved = _cells[_key(uid, day)];
    final carried = _isCarried(uid, day);
    final cur = _eff(uid, day);
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
          for (final r in _eff('${p['id']}', day)?.routes ?? const <String>[]) {
            takenBy[r] = '${p['name'] ?? ''}';
          }
        }
        final title = '${person['name'] ?? ''} · ${DateFormat(_standing ? 'EEEE' : 'EEE d MMM').format(day)}';
        final form = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (carried)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(6)),
                  child: const Text('Carried over from an earlier week. Saving makes it this week\'s own plan.',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF1D4ED8))),
                ),
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
            ]);
        final actions = <Widget>[
          if (saved != null && _autoCopy)
            TextButton(onPressed: () => Navigator.pop(ctx, 'revert'), child: const Text('Use carried plan')),
          if (cur != null || saved != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'clear'),
              style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
              child: const Text('Clear'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ];
        if (_narrow) {
          // Phone: full screen, so search + list + note + Save fit with the keyboard open.
          return Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save'))],
              ),
              body: Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 0), child: form),
              bottomNavigationBar: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Wrap(alignment: WrapAlignment.end, spacing: 4, children: actions.sublist(0, actions.length - 2)),
                ),
              ),
            ),
          );
        }
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
          contentPadding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          content: SizedBox(width: 520, height: 540, child: form),
          actions: actions,
        );
      }),
    );
    final note = noteCtrl.text;
    noteCtrl.dispose();
    if (res == null) return;
    final days = [day, ...alsoDays];
    if (res == 'revert') {
      await _saveCells(uid, [day], const [], '', revert: true);
    } else if (res == 'clear') {
      await _saveCells(uid, days, const [], '');
    } else {
      await _saveCells(uid, days, picked.toList(), note);
    }
  }

  // ── History (lifecycle) ───────────────────────────────────────────────────
  Future<void> _openHistory() async {
    final orgId = _orgId;
    if (orgId == null) return;
    List<Map<String, dynamic>> rows = [];
    String? err;
    try {
      rows = List<Map<String, dynamic>>.from(await _db
          .from('route_roster_log')
          .select()
          .eq('org_id', orgId)
          .order('changed_at', ascending: false)
          .limit(500));
    } catch (e) {
      err = e.toString().contains('route_roster_log')
          ? 'History needs the database update — run 345_route_roster_standing_log.sql.'
          : 'Could not load history: $e';
    }
    if (!mounted) return;
    final nameOf = {for (final p in _people) '${p['id']}': '${p['name'] ?? ''}'};
    String routesText(List? ids) {
      final l = List<String>.from(ids ?? const []);
      return l.isEmpty ? '—' : l.map(_routeName).join(', ');
    }
    String? who = 'all';
    String kind = 'all';
    const dayNames = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final shown = rows.where((r) {
          if (kind != 'all' && r['kind'] != kind) return false;
          if (who != 'all' && r['user_id'] != who) return false;
          return true;
        }).toList();
        final filters = Wrap(spacing: 8, runSpacing: 8, children: [
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String>(
              value: who,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Salesperson', isDense: true, border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All')),
                for (final p in _people) DropdownMenuItem(value: '${p['id']}', child: Text('${p['name'] ?? ''}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setD(() => who = v ?? 'all'),
            ),
          ),
          SizedBox(
            width: 170,
            child: DropdownButtonFormField<String>(
              value: kind,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Show', isDense: true, border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('Everything')),
                DropdownMenuItem(value: 'standing', child: Text('Standing roster')),
                DropdownMenuItem(value: 'dated', child: Text('Date-bound roster')),
                DropdownMenuItem(value: 'setting', child: Text('Settings')),
              ],
              onChanged: (v) => setD(() => kind = v ?? 'all'),
            ),
          ),
        ]);
        final list = err != null
            ? Center(child: Text(err!, style: const TextStyle(color: AppTheme.danger)))
            : shown.isEmpty
                ? const Center(child: Text('No changes recorded yet.', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: shown.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = shown[i];
                      final at = DateTime.tryParse('${r['changed_at']}')?.toLocal();
                      final whenWho = '${at == null ? '' : DateFormat('d MMM yyyy, h:mm a').format(at)} · ${r['changed_by_name'] ?? '—'}';
                      if (r['kind'] == 'setting') {
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.settings_outlined, size: 18, color: AppTheme.textSecondary),
                          title: Text('${r['detail'] ?? ''}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          subtitle: Text(whenWho, style: const TextStyle(fontSize: 11.5)),
                        );
                      }
                      final slot = r['kind'] == 'standing'
                          ? '${dayNames[(r['weekday'] as int?) ?? 0]} (standing)'
                          : DateFormat('EEE d MMM yyyy').format(DateTime.parse('${r['day']}'));
                      final cleared = r['action'] == 'cleared';
                      final oldN = ((r['old_note'] as String?) ?? '').trim();
                      final newN = ((r['new_note'] as String?) ?? '').trim();
                      return ListTile(
                        dense: true,
                        leading: Icon(cleared ? Icons.backspace_outlined : Icons.edit_calendar_outlined,
                            size: 18, color: cleared ? AppTheme.danger : AppTheme.primary),
                        title: Text('${nameOf[r['user_id']] ?? 'Salesperson'} · $slot',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const SizedBox(height: 2),
                          Text.rich(TextSpan(children: [
                            const TextSpan(text: 'Routes: '),
                            if (r['old_routes'] != null)
                              TextSpan(text: routesText(r['old_routes'] as List?),
                                  style: const TextStyle(decoration: TextDecoration.lineThrough, color: AppTheme.textSecondary)),
                            if (r['old_routes'] != null) const TextSpan(text: '  →  '),
                            TextSpan(text: cleared ? 'cleared' : routesText(r['new_routes'] as List?),
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ]), style: const TextStyle(fontSize: 12)),
                          if (oldN != newN)
                            Text('Note: ${oldN.isEmpty ? '—' : oldN}  →  ${newN.isEmpty ? '—' : newN}', style: const TextStyle(fontSize: 12)),
                          Text(whenWho, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ]),
                      );
                    },
                  );
        final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          filters,
          const SizedBox(height: 6),
          Text('${shown.length} change${shown.length == 1 ? '' : 's'} (latest 500)',
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          Expanded(child: list),
        ]);
        if (_narrow) {
          return Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Roster history', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ),
              body: Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 0), child: body),
            ),
          );
        }
        return AlertDialog(
          title: const Text('Roster history', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          content: SizedBox(width: 640, height: 520, child: body),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        );
      }),
    );
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
      final c = _eff(uid, d);
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
              pw.Text(
                  _standing
                      ? 'Effective from ${_standingFrom != null ? DateFormat('d MMM yyyy').format(_standingFrom!) : DateFormat('d MMM yyyy').format(DateTime.now())} onwards - valid until changed'
                      : 'Week of ${DateFormat('d MMM').format(days.first)} – ${DateFormat('d MMM yyyy').format(days.last)}',
                  style: const pw.TextStyle(fontSize: 10)),
            ]),
          ),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('Generated by ${ref.read(currentUserProvider)?.name ?? '-'}',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
            pw.Text(DateFormat('d MMM yyyy, h:mm a').format(DateTime.now()),
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
          ]),
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
                      child: pw.Text(DateFormat(_standing ? 'EEEE' : 'EEE d MMM').format(d),
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
    await outputPdf(await doc.save(), _standing ? 'Route Roster' : 'Route Roster ${DateFormat('d MMM').format(days.first)}',
        date: _standing ? DateTime.now() : days.first);
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
    _narrow = narrow;
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
        Text(
            _standing
                ? 'Standing roster — one Monday–Sunday plan, valid until changed.'
                    '${_standingFrom != null ? ' Effective from ${DateFormat('d MMM yyyy').format(_standingFrom!)}${_standingBy != null ? ' (updated by $_standingBy)' : ''}.' : ''}'
                    '${canEdit ? ' Tap a cell to edit.' : ''}'
                : (canEdit
                    ? 'Date-bound roster — plan each week. Tap a cell to edit.'
                        '${_autoCopy ? ' Faded cells are carried over from an earlier week.' : ''}'
                    : 'Date-bound roster — weekly plan of salespersons and routes.'),
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (!_standing) ...[
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
          ],
          SizedBox(
            width: 220,
            child: TextField(
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: const InputDecoration(
                  hintText: 'Search salesperson', prefixIcon: Icon(Icons.search, size: 18), isDense: true,
                  filled: true, fillColor: Colors.white, border: OutlineInputBorder()),
            ),
          ),
          if (!_standing)
          Tooltip(
            message: 'When on, a week with no changes follows the last saved plan for each salesperson and day.',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(value: _autoCopy, onChanged: canEdit && !_loading ? _setAutoCopy : null),
              const Text('Auto-carry to next weeks', style: TextStyle(fontSize: 12.5)),
            ]),
          ),
          if (canEdit && !_autoCopy && !_standing)
            OutlinedButton.icon(
              onPressed: _loading ? null : _copyPreviousWeek,
              icon: const Icon(Icons.content_copy_outlined, size: 16),
              label: const Text('Copy previous week'),
            ),
          if (canEdit)
            OutlinedButton.icon(
              onPressed: _loading
                  ? null
                  : () async {
                      final m = await _chooseModeDialog();
                      if (m != null) await _switchMode(m);
                    },
              icon: Icon(_standing ? Icons.push_pin_outlined : Icons.date_range_outlined, size: 16),
              label: Text(_standing ? 'Type: Standing' : 'Type: Date-bound'),
            ),
          OutlinedButton.icon(
            onPressed: _openHistory,
            icon: const Icon(Icons.history, size: 16),
            label: const Text('History'),
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
      final isToday = _standing ? d.weekday == DateTime.now().weekday : _ds(d) == todayS;
      return Container(
        width: _dayW,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isToday ? AppTheme.primary.withOpacity(0.10) : (_isRest(d) ? const Color(0xFFF1F5F9) : AppTheme.background),
          border: const Border(left: line, bottom: line),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(DateFormat(_narrow ? 'EEE' : 'EEEE').format(d),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isToday ? AppTheme.primary : AppTheme.textPrimary)),
          Text(_standing
                  ? (_isRest(d) ? 'rest day' : '')
                  : '${DateFormat('d MMM').format(d)}${_isRest(d) ? (_narrow ? ' · rest' : ' · rest day') : ''}',
              style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        ]),
      );
    }

    Widget cell(Map<String, dynamic> p, DateTime d) {
      final c = _eff('${p['id']}', d);
      final carried = c != null && _isCarried('${p['id']}', d);
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
                      style: TextStyle(
                          fontSize: _narrow ? 10.5 : 11.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          color: carried ? AppTheme.textSecondary : AppTheme.textPrimary)),
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
      final tip = clash
          ? 'A route here is also planned for another salesperson this day'
          : (carried ? 'Carried over from an earlier week' : null);
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
                    title: Text('Not planned · ${DateFormat(_standing ? 'EEEE' : 'EEE d MMM').format(d)}', style: const TextStyle(fontSize: 15)),
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
          child: Text(_narrow ? '${active - un.length}/$active' : '${active - un.length}/$active routes planned',
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
        child: Text(_narrow ? 'Salesperson' : 'Salesperson (${people.length})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ),
      for (final p in people)
        Container(
          width: _nameW,
          height: _rowH,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: line)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['name'] ?? ''}', maxLines: _narrow ? 2 : 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: _narrow ? 11.5 : 12.5, fontWeight: FontWeight.w700)),
            if (!_narrow && (p['phone'] as String?)?.isNotEmpty == true)
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
