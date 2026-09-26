// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../layout/main_layout.dart'; // poRejectedUnackedCountProvider
import '../../features/auth/auth_controller.dart';

/// App-global "your Purchase Order was rejected" alert for the PO's CREATOR.
/// Mounted once in the shell so it works on every screen. When a PO this user
/// created is rejected (and not yet acknowledged) it plays a short ding and
/// shows a banner with the approver's reason. "Acknowledge" records the
/// acknowledgement (clears the badge + adds an audit-trail entry); "Open" jumps
/// to the PO; "×" hides the banner for this session (badge stays until acked).
class GlobalPoRejectAlert extends ConsumerStatefulWidget {
  const GlobalPoRejectAlert({super.key});
  @override
  ConsumerState<GlobalPoRejectAlert> createState() => _GlobalPoRejectAlertState();
}

class _GlobalPoRejectAlertState extends ConsumerState<GlobalPoRejectAlert> {
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _safety;
  StreamSubscription<html.Event>? _visSub;
  bool _booted = false;

  List<Map<String, dynamic>> _rows = []; // my rejected + unacked POs, newest first
  final Set<String> _dinged = {}; // already chimed for this session
  final Set<String> _hidden = {}; // banner dismissed this session
  OverlayEntry? _banner;
  html.AudioElement? _ding;
  bool _busy = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _uid => ref.read(currentUserProvider)?.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
    _visSub = html.document.onVisibilityChange.listen((_) {
      if (html.document.visibilityState == 'visible') _refresh();
    });
  }

  Future<void> _boot() async {
    if (_booted) return;
    final orgId = _orgId;
    if (orgId == null || _uid == null) {
      Future.delayed(const Duration(seconds: 1), _boot);
      return;
    }
    _booted = true;
    await _refresh();
    _subscribe(orgId);
    // Safety net in case realtime isn't enabled on purchase_orders.
    _safety = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
  }

  void _subscribe(String orgId) {
    if (_channel != null) return;
    _channel = Supabase.instance.client
        .channel('global_po_reject_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'purchase_orders',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'org_id', value: orgId),
          callback: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), _refresh);
          },
        )
        .subscribe();
  }

  Future<void> _refresh() async {
    final orgId = _orgId;
    final uid = _uid;
    if (orgId == null || uid == null || !mounted) return;
    try {
      final res = await Supabase.instance.client
          .from('purchase_orders')
          .select('id, voucher_number, rejected_at, rejected_by_name, reject_reason')
          .eq('org_id', orgId)
          .eq('created_by', uid)
          .not('rejected_at', 'is', null)
          .filter('reject_ack_at', 'is', null)
          .filter('voided_at', 'is', null)
          .order('rejected_at', ascending: false);
      _rows = List<Map<String, dynamic>>.from(res as List);
      ref.invalidate(poRejectedUnackedCountProvider);
      final ids = {for (final r in _rows) r['id'] as String};
      final fresh = ids.difference(_dinged);
      if (fresh.isNotEmpty) {
        _dinged.addAll(fresh);
        _hidden.removeAll(fresh); // a new rejection re-shows the banner
        _playDing();
      }
      final visible = _rows.where((r) => !_hidden.contains(r['id'])).toList();
      if (visible.isEmpty) {
        _hideBanner();
      } else {
        _showBanner();
      }
    } catch (_) {/* transient; next tick retries */}
  }

  List<Map<String, dynamic>> get _visible =>
      _rows.where((r) => !_hidden.contains(r['id'])).toList();

  Future<void> _acknowledge(Map<String, dynamic> r) async {
    if (_busy) return;
    _busy = true;
    _banner?.markNeedsBuild();
    final u = ref.read(currentUserProvider);
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      final client = Supabase.instance.client;
      await client.from('purchase_orders').update({
        'reject_ack_at': now, 'reject_ack_by': u?.id, 'updated_at': now,
      }).eq('id', r['id']);
      await client.from('voucher_audit_log').insert({
        'id': 'val_${DateTime.now().microsecondsSinceEpoch}',
        'org_id': _orgId, 'voucher_id': r['id'], 'voucher_type': 'PO',
        'action': 'rejection_acknowledged',
        'details': 'Rejection acknowledged by ${u?.name ?? ''}',
        'performed_by': u?.id, 'performed_at': now,
      });
    } catch (_) {/* refresh below shows the true state */}
    _busy = false;
    await _refresh();
  }

  void _open(BuildContext ctx, String id) {
    _hideBanner();
    _hidden.addAll(_rows.map((r) => r['id'] as String));
    try {
      GoRouter.of(ctx).go('/erp/purchase?focus=$id');
    } catch (_) {}
  }

  void _dismiss() {
    _hidden.addAll(_rows.map((r) => r['id'] as String));
    _hideBanner();
  }

  // ── Banner ──────────────────────────────────────────────────────────────
  void _showBanner() {
    if (_banner != null) {
      _banner!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _banner = OverlayEntry(builder: (ctx) {
      final list = _visible;
      if (list.isEmpty) return const SizedBox.shrink();
      final r = list.first;
      final more = list.length - 1;
      final by = (r['rejected_by_name'] as String?) ?? '';
      final reason = ((r['reject_reason'] as String?) ?? '').trim();
      return Positioned(
        top: 64,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 600),
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(
                color: Colors.red.shade700,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 16, offset: const Offset(0, 4)),
                ],
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.cancel_outlined, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      '${r['voucher_number'] ?? 'Purchase Order'} was rejected'
                      '${by.isNotEmpty ? ' by $by' : ''}'
                      '${more > 0 ? '  (+$more more)' : ''}',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    if (reason.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text('Reason: $reason',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                    ],
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      TextButton(
                        onPressed: _busy ? null : () => _acknowledge(r),
                        style: TextButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.red.shade800,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
                        child: const Text('Acknowledge', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: () => _open(ctx, r['id'] as String),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white70),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
                        child: const Text('Open PO', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                      ),
                    ]),
                  ]),
                ),
                IconButton(
                  tooltip: 'Hide (stays on the badge until acknowledged)',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                  onPressed: _dismiss,
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

  // ── Ding (single short two-tone chime) ──────────────────────────────────
  void _playDing() {
    try {
      final el = (_ding ??= html.AudioElement()..volume = 1.0);
      if ((el.src).isEmpty) el.src = _buildDingWav();
      el.currentTime = 0;
      el.play();
    } catch (_) {}
  }

  String _buildDingWav() {
    const sr = 11025;
    final n = (sr * 0.9).toInt();
    const twoPi = 2 * math.pi;
    final samples = Int16List(n);
    for (var i = 0; i < n; i++) {
      final t = i / sr;
      final double freq, tSeg;
      if (t < 0.35) {
        freq = 880.0; // A5
        tSeg = t;
      } else {
        freq = 659.25; // E5 — a falling "ding-dong"
        tSeg = t - 0.35;
      }
      final attack = tSeg < 0.006 ? tSeg / 0.006 : 1.0;
      final decay = math.exp(-tSeg * 6.0);
      final tail = t > 0.86 ? (0.9 - t) / 0.04 : 1.0;
      final env = attack * decay * (tail < 0 ? 0.0 : tail);
      samples[i] = (math.sin(twoPi * freq * tSeg) * env * 16000.0).round().clamp(-32767, 32767);
    }
    final pcm = samples.buffer.asUint8List();
    final header = ByteData(44);
    void s4(int off, String s) {
      for (var i = 0; i < 4; i++) header.setUint8(off + i, s.codeUnitAt(i));
    }
    s4(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
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
    header.setUint32(40, pcm.length, Endian.little);
    final out = Uint8List(44 + pcm.length);
    out.setRange(0, 44, header.buffer.asUint8List());
    out.setRange(44, 44 + pcm.length, pcm);
    return 'data:audio/wav;base64,${base64Encode(out)}';
  }

  @override
  void dispose() {
    _visSub?.cancel();
    _debounce?.cancel();
    _safety?.cancel();
    try { _ding?.pause(); } catch (_) {}
    _hideBanner();
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
