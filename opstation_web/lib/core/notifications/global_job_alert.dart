// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../layout/main_layout.dart'; // jobAckPendingCountProvider
import '../permissions/access_control.dart'; // accessSyncProvider
import '../../features/auth/auth_controller.dart';

/// Set by the global alert's "Open & note" button to the job the user should
/// open. The Job Card screen watches this and opens that exact job (with its
/// acknowledge modal) — works whether the screen is already mounted or is being
/// navigated to fresh. The screen clears it back to null once consumed.
final jobCardOpenRequestProvider = StateProvider<String?>((ref) => null);

/// App-global "new job" alert. Mounted once in the shell so it runs on EVERY
/// screen while the user is logged in — the buzzer and banner fire even when the
/// Job Card screen is not open and even when the browser tab is minimised
/// (a backgrounded desktop tab still receives realtime messages and can play
/// audio). Gated by org.job_ack_flow. A job the current user created never
/// alerts them; the first person to click "Noted" (on the Job Card screen)
/// clears it for everyone via realtime.
class GlobalJobAlert extends ConsumerStatefulWidget {
  const GlobalJobAlert({super.key});

  /// True while this controller is mounted — the per-screen Job Card buzzer
  /// stands down when this is set so the alarm never double-plays.
  static bool isActive = false;

  @override
  ConsumerState<GlobalJobAlert> createState() => _GlobalJobAlertState();
}

class _GlobalJobAlertState extends ConsumerState<GlobalJobAlert> {
  bool _enabled = false;
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _buzzTimer; // 5-min repeat while alerts pending
  Timer? _buzzStop; // stops one 22s burst
  Timer? _safety; // periodic catch-up in case realtime drops
  html.AudioElement? _buzzEl;
  String _buzzUri = '';
  StreamSubscription<html.Event>? _visSub;
  bool _resubscribing = false;
  bool _booted = false;

  Set<String> _alertIds = {}; // unacked queued jobs NOT created by me
  final Set<String> _dismissed = {}; // banner dismissed (X / swipe) this session
  String? _targetId; // the newest unacked job — what "Open & note" opens
  OverlayEntry? _banner;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _uid => ref.read(currentUserProvider)?.id;

  @override
  void initState() {
    super.initState();
    GlobalJobAlert.isActive = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
    // Instantly catch up when the tab is un-minimised / refocused.
    _visSub = html.document.onVisibilityChange.listen((_) {
      if (html.document.visibilityState == 'visible') {
        final o = _orgId;
        if (o != null) _subscribe(o);
        _refresh();
      }
    });
  }

  Future<void> _boot() async {
    if (_booted) return;
    final orgId = _orgId;
    if (orgId == null) {
      Future.delayed(const Duration(seconds: 1), _boot);
      return;
    }
    _booted = true;
    await _loadConfig();
    if (!_enabled) return;
    await _refresh();
    _subscribe(orgId);
    // Safety net: re-check every 90s even if a realtime event is missed.
    _safety = Timer.periodic(const Duration(seconds: 90), (_) => _refresh());
  }

  bool _skipAdmin = false; // org.job_ack_skip_admin — admins get badge, no buzzer

  // Only users who can actually open the Job Card screen should be alerted.
  bool get _hasAccess =>
      ref.read(accessSyncProvider)?.canAccessRoute('/manufacturing/job-card') ??
      false;

  // Admins can opt out of the buzzer/banner (badge still shows) via the toggle.
  bool get _suppressForMe {
    if (!_skipAdmin) return false;
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin ||
        r == WebUserRole.masterAdmin ||
        r == WebUserRole.superAdmin;
  }

