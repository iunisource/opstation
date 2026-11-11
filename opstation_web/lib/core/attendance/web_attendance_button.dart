// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/auth_controller.dart';
import '../theme/app_theme.dart';
import '../utils/friendly_error.dart';

/// Top-bar attendance button for ERP users (SQL 460, Admin Settings →
/// "Web check-in on office Wi-Fi").
///  • On an office network and not checked in → the icon throbs blue.
///  • 15 min before the shift ends (checked in, not out) → throbs orange and a
///    "Don't forget to check out" popup opens once.
///  • "Not now" / "Dismiss" stops the throbbing for the rest of the day.
class WebAttendanceButton extends ConsumerStatefulWidget {
  const WebAttendanceButton({super.key});
  @override
  ConsumerState<WebAttendanceButton> createState() => _WebAttendanceButtonState();
}

class _WebAttendanceButtonState extends ConsumerState<WebAttendanceButton> with SingleTickerProviderStateMixin {
  static const _remindBeforeMin = 15;
  static const _snoozeMin = 10;

  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  Map<String, dynamic>? _s;
  DateTime _fetchedAt = DateTime.now();
  Timer? _refreshTimer;
  Timer? _tickTimer;
  bool _dialogOpen = false;
  bool _busy = false;
  String? _orgId;
  String? _userId;

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) => _refresh());
    _tickTimer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _tickTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  // ── data ──────────────────────────────────────────────────────────────────
  Future<void> _refresh() async {
    final u = ref.read(currentUserProvider);
    if (u == null || u.role != WebUserRole.erpUser || u.orgId == null) {
      if (_s != null && mounted) setState(() => _s = null);
      return;
    }
    _orgId = u.orgId;
    _userId = u.id;
    _noteUser(u.id);
    try {
      final r = await _db.rpc('web_attendance_status', params: {'p_org': u.orgId});
      if (!mounted) return;
      setState(() {
        _s = r is Map ? Map<String, dynamic>.from(r) : null;
        _fetchedAt = DateTime.now();
      });
      _tick();
    } catch (_) {
      // SQL 460 not run yet, or offline — stay hidden.
    }
  }

  // ── this computer (for quiet screening of punches) ──────────────────────
  static String _deviceId() {
    const k = 'opstation.device_id';
    try {
      final v = html.window.localStorage[k];
      if (v != null && v.isNotEmpty) return v;
      final r = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final id = 'dev_${r}_${(DateTime.now().hashCode ^ r.hashCode).toRadixString(36)}';
      html.window.localStorage[k] = id;
      return id;
    } catch (_) {
      return '';
    }
  }

  /// Remembers who used this browser before the current login.
  static void _noteUser(String id) {
    try {
      final last = html.window.localStorage['opstation.device.last_user'];
      if (last != null && last.isNotEmpty && last != id) {
        html.window.localStorage['opstation.device.prev_user'] =
            jsonEncode({'id': last, 'at': DateTime.now().millisecondsSinceEpoch});
      }
      html.window.localStorage['opstation.device.last_user'] = id;
    } catch (_) {}
  }

  static String? _prevUser() {
    try {
      final raw = html.window.localStorage['opstation.device.prev_user'];
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map;
      final at = DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt());
      if (DateTime.now().difference(at) > const Duration(hours: 12)) return null;
      return m['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  bool get _enabled => _s?['enabled'] == true;
  bool get _linked => _enabled && _s?['employee'] == true;
  bool get _onOffice => _s?['on_office'] == true;
  String? get _in => _s?['check_in'] as String?;
  String? get _out => _s?['check_out'] as String?;
  String get _day => '${_s?['day'] ?? ''}';

  // Per user, per day: dismissals + snooze, kept in this browser.
  String get _key => 'opstation.att.${_userId ?? ''}.$_day';
  Map<String, dynamic> _mem() {
    try {
      final raw = html.window.localStorage[_key];
      return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  void _setMem(String k, dynamic v) {
    try {
      final m = _mem()..[k] = v;
      html.window.localStorage[_key] = jsonEncode(m);
    } catch (_) {}
  }

  static int? _min(String? hhmm) {
    if (hhmm == null || !hhmm.contains(':')) return null;
    final p = hhmm.split(':');
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    return (h == null || m == null) ? null : h * 60 + m;
  }

  /// Company-time minutes now (server clock at fetch + time since).
  int? get _nowMin {
    final base = _min(_s?['now'] as String?);
    if (base == null) return null;
    return (base + DateTime.now().difference(_fetchedAt).inMinutes) % 1440;
  }

  bool get _needIn => _linked && _onOffice && _in == null && _mem()['inDismiss'] != true;

  bool get _dueOut {
    if (!_linked || _in == null || _out != null) return false;
    final m = _mem();
    if (m['outDismiss'] == true) return false;
    final snooze = m['snooze'] as int?;
    if (snooze != null && DateTime.now().millisecondsSinceEpoch < snooze) return false;
    final end = _min((_s?['shift'] as Map?)?['end'] as String?);
    final now = _nowMin;
    if (end == null || now == null) return false;
    final diff = (now - (end - _remindBeforeMin)) % 1440; // minutes since reminder time
    return diff >= 0 && diff <= 240;
  }

  void _tick() {
    if (!mounted) return;
    final throb = _needIn || _dueOut;
    if (throb && !_pulse.isAnimating) _pulse.repeat(reverse: true);
    if (!throb && _pulse.isAnimating) { _pulse.stop(); _pulse.value = 0; }
    setState(() {});
    if (_dueOut && !_dialogOpen) _showCheckoutReminder();
  }

  Future<void> _punch(String dir) async {
    if (_busy || _orgId == null) return;
    setState(() => _busy = true);
    try {
      final r = await _db.rpc('web_attendance_punch', params: {
        'p_org': _orgId,
        'p_dir': dir,
        'p_device': _deviceId(),
        'p_signed_in_at': _db.auth.currentUser?.lastSignInAt,
        'p_prev_user': _prevUser(),
      });
      final t = r is Map ? '${r['time'] ?? ''}' : '';
      _snack(dir == 'in' ? 'Checked in${t.isEmpty ? '' : ' at ${_fmt(t)}'}' : 'Checked out${t.isEmpty ? '' : ' at ${_fmt(t)}'}');
    } catch (e) {
      _snack(friendlyError(dir == 'in' ? 'Could not check in' : 'Could not check out', e));
    }
    if (mounted) setState(() => _busy = false);
    await _refresh();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  static String _fmt(String? hhmm) {
    final m = _min(hhmm);
    if (m == null) return hhmm ?? '';
    return DateFormat('h:mm a').format(DateTime(2000, 1, 1, m ~/ 60, m % 60));
  }

  String _worked() {
    final a = _min(_in), n = _nowMin;
    if (a == null || n == null) return '';
    var d = n - a;
    if (d < 0) d += 1440;
    return '${d ~/ 60} h ${d % 60} m so far';
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    ref.listen(currentUserProvider, (_, __) => _refresh());
    if (!_enabled) return const SizedBox.shrink();
    final orange = _dueOut;
    final active = _needIn || orange;
    final c = orange ? const Color(0xFFF59E0B) : AppTheme.primary;
    final done = _in != null && _out != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: !_linked ? 'Attendance' : done ? 'Attendance done for today' : _in != null ? 'Check out' : 'Check in',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _openPanel,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) {
              final t = active ? _pulse.value : 0.0;
              return Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? c : Colors.transparent,
                  border: active ? null : Border.all(color: Colors.white.withOpacity(0.35)),
                  boxShadow: active
                      ? [
                          BoxShadow(color: c.withOpacity(0.25 + 0.35 * t), spreadRadius: 2 + 4 * t),
                          BoxShadow(color: c.withOpacity(0.35 + 0.45 * t), blurRadius: 10 + 16 * t, spreadRadius: 1 + 4 * t),
                        ]
                      : null,
                ),
                child: Icon(done ? Icons.task_alt_rounded : Icons.timer_outlined, size: 18, color: Colors.white),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openPanel() async {
    await _refresh();
    if (!mounted || !_enabled) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.08),
      builder: (ctx) => Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 60, right: 70),
          child: Material(
            color: Colors.white,
            elevation: 12,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(width: 310, child: _panel(ctx)),
          ),
        ),
      ),
    );
    _tick();
  }

  Widget _panel(BuildContext ctx) {
    final first = '${_s?['name'] ?? ''}'.trim().split(' ').first;
    final h = DateTime.now().hour;
    final hi = h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
    final shift = _s?['shift'] as Map?;
    final shiftLine = shift == null
        ? null
        : [
            if ('${shift['name'] ?? ''}'.isNotEmpty) '${shift['name']}',
            if (shift['start'] != null && shift['end'] != null) '${_fmt(shift['start'] as String?)} – ${_fmt(shift['end'] as String?)}',
          ].join(' · ');
    Widget netChip() => Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: _onOffice ? const Color(0xFFECFDF5) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            _onOffice ? '●  On office network · ${_s?['network'] ?? ''}' : '●  Not on an office network — goes for review',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700,
                color: _onOffice ? const Color(0xFF047857) : const Color(0xFF64748B)),
          ),
        );
    Widget btn(String label, Color color, VoidCallback? onTap) => SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: color, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            ),
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        );
    Widget link(String label, VoidCallback onTap) => Center(
          child: TextButton(onPressed: onTap, child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        );

    if (!_linked) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Attendance', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          SizedBox(height: 6),
          Text('Your login is not linked to an employee record yet, so you can\'t check in from here. '
              'Ask HR to pick your login under "Opstation login" on your employee record.',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.4)),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$hi${first.isEmpty ? '' : ', $first'}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        if (shiftLine != null && shiftLine.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 3),
              child: Text(shiftLine, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        netChip(),
        const SizedBox(height: 10),
        Text(DateFormat('h:mm a').format(DateTime.now()),
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        const SizedBox(height: 10),
        if (_in == null) ...[
          btn('Check in', AppTheme.primary, !_busy ? () { Navigator.pop(ctx); _punch('in'); } : null),
          if (_onOffice)
            link('Not now — stop reminding me today', () { _setMem('inDismiss', true); Navigator.pop(ctx); _tick(); })
          else
            const SizedBox(height: 10),
        ] else if (_out == null) ...[
          Text('Checked in at ${_fmt(_in)} · ${_worked()}', style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          const SizedBox(height: 10),
          btn('Check out', const Color(0xFFF59E0B), !_busy ? () { Navigator.pop(ctx); _punch('out'); } : null),
          const SizedBox(height: 10),
        ] else ...[
          Text('Checked in at ${_fmt(_in)} · out at ${_fmt(_out)}. All done for today.',
              style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          const SizedBox(height: 10),
        ],
      ]),
    );
  }

  Future<void> _showCheckoutReminder() async {
    if (!mounted) return;
    _dialogOpen = true;
    final end = _fmt((_s?['shift'] as Map?)?['end'] as String?);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 380,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFFFFF7ED), boxShadow: [
                  BoxShadow(color: const Color(0xFFF59E0B).withOpacity(0.15), spreadRadius: 6),
                  BoxShadow(color: const Color(0xFFF59E0B).withOpacity(0.35), blurRadius: 22, spreadRadius: 4),
                ]),
                child: const Icon(Icons.alarm_rounded, color: Color(0xFFF59E0B), size: 28),
              ),
              const SizedBox(height: 14),
              const Text("Don't forget to check out", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('Your shift ends at $end. Checked in at ${_fmt(_in)} · ${_worked()}.',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.4)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, 'later'),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)),
                  child: const Text('Remind me later'))),
                const SizedBox(width: 8),
                Expanded(child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, 'out'),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF59E0B), foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13)),
                  child: const Text('Check out now', style: TextStyle(fontWeight: FontWeight.w700)))),
              ]),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'dismiss'),
                child: const Text('Dismiss — stop reminding me today', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
            ]),
          ),
        ),
      ),
    );
    if (choice == 'out') {
      await _punch('out');
    } else if (choice == 'dismiss') {
      _setMem('outDismiss', true);
    } else {
      // "Remind me later" or closed: ask again in a few minutes.
      _setMem('snooze', DateTime.now().add(const Duration(minutes: _snoozeMin)).millisecondsSinceEpoch);
    }
    _dialogOpen = false;
    _tick();
  }
}
