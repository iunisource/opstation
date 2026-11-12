import 'dart:async';
import 'dart:html' as html;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';

/// Attendance Board — an Andon-style visual-management display for an executive
/// or floor wall screen. Each employee is a card whose colour signals state at
/// a glance: green = present, amber = leave / half-day, grey = not arrived yet,
/// red = absent, slate = day off (holiday / rest). Headline counts give the
/// birds-eye summary. Grouped by department, auto-refreshes every 45s, and can
/// go true full-screen for a wall display.
class HrAttendanceBoardScreen extends ConsumerStatefulWidget {
  const HrAttendanceBoardScreen({super.key});
  @override
  ConsumerState<HrAttendanceBoardScreen> createState() => _HrAttendanceBoardScreenState();
}

enum _St { present, left, leave, notArrived, absent, off }

class _Emp {
  final String id, name, code, deptName;
  final String? photoUrl;
  final _St state;
  final String? checkIn, checkOut;
  _Emp(this.id, this.name, this.code, this.deptName, this.photoUrl, this.state, this.checkIn, this.checkOut);
}

class _HrAttendanceBoardScreenState extends ConsumerState<HrAttendanceBoardScreen> {
  DateTime _date = DateTime.now();
  String? _branchId; // null = all
  List<Map<String, dynamic>> _branches = [];
  Map<String, String> _deptName = {};
  List<_Emp> _emps = [];
  bool _loading = true;
  bool _fullscreen = false;
  _St? _filter; // tapped count chip → show only these
  final Set<String> _collapsed = {}; // phone: collapsed departments
  DateTime _lastRefresh = DateTime.now();
  Timer? _refresh;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  bool get _isToday => _fmt(_date) == _fmt(DateTime.now());

