import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Public, no-login page reached by scanning the QR on a printed job order:
///   https://<app>/#/f/<floor_token>
///
/// A factory worker (not a system user) taps Start when they begin, or
/// Finished when they're done. Both call the token-secured `floor-action` edge
/// function, which flips the job's On-the-Floor flags. Mobile-first, big touch
/// targets, works on any phone browser.
class FloorScanScreen extends StatefulWidget {
  final String token;
  const FloorScanScreen({super.key, required this.token});
  @override
  State<FloorScanScreen> createState() => _FloorScanScreenState();
}

class _FloorScanScreenState extends State<FloorScanScreen> {
  static const _brand = Color(0xFF2F6FED);
  static const _ink = Color(0xFF0F1729);

  bool _loading = true;
  bool _busy = false;
  String? _error;      // fatal load error code
  Map<String, dynamic>? _job;
  String? _doneMessage; // shown after a successful action

  @override
  void initState() { super.initState(); _load(); }

  Future<Map<String, dynamic>?> _call({String? action}) async {
    final body = <String, dynamic>{'token': widget.token};
    if (action != null) body['action'] = action;
    final res = await Supabase.instance.client.functions.invoke('floor-action', body: body);
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final d = await _call();
      if (!mounted) return;
      if (d == null || d['ok'] != true) {
        setState(() { _error = (d?['error'] as String?) ?? 'unknown'; _loading = false; });
      } else {
        setState(() { _job = d; _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _error = 'network'; _loading = false; });
    }
  }

  Future<void> _act(String action) async {
    setState(() { _busy = true; });
    try {
      final d = await _call(action: action);
      if (!mounted) return;
      if (d == null || d['ok'] != true) {
        _snack(_errorText((d?['error'] as String?) ?? 'unknown'));
        setState(() { _busy = false; if (d != null) _job = {..._job ?? {}, ...d}; });
      } else {
        setState(() {
          _job = d;
          _busy = false;
          _doneMessage = action == 'start'
              ? 'Job marked ON THE FLOOR. You can close this page.'
              : 'Job marked FINISHED. Your supervisor will post the final quantity.';
        });
      }
    } catch (_) {
      if (mounted) { _snack('Network problem — please try again.'); setState(() => _busy = false); }
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  String _errorText(String code) {
    switch (code) {
      case 'not_found':
      case 'bad_token': return 'This code isn\'t valid. Ask your supervisor for a fresh job order.';
      case 'closed': return 'This job is already completed or closed.';
      case 'network': return 'No connection. Check your internet and try again.';
      default: return 'Something went wrong. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FC),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _loading
                  ? const Padding(padding: EdgeInsets.only(top: 80), child: CircularProgressIndicator())
                  : _error != null
                      ? _errorCard()
                      : _card(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brandHeader() => Column(children: [
    Container(
      width: 54, height: 54, alignment: Alignment.center,
      decoration: BoxDecoration(color: _brand, borderRadius: BorderRadius.circular(14)),
      child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 26)),
    ),
    const SizedBox(height: 10),
    const Text('Opstation · Production', style: TextStyle(fontSize: 13, color: _ink, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
    const SizedBox(height: 18),
  ]);

  Widget _errorCard() => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 20, offset: const Offset(0, 8))]),
    child: Column(children: [
      _brandHeader(),
      const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 44),
      const SizedBox(height: 12),
      Text(_errorText(_error!), textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: _ink, height: 1.4)),
      const SizedBox(height: 18),
      OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 18), label: const Text('Try again')),
    ]),
  );

  Widget _card() {
    final j = _job!;
    final jobNo = (j['job_number'] as String?) ?? '—';
    final product = (j['product'] as String?) ?? '';
    final sku = (j['sku'] as String?) ?? '';
    final onFloor = j['on_floor'] == true;
    final finished = j['finished'] == true;
    final closed = j['closed'] == true;
    final canStart = j['can_start'] == true;
    final canFinish = j['can_finish'] == true;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 20, offset: const Offset(0, 8))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _brandHeader(),
        Text(jobNo, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: _ink)),
        if (product.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(product + (sku.isNotEmpty ? '  ·  $sku' : ''), textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF5B6473))),
        ],
        const SizedBox(height: 16),
        _statusPill(onFloor: onFloor, finished: finished, closed: closed),
        const SizedBox(height: 22),

        if (_doneMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF16A34A).withOpacity(0.10), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF16A34A).withOpacity(0.4))),
            child: Row(children: [
              const Icon(Icons.check_circle, color: Color(0xFF16A34A)), const SizedBox(width: 10),
              Expanded(child: Text(_doneMessage!, style: const TextStyle(fontSize: 14, color: Color(0xFF166534), fontWeight: FontWeight.w600))),
            ]),
          ),
        ] else if (closed) ...[
          const Text('This job is already completed or closed.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Color(0xFF5B6473))),
        ] else ...[
          if (canStart)
            _bigButton(
              label: 'Start — put on the floor',
              icon: Icons.play_arrow_rounded,
              color: _brand,
              onTap: _busy ? null : () => _act('start'),
            ),
          if (canFinish)
            _bigButton(
              label: 'Finished — ready to close',
              icon: Icons.flag_rounded,
              color: const Color(0xFF16A34A),
              onTap: _busy ? null : () => _confirmFinish(),
            ),
          const SizedBox(height: 6),
          Text(
            canFinish
                ? 'Tap Finished only when the whole job is done. Your supervisor still posts the final quantity.'
                : 'Tap Start when you begin work on this job.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A93A3), height: 1.4),
          ),
        ],
        if (_busy) const Padding(padding: EdgeInsets.only(top: 18), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))),
      ]),
    );
  }

  Future<void> _confirmFinish() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Mark job finished?'),
        content: const Text('This tells your supervisor the job is done and takes it off the running board. Only tap this when all work is complete.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(dctx, true), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A)), child: const Text('Yes, finished')),
        ],
      ),
    );
    if (ok == true) _act('finish');
  }

  Widget _statusPill({required bool onFloor, required bool finished, required bool closed}) {
    String label; Color c; IconData ic;
    if (closed) { label = 'Completed / Closed'; c = const Color(0xFF6B7280); ic = Icons.lock_outline; }
    else if (finished) { label = 'Finished — awaiting close'; c = const Color(0xFF16A34A); ic = Icons.flag_rounded; }
    else if (onFloor) { label = 'On the floor'; c = _brand; ic = Icons.bolt_rounded; }
    else { label = 'Not started'; c = const Color(0xFFD97706); ic = Icons.schedule; }
    return Align(
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: c.withOpacity(0.10), borderRadius: BorderRadius.circular(20), border: Border.all(color: c.withOpacity(0.35))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, size: 16, color: c), const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c)),
        ]),
      ),
    );
  }

  Widget _bigButton({required String label, required IconData icon, required Color color, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 58,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 24),
          label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color, foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }
}
