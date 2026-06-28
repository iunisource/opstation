import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
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

enum _St { present, leave, notArrived, absent, off }

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
    final hasIn = cin != null && cin.isNotEmpty;
    if (st == 'absent') return _St.absent;
    if (st == 'leave') return _St.leave;
    if (st == 'half_day') return _St.leave;
    if (st == 'holiday' || st == 'rest_day') return _St.off;
    if (st == 'present' && hasIn) return _St.present;
    return _St.notArrived;
  }

  // palette
  Color _color(_St s) => switch (s) {
    _St.present => const Color(0xFF2E9E5B),
    _St.leave => const Color(0xFFD9822B),
    _St.notArrived => const Color(0xFF8A93A3),
    _St.absent => const Color(0xFFD64545),
    _St.off => const Color(0xFF5B6473),
  };
  String _label(_St s) => switch (s) {
    _St.present => 'Present',
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _topBar(),
            const SizedBox(height: 14),
            _headline(),
            const SizedBox(height: 16),
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
    return Row(children: [
      const Text('Attendance Board', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
      const SizedBox(width: 16),
      // date stepper
      _ghostBtn(Icons.chevron_left, () => setState(() { _date = _date.subtract(const Duration(days: 1)); _load(); })),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(DateFormat('EEE, d MMM yyyy').format(_date), style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600))),
      _ghostBtn(Icons.chevron_right, _isToday ? null : () => setState(() { _date = _date.add(const Duration(days: 1)); _load(); })),
      const SizedBox(width: 12),
      if (_branches.isNotEmpty)
        Container(
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
        ),
      const Spacer(),
      Text('Updated ${DateFormat('h:mm:ss a').format(_lastRefresh)}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
      const SizedBox(width: 10),
      _ghostBtn(Icons.refresh, () => _load()),
      const SizedBox(width: 6),
      _ghostBtn(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, _toggleFullscreen),
    ]);
  }

  Widget _ghostBtn(IconData icon, VoidCallback? onTap) {
    return Material(color: Colors.white10, borderRadius: BorderRadius.circular(8),
      child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 20, color: onTap == null ? Colors.white24 : Colors.white70))));
  }

  Widget _headline() {
    Widget tile(String label, int n, Color c) => Expanded(child: Container(
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withOpacity(0.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$n', style: TextStyle(color: c, fontSize: 30, fontWeight: FontWeight.w900, height: 1)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    ));
    final total = _emps.length;
    return Row(children: [
      tile('Present', _count(_St.present), const Color(0xFF2E9E5B)),
      tile('Not arrived', _count(_St.notArrived), const Color(0xFF8A93A3)),
      tile('Leave / Half', _count(_St.leave), const Color(0xFFD9822B)),
      tile('Absent', _count(_St.absent), const Color(0xFFD64545)),
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white24)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$total', style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, height: 1)),
          const SizedBox(height: 2),
          const Text('Total staff', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      )),
    ]);
  }

  Widget _grid() {
    // group by department, preserve a stable order
    final groups = <String, List<_Emp>>{};
    for (final e in _emps) { (groups[e.deptName] ??= []).add(e); }
    final deptOrder = groups.keys.toList()..sort();
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final dept in deptOrder) ...[
          Padding(padding: const EdgeInsets.only(top: 6, bottom: 10),
            child: Row(children: [
              Text(dept, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('${groups[dept]!.where((e) => e.state == _St.present).length}/${groups[dept]!.length} present',
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ])),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (final e in groups[dept]!) _card(e),
          ]),
          const SizedBox(height: 18),
        ],
      ]),
    );
  }

  Widget _card(_Emp e) {
    final c = _color(e.state);
    return Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withOpacity(0.55), width: 1.4),
      ),
      child: Column(children: [
        Stack(alignment: Alignment.bottomRight, children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c, width: 2.4),
              color: Colors.white12,
              image: (e.photoUrl != null && e.photoUrl!.isNotEmpty)
                  ? DecorationImage(image: NetworkImage(e.photoUrl!), fit: BoxFit.cover) : null,
            ),
            child: (e.photoUrl == null || e.photoUrl!.isEmpty)
                ? const Icon(Icons.person, color: Colors.white54, size: 28) : null,
          ),
          Container(width: 16, height: 16, decoration: BoxDecoration(
            color: c, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF0B1220), width: 2))),
        ]),
        const SizedBox(height: 8),
        Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
        Text(e.code, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: c.withOpacity(0.22), borderRadius: BorderRadius.circular(6)),
          child: Text(
            e.state == _St.present && e.checkIn != null ? 'In ${_to12(e.checkIn!)}' : _label(e.state),
            style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  String _to12(String hhmm) {
    final p = hhmm.split(':');
    if (p.length != 2) return hhmm;
    var h = int.tryParse(p[0]) ?? 0;
    final m = p[1];
    final ap = h >= 12 ? 'PM' : 'AM';
    h = h % 12; if (h == 0) h = 12;
    return '$h:$m $ap';
  }
}