  @override
  void initState() {
    super.initState();
    _loadFilters();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 45), (_) { if (_isToday) _load(); });
    html.document.addEventListener('fullscreenchange', _onFsChange);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    html.document.removeEventListener('fullscreenchange', _onFsChange);
    super.dispose();
  }

  void _onFsChange(html.Event _) {
    final fs = html.document.fullscreenElement != null;
    if (mounted) setState(() => _fullscreen = fs);
  }

  void _toggleFullscreen() {
    try {
      if (html.document.fullscreenElement == null) {
        html.document.documentElement?.requestFullscreen();
      } else {
        html.document.exitFullscreen();
      }
    } catch (_) { }
  }

  Future<void> _loadFilters() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final br = await client.from('branches').select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
      final dp = await client.from('hr_departments').select('id, name').eq('org_id', orgId);
      if (mounted) setState(() {
        _branches = List<Map<String, dynamic>>.from(br);
        _deptName = {for (final d in dp as List) d['id'] as String: d['name'] as String};
      });
    } catch (_) { }
  }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) { setState(() => _loading = false); return; }
    try {
      final client = Supabase.instance.client;
      var empQ = client.from('hr_employees')
          .select('id, full_name, employee_code, department_id, photo_url, status, branch_id')
          .eq('org_id', orgId).eq('status', 'active').eq('approval_status', 'approved').eq('is_voided', false);
      if (_branchId != null) empQ = empQ.eq('branch_id', _branchId!);
      final employees = await empQ.order('full_name');

      final att = await client.from('hr_attendance').select('employee_id, status, check_in, check_out')
          .eq('org_id', orgId).eq('att_date', _fmt(_date));
      final byEmp = {for (final a in att as List) a['employee_id'] as String: a};

      final list = <_Emp>[];
      for (final e in employees as List) {
        final rec = byEmp[e['id'] as String];
        final st = _stateFor(rec);
        list.add(_Emp(
          e['id'] as String,
          e['full_name'] as String? ?? '',
          e['employee_code'] as String? ?? '',
          _deptName[e['department_id']] ?? 'Unassigned',
          e['photo_url'] as String?,
          st,
          rec?['check_in'] as String?,
          rec?['check_out'] as String?,
        ));
      }
      if (mounted) setState(() { _emps = list; _loading = false; _lastRefresh = DateTime.now(); });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  _St _stateFor(Map? rec) {
    if (rec == null) return _St.notArrived;
    final st = (rec['status'] as String? ?? '').toLowerCase();
    final cin = rec['check_in'] as String?;
    final cout = rec['check_out'] as String?;
    final hasIn = cin != null && cin.isNotEmpty;
    final hasOut = cout != null && cout.isNotEmpty;
    if (st == 'absent') return _St.absent;
    if (st == 'leave') return _St.leave;
    if (st == 'half_day') return _St.leave;
    if (st == 'holiday' || st == 'rest_day') return _St.off;
    // This is a live "who's here now" board: once someone has checked out they
    // have left for the day, so they are no longer "present" (on site).
    if (st == 'present' && hasIn && hasOut) return _St.left;
    if (st == 'present' && hasIn) return _St.present;
    return _St.notArrived;
  }

  // palette
  Color _color(_St s) => switch (s) {
    _St.present => const Color(0xFF2E9E5B),
    _St.left => const Color(0xFF5B7F9E),
    _St.leave => const Color(0xFFD9822B),
    _St.notArrived => const Color(0xFF8A93A3),
    _St.absent => const Color(0xFFD64545),
    _St.off => const Color(0xFF5B6473),
  };
  String _label(_St s) => switch (s) {
    _St.present => 'Present',
    _St.left => 'Left',
    _St.leave => 'Leave / Half',
    _St.notArrived => 'Not arrived',
    _St.absent => 'Absent',
    _St.off => 'Day off',
  };

  int _count(_St s) => _emps.where((e) => e.state == s).length;

  @override
  Widget build(BuildContext context) {
    final bg = const Color(0xFF0B1220);
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: isNarrow(context)
              ? const EdgeInsets.fromLTRB(12, 12, 12, 12)
              : const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _topBar(),
            const SizedBox(height: 10),
            _headline(),
            const SizedBox(height: 6),
            Expanded(child: _loading
                ? const Center(child: CircularProgressIndicator(color: Colors.white54))
                : (_emps.isEmpty
                    ? const Center(child: Text('No employees', style: TextStyle(color: Colors.white54)))
                    : _grid())),
          ]),
        ),
      ),
    );
  }

  Widget _topBar() {
    final title = Text(isNarrow(context) ? 'Attendance' : 'Attendance Board',
        style: TextStyle(color: Colors.white, fontSize: isNarrow(context) ? 19 : (_fullscreen ? 26 : 22), fontWeight: FontWeight.w800));
    final dateStepper = Row(mainAxisSize: MainAxisSize.min, children: [
      _ghostBtn(Icons.chevron_left, () => setState(() { _date = _date.subtract(const Duration(days: 1)); _load(); })),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(DateFormat('EEE, d MMM yyyy').format(_date), style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600))),
      _ghostBtn(Icons.chevron_right, _isToday ? null : () => setState(() { _date = _date.add(const Duration(days: 1)); _load(); })),
    ]);
    final branchDropdown = _branches.isNotEmpty
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(child: DropdownButton<String?>(
              value: _branchId, dropdownColor: const Color(0xFF18213a),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              hint: const Text('All branches', style: TextStyle(color: Colors.white70, fontSize: 13)),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All branches')),
                ..._branches.map((b) => DropdownMenuItem<String?>(value: b['id'] as String, child: Text(b['name'] as String? ?? ''))),
              ],
              onChanged: (v) => setState(() { _branchId = v; _load(); }),
            )),
          )
        : null;
    final updated = Text('Updated ${DateFormat('h:mm:ss a').format(_lastRefresh)}', style: const TextStyle(color: Colors.white38, fontSize: 12));
    final actionBtns = Row(mainAxisSize: MainAxisSize.min, children: [
      _ghostBtn(Icons.refresh, () => _load()),
      const SizedBox(width: 6),
      _ghostBtn(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, _toggleFullscreen),
    ]);

    if (isNarrow(context)) {
      return Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        title,
        dateStepper,
        if (branchDropdown != null) branchDropdown,
        updated,
        actionBtns,
      ]);
    }

    return Row(children: [
      title,
      const SizedBox(width: 16),
      // date stepper
      dateStepper,
      const SizedBox(width: 12),
      if (branchDropdown != null) branchDropdown,
      const Spacer(),
      updated,
      const SizedBox(width: 10),
      actionBtns,
    ]);
  }

  Widget _ghostBtn(IconData icon, VoidCallback? onTap) {
    return Material(color: Colors.white10, borderRadius: BorderRadius.circular(8),
      child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 20, color: onTap == null ? Colors.white24 : Colors.white70))));
  }

  /// Counts as one row of small chips (tap one to show only those people).
  Widget _headline() {
    final narrow = isNarrow(context);
    final big = _fullscreen;
    Widget chip(String label, int n, Color c, _St? st) {
      final sel = _filter == st && st != null;
      return Material(
        color: sel ? c.withOpacity(0.28) : c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(narrow ? 8 : 999),
        child: InkWell(
          borderRadius: BorderRadius.circular(narrow ? 8 : 999),
          onTap: () => setState(() => _filter = (st == null || _filter == st) ? null : st),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: narrow ? 6 : 12, vertical: narrow ? 6 : 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(narrow ? 8 : 999),
              border: Border.all(color: sel ? c : c.withOpacity(0.45), width: sel ? 1.6 : 1),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text('$n', style: TextStyle(color: c == Colors.white ? Colors.white : c, fontSize: big ? 20 : (narrow ? 15 : 16), fontWeight: FontWeight.w900)),
              const SizedBox(width: 5),
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white70, fontSize: big ? 14 : (narrow ? 11 : 12), fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
      );
    }
    final chips = [
      chip('On site', _count(_St.present), _color(_St.present), _St.present),
      chip('Left', _count(_St.left), _color(_St.left), _St.left),
      chip(narrow ? 'Not arr.' : 'Not arrived', _count(_St.notArrived), _color(_St.notArrived), _St.notArrived),
      chip(narrow ? 'Leave' : 'Leave / Half', _count(_St.leave), _color(_St.leave), _St.leave),
      chip('Absent', _count(_St.absent), _color(_St.absent), _St.absent),
      if (_count(_St.off) > 0) chip('Day off', _count(_St.off), _color(_St.off), _St.off),
      chip(narrow ? 'Total' : 'Total staff', _emps.length, Colors.white, null),
    ];
    if (narrow) {
      return GridView.count(
        crossAxisCount: 3, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 3.1,
        children: chips,
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      ...chips,
      if (_filter != null)
        TextButton(onPressed: () => setState(() => _filter = null),
            child: const Text('Show everyone', style: TextStyle(color: Colors.white70, fontSize: 12))),
    ]);
  }

  Widget _grid() {
    final narrow = isNarrow(context);
    final shown = _filter == null ? _emps : _emps.where((e) => e.state == _filter).toList();
    if (shown.isEmpty) {
      return Center(child: Text('Nobody is ${_label(_filter!).toLowerCase()}', style: const TextStyle(color: Colors.white54)));
    }
    // group by department, stable order
    final groups = <String, List<_Emp>>{};
    for (final e in shown) { (groups[e.deptName] ??= []).add(e); }
    final deptOrder = groups.keys.toList()..sort();
    final tileW = _fullscreen ? 300.0 : 250.0;
    return LayoutBuilder(builder: (ctx, box) {
      // Tiles fill the row evenly: as many columns as fit at ~tileW each.
      final cols = narrow ? 1 : (box.maxWidth / tileW).floor().clamp(1, 12).toInt();
      final w = narrow ? box.maxWidth : (box.maxWidth - (cols - 1) * 6) / cols;
      return SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final dept in deptOrder) ...[
            InkWell(
              onTap: narrow ? () => setState(() => _collapsed.contains(dept) ? _collapsed.remove(dept) : _collapsed.add(dept)) : null,
              child: Padding(padding: const EdgeInsets.only(top: 8, bottom: 6),
                child: Row(children: [
                  Text(dept, style: TextStyle(color: Colors.white, fontSize: _fullscreen ? 17 : 14, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Flexible(child: Text(
                      '${groups[dept]!.where((e) => e.state == _St.present).length}/${groups[dept]!.length} on site'
                      '${groups[dept]!.any((e) => e.state == _St.left) ? ' · ${groups[dept]!.where((e) => e.state == _St.left).length} left' : ''}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12))),
                  if (narrow) ...[
                    const Spacer(),
                    Icon(_collapsed.contains(dept) ? Icons.expand_more : Icons.expand_less, color: Colors.white38, size: 18),
                  ],
                ])),
            ),
            if (!(narrow && _collapsed.contains(dept)))
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final e in groups[dept]!) SizedBox(width: w, child: _card(e)),
              ]),
          ],
          const SizedBox(height: 16),
        ]),
      );
    });
  }

  /// One short tile: photo · name/code · In and Out stacked on the right (never cut).
  Widget _card(_Emp e) {
    final c = _color(e.state);
    final big = _fullscreen;
    final av = big ? 46.0 : 38.0;
    Widget time(String tag, String value, Color color, {bool bold = false}) => Text.rich(
          TextSpan(children: [
            TextSpan(text: '$tag ', style: TextStyle(color: Colors.white38, fontSize: big ? 11 : 9.5, fontWeight: FontWeight.w800, letterSpacing: .4)),
            TextSpan(text: value, style: TextStyle(color: color, fontSize: big ? 14 : 12, fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          maxLines: 1, softWrap: false,
        );
    final hasIn = e.checkIn != null && e.checkIn!.isNotEmpty;
    final hasOut = e.checkOut != null && e.checkOut!.isNotEmpty;
    final right = hasIn || hasOut
        ? Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            if (hasIn) time('IN', _to12(e.checkIn!), const Color(0xFF86EFAC)),
            if (hasOut) time('OUT', _to12(e.checkOut!), const Color(0xFF93C5FD), bold: true)
            else if (e.state == _St.present) time('OUT', '—', Colors.white24),
          ])
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: c.withOpacity(0.18), borderRadius: BorderRadius.circular(6)),
            child: Text(_label(e.state), style: TextStyle(color: c, fontSize: big ? 12.5 : 11, fontWeight: FontWeight.w700)),
          );
    return Material(
      color: const Color(0xFF111827),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => context.go('/hr/employees?focus=${e.id}'),
        child: Container(
          padding: EdgeInsets.fromLTRB(8, big ? 9 : 7, 9, big ? 9 : 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border(
              left: BorderSide(color: c, width: 4),
              top: const BorderSide(color: Color(0xFF1F2937)),
              right: const BorderSide(color: Color(0xFF1F2937)),
              bottom: const BorderSide(color: Color(0xFF1F2937)),
            ),
          ),
          child: Row(children: [
            Container(
              width: av, height: av,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white12,
                image: (e.photoUrl != null && e.photoUrl!.isNotEmpty)
                    ? DecorationImage(image: NetworkImage(e.photoUrl!), fit: BoxFit.cover) : null,
              ),
              child: (e.photoUrl == null || e.photoUrl!.isEmpty)
                  ? Icon(Icons.person, color: Colors.white54, size: av * 0.5) : null,
            ),
            const SizedBox(width: 9),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontSize: big ? 15 : 13, fontWeight: FontWeight.w700)),
              Text(e.code, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white38, fontSize: big ? 12 : 11)),
            ])),
            const SizedBox(width: 6),
            right,
          ]),
        ),
      ),
    );
  }

  String _to12(String hhmm) {
    final p = hhmm.split(':');
    if (p.length < 2) return hhmm;
    var h = int.tryParse(p[0]) ?? 0;
    final m = p[1];
    final ap = h >= 12 ? 'PM' : 'AM';
    h = h % 12; if (h == 0) h = 12;
    return '$h:$m $ap';
  }
}