  Future<void> _loadConfig() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId)
          .inFilter('key', ['org.job_ack_flow', 'org.job_ack_skip_admin']);
      for (final r in rows as List) {
        final v = (r['value'] as String?)?.trim() == 'true';
        if (r['key'] == 'org.job_ack_flow') _enabled = v;
        if (r['key'] == 'org.job_ack_skip_admin') _skipAdmin = v;
      }
    } catch (_) {/* default off */}
  }

  // ── Realtime ──────────────────────────────────────────────────────────────
  void _subscribe(String orgId) {
    if (_channel != null || !_enabled) return;
    _channel = Supabase.instance.client
        .channel('global_job_alert_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'job_cards',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'org_id', value: orgId),
          callback: (_) => _scheduleRefresh(),
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
    Future.delayed(const Duration(seconds: 2), () {
      _resubscribing = false;
      if (!mounted) return;
      final ch = _channel;
      if (ch != null) {
        Supabase.instance.client.removeChannel(ch);
        _channel = null;
      }
      final orgId = _orgId;
      if (orgId != null) {
        _subscribe(orgId);
        _refresh();
      }
    });
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), _refresh);
  }

  Future<void> _refresh() async {
    if (!_enabled) return;
    final orgId = _orgId;
    final uid = _uid;
    if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('job_cards')
          .select('id, created_by, created_at')
          .eq('org_id', orgId)
          .eq('status', 'queued')
          .filter('acknowledged_at', 'is', null)
          .order('created_at', ascending: false);
      final ids = <String>{};
      String? newest;
      for (final j in rows as List) {
        final id = j['id'] as String;
        if ((j['created_by'] as String?) == uid) continue; // not my own
        if (_dismissed.contains(id)) continue; // dismissed this session
        ids.add(id);
        newest ??= id; // first row = newest (ordered desc)
      }
      final justArrived = ids.difference(_alertIds).isNotEmpty;
      _alertIds = ids;
      _targetId = newest;
      ref.invalidate(jobAckPendingCountProvider); // badge stays regardless
      // No Job Card access, or admins with the skip toggle on: keep the badge,
      // silence buzzer + banner.
      if (ids.isEmpty || !_hasAccess || _suppressForMe) {
        _disarm();
        _hideBanner();
      } else {
        if (_buzzTimer == null) {
          _buzz();
          _buzzTimer = Timer.periodic(const Duration(minutes: 5), (_) {
            if (_enabled && _alertIds.isNotEmpty) {
              _buzz();
            } else {
              _disarm();
            }
          });
        } else if (justArrived) {
          _buzz();
        }
        _showBanner();
      }
    } catch (_) {/* transient; safety timer / next event recovers */}
  }

  // ── Buzzer (loud 22s klaxon, synthesised WAV, no asset) ────────────────────
  void _disarm() {
    _buzzTimer?.cancel();
    _buzzTimer = null;
    _buzzStop?.cancel();
    _buzzStop = null;
    try { _buzzEl?.pause(); } catch (_) {}
  }

  void _buzz() {
    try {
      if (_buzzUri.isEmpty) _buzzUri = _buildBuzzerWav();
      final el = (_buzzEl ??= html.AudioElement()
        ..loop = true
        ..volume = 1.0);
      if (el.src != _buzzUri) el.src = _buzzUri;
      el.currentTime = 0;
      el.play();
      _buzzStop?.cancel();
      _buzzStop = Timer(const Duration(seconds: 22), () {
        try { _buzzEl?.pause(); } catch (_) {}
      });
    } catch (_) {}
  }

  String _buildBuzzerWav() {
    const sr = 11025;
    const n = sr;
    final samples = Int16List(n);
    for (var i = 0; i < n; i++) {
      final t = i / sr;
      final hi = (((t * 1000) ~/ 150) % 2) == 0;
      final f = hi ? 900.0 : 640.0;
      final phase = (t * f) % 1.0;
      samples[i] = (phase < 0.5 ? 26000 : -26000);
    }
    final pcm = samples.buffer.asUint8List();
    final dataLen = pcm.length;
    final header = ByteData(44);
    void s4(int off, String s) {
      for (var i = 0; i < 4; i++) header.setUint8(off + i, s.codeUnitAt(i));
    }
    s4(0, 'RIFF');
    header.setUint32(4, 36 + dataLen, Endian.little);
    s4(8, 'WAVE');
    s4(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sr, Endian.little);
    header.setUint32(28, sr * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    s4(36, 'data');
    header.setUint32(40, dataLen, Endian.little);
    final out = Uint8List(44 + dataLen);
    out.setRange(0, 44, header.buffer.asUint8List());
    out.setRange(44, 44 + dataLen, pcm);
    return 'data:audio/wav;base64,${base64Encode(out)}';
  }

  // ── Banner (floats over any screen while jobs await acknowledgement) ───────
  void _showBanner() {
    final count = _alertIds.length;
    if (_banner != null) {
      _banner!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _banner = OverlayEntry(builder: (ctx) {
      final n = _alertIds.length;
      return Positioned(
        top: 10,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              // Swipe up to dismiss.
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < 0) _onDismiss();
              },
              child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              decoration: BoxDecoration(
                color: Colors.deepOrange.shade700,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 16, offset: const Offset(0, 4)),
                ],
              ),
              child: Row(children: [
                const Icon(Icons.notifications_active, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      '$n new job${n == 1 ? '' : 's'} need acknowledgement',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () {
                    // Hand the exact job to the Job Card screen, then open it.
                    final id = _targetId;
                    if (id != null) {
                      // Clear-then-set guarantees a change event even if the
                      // same job was the previous request.
                      ref.read(jobCardOpenRequestProvider.notifier).state = null;
                      ref.read(jobCardOpenRequestProvider.notifier).state = id;
                    }
                    try {
                      GoRouter.of(ctx).go('/manufacturing/job-card');
                    } catch (_) {}
                  },
                  style: TextButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.deepOrange.shade800,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
                  child: const Text('Open & note', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                ),
                // Dismiss (also swipe up). Silences the banner + buzzer for these
                // jobs this session; the pending badge still shows.
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                  onPressed: _onDismiss,
                ),
              ]),
            ),
            ),
          ),
        ),
      );
    });
    overlay.insert(_banner!);
    // ignore: unused_local_variable
    final _ = count;
  }

  void _onDismiss() {
    _dismissed.addAll(_alertIds);
    _alertIds = {};
    _disarm();
    _hideBanner();
  }

  void _hideBanner() {
    _banner?.remove();
    _banner = null;
  }

  @override
  void dispose() {
    GlobalJobAlert.isActive = false;
    _visSub?.cancel();
    _debounce?.cancel();
    _safety?.cancel();
    _disarm();
    try { _buzzEl?.pause(); } catch (_) {}
    _hideBanner();
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-evaluate once access finishes resolving (it loads asynchronously).
    ref.listen(accessSyncProvider, (_, __) {
      if (mounted) _refresh();
    });
    return const SizedBox.shrink();
  }
}
