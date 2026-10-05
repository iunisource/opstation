// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Duty Roster (Manufacturing ▸ Duty Roster, SQL 319).
///
/// Who works on which station / line each day.
///  • Week view — workers down the side, Mon–Sun across. Tap a cell to set the
///    station or Off; row menu fills the whole week; "Copy last week" plans fast.
///  • Day view — a board per station showing who is on it today.
/// Attendance is read-only here: rostered people who are absent / on leave that
/// day are flagged so a supervisor can reassign. Payroll is not affected.
class ErpDutyRosterScreen extends ConsumerStatefulWidget {
  const ErpDutyRosterScreen({super.key});
  @override
  ConsumerState<ErpDutyRosterScreen> createState() => _ErpDutyRosterScreenState();
}

const _palette = ['#2F6FED', '#0EA5E9', '#14B8A6', '#22C55E', '#EAB308', '#F97316', '#EF4444', '#EC4899', '#8B5CF6', '#64748B'];
Color _hex(String? h) {
  final s = (h ?? '#2F6FED').replaceAll('#', '');
  return Color(int.tryParse('FF$s', radix: 16) ?? 0xFF2F6FED);
}

class _ErpDutyRosterScreenState extends ConsumerState<ErpDutyRosterScreen> {
  bool _loading = true;
  String? _error;
  String _view = 'week'; // week | day
  late DateTime _weekStart; // Monday
  late DateTime _day;
  String _search = '';
  String? _deptFilter;

  List<Map<String, dynamic>> _stations = [];
  List<Map<String, dynamic>> _employees = [];
  final Map<String, String> _deptName = {};
  final Map<String, Map<String, dynamic>> _roster = {}; // '$emp|$yyyy-MM-dd' -> row
  final Map<String, String> _att = {};                 // '$emp|$date' -> absent | leave | half_day …
  final Set<String> _hidden = {};                      // employees hidden from the roster (SQL 320)
  bool _showHidden = false;
  final Set<String> _sel = {};                         // multi-select (week grid)

