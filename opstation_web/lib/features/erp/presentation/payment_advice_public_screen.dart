import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Public, no-login copy of a Payment Advice, opened by scanning the QR code on
/// the printed slip:  https://<app>/#/pa/<public_token>
///
/// Read-only. Shows what is needed to verify the slip against the system
/// record — parties, bank details, amounts to pay, total, status and who
/// created / approved it and when. The party's current balance is not shown.
class PaymentAdvicePublicScreen extends StatefulWidget {
  final String token;
  const PaymentAdvicePublicScreen({super.key, required this.token});
  @override
  State<PaymentAdvicePublicScreen> createState() => _PaymentAdvicePublicScreenState();
}

class _PaymentAdvicePublicScreenState extends State<PaymentAdvicePublicScreen> {
  static const _brand = Color(0xFF2F6FED);
  static const _ink = Color(0xFF0F1729);
  static const _muted = Color(0xFF6B7280);
  static const _rule = Color(0xFFE5E7EB);

  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  Map<String, dynamic>? _a;
  DateTime? _updatedAt;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Live: re-read every 30 s so an open page follows edits / approval /
    // cancellation without the link being shared again.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (silent && (_loading || _refreshing)) return;
    setState(() {
      if (silent) {
        _refreshing = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final res = await Supabase.instance.client
          .rpc('public_payment_advice', params: {'p_token': widget.token});
      final m = res is Map ? Map<String, dynamic>.from(res) : null;
      if (!mounted) return;
      setState(() {
        if (m == null || m['ok'] != true) {
          _error = 'not_found';
          _a = null;
        } else {
          _a = m;
          _error = null;
          _updatedAt = DateTime.now();
        }
        _loading = false;
        _refreshing = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          // A failed background refresh keeps the last good copy on screen.
          if (!silent || _a == null) _error = 'network';
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  static String _money(num? v) {
    final d = (v ?? 0).toDouble();
    final f = d == d.roundToDouble() ? NumberFormat('#,##0') : NumberFormat('#,##0.00');
    return 'Rs ${f.format(d)}';
  }

  static String _dt(Object? v, {bool time = true}) {
    final d = DateTime.tryParse('${v ?? ''}');
    if (d == null) return '—';
    return DateFormat(time ? 'd MMM yyyy, HH:mm' : 'd MMM yyyy').format(d.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _errorView()
                : _withWatermark(_body()),
      ),
    );
  }

  /// Cancelled / rejected advices get a visible repeated watermark across the
  /// whole page, so a forwarded screenshot can't pass as payable.
  Widget _withWatermark(Widget child) {
    final st = (_a?['status'] as String?) ?? '';
    final mark = st == 'void' ? 'CANCELLED' : st == 'rejected' ? 'REJECTED' : null;
    if (mark == null) return child;
    return Stack(children: [
      child,
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(painter: _WatermarkPainter(mark)),
        ),
      ),
    ]);
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_error == 'network' ? Icons.wifi_off : Icons.search_off, size: 44, color: _muted),
            const SizedBox(height: 12),
            Text(
              _error == 'network'
                  ? 'Could not reach the server. Check the connection and try again.'
                  : 'This payment advice could not be found. The code may be damaged or the advice no longer exists.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: _ink),
            ),
            if (_error == 'network') ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Try again')),
            ],
          ]),
        ),
      );

  Widget _body() {
    final a = _a!;
    final status = (a['status'] as String?) ?? 'approved';
    final (Color sc, String sl) = switch (status) {
      'void' => (const Color(0xFFB91C1C), 'CANCELLED'),
      'rejected' => (const Color(0xFFB91C1C), 'REJECTED'),
      'pending' => (const Color(0xFFB45309), 'PENDING APPROVAL'),
      _ => (const Color(0xFF15803D), 'APPROVED'),
    };
    final lines = List<Map<String, dynamic>>.from(
        ((a['lines'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Verified banner
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: status == 'void' || status == 'rejected'
                    ? const Color(0xFFFEE2E2)
                    : const Color(0xFFDCFCE7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Icon(
                    status == 'void' || status == 'rejected' ? Icons.cancel : Icons.verified,
                    color: sc),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status == 'void'
                        ? 'This payment advice was CANCELLED and must not be paid.'
                        : status == 'rejected'
                            ? 'This payment advice was REJECTED and must not be paid.'
                            : status == 'pending'
                                ? 'Genuine system record — still awaiting approval.'
                                : 'Genuine system record. Compare the printed copy with the details below.',
                    style: TextStyle(color: sc, fontWeight: FontWeight.w700, fontSize: 13.5),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _rule),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(((a['org_name'] as String?) ?? '').toUpperCase(),
                    style: const TextStyle(
                        color: _brand, fontWeight: FontWeight.w800, letterSpacing: 1.5, fontSize: 12)),
                const SizedBox(height: 6),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Payment Advice',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink)),
                      const SizedBox(height: 2),
                      Text('${a['advice_number'] ?? ''}  ·  ${_dt(a['advice_date'], time: false)}',
                          style: const TextStyle(color: _muted, fontSize: 13)),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        color: sc.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                    child: Text(sl,
                        style: TextStyle(color: sc, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1)),
                  ),
                ]),
                if (((a['note'] as String?) ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Note: ${(a['note'] as String).trim()}', style: const TextStyle(color: _muted, fontSize: 13)),
                ],
                if (status == 'void') ...[
                  const SizedBox(height: 8),
                  Text(
                    'Cancelled${a['voided_by_name'] != null ? ' by ${a['voided_by_name']}' : ''}'
                    '${a['voided_at'] != null ? ' on ${_dt(a['voided_at'])}' : ''}'
                    '${((a['void_reason'] as String?) ?? '').isNotEmpty ? ' — ${a['void_reason']}' : ''}',
                    style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 16),
                for (var i = 0; i < lines.length; i++) _lineTile(i, lines[i]),
                const Divider(height: 24),
                Row(children: [
                  const Text('GRAND TOTAL', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
                  const Spacer(),
                  Text(_money(a['grand_total'] as num?),
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: _brand)),
                ]),
                const SizedBox(height: 18),
                Wrap(spacing: 28, runSpacing: 14, children: [
                  _foot('CREATED BY', a['created_by_name'] as String?, _dt(a['created_at']),
                      a['created_signature_url'] as String?),
                  if (status == 'rejected')
                    _foot('REJECTED BY', a['rejected_by_name'] as String?, _dt(a['rejected_at']), null)
                  else
                    _foot(
                        'APPROVED BY',
                        a['approved_by_name'] as String?,
                        a['approved_at'] != null ? _dt(a['approved_at']) : 'Awaiting approval',
                        a['approved_signature_url'] as String?,
                        stamp: a['approved_stamp_url'] as String?),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Flexible(
                child: Text(
                    'Live copy · last updated ${DateFormat('d MMM yyyy, HH:mm:ss').format(_updatedAt ?? DateTime.now())}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _muted, fontSize: 11.5)),
              ),
              const SizedBox(width: 6),
              _refreshing
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton.icon(
                      onPressed: () => _load(silent: true),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Refresh', style: TextStyle(fontSize: 12)),
                    ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _lineTile(int i, Map<String, dynamic> l) {
    final bank = ((l['bank_details'] as String?) ?? '').trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _rule),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${i + 1}. ', style: const TextStyle(color: _muted, fontWeight: FontWeight.w600)),
          Expanded(
            child: Text((l['party_name'] as String?) ?? '',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: _ink)),
          ),
          Text(_money(l['amount_to_pay'] as num?),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: _ink)),
        ]),
        if (bank.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(bank, style: const TextStyle(fontSize: 12.5, color: _muted, height: 1.35)),
        ],
      ]),
    );
  }

  Widget _foot(String label, String? who, String when, String? sig, {String? stamp}) {
    return SizedBox(
      width: 220,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(fontSize: 10.5, color: _muted, fontWeight: FontWeight.w800, letterSpacing: 1)),
        const SizedBox(height: 3),
        Text(who ?? '—', style: const TextStyle(fontWeight: FontWeight.w700, color: _ink)),
        Text(when, style: const TextStyle(fontSize: 11.5, color: _muted)),
        if ((sig ?? '').isNotEmpty || (stamp ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              if ((sig ?? '').isNotEmpty)
                SizedBox(
                    height: 44,
                    width: 120,
                    child: Image.network(sig!, fit: BoxFit.contain, alignment: Alignment.centerLeft,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink())),
              if ((stamp ?? '').isNotEmpty)
                SizedBox(
                    height: 48,
                    width: 48,
                    child: Image.network(stamp!, fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink())),
            ]),
          ),
      ]),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  final String text;
  _WatermarkPainter(this.text);

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xFFB91C1C).withOpacity(0.13),
          fontSize: 30,
          fontWeight: FontWeight.w900,
          letterSpacing: 4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const gapX = 70.0, gapY = 110.0;
    final stepX = tp.width + gapX;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-math.pi / 6);
    final reach = math.sqrt(size.width * size.width + size.height * size.height);
    var row = 0;
    for (var y = -reach; y < reach; y += gapY, row++) {
      final shift = (row.isOdd ? stepX / 2 : 0.0);
      for (var x = -reach - shift; x < reach; x += stepX) {
        tp.paint(canvas, Offset(x, y));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WatermarkPainter old) => old.text != text;
}
