import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format/time_format.dart';

/// Public, no-login check of a reimbursement claim, opened by scanning the QR
/// on the printed Trip Summary / Combined Trip Summary:
///   https://<app>/#/rc/<public_token>
/// Shows what the system holds for the claim so a printed copy can be compared
/// with the real record (SQL 485).
class ReimbClaimPublicScreen extends StatefulWidget {
  final String token;
  const ReimbClaimPublicScreen({super.key, required this.token});
  @override
  State<ReimbClaimPublicScreen> createState() => _ReimbClaimPublicScreenState();
}

class _ReimbClaimPublicScreenState extends State<ReimbClaimPublicScreen> {
  static const _ink = Color(0xFF0F1729);
  static const _muted = Color(0xFF6B7280);
  static const _rule = Color(0xFFE5E7EB);
  static const _green = Color(0xFF059669);

  bool _loading = true;
  String? _error; // not_found | network
  Map<String, dynamic>? _c;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final r = await Supabase.instance.client.rpc('public_reimb_claim', params: {'p_token': widget.token});
      final m = r is Map ? Map<String, dynamic>.from(r) : null;
      if (!mounted) return;
      setState(() {
        if (m == null || m['ok'] != true) {
          _error = 'not_found';
        } else {
          _c = m;
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _error = 'network'; _loading = false; });
    }
  }

  String _d(Object? v, [String f = 'd MMM yyyy']) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '—' : DateFormat(f).format(d.toLocal());
  }

  String _km(Object? v) => '${NumberFormat('#,##0.##').format((v as num?) ?? 0)} km';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: _loading
                  ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                  : _error != null
                      ? _notFound()
                      : _body(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _rule),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _notFound() => _card([
        Row(children: [
          const Icon(Icons.gpp_bad_outlined, color: Color(0xFFB91C1C), size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_error == 'network' ? 'Could not check right now' : 'Not a genuine document',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _ink)),
          ),
        ]),
        const SizedBox(height: 10),
        Text(
          _error == 'network'
              ? 'Check the internet connection and try again.'
              : 'This code does not match any claim in Opstation. The printed copy may be altered or not issued by the system.',
          style: const TextStyle(color: _muted, fontSize: 13.5),
        ),
        if (_error == 'network') ...[
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('Try again')),
        ],
      ]);

  Widget _row(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: const TextStyle(color: _muted, fontSize: 13))),
          Expanded(child: Text(v, style: TextStyle(color: _ink, fontSize: 13.5, fontWeight: bold ? FontWeight.w800 : FontWeight.w600))),
        ]),
      );

  Widget _body() {
    final c = _c!;
    final status = '${c['status'] ?? ''}';
    final (Color sc, String sl) = switch (status) {
      'paid' => (const Color(0xFF1D4ED8), 'PAID'),
      'approved' => (_green, 'APPROVED'),
      'rejected' => (const Color(0xFFB91C1C), 'REJECTED'),
      _ => (const Color(0xFFB45309), 'AWAITING APPROVAL'),
    };
    final from = _d(c['date_from']), to = _d(c['date_to']);
    final days = [for (final e in (c['days'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    return Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: _green.withOpacity(0.08), borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _green.withOpacity(0.35))),
        child: Row(children: [
          const Icon(Icons.verified, color: _green, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Genuine document', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _ink)),
              const SizedBox(height: 2),
              Text('Issued by Opstation for ${c['org_name'] ?? ''}. Compare the details below with the printed copy.',
                  style: const TextStyle(fontSize: 12.5, color: _muted)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      _card([
        Row(children: [
          Expanded(
            child: Text(c['doc_type'] == 'trip_summary' ? 'Trip Summary' : 'Combined Trip Summary',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: sc.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
            child: Text(sl, style: TextStyle(color: sc, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .4)),
          ),
        ]),
        const SizedBox(height: 8),
        _row('Claimed by', '${c['claimant_name'] ?? '—'}'),
        _row('Period', from == to ? from : '$from – $to'),
        _row('Distance', _km(c['km'])),
        if (c['amount'] != null) _row('Amount', 'Rs ${NumberFormat('#,##0').format(c['amount'])}', bold: true),
        if (c['decided_by_name'] != null)
          _row('Approved by', '${c['decided_by_name']} · ${_d(c['decided_at'], orgTime('d MMM yyyy, h:mm a'))}'),
        if (c['paid_on'] != null) _row('Paid on', _d(c['paid_on'])),
        if (days.isNotEmpty) ...[
          const Divider(height: 22),
          const Text('Days', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _ink)),
          const SizedBox(height: 4),
          for (final d in days)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text(_d(d['day'], 'EEE, d MMM yyyy'), style: const TextStyle(fontSize: 13, color: _ink))),
                Text(_km(d['km']), style: const TextStyle(fontSize: 13, color: _ink, fontWeight: FontWeight.w600)),
              ]),
            ),
        ],
      ]),
      const SizedBox(height: 10),
      const Text('Opstation · read-only record', style: TextStyle(fontSize: 11, color: _muted)),
    ]);
  }
}