  final _dk = DateFormat('yyyy-MM-dd');
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  SupabaseClient get _c => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    final t = DateTime.now();
    final today = DateTime(t.year, t.month, t.day);
    _weekStart = today.subtract(Duration(days: today.weekday - 1));
    _day = today;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  List<DateTime> get _days => [for (var i = 0; i < 7; i++) _weekStart.add(Duration(days: i))];
  String _key(String emp, DateTime d) => '$emp|${_dk.format(d)}';
  Map<String, dynamic>? _station(String? id) {
    if (id == null) return null;
    for (final s in _stations) { if (s['id'] == id) return s; }
    return null;
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  // ── Data ─────────────────────────────────────────────────────────────────
  Future<void> _loadAll() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _loadAll(); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final st = await _c.from('duty_stations').select().eq('org_id', orgId).order('sort_order').order('name');
      final emps = await _c.from('hr_employees').select().eq('org_id', orgId).order('full_name');
      try {
        for (final d in await _c.from('hr_departments').select('id, name').eq('org_id', orgId) as List) {
          _deptName['${d['id']}'] = '${d['name'] ?? ''}';
        }
      } catch (_) {}
      _stations = List<Map<String, dynamic>>.from(st as List);
      _hidden.clear();
      try {
        for (final h in await _c.from('duty_roster_hidden').select('employee_id').eq('org_id', orgId) as List) {
          _hidden.add('${h['employee_id']}');
        }
      } catch (_) {} // SQL 320 not run yet — nobody hidden
      _employees = List<Map<String, dynamic>>.from(emps as List).where((e) {
        if (e['is_voided'] == true) return false;
        final s = '${e['status'] ?? 'active'}';
        if (s == 'left' || s == 'inactive') return false;
        final ap = e['approval_status'];
        return ap == null || ap == 'approved';
      }).toList();
      await _loadRange();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  /// Roster + attendance + approved leave for the visible week (or the day's week).
  Future<void> _loadRange() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final from = _view == 'week' ? _weekStart : _day;
    final to = _view == 'week' ? _weekStart.add(const Duration(days: 6)) : _day;
    try {
      final rows = await _c.from('duty_roster').select().eq('org_id', orgId)
          .gte('roster_date', _dk.format(from)).lte('roster_date', _dk.format(to));
      _roster.removeWhere((k, _) { final d = DateTime.tryParse(k.split('|').last); return d != null && !d.isBefore(from) && !d.isAfter(to); });
      for (final r in rows as List) {
        _roster['${r['employee_id']}|${r['roster_date']}'] = Map<String, dynamic>.from(r as Map);
      }
      _att.removeWhere((k, _) { final d = DateTime.tryParse(k.split('|').last); return d != null && !d.isBefore(from) && !d.isAfter(to); });
      try {
        final att = await _c.from('hr_attendance').select('employee_id, att_date, status').eq('org_id', orgId)
            .gte('att_date', _dk.format(from)).lte('att_date', _dk.format(to));
        for (final a in att as List) {
          final s = '${a['status'] ?? ''}';
          if (s == 'absent' || s == 'leave' || s == 'half_day') _att['${a['employee_id']}|${a['att_date']}'] = s;
        }
      } catch (_) {}
      try {
        final lv = await _c.from('hr_leave_requests').select('employee_id, from_date, to_date, status').eq('org_id', orgId)
            .eq('status', 'approved').lte('from_date', _dk.format(to)).gte('to_date', _dk.format(from));
        for (final l in lv as List) {
          final a = DateTime.tryParse('${l['from_date']}'), b = DateTime.tryParse('${l['to_date']}');
          if (a == null || b == null) continue;
          for (var d = a; !d.isAfter(b); d = d.add(const Duration(days: 1))) {
            _att.putIfAbsent('${l['employee_id']}|${_dk.format(d)}', () => 'leave');
          }
        }
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString().contains('duty_roster') ? 'Run SQL 319 in Supabase first.' : '$e'; });
    }
  }

  Future<void> _set(String emp, DateTime d, {String? stationId, bool off = false, bool clear = false}) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final k = _key(emp, d);
    final prev = _roster[k];
    try {
      if (clear) {
        setState(() => _roster.remove(k));
        await _c.from('duty_roster').delete().eq('org_id', orgId).eq('employee_id', emp).eq('roster_date', _dk.format(d));
        return;
      }
      final row = {
        'id': prev?['id'] ?? 'dr_${DateTime.now().microsecondsSinceEpoch}',
        'org_id': orgId, 'employee_id': emp, 'roster_date': _dk.format(d),
        'station_id': off ? null : stationId, 'is_off': off,
        'updated_by': ref.read(currentUserProvider)?.id,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      setState(() => _roster[k] = row);
      await _c.from('duty_roster').upsert(row, onConflict: 'org_id,employee_id,roster_date');
    } catch (e) {
      setState(() { if (prev == null) { _roster.remove(k); } else { _roster[k] = prev; } });
      _snack(e.toString().contains('duty_roster') ? 'Run SQL 319 in Supabase first.' : 'Could not save: $e');
    }
  }

  Future<void> _copyLastWeek() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final prevStart = _weekStart.subtract(const Duration(days: 7));
    try {
      final rows = List<Map<String, dynamic>>.from(await _c.from('duty_roster').select().eq('org_id', orgId)
          .gte('roster_date', _dk.format(prevStart)).lte('roster_date', _dk.format(prevStart.add(const Duration(days: 6)))));
      final now = DateTime.now().toUtc().toIso8601String();
      final uid = ref.read(currentUserProvider)?.id;
      final out = <Map<String, dynamic>>[];
      var i = 0;
      for (final r in rows) {
        final d = DateTime.tryParse('${r['roster_date']}');
        if (d == null) continue;
        final nd = d.add(const Duration(days: 7));
        if (_roster.containsKey('${r['employee_id']}|${_dk.format(nd)}')) continue; // never overwrite this week's plan
        out.add({
          'id': 'dr_${DateTime.now().microsecondsSinceEpoch}_${i++}', 'org_id': orgId, 'employee_id': r['employee_id'],
          'roster_date': _dk.format(nd), 'station_id': r['station_id'], 'is_off': r['is_off'] == true,
          'note': r['note'], 'updated_by': uid, 'updated_at': now,
        });
      }
      if (out.isEmpty) { _snack(rows.isEmpty ? 'Last week has no roster to copy.' : 'This week is already planned — nothing to copy.'); return; }
      for (var j = 0; j < out.length; j += 500) {
        await _c.from('duty_roster').upsert(out.sublist(j, (j + 500).clamp(0, out.length)), onConflict: 'org_id,employee_id,roster_date');
      }
      _snack('Copied ${out.length} assignment${out.length == 1 ? '' : 's'} from last week');
      await _loadRange();
    } catch (e) { _snack('Could not copy: $e'); }
  }

  // ── Stations dialog ──────────────────────────────────────────────────────
  Future<void> _manageStations() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final nameCtrl = TextEditingController();
    String color = _palette[_stations.length % _palette.length];
    await showDialog<void>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      Future<void> add() async {
        final n = nameCtrl.text.trim();
        if (n.isEmpty) return;
        final row = {'id': 'dst_${DateTime.now().microsecondsSinceEpoch}', 'org_id': orgId, 'name': n, 'color': color,
            'sort_order': _stations.length, 'is_active': true};
        try {
          await _c.from('duty_stations').insert(row);
          setState(() => _stations.add(row));
          nameCtrl.clear();
          setD(() => color = _palette[_stations.length % _palette.length]);
        } catch (e) { _snack(e.toString().contains('duty_stations') ? 'Run SQL 319 in Supabase first.' : 'Could not add: $e'); }
      }
      Future<void> upd(Map<String, dynamic> s, Map<String, dynamic> patch) async {
        try {
          await _c.from('duty_stations').update(patch).eq('id', s['id'] as String);
          setState(() => s.addAll(patch));
          setD(() {});
        } catch (e) { _snack('Could not update: $e'); }
      }
      Future<void> move(int i, int dir) async {
        final j = i + dir;
        if (j < 0 || j >= _stations.length) return;
        setState(() { final t = _stations.removeAt(i); _stations.insert(j, t); });
        setD(() {});
        for (var k = 0; k < _stations.length; k++) {
          try { await _c.from('duty_stations').update({'sort_order': k}).eq('id', _stations[k]['id'] as String); } catch (_) {}
          _stations[k]['sort_order'] = k;
        }
      }
      return AlertDialog(
        title: const Text('Stations / lines', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: TextField(controller: nameCtrl, autofocus: true, onSubmitted: (_) => add(),
                decoration: const InputDecoration(hintText: 'New station, e.g. Cutting, Pleating, QC, Packing', isDense: true, border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: 'Colour',
              onSelected: (v) => setD(() => color = v),
              itemBuilder: (_) => [for (final p in _palette) PopupMenuItem(value: p, child: Container(width: 60, height: 18, decoration: BoxDecoration(color: _hex(p), borderRadius: BorderRadius.circular(4))))],
              child: Container(width: 28, height: 28, decoration: BoxDecoration(color: _hex(color), borderRadius: BorderRadius.circular(6))),
            ),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: add, child: const Text('Add')),
          ]),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: _stations.isEmpty
                ? const Padding(padding: EdgeInsets.all(16), child: Text('No stations yet.', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.builder(shrinkWrap: true, itemCount: _stations.length, itemBuilder: (_, i) {
                    final s = _stations[i];
                    final active = s['is_active'] != false;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: PopupMenuButton<String>(
                        tooltip: 'Colour',
                        onSelected: (v) => upd(s, {'color': v}),
                        itemBuilder: (_) => [for (final p in _palette) PopupMenuItem(value: p, child: Container(width: 60, height: 18, decoration: BoxDecoration(color: _hex(p), borderRadius: BorderRadius.circular(4))))],
                        child: Container(width: 22, height: 22, decoration: BoxDecoration(color: _hex(s['color'] as String?), borderRadius: BorderRadius.circular(5))),
                      ),
                      title: Text('${s['name']}', style: TextStyle(fontWeight: FontWeight.w600, color: active ? AppTheme.textPrimary : AppTheme.textSecondary,
                          decoration: active ? null : TextDecoration.lineThrough)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.arrow_upward, size: 16), onPressed: i == 0 ? null : () => move(i, -1)),
                        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.arrow_downward, size: 16), onPressed: i == _stations.length - 1 ? null : () => move(i, 1)),
                        IconButton(visualDensity: VisualDensity.compact, tooltip: 'Rename', icon: const Icon(Icons.edit_outlined, size: 16), onPressed: () async {
                          final c2 = TextEditingController(text: '${s['name']}');
                          final v = await showDialog<String>(context: ctx, builder: (c3) => AlertDialog(
                            title: const Text('Rename station'),
                            content: TextField(controller: c2, autofocus: true, onSubmitted: (t) => Navigator.pop(c3, t)),
                            actions: [TextButton(onPressed: () => Navigator.pop(c3), child: const Text('Cancel')),
                              ElevatedButton(onPressed: () => Navigator.pop(c3, c2.text), child: const Text('Save'))],
                          ));
                          if (v != null && v.trim().isNotEmpty) await upd(s, {'name': v.trim()});
                        }),
                        Switch(value: active, onChanged: (v) => upd(s, {'is_active': v})),
                      ]),
                    );
                  }),
          ),
          const SizedBox(height: 4),
          const Text('Switch a station off to hide it from new assignments; past rosters keep it.',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      );
    }));
  }

  // ── Assign menu ──────────────────────────────────────────────────────────
  Future<void> _pickFor(String emp, DateTime d, Offset pos) async {
    final active = _stations.where((s) => s['is_active'] != false).toList();
    if (active.isEmpty) { _snack('Add your stations first (Stations button).'); _manageStations(); return; }
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: [
        for (final s in active)
          PopupMenuItem(value: 's:${s['id']}', height: 36, child: Row(children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(color: _hex(s['color'] as String?), borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 8), Text('${s['name']}', style: const TextStyle(fontSize: 13)),
          ])),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'off', height: 36, child: Text('Off', style: TextStyle(fontSize: 13))),
        const PopupMenuItem(value: 'clear', height: 36, child: Text('Clear', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
      ],
    );
    if (v == null) return;
    if (v == 'off') { await _set(emp, d, off: true); }
    else if (v == 'clear') { await _set(emp, d, clear: true); }
    else { await _set(emp, d, stationId: v.substring(2)); }
  }

  Future<void> _fillWeek(String emp) async {
    final active = _stations.where((s) => s['is_active'] != false).toList();
    if (active.isEmpty) { _snack('Add your stations first.'); return; }
    final v = await showDialog<String>(context: context, builder: (ctx) => SimpleDialog(
      title: const Text('Whole week (Mon–Sat) to…', style: TextStyle(fontSize: 15)),
      children: [
        for (final s in active)
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, '${s['id']}'), child: Row(children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(color: _hex(s['color'] as String?), borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 8), Text('${s['name']}'),
          ])),
      ],
    ));
    if (v == null) return;
    for (final d in _days.take(6)) { await _set(emp, d, stationId: v); }
  }

  // ── Hide members ─────────────────────────────────────────────────────────
  Future<void> _setHidden(Iterable<String> ids, bool hide) async {
    final orgId = _orgId;
    final list = ids.toSet().toList();
    if (orgId == null || list.isEmpty) return;
    final before = Set<String>.from(_hidden);
    setState(() {
      if (hide) { _hidden.addAll(list); } else { _hidden.removeAll(list); }
      if (hide && !_showHidden) _sel.removeAll(list);
    });
    try {
      if (hide) {
        final uid = ref.read(currentUserProvider)?.id;
        final now = DateTime.now().toUtc().toIso8601String();
        await _c.from('duty_roster_hidden').upsert(
            [for (final id in list) {'org_id': orgId, 'employee_id': id, 'hidden_by': uid, 'hidden_at': now}],
            onConflict: 'org_id,employee_id');
      } else {
        await _c.from('duty_roster_hidden').delete().eq('org_id', orgId).inFilter('employee_id', list);
      }
    } catch (e) {
      setState(() { _hidden..clear()..addAll(before); });
      _snack(e.toString().contains('duty_roster_hidden') ? 'Run SQL 320 in Supabase first.' : 'Could not save: $e');
    }
  }

  /// Tick who is on the roster. Unticked people are hidden for everyone.
  Future<void> _manageMembers() async {
    final vis = <String>{for (final e in _employees) if (!_hidden.contains('${e['id']}')) '${e['id']}'};
    String q = '';
    String? dept;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      final list = _employees.where((e) {
        if (dept != null && e['department_id'] != dept) return false;
        return q.isEmpty || matchesQuery('${e['full_name'] ?? ''} ${e['employee_code'] ?? ''} ${e['designation'] ?? ''}', q);
      }).toList();
      final allOn = list.isNotEmpty && list.every((e) => vis.contains('${e['id']}'));
      return AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('Roster members', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          Text('${vis.length} of ${_employees.length} shown', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
        content: SizedBox(width: 480, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: TextField(
              autofocus: true,
              onChanged: (v) => setD(() => q = v),
              decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
            )),
            if (_deptName.isNotEmpty) ...[
              const SizedBox(width: 8),
              DropdownButton<String?>(
                value: dept,
                hint: const Text('All departments'),
                items: [const DropdownMenuItem<String?>(value: null, child: Text('All departments')),
                  for (final e in _deptName.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value))],
                onChanged: (v) => setD(() => dept = v),
              ),
            ],
          ]),
          const SizedBox(height: 6),
          Row(children: [
            TextButton(onPressed: () => setD(() { for (final e in list) { vis.add('${e['id']}'); } }), child: const Text('Tick all')),
            TextButton(onPressed: () => setD(() { for (final e in list) { vis.remove('${e['id']}'); } }), child: const Text('Untick all')),
            const Spacer(),
            Text(q.isEmpty && dept == null ? '' : '${list.length} in this list', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: ListView.builder(shrinkWrap: true, itemCount: list.length, itemBuilder: (_, i) {
              final e = list[i];
              final id = '${e['id']}';
              return CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                value: vis.contains(id),
                onChanged: (v) => setD(() { if (v == true) { vis.add(id); } else { vis.remove(id); } }),
                title: Text('${e['full_name'] ?? ''}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text([e['employee_code'], e['designation'], _deptName['${e['department_id']}']].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
                    style: const TextStyle(fontSize: 11)),
              );
            }),
          ),
          const SizedBox(height: 6),
          Text(allOn ? 'Untick people who should not appear on the roster (e.g. keep only team leads).' : 'Unticked people are hidden from the roster for everyone. Their past assignments are kept.',
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      );
    }));
    if (ok != true) return;
    final toHide = [for (final e in _employees) if (!vis.contains('${e['id']}') && !_hidden.contains('${e['id']}')) '${e['id']}'];
    final toShow = [for (final id in _hidden) if (vis.contains(id)) id];
    if (toHide.isNotEmpty) await _setHidden(toHide, true);
    if (toShow.isNotEmpty) await _setHidden(toShow, false);
  }

  // ── Multi-select: assign many workers at once ────────────────────────────
  Future<void> _bulkAssign() async {
    final orgId = _orgId;
    final emps = _sel.toList();
    if (orgId == null || emps.isEmpty) return;
    final active = _stations.where((s) => s['is_active'] != false).toList();
    if (active.isEmpty) { _snack('Add your stations first (Stations button).'); _manageStations(); return; }
    final week = _view == 'week';
    String? choice; // s:<id> | off | clear
    final dayIdx = <int>{0, 1, 2, 3, 4, 5};
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      Widget chip(String value, String label, Color c) => ChoiceChip(
            label: Text(label, style: const TextStyle(fontSize: 12.5)),
            avatar: Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
            selected: choice == value,
            onSelected: (_) => setD(() => choice = value),
          );
      return AlertDialog(
        title: Text('Assign ${emps.length} selected worker${emps.length == 1 ? '' : 's'}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Station', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s in active) chip('s:${s['id']}', '${s['name']}', _hex(s['color'] as String?)),
            chip('off', 'Off', Colors.blueGrey),
            chip('clear', 'Clear', const Color(0xFFCBD5E1)),
          ]),
          const SizedBox(height: 14),
          Text(week ? 'Days' : 'Day', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          if (week)
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (var i = 0; i < 7; i++)
                FilterChip(
                  label: Text(DateFormat('EEE d').format(_days[i]), style: const TextStyle(fontSize: 12)),
                  selected: dayIdx.contains(i),
                  onSelected: (v) => setD(() { if (v) { dayIdx.add(i); } else { dayIdx.remove(i); } }),
                ),
            ])
          else
            Text(DateFormat('EEEE, d MMM y').format(_day), style: const TextStyle(fontWeight: FontWeight.w600)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: choice == null || (week && dayIdx.isEmpty) ? null : () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      );
    }));
    if (ok != true || choice == null) return;
    final dates = week ? [for (final i in (dayIdx.toList()..sort())) _days[i]] : [_day];
    final dks = [for (final d in dates) _dk.format(d)];
    try {
      if (choice == 'clear') {
        await _c.from('duty_roster').delete().eq('org_id', orgId).inFilter('employee_id', emps).inFilter('roster_date', dks);
      } else {
        final off = choice == 'off';
        final sid = off ? null : choice!.substring(2);
        final uid = ref.read(currentUserProvider)?.id;
        final now = DateTime.now().toUtc().toIso8601String();
        final out = <Map<String, dynamic>>[];
        var n = 0;
        for (final emp in emps) {
          for (final d in dates) {
            final prev = _roster[_key(emp, d)];
            out.add({
              'id': prev?['id'] ?? 'dr_${DateTime.now().microsecondsSinceEpoch}_${n++}',
              'org_id': orgId, 'employee_id': emp, 'roster_date': _dk.format(d),
              'station_id': sid, 'is_off': off, 'updated_by': uid, 'updated_at': now,
            });
          }
        }
        for (var j = 0; j < out.length; j += 500) {
          await _c.from('duty_roster').upsert(out.sublist(j, (j + 500).clamp(0, out.length)), onConflict: 'org_id,employee_id,roster_date');
        }
      }
      _snack('Updated ${emps.length} worker${emps.length == 1 ? '' : 's'} × ${dates.length} day${dates.length == 1 ? '' : 's'}');
      setState(() => _sel.clear());
      await _loadRange();
    } catch (e) {
      _snack(e.toString().contains('duty_roster') ? 'Run SQL 319 in Supabase first.' : 'Could not save: $e');
    }
  }

  Widget _selectionBar() {
    final anyHidden = _sel.any(_hidden.contains);
    final anyShown = _sel.any((id) => !_hidden.contains(id));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: AppTheme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35))),
      child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${_sel.length} selected', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        ElevatedButton.icon(onPressed: _bulkAssign, icon: const Icon(Icons.assignment_ind_outlined, size: 16), label: const Text('Assign…')),
        if (anyShown) OutlinedButton.icon(
          onPressed: () => _setHidden(_sel.where((id) => !_hidden.contains(id)).toList(), true),
          icon: const Icon(Icons.visibility_off_outlined, size: 16), label: const Text('Hide from roster')),
        if (anyHidden) OutlinedButton.icon(
          onPressed: () => _setHidden(_sel.where(_hidden.contains).toList(), false),
          icon: const Icon(Icons.visibility_outlined, size: 16), label: const Text('Show on roster')),
        TextButton(onPressed: () => setState(() => _sel.clear()), child: const Text('Clear selection')),
      ]),
    );
  }

  // ── Filters ──────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> get _shownEmployees => _employees.where((e) {
        if (!_showHidden && _hidden.contains('${e['id']}')) return false;
        if (_deptFilter != null && e['department_id'] != _deptFilter) return false;
        return _search.isEmpty || matchesQuery('${e['full_name'] ?? ''} ${e['employee_code'] ?? ''}', _search);
      }).toList();

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.of(context).size.width < 760;
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(mobile ? 12 : 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Duty Roster', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'week', label: Text('Week'), icon: Icon(Icons.calendar_view_week, size: 16)),
              ButtonSegment(value: 'day', label: Text('Day'), icon: Icon(Icons.view_column_outlined, size: 16)),
            ],
            selected: {_view},
            showSelectedIcon: false,
            onSelectionChanged: (v) { setState(() => _view = v.first); _loadRange(); },
          ),
          _dateNav(),
          OutlinedButton.icon(onPressed: _manageMembers, icon: const Icon(Icons.groups_outlined, size: 16),
              label: Text('Members (${_employees.where((e) => !_hidden.contains('${e['id']}')).length}/${_employees.length})')),
          OutlinedButton.icon(onPressed: _manageStations, icon: const Icon(Icons.factory_outlined, size: 16), label: Text('Stations (${_stations.where((s) => s['is_active'] != false).length})')),
          if (_view == 'week') OutlinedButton.icon(onPressed: _copyLastWeek, icon: const Icon(Icons.copy_all_outlined, size: 16), label: const Text('Copy last week')),
          OutlinedButton.icon(onPressed: _print, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print')),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 240, child: TextField(
            onChanged: (v) => setState(() => _search = v),
            decoration: const InputDecoration(hintText: 'Search worker…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
          )),
          if (_deptName.isNotEmpty)
            DropdownButton<String?>(
              value: _deptFilter,
              hint: const Text('All departments'),
              items: [const DropdownMenuItem<String?>(value: null, child: Text('All departments')),
                for (final e in _deptName.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => _deptFilter = v),
            ),
          if (_employees.any((e) => _hidden.contains('${e['id']}')))
            FilterChip(
              label: Text('Show hidden (${_employees.where((e) => _hidden.contains('${e['id']}')).length})', style: const TextStyle(fontSize: 12)),
              selected: _showHidden,
              onSelected: (v) => setState(() { _showHidden = v; if (!v) _sel.removeWhere(_hidden.contains); }),
            ),
          _legendChip(Colors.red, 'Absent'),
          _legendChip(Colors.orange, 'On leave'),
          _legendChip(Colors.amber.shade700, 'Half day'),
        ]),
        const SizedBox(height: 10),
        if (_sel.isNotEmpty && !_loading && _error == null) _selectionBar(),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                : _view == 'week' ? _weekGrid(mobile) : _dayBoard()),
      ]),
    );
  }

  Widget _legendChip(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
      ]);

  Widget _dateNav() {
    final f = DateFormat('d MMM');
    final label = _view == 'week'
        ? '${f.format(_weekStart)} – ${DateFormat('d MMM y').format(_weekStart.add(const Duration(days: 6)))}'
        : DateFormat('EEE, d MMM y').format(_day);
    void shift(int n) {
      setState(() {
        if (_view == 'week') { _weekStart = _weekStart.add(Duration(days: 7 * n)); }
        else { _day = _day.add(Duration(days: n)); }
      });
      _loadRange();
    }
    return Container(
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.chevron_left), onPressed: () => shift(-1)),
        InkWell(
          onTap: () async {
            final p = await showDatePicker(context: context, initialDate: _view == 'week' ? _weekStart : _day, firstDate: DateTime(2020), lastDate: DateTime(2100));
            if (p == null) return;
            setState(() { _day = p; _weekStart = p.subtract(Duration(days: p.weekday - 1)); });
            _loadRange();
          },
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
        ),
        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.chevron_right), onPressed: () => shift(1)),
        TextButton(onPressed: () {
          final t = DateTime.now();
          setState(() { _day = DateTime(t.year, t.month, t.day); _weekStart = _day.subtract(Duration(days: _day.weekday - 1)); });
          _loadRange();
        }, child: Text(_view == 'week' ? 'This week' : 'Today', style: const TextStyle(fontSize: 12))),
      ]),
    );
  }

  Widget? _flag(String emp, DateTime d) {
    final s = _att[_key(emp, d)];
    if (s == null) return null;
    final c = s == 'absent' ? Colors.red : s == 'leave' ? Colors.orange : Colors.amber.shade700;
    return Tooltip(
      message: s == 'absent' ? 'Absent' : s == 'leave' ? 'On leave' : 'Half day',
      child: Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
    );
  }

  Widget _cell(String emp, DateTime d) {
    final r = _roster[_key(emp, d)];
    final st = _station(r?['station_id'] as String?);
    final off = r?['is_off'] == true;
    final flag = _flag(emp, d);
    final clash = flag != null && st != null; // rostered but absent / on leave
    return Builder(builder: (ctx) => InkWell(
      onTapDown: (det) => _pickFor(emp, d, det.globalPosition),
      onTap: () {},
      child: Container(
        height: 40,
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: st != null ? _hex(st['color'] as String?).withValues(alpha: 0.14) : (off ? const Color(0xFFF1F5F9) : Colors.white),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: clash ? Colors.red : (st != null ? _hex(st['color'] as String?).withValues(alpha: 0.5) : AppTheme.border),
              width: clash ? 1.5 : 1),
        ),
        child: Row(children: [
          Expanded(child: Text(
            st != null ? '${st['name']}' : (off ? 'Off' : ''),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, fontWeight: st != null ? FontWeight.w700 : FontWeight.w500,
                color: st != null ? _hex(st['color'] as String?) : AppTheme.textSecondary),
          )),
          if (flag != null) flag,
          if (st == null && !off && flag == null) const Icon(Icons.add, size: 14, color: Color(0xFFCBD5E1)),
        ]),
      ),
    ));
  }

  Widget _weekGrid(bool mobile) {
    final emps = _shownEmployees;
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    const nameW = 210.0, dayW = 118.0;
    final head = Container(
      color: Colors.white,
      child: Row(children: [
        SizedBox(width: nameW, child: Row(children: [
          Checkbox(
            visualDensity: VisualDensity.compact,
            tristate: true,
            value: emps.isEmpty || !emps.any((e) => _sel.contains('${e['id']}'))
                ? false
                : emps.every((e) => _sel.contains('${e['id']}')) ? true : null,
            onChanged: emps.isEmpty ? null : (_) => setState(() {
              final all = emps.every((e) => _sel.contains('${e['id']}'));
              for (final e in emps) { if (all) { _sel.remove('${e['id']}'); } else { _sel.add('${e['id']}'); } }
            }),
          ),
          const Text('Worker', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        ])),
        for (final d in _days)
          SizedBox(width: dayW, child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            color: d == today ? AppTheme.primary.withValues(alpha: 0.08) : null,
            child: Column(children: [
              Text(DateFormat('EEE').format(d), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: d.weekday == 7 ? AppTheme.danger : AppTheme.textSecondary)),
              Text(DateFormat('d MMM').format(d), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
              Text('${emps.where((e) => _roster[_key('${e['id']}', d)]?['station_id'] != null).length} on duty',
                  style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
            ]),
          )),
        const SizedBox(width: 40),
      ]),
    );
    final table = Column(children: [
      head,
      const Divider(height: 1),
      Expanded(child: emps.isEmpty
          ? Center(child: Text(_employees.isEmpty ? 'No active employees. Add them in HR → Employee Directory.'
                  : 'Nobody to show. Use Members to choose who is on the roster.', style: const TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(
              itemCount: emps.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
              itemBuilder: (_, i) {
                final e = emps[i];
                final id = '${e['id']}';
                final isHidden = _hidden.contains(id);
                final picked = _sel.contains(id);
                return Container(
                  color: picked ? AppTheme.primary.withValues(alpha: 0.05) : null,
                  child: Row(children: [
                  SizedBox(width: nameW, child: Row(children: [
                    Checkbox(
                      visualDensity: VisualDensity.compact,
                      value: picked,
                      onChanged: (v) => setState(() { if (v == true) { _sel.add(id); } else { _sel.remove(id); } }),
                    ),
                    Expanded(child: Padding(
                      padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(child: Text('${e['full_name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: isHidden ? AppTheme.textSecondary : AppTheme.textPrimary))),
                          if (isHidden) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.visibility_off_outlined, size: 13, color: AppTheme.textSecondary)),
                        ]),
                        Text([e['employee_code'], e['designation'], _deptName['${e['department_id']}']].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
                      ]),
                    )),
                  ])),
                  for (final d in _days) SizedBox(width: dayW, child: _cell(id, d)),
                  SizedBox(width: 40, child: PopupMenuButton<String>(
                    tooltip: 'Row actions',
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (v) async {
                      if (v == 'fill') await _fillWeek(id);
                      if (v == 'clear') { for (final d in _days) { if (_roster.containsKey(_key(id, d))) await _set(id, d, clear: true); } }
                      if (v == 'hide') await _setHidden([id], true);
                      if (v == 'show') await _setHidden([id], false);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'fill', child: Text('Assign whole week…')),
                      const PopupMenuItem(value: 'clear', child: Text('Clear this week')),
                      const PopupMenuDivider(),
                      isHidden
                          ? const PopupMenuItem(value: 'show', child: Text('Show on roster'))
                          : const PopupMenuItem(value: 'hide', child: Text('Hide from roster')),
                    ],
                  )),
                ]));
              },
            )),
    ]);
    const totalW = nameW + dayW * 7 + 40;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: LayoutBuilder(builder: (context, c) => c.maxWidth >= totalW
            ? table
            : SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: totalW, height: c.maxHeight, child: table))),
      ),
    );
  }

  Widget _dayBoard() {
    // Hidden people still show on a station they are assigned to that day
    // (so no assignment silently disappears), but not under Off / Not assigned.
    final shownIds = {for (final e in _shownEmployees) '${e['id']}'};
    final emps = _employees.where((e) {
      final id = '${e['id']}';
      if (shownIds.contains(id)) return true;
      if (!_hidden.contains(id)) return false;
      if (_deptFilter != null && e['department_id'] != _deptFilter) return false;
      if (_search.isNotEmpty && !matchesQuery('${e['full_name'] ?? ''} ${e['employee_code'] ?? ''}', _search)) return false;
      final r = _roster[_key(id, _day)];
      return r != null && r['is_off'] != true && r['station_id'] != null;
    }).toList();
    final byStation = <String, List<Map<String, dynamic>>>{};
    final off = <Map<String, dynamic>>[];
    final unassigned = <Map<String, dynamic>>[];
    for (final e in emps) {
      final r = _roster[_key('${e['id']}', _day)];
      if (r == null) { unassigned.add(e); continue; }
      if (r['is_off'] == true) { off.add(e); continue; }
      (byStation['${r['station_id']}'] ??= []).add(e);
    }
    final cols = <(String, Color, List<Map<String, dynamic>>)>[
      for (final s in _stations)
        if (s['is_active'] != false || (byStation['${s['id']}']?.isNotEmpty ?? false))
          ('${s['name']}', _hex(s['color'] as String?), byStation['${s['id']}'] ?? []),
      ('Off', Colors.blueGrey, off),
      ('Not assigned', AppTheme.textSecondary, unassigned),
    ];
    final absentOnDuty = emps.where((e) {
      final r = _roster[_key('${e['id']}', _day)];
      return r != null && r['is_off'] != true && _att.containsKey(_key('${e['id']}', _day));
    }).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (absentOnDuty > 0)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFFCA5A5))),
          child: Text('$absentOnDuty rostered worker${absentOnDuty == 1 ? ' is' : 's are'} absent / on leave today — tap them to reassign their station.',
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF991B1B), fontWeight: FontWeight.w600)),
        ),
      Expanded(child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final c in cols)
          Container(
            width: 230,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(color: c.$2.withValues(alpha: 0.12), borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
                child: Row(children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: c.$2, borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(c.$1, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13))),
                  Text('${c.$3.length}', style: TextStyle(fontWeight: FontWeight.w800, color: c.$2)),
                ]),
              ),
              Expanded(child: c.$3.isEmpty
                  ? const Center(child: Text('—', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView(padding: const EdgeInsets.all(8), children: [
                      for (final e in c.$3)
                        Builder(builder: (_) {
                          final id = '${e['id']}';
                          final flag = _flag(id, _day);
                          return InkWell(
                            onTapDown: (det) => _pickFor(id, _day, det.globalPosition),
                            onTap: () {},
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: AppTheme.background, borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: flag != null && c.$1 != 'Off' && c.$1 != 'Not assigned' ? Colors.red : AppTheme.border),
                              ),
                              child: Row(children: [
                                Expanded(child: Text('${e['full_name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
                                if (flag != null) flag,
                              ]),
                            ),
                          );
                        }),
                    ])),
            ]),
          ),
      ])),
    ]);
  }

  // ── Print (week grid, landscape) ─────────────────────────────────────────
  void _print() {
    String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final emps = _shownEmployees;
    final days = _view == 'week' ? _days : [_day];
    final b = StringBuffer();
    b.write('<!doctype html><html><head><meta charset="utf-8"><title>Duty Roster</title><style>'
        '@page{size:A4 ${days.length > 1 ? 'landscape' : 'portrait'};margin:10mm}'
        '*{-webkit-print-color-adjust:exact;print-color-adjust:exact}'
        'body{font-family:-apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#0f172a;margin:0}'
        '.hd{display:flex;justify-content:space-between;align-items:flex-end;border-bottom:3px solid #1e3a8a;padding-bottom:6px;margin-bottom:10px}'
        'h1{font-size:20px;margin:0;color:#1e3a8a}.org{font-size:10px;letter-spacing:1.3px;text-transform:uppercase;color:#475569;font-weight:700}'
        '.per{font-size:13px;font-weight:800}'
        'table{border-collapse:collapse;width:100%;font-size:10.5px}thead{display:table-header-group}'
        'th{background:#1e3a8a;color:#fff;padding:6px 4px;font-size:9.5px}td{border:1px solid #e2e8f0;padding:5px 4px;text-align:center}'
        'td.n{text-align:left;font-weight:600;white-space:nowrap}tr{break-inside:avoid}'
        '.st{display:inline-block;padding:2px 6px;border-radius:4px;font-weight:700}.off{color:#94a3b8}'
        '.ab{color:#b91c1c;font-weight:800}'
        '.foot{margin-top:10px;font-size:9px;color:#64748b}'
        '</style></head><body>');
    final per = days.length > 1
        ? '${DateFormat('d MMM').format(days.first)} – ${DateFormat('d MMM y').format(days.last)}'
        : DateFormat('EEEE, d MMM y').format(days.first);
    b.write('<div class="hd"><div><div class="org">${esc(org)}</div><h1>Duty Roster</h1></div><div class="per">$per</div></div>');
    b.write('<table><thead><tr><th style="text-align:left">Worker</th>');
    for (final d in days) { b.write('<th>${DateFormat('EEE d MMM').format(d)}</th>'); }
    b.write('</tr></thead><tbody>');
    for (final e in emps) {
      final id = '${e['id']}';
      b.write('<tr><td class="n">${esc('${e['full_name'] ?? ''}')}</td>');
      for (final d in days) {
        final r = _roster[_key(id, d)];
        final st = _station(r?['station_id'] as String?);
        final a = _att[_key(id, d)];
        final mark = a == null ? '' : ' <span class="ab">(${a == 'absent' ? 'A' : a == 'leave' ? 'L' : '½'})</span>';
        if (st != null) {
          final col = '${st['color'] ?? '#2F6FED'}';
          b.write('<td><span class="st" style="background:${col}22;color:$col">${esc('${st['name']}')}</span>$mark</td>');
        } else if (r?['is_off'] == true) {
          b.write('<td class="off">Off$mark</td>');
        } else {
          b.write('<td>$mark</td>');
        }
      }
      b.write('</tr>');
    }
    b.write('</tbody></table><div class="foot">A = absent · L = on leave · ½ = half day (from attendance). '
        'Printed ${DateFormat('d MMM y, h:mm a').format(DateTime.now())}</div></body></html>');
    final doc = b.toString();
    try {
      html.document.getElementById('ops-print-frame')?.remove();
      final frame = html.IFrameElement()
        ..id = 'ops-print-frame'
        ..style.position = 'fixed'
        ..style.left = '-9999px'
        ..style.width = '0'
        ..style.height = '0'
        ..style.border = '0';
      frame.srcdoc = doc.replaceFirst('</body>',
          '<script>window.onload=function(){setTimeout(function(){try{window.focus();window.print();}catch(e){}},350);};</script></body>');
      html.document.body!.append(frame);
    } catch (_) {
      final blob = html.Blob([doc], 'text/html;charset=utf-8');
      html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
    }
  }
}
