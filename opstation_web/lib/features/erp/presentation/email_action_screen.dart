import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Confirm page behind the Approve / Reject buttons in a PO or Payment Advice
/// notification email:  https://<app>/#/act/<token>?a=approve|reject
///
/// No login — the personal, single-use token is the key. Nothing changes until
/// the recipient presses Confirm (mail scanners that pre-open links therefore
/// cannot approve anything). The server re-checks that the document is still
/// pending and that the recipient is still an approver.
class EmailActionScreen extends StatefulWidget {
  final String token;
  final String? action;
  const EmailActionScreen({super.key, required this.token, this.action});
  @override
  State<EmailActionScreen> createState() => _EmailActionScreenState();
}

class _EmailActionScreenState extends State<EmailActionScreen> {
  static const _brand = Color(0xFF2F6FED);
  static const _ink = Color(0xFF0F1729);
  static const _muted = Color(0xFF6B7280);
  static const _rule = Color(0xFFE5E7EB);
  static const _green = Color(0xFF16A34A);
  static const _red = Color(0xFFDC2626);

  bool _loading = true;
  bool _busy = false;
  String? _error; // not_found | network
  Map<String, dynamic>? _info;
  Map<String, dynamic>? _doc;
  late String _mode; // approve | reject
  String? _done; // approve | reject once confirmed
  String? _actionError;
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _mode = widget.action == 'reject' ? 'reject' : 'approve';
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  SupabaseClient get _db => Supabase.instance.client;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _db.rpc('email_action_info', params: {'p_token': widget.token});
      final m = res is Map ? Map<String, dynamic>.from(res) : null;
      if (!mounted) return;
      setState(() {
        if (m == null || m['ok'] != true) {
          _error = 'not_found';
        } else {
          _info = m;
          _doc = Map<String, dynamic>.from(m['doc'] as Map);
          final canA = m['can_approve'] == true, canR = m['can_reject'] == true;
          if (_mode == 'approve' && !canA && canR) _mode = 'reject';
          if (_mode == 'reject' && !canR && canA) _mode = 'approve';
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'network';
          _loading = false;
        });
      }
    }
  }

  Future<void> _confirm() async {
    if (_busy) return;
    if (_mode == 'reject' && _reason.text.trim().isEmpty) {
      setState(() => _actionError = 'Please enter the reason for rejection.');
      return;
    }
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final res = await _db.rpc('email_action_do', params: {
        'p_token': widget.token,
        'p_action': _mode,
        'p_reason': _mode == 'reject' ? _reason.text.trim() : null,
      });
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      if (m['doc'] is Map) _doc = Map<String, dynamic>.from(m['doc'] as Map);
      if (m['ok'] == true) {
        setState(() {
          _done = _mode;
          _busy = false;
        });
      } else {
        setState(() {
          _busy = false;
          _actionError = switch (m['error']) {
            'used' => 'This link has already been used.',
            'expired' => 'This link has expired. Open the document in Opstation instead.',
            'not_pending' => 'This document is no longer awaiting approval.',
            'no_permission' => 'You are no longer allowed to do this. Ask an admin to check your approval rights.',
            'reason_required' => 'Please enter the reason for rejection.',
            _ => 'That did not go through. Please try again.',
          };
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _actionError = 'Could not reach the server. Check the connection and try again.';
        });
      }
    }
  }

  // ── formatting ────────────────────────────────────────────────────────────
  static String _money(Object? v) {
    final d = (v is num ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble();
    final f = d == d.roundToDouble() ? NumberFormat('#,##0') : NumberFormat('#,##0.00');
    return 'Rs ${f.format(d)}';
  }

  static String _qty(Object? v) {
    final d = (v is num ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble();
    return d == d.roundToDouble() ? NumberFormat('#,##0').format(d) : NumberFormat('#,##0.###').format(d);
  }

  static String _dt(Object? v, {bool time = true}) {
    final d = DateTime.tryParse('${v ?? ''}');
    if (d == null) return '—';
    return DateFormat(time ? 'd MMM yyyy, HH:mm' : 'd MMM yyyy').format(d.toLocal());
  }

  bool get _isPo => _doc?['kind'] == 'po';

  void _openInApp() {
    final id = _doc?['id'];
    context.go(_isPo ? '/erp/purchase?focus=$id' : '/financials/payment-advice');
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _errorView()
                : _body(),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_error == 'network' ? Icons.wifi_off : Icons.link_off, size: 44, color: _muted),
            const SizedBox(height: 12),
            Text(
              _error == 'network'
                  ? 'Could not reach the server. Check the connection and try again.'
                  : 'This link is not valid. It may be incomplete or the document no longer exists.',
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _card(),
            const SizedBox(height: 14),
            _actionPanel(),
            const SizedBox(height: 10),
            Center(
              child: TextButton.icon(
                onPressed: _openInApp,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Go to screen (to edit)'),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _card() {
    final d = _doc!;
    final lines = List<Map<String, dynamic>>.from(
        ((d['lines'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final rates = d['show_rates'] == true;
    final note = ((d['note'] as String?) ?? '').trim();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _rule),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: _brand,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(((d['org_name'] as String?) ?? '').toUpperCase(),
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w800, letterSpacing: 1.5, fontSize: 11)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text('${d['title'] ?? ''}',
                    style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
              ),
              _stateChip(d['state'] as String?),
            ]),
            Text('${d['number'] ?? ''}  ·  ${_dt(d['date'], time: false)}',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(TextSpan(style: const TextStyle(color: Color(0xFF374151), fontSize: 13.5), children: [
              const TextSpan(text: 'Submitted by '),
              TextSpan(text: '${d['created_by_name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: ' on ${_dt(d['created_at'])}'),
            ])),
            if (_isPo) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 28, runSpacing: 8, children: [
                _meta('SUPPLIER', '${d['supplier_name'] ?? '—'}'),
                if ((d['branch_name'] ?? '').toString().isNotEmpty) _meta('BRANCH', '${d['branch_name']}'),
              ]),
            ],
            const SizedBox(height: 14),
            for (var i = 0; i < lines.length; i++) _line(i, lines[i], rates),
            if (!_isPo || rates) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFFEEF3FE), borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Text(_isPo ? 'PO TOTAL' : 'TOTAL TO PAY',
                      style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1, fontSize: 12)),
                  const Spacer(),
                  Text(_money(d['total']),
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19, color: _brand)),
                ]),
              ),
            ],
            if (note.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: Color(0xFFF9FAFB),
                  border: Border(left: BorderSide(color: _brand, width: 3)),
                ),
                child: Text('${_isPo ? 'Remarks' : 'Note'}: $note',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _stateChip(String? s) {
    final (Color bg, Color fg, String t) = switch (s) {
      'approved' => (const Color(0xFFDCFCE7), const Color(0xFF166534), 'APPROVED'),
      'rejected' => (const Color(0xFFFEE2E2), const Color(0xFF991B1B), 'REJECTED'),
      'void' => (const Color(0xFFFEE2E2), const Color(0xFF991B1B), 'VOID'),
      'pending' => (const Color(0xFFFEF3C7), const Color(0xFF92400E), 'AWAITING APPROVAL'),
      _ => (const Color(0xFFE5E7EB), const Color(0xFF374151), (s ?? '').toUpperCase()),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(t, style: TextStyle(color: fg, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: .8)),
    );
  }

  Widget _meta(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 10.5, color: _muted, fontWeight: FontWeight.w700, letterSpacing: .8)),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _ink)),
      ]);

  Widget _line(int i, Map<String, dynamic> l, bool rates) {
    final sub = _isPo
        ? [
            if ((l['sku'] ?? '').toString().isNotEmpty) '${l['sku']}',
            '${_qty(l['qty'])}${(l['uom'] ?? '').toString().isNotEmpty ? ' ${l['uom']}' : ''}'
                '${rates ? ' × ${_money(l['rate'])}' : ''}',
          ].join('  ·  ')
        : ((l['detail'] as String?) ?? '').trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _rule),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 22, child: Text('${i + 1}', style: const TextStyle(color: _muted, fontWeight: FontWeight.w600))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${l['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: _ink)),
            if (sub.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(sub, style: const TextStyle(fontSize: 12.5, color: _muted, height: 1.35)),
            ],
          ]),
        ),
        if (!_isPo || rates)
          Text(_money(l['amount']), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: _ink)),
      ]),
    );
  }

  Widget _panel({required Color color, required IconData icon, required String title, String? body}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(.35), width: 1.5),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 16)),
            if (body != null) ...[
              const SizedBox(height: 4),
              Text(body, style: const TextStyle(color: Color(0xFF374151), fontSize: 13.5, height: 1.4)),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _actionPanel() {
    final d = _doc!;
    final info = _info!;
    final state = d['state'] as String?;

    if (_done != null) {
      return _done == 'approve'
          ? _panel(
              color: _green,
              icon: Icons.check_circle,
              title: 'Approved',
              body: '${d['number'] ?? 'The document'} is approved in your name '
                  '(${info['user_name'] ?? ''}) and recorded in the audit trail. You can close this page.')
          : _panel(
              color: _red,
              icon: Icons.cancel,
              title: 'Rejected',
              body: '${d['number'] ?? 'The document'} was sent back with your reason. You can close this page.');
    }

    if (state != 'pending') {
      final who = state == 'approved'
          ? 'Approved by ${d['approved_by_name'] ?? '—'} on ${_dt(d['approved_at'])}.'
          : state == 'rejected'
              ? 'Rejected by ${d['rejected_by_name'] ?? '—'} on ${_dt(d['rejected_at'])}'
                  '${((d['reject_reason'] as String?) ?? '').isNotEmpty ? ' — ${d['reject_reason']}' : ''}.'
              : state == 'void'
                  ? 'This document was voided.'
                  : 'It was changed after this email was sent (for example, unlocked for editing).';
      return _panel(
          color: _muted, icon: Icons.info_outline, title: 'No longer awaiting approval', body: who);
    }
    if (info['used_at'] != null) {
      return _panel(
          color: _muted, icon: Icons.link_off, title: 'This link has already been used',
          body: 'Open the document in Opstation to see where it stands.');
    }
    if (info['expired'] == true) {
      return _panel(
          color: _muted, icon: Icons.timer_off_outlined, title: 'This link has expired',
          body: 'Links in approval emails work for 7 days. Open the document in Opstation to act on it.');
    }
    final canA = info['can_approve'] == true, canR = info['can_reject'] == true;
    if (!canA && !canR) {
      return _panel(
          color: _muted, icon: Icons.lock_outline, title: 'You cannot act on this',
          body: 'Your approval rights for this document have changed. Ask an admin if this is unexpected.');
    }

    final approve = _mode == 'approve';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _rule),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Acting as ${info['user_name'] ?? ''}',
            style: const TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 10),
        if (canA && canR)
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'approve', label: Text('Approve'), icon: Icon(Icons.check)),
              ButtonSegment(value: 'reject', label: Text('Reject'), icon: Icon(Icons.close)),
            ],
            selected: {_mode},
            onSelectionChanged: _busy ? null : (s) => setState(() {
              _mode = s.first;
              _actionError = null;
            }),
          ),
        const SizedBox(height: 14),
        if (approve)
          Text('Approve ${d['number'] ?? ''}${!_isPo || d['show_rates'] == true ? ' for ${_money(d['total'])}' : ''}?',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _ink))
        else ...[
          Text(
              _isPo
                  ? 'The PO goes back to its creator as a draft with your reason.'
                  : 'The advice is marked rejected with your reason.',
              style: const TextStyle(fontSize: 13, color: _muted)),
          const SizedBox(height: 10),
          TextField(
            controller: _reason,
            minLines: 3,
            maxLines: 6,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Reason for rejection *', border: OutlineInputBorder()),
          ),
        ],
        if (_actionError != null) ...[
          const SizedBox(height: 10),
          Text(_actionError!, style: const TextStyle(color: _red, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 14),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: approve ? _green : _red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
            ),
            onPressed: _busy ? null : _confirm,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(approve ? Icons.check_circle : Icons.cancel),
            label: Text(approve ? 'Confirm approval' : 'Confirm rejection'),
          ),
        ),
      ]),
    );
  }
}
