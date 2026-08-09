// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../layout/main_layout.dart'; // transferPendingCountProvider, userBranchIdsProvider
import '../../features/auth/auth_controller.dart';

/// Set by the transfer alert's "Open & Accept" button to the transfer id the
/// user should open. The Stock Transfers screen watches this and opens that
/// transfer (where Approve & Receive lives), then clears it to null.
final transferOpenRequestProvider = StateProvider<String?>((ref) => null);

/// App-global "transfer awaiting acceptance" alert. Mounted once in the shell so
/// it runs on EVERY screen while logged in — buzzer + banner fire even when the
/// Stock Transfers screen is not open and even when the tab is minimised.
///
/// Scope: any in_transit transfer touching a branch this user can see (either
/// endpoint), except one this user dispatched themselves. The buzzer is a
/// shorter 12-second klaxon. It stops when EITHER banner button is clicked:
/// "Open & Accept" (go accept it) or "Ignore" (silence it for this session; the
/// transfer stays pending and still counts on the badge).
class GlobalTransferAlert extends ConsumerStatefulWidget {
  const GlobalTransferAlert({super.key});
  static bool isActive = false;
  @override
  ConsumerState<GlobalTransferAlert> createState() => _GlobalTransferAlertState();
}

class _GlobalTransferAlertState extends ConsumerState<GlobalTransferAlert> {
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _buzzTimer;
  Timer? _buzzStop;
  Timer? _safety;
  html.AudioElement? _buzzEl;
  String _buzzUri = '';
  StreamSubscription<html.Event>? _visSub;
  bool _resubscribing = false;
  bool _booted = false;

  Set<String> _alertIds = {}; // in-scope pending transfers, minus ignored
  final Set<String> _ignored = {}; // "Ignore"d this session
  String? _targetId; // newest pending transfer -> what "Open & Accept" opens
  OverlayEntry? _banner;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _uid => ref.read(currentUserProvider)?.id;

  @override
  void initState() {
    super.initState();
    GlobalTransferAlert.isActive = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
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
    await _refresh();
    _subscribe(orgId);
    _safety = Timer.periodic(const Duration(seconds: 90), (_) => _refresh());
  }

  void _subscribe(String orgId) {
    if (_channel != null) return;
    _channel = Supabase.instance.client
        .channel('global_transfer_alert_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'stock_transfers',
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
    final orgId = _orgId;
    final uid = _uid;
    if (orgId == null) return;
    try {
      final branchIds = await ref.read(userBranchIdsProvider.future);
      final rows = await Supabase.instance.client
          .from('stock_transfers')
          .select('id, from_branch_id, to_branch_id, dispatched_by, dispatched_at')
          .eq('org_id', orgId)
          .eq('status', 'in_transit')
          .order('dispatched_at', ascending: false);
      final ids = <String>{};
      String? newest;
      for (final t in rows as List) {
        final id = t['id'] as String;
        // In scope for this user?
        final inScope = branchIds == null ||
            branchIds.contains(t['from_branch_id']) ||
            branchIds.contains(t['to_branch_id']);
        if (!inScope) continue;
        if ((t['dispatched_by'] as String?) == uid) continue; // not my own dispatch
        if (_ignored.contains(id)) continue; // silenced this session
        ids.add(id);
        newest ??= id;
      }
      final justArrived = ids.difference(_alertIds).isNotEmpty;
      _alertIds = ids;
      _targetId = newest;
      ref.invalidate(transferPendingCountProvider); // keep the nav badge live
      if (ids.isEmpty) {
        _disarm();
        _hideBanner();
      } else {
        if (_buzzTimer == null) {
          _buzz();
          _buzzTimer = Timer.periodic(const Duration(minutes: 5), (_) {
            if (_alertIds.isNotEmpty) {
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

  // ── Buzzer (shorter 12s klaxon) ─────────────────────────────────────────
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
      _buzzStop = Timer(const Duration(seconds: 12), () {
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

  // ── Banner ──────────────────────────────────────────────────────────────
  void _onIgnore() {
    _ignored.addAll(_alertIds); // silence exactly what's showing now
    _alertIds = {};
    _disarm();
    _hideBanner();
  }

  void _onOpenAccept(BuildContext ctx) {
    final id = _targetId;
    if (id != null) {
      ref.read(transferOpenRequestProvider.notifier).state = null;
      ref.read(transferOpenRequestProvider.notifier).state = id;
    }
    _disarm(); // stop the buzzer immediately on click
    _hideBanner();
    try {
      GoRouter.of(ctx).go('/erp/stock-transfers');
    } catch (_) {}
  }

  void _showBanner() {
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
            child: Container(
              constraints: const BoxConstraints(maxWidth: 560),
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
                const Icon(Icons.local_shipping, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      '$n stock transfer${n == 1 ? '' : 's'} awaiting acceptance',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: _onIgnore,
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                  child: const Text('Ignore', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => _onOpenAccept(ctx),
                  style: TextButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.deepOrange.shade800,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
                  child: const Text('Open & Accept', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                ),
              ]),
            ),
          ),
        ),
      );
    });
    overlay.insert(_banner!);
  }

  void _hideBanner() {
    _banner?.remove();
    _banner = null;
  }

  @override
  void dispose() {
    GlobalTransferAlert.isActive = false;
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
  Widget build(BuildContext context) => const SizedBox.shrink();
}
