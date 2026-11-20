// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/auth_controller.dart';
import 'alert_chime.dart';
import 'floating_alert_card.dart';
import 'floating_alerts_model.dart';

/// Floating alerts, shown in a corner of the screen in addition to the bell: a new
/// notification for this person appears as a small card (with a chime) and goes away
/// after a few seconds. Mounted once in the shell; draws nothing when idle.
///
/// New notifications are noticed the instant they are written (realtime on
/// notification_recipients) and, as a safety net, by a check every 30 seconds.
/// Alerts are shown only while Opstation is open and visible; in the background
/// the browser push does the job, and what arrives meanwhile waits in the bell.
/// An alert that goes away by itself stays unread in the bell; opening it from the
/// alert marks it read. Options: Admin Settings → Floating alerts.
class FloatingAlertsHost extends ConsumerStatefulWidget {
  const FloatingAlertsHost({super.key});

  @override
  ConsumerState<FloatingAlertsHost> createState() => _FloatingAlertsHostState();
}

class _FloatingAlertsHostState extends ConsumerState<FloatingAlertsHost> {
  FloatingAlertSettings _s = const FloatingAlertSettings();
  final FloatingAlertQueue _q = FloatingAlertQueue();
  final Set<String> _seen = {};
  RealtimeChannel? _ch;
  Timer? _poll;
  Timer? _cfg;
  StreamSubscription<html.Event>? _g1, _g2, _g3;
  String? _uid;
  String? _org;
  bool _booted = false;
  bool _resubscribing = false;

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    // Browsers keep audio locked until the first click or key press.
    _g1 = html.document.onMouseDown.listen((_) => AlertChime.unlock());
    _g2 = html.document.onKeyDown.listen((_) => AlertChime.unlock());
    _g3 = html.document.onTouchStart.listen((_) => AlertChime.unlock());
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _teardown();
    _g1?.cancel();
    _g2?.cancel();
    _g3?.cancel();
    super.dispose();
  }

  void _teardown() {
    _poll?.cancel();
    _cfg?.cancel();
    _poll = null;
    _cfg = null;
    final ch = _ch;
    if (ch != null) {
      try {
        _db.removeChannel(ch);
      } catch (_) {}
      _ch = null;
    }
  }

  Future<void> _boot() async {
    if (_booted || !mounted) return;
    final u = ref.read(currentUserProvider);
    if (u == null || u.orgId == null) {
      Future.delayed(const Duration(seconds: 1), _boot);
      return;
    }
    _booted = true;
    _uid = u.id;
    _org = u.orgId;
    await _loadSettings();
    await _seed();
    if (!mounted) return;
    _subscribe();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _check());
    _cfg = Timer.periodic(const Duration(seconds: 60), (_) => _loadSettings());
  }

  /// Another person or organisation signed in: start again.
  void _restart() {
    _teardown();
    _seen.clear();
    _q.clear();
    _booted = false;
    if (mounted) setState(() {});
    _boot();
  }

  Future<void> _loadSettings() async {
    final org = _org;
    if (org == null) return;
    try {
      final rows = await _db
          .from('app_config')
          .select('key, value')
          .eq('org_id', org)
          .inFilter('key', FloatingAlertSettings.keys);
      final m = <String, String>{};
      for (final r in rows as List) {
        m.putIfAbsent('${r['key']}', () => '${r['value'] ?? ''}');
      }
      final s = FloatingAlertSettings.fromConfig(m);
      if (!mounted) return;
      setState(() {
        _s = s;
        _q.maxVisible = s.maxVisible;
        if (!s.enabled) _q.clear();
      });
    } catch (_) {}
  }

  Future<Set<String>> _unreadIds() async {
    final uid = _uid;
    if (uid == null) return {};
    final res = await _db
        .from('notification_recipients')
        .select('notification_id')
        .eq('recipient_user_id', uid)
        .filter('read_at', 'is', null)
        .limit(500);
    return {for (final r in res as List) '${r['notification_id']}'};
  }

  /// What is already unread when the page opens is not announced again.
  Future<void> _seed() async {
    try {
      _seen.addAll(await _unreadIds());
    } catch (_) {}
  }

  void _subscribe() {
    final uid = _uid;
    if (uid == null || _ch != null) return;
    _ch = _db
        .channel('floating_alerts_$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notification_recipients',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'recipient_user_id', value: uid),
          callback: (payload) {
            final id = payload.newRecord['notification_id'];
            if (id != null) _incoming('$id');
          },
        )
        .subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut ||
          status == RealtimeSubscribeStatus.closed) {
        _scheduleResubscribe();
      }
    });
  }

  void _scheduleResubscribe() {
    if (_resubscribing) return;
    _resubscribing = true;
    Future.delayed(const Duration(seconds: 3), () {
      _resubscribing = false;
      if (!mounted) return;
      final ch = _ch;
      if (ch != null) {
        try {
          _db.removeChannel(ch);
        } catch (_) {}
        _ch = null;
      }
      _subscribe();
      _check();
    });
  }

  /// The safety net: anything unread that was not seen before is new.
  Future<void> _check() async {
    if (!mounted || !_booted) return;
    try {
      for (final id in await _unreadIds()) {
        if (!_seen.contains(id)) await _incoming(id);
      }
    } catch (_) {}
  }

  bool get _tabVisible => html.document.visibilityState == 'visible';

  Future<void> _incoming(String id) async {
    if (!_seen.add(id)) return;
    if (_seen.length > 1000) {
      final drop = _seen.take(500).toList();
      _seen.removeAll(drop);
    }
    // A hidden tab, or alerts switched off: it is noted (so it never pops up later)
    // but not shown; the bell and the browser push carry it.
    if (!_s.enabled || !_tabVisible) return;
    try {
      final n = await _db
          .from('notifications')
          .select('id, title, body, link_url, created_at')
          .eq('id', id)
          .maybeSingle();
      if (n == null || !mounted) return;
      final alert = FloatingAlert(
        id: id,
        title: '${n['title'] ?? ''}'.trim().isEmpty ? 'Notification' : '${n['title']}'.trim(),
        body: '${n['body'] ?? ''}'.trim(),
        link: n['link_url'] as String?,
        createdAt: DateTime.tryParse('${n['created_at'] ?? ''}'),
      );
      final r = _q.add(alert);
      if (r == AddResult.shown && _s.chime) AlertChime.play();
      if (r != AddResult.duplicate && mounted) setState(() {});
    } catch (_) {}
  }

  void _dismiss(String id) {
    if (!mounted) return;
    setState(() => _q.dismiss(id));
  }

  Future<void> _open(FloatingAlert a) async {
    _dismiss(a.id);
    final uid = _uid;
    if (uid != null) {
      try {
        await _db
            .from('notification_recipients')
            .update({'read_at': DateTime.now().toUtc().toIso8601String()})
            .eq('notification_id', a.id)
            .eq('recipient_user_id', uid);
      } catch (_) {}
    }
    final link = a.link ?? '';
    if (link.isNotEmpty && !link.startsWith('http') && mounted) {
      try {
        context.go(link);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentUserProvider, (prev, next) {
      if (prev?.id != next?.id || prev?.orgId != next?.orgId) _restart();
    });
    if (!_s.enabled || _q.visible.isEmpty) return const SizedBox.shrink();
    final narrow = MediaQuery.of(context).size.width < 600;
    return Positioned(
      top: _s.bottom ? null : 64,
      bottom: _s.bottom ? 20 : null,
      right: narrow ? 8 : 20,
      left: narrow ? 8 : null,
      width: narrow ? null : 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: narrow ? CrossAxisAlignment.center : CrossAxisAlignment.end,
        children: [
          for (final a in _q.visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: FloatingAlertCard(
                key: ValueKey(a.id),
                alert: a,
                seconds: _s.seconds,
                pauseOnHover: _s.pauseOnHover,
                onClose: () => _dismiss(a.id),
                onOpen: () => _open(a),
                onExpired: () => _dismiss(a.id),
              ),
            ),
          if (_q.waiting.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF111B33),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 16, offset: const Offset(0, 6))],
              ),
              child: Text('${_q.waiting.length} more alert${_q.waiting.length == 1 ? '' : 's'} waiting',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
            ),
        ],
      ),
    );
  }
}
