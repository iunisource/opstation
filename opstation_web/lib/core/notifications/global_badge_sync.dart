// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../layout/main_layout.dart';
import '../../features/auth/auth_controller.dart';

/// Headless controller mounted once in the shell. It listens to realtime
/// changes on every table that drives an approval / supervision badge and
/// invalidates the matching count providers, so the sidebar counters refresh
/// the instant a voucher lands for approval or is supervised/approved — no page
/// reload needed. Renders nothing (SizedBox.shrink).
///
/// Requires the source tables to be in the `supabase_realtime` publication
/// (see the accompanying SQL migration). A 90s safety poll and resubscribe-on-
/// error keep counters correct even if a realtime event is dropped.
class GlobalBadgeSync extends ConsumerStatefulWidget {
  const GlobalBadgeSync({super.key});

  @override
  ConsumerState<GlobalBadgeSync> createState() => _GlobalBadgeSyncState();
}

class _GlobalBadgeSyncState extends ConsumerState<GlobalBadgeSync> {
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _safety;
  StreamSubscription<html.Event>? _visSub;
  bool _resubscribing = false;
  bool _booted = false;

  // Admin "new PO landed" ping.
  Object? _audio;                 // Web Audio context
  bool _audioUnlocked = false;
  StreamSubscription<html.Event>? _gestureSub;
  int? _lastPoPending;            // last seen pending-PO count (null until first read)

  bool get _isAdmin {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
  }

  // Every table whose rows change an approval / supervision counter.
  static const _tables = <String>[
    'purchase_invoices', // piReviewPendingProvider
    'purchase_return_invoices', // priReviewPendingProvider
    'sales_invoices', // siReviewPendingProvider
    'purchase_grns', // grnPendingInvoiceCountProvider + grnSupervisePendingProvider
    'purchase_orders', // poPendingApprovalCountProvider
    'customers', // customerSupervisePendingProvider
    'suppliers', // supplierPendingCountProvider
    'field_orders', // fieldOrderPendingCountProvider
    'retailer_orders', // retailerOrderPendingCountProvider
    'products', // productSupervisePendingProvider
  ];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
    // Instantly catch up when the tab is un-minimised / refocused.
    _visSub = html.document.onVisibilityChange.listen((_) {
      if (html.document.visibilityState == 'visible') {
        final o = _orgId;
        if (o != null) _subscribe(o);
        _refresh();
      }
    });
    // Browsers block audio until a user gesture — unlock on the first one.
    _gestureSub = html.document.onPointerDown.listen((_) => _ensureAudio());
    html.document.onKeyDown.listen((_) => _ensureAudio());
  }

  // ── admin ping ─────────────────────────────────────────────────────────────
  void _ensureAudio() {
    try {
      if (_audio == null) {
        var ctor = js_util.getProperty(html.window, 'AudioContext');
        ctor ??= js_util.getProperty(html.window, 'webkitAudioContext');
        if (ctor == null) return;
        _audio = js_util.callConstructor(ctor, const []);
      }
      final ctx = _audio;
      if (ctx != null && js_util.getProperty(ctx, 'state') == 'suspended') {
        js_util.callMethod(ctx, 'resume', const []);
      }
      _audioUnlocked = true;
    } catch (_) {}
  }

  // Two-tone "ping" for a newly-landed PO.
  void _ping() {
    if (!_audioUnlocked) return;
    final ctx = _audio;
    if (ctx == null) return;
    try {
      final now = js_util.getProperty(ctx, 'currentTime') as num;
      final dest = js_util.getProperty(ctx, 'destination');
      void tone(double freq, double start, double dur, double vol) {
        final osc = js_util.callMethod(ctx, 'createOscillator', const []);
        final gain = js_util.callMethod(ctx, 'createGain', const []);
        js_util.callMethod(osc, 'connect', [gain]);
        js_util.callMethod(gain, 'connect', [dest]);
        js_util.setProperty(osc, 'type', 'sine');
        js_util.setProperty(js_util.getProperty(osc, 'frequency'), 'value', freq);
        js_util.setProperty(js_util.getProperty(gain, 'gain'), 'value', vol);
        final t0 = now + start;
        js_util.callMethod(osc, 'start', [t0]);
        js_util.callMethod(osc, 'stop', [t0 + dur]);
      }
      tone(1046, 0.0, 0.14, 0.35);   // C6
      tone(1568, 0.15, 0.18, 0.35);  // G6
    } catch (_) {}
  }

  // After a refresh, ping admins if the pending-PO count went UP (a PO landed).
  Future<void> _checkPoPing() async {
    if (!_isAdmin) return;
    try {
      final n = await ref.read(poPendingApprovalCountProvider.future);
      if (_lastPoPending != null && n > _lastPoPending!) _ping();
      _lastPoPending = n;
    } catch (_) {}
  }

  Future<void> _boot() async {
    if (_booted) return;
    final orgId = _orgId;
    if (orgId == null) {
      Future.delayed(const Duration(seconds: 1), _boot);
      return;
    }
    _booted = true;
    _subscribe(orgId);
    _checkPoPing(); // seed the PO baseline (no ping on first read)
    // Safety net: re-check every 90s even if a realtime event is missed.
    _safety = Timer.periodic(const Duration(seconds: 90), (_) => _refresh());
  }

  void _subscribe(String orgId) {
    if (_channel != null) return;
    var ch = Supabase.instance.client.channel('global_badge_sync_$orgId');
    for (final t in _tables) {
      ch = ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: t,
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq, column: 'org_id', value: orgId),
        callback: (_) => _scheduleRefresh(),
      );
    }
    _channel = ch.subscribe((status, [error]) {
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
    _debounce = Timer(const Duration(milliseconds: 300), _refresh);
  }

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(piReviewPendingProvider);
    ref.invalidate(priReviewPendingProvider);
    ref.invalidate(siReviewPendingProvider);
    ref.invalidate(grnPendingInvoiceCountProvider);
    ref.invalidate(grnSupervisePendingProvider);
    ref.invalidate(customerSupervisePendingProvider);
    ref.invalidate(poPendingApprovalCountProvider);
    ref.invalidate(supplierPendingCountProvider);
    ref.invalidate(fieldOrderPendingCountProvider);
    ref.invalidate(retailerOrderPendingCountProvider);
    ref.invalidate(productSupervisePendingProvider);
    _checkPoPing(); // ping admins if a new PO just landed
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _safety?.cancel();
    _visSub?.cancel();
    _gestureSub?.cancel();
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
