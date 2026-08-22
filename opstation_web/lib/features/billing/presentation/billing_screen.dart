import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'plan_cards.dart';

/// Org-facing Billing & Subscription screen (master admin / admin). Designed to
/// feel confident and welcoming — this is where we ask for the card, so it
/// reassures (secure, no charge during trial, cancel anytime) rather than nags.
///
/// PCI note: real card capture goes through the gateway's HOSTED tokenization
/// (Safepay/Stripe) — never a raw card form in this app. Until the gateway is
/// connected, "Add payment method" explains how to activate. When wired, point
/// _addCard() at the hosted checkout/setup.
class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});
  @override
  ConsumerState<BillingScreen> createState() => _State();
}

class _State extends ConsumerState<BillingScreen> {
  bool _loading = true;
  Map<String, dynamic>? _sub;
  Map<String, dynamic>? _card;
  List<Map<String, dynamic>> _invoices = [];
  List<Map<String, dynamic>> _payments = [];
  List<Map<String, dynamic>> _plans = [];

  String? get _planId => _sub?['plan_id'] as String?;
  String get _planName {
    final p = _plans.where((e) => e['id'] == _planId).toList();
    return p.isNotEmpty ? (p.first['name'] as String? ?? 'Your plan') : 'Your plan';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  SupabaseClient get _c => Supabase.instance.client;

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      _sub = await _c.from('org_subscriptions').select('*').eq('org_id', orgId).maybeSingle();
      _card = await _c.from('org_payment_methods')
          .select('brand, last4, exp_month, exp_year')
          .eq('org_id', orgId).eq('is_default', true).eq('status', 'active').maybeSingle();
      _invoices = List<Map<String, dynamic>>.from(await _c.from('subscription_invoices')
          .select('invoice_number, amount, status, due_date, paid_at')
          .eq('org_id', orgId).order('issued_at', ascending: false).limit(24));
      _payments = List<Map<String, dynamic>>.from(await _c.from('subscription_payments')
          .select('amount, status, provider, created_at')
          .eq('org_id', orgId).order('created_at', ascending: false).limit(24));
      _plans = List<Map<String, dynamic>>.from(await _c.from('subscription_plans')
          .select('id, name, amount, tagline, badge, highlight, features, module_keys')
          .eq('is_active', true).order('sort_order'));
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load error: $e')));
    }
  }

  String _fmt(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso);
    if (d == null) return '—';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _money(num v) => 'PKR ${v.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';

  int _daysLeft() {
    final iso = _sub?['current_period_end'] as String?;
    final d = iso == null ? null : DateTime.tryParse(iso);
    if (d == null) return -1;
    return d.difference(DateTime.now()).inDays;
  }

  Future<void> _changePlan(Map<String, dynamic> plan) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Switch to ${plan['name']}?'),
        content: Text(
          'Your plan will change to ${plan['name']} (${_money((plan['amount'] as num?) ?? 0)}/month) '
          'and the modules included in that plan will be enabled. You can change again anytime.',
          style: const TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _c.rpc('sub_change_plan', params: {'p_org': ref.read(currentUserProvider)?.orgId, 'p_plan_id': plan['id']});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Switched to ${plan['name']}. Reload to see updated menus.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not change plan: $e')));
    }
  }

  void _addCard() {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Container(
            height: 38, width: 38, alignment: Alignment.center,
            decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.lock_outline, color: AppTheme.primary, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('Add a payment method', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
        ]),
        content: const SizedBox(
          width: 400,
          child: Text(
            'Secure online card payments are being enabled for your account. '
            'To activate your subscription now, contact billing@opstationerp.com and '
            'our team will set up your card securely.\n\n'
            'For your protection, you will never be asked to enter full card details '
            'inside the app — card capture happens on our payment provider\'s secure page.',
            style: TextStyle(fontSize: 13.5, height: 1.6, color: AppTheme.textSecondary),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Close')),
          ElevatedButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Got it')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final status = (_sub?['status'] as String?) ?? 'active';
    final trialing = status == 'trialing';
    final daysLeft = _daysLeft();
    final hasCard = _card != null;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ── Hero ──────────────────────────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [Color(0xFF1B45A0), Color(0xFF2F6FED), Color(0xFF4B84F5)],
                  ),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(trialing ? 'FREE TRIAL' : _planName.toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Text(
                    trialing
                        ? (daysLeft >= 0 ? 'You have $daysLeft day${daysLeft == 1 ? '' : 's'} left in your trial' : 'Your trial has ended')
                        : 'Your subscription is active',
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, height: 1.2),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    trialing
                        ? 'Add a payment method to keep everything running the moment your trial ends. No charge until then.'
                        : (daysLeft >= 0
                            ? 'Next payment of ${_money((_sub?['amount'] as num?) ?? 0)} on ${_fmt(_sub?['current_period_end'] as String?)}.'
                            : 'Thank you for being with Opstation.'),
                    style: TextStyle(color: Colors.white.withOpacity(0.88), fontSize: 14, height: 1.5),
                  ),
                ]),
              ),
              const SizedBox(height: 16),

              // ── The ask: payment method ───────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: hasCard ? AppTheme.border : AppTheme.primary.withOpacity(0.35)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      height: 44, width: 44, alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: (hasCard ? AppTheme.success : AppTheme.primary).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(hasCard ? Icons.verified_user_outlined : Icons.credit_card,
                          color: hasCard ? AppTheme.success : AppTheme.primary, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(hasCard ? 'Payment method on file' : 'Activate your subscription',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text(
                          hasCard
                              ? '${_card!['brand'] ?? 'Card'} ••••${_card!['last4'] ?? ''}   ·   expires ${_card!['exp_month'] ?? '--'}/${_card!['exp_year'] ?? '--'}'
                              : 'Add a card so your workspace keeps running after the trial.',
                          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _addCard,
                      icon: Icon(hasCard ? Icons.edit_outlined : Icons.add, size: 18),
                      label: Text(hasCard ? 'Update' : 'Add payment method'),
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  Wrap(spacing: 20, runSpacing: 10, children: const [
                    _Trust(icon: Icons.lock_outline, text: 'Secure & encrypted'),
                    _Trust(icon: Icons.event_available_outlined, text: 'No charge during your trial'),
                    _Trust(icon: Icons.autorenew, text: 'Cancel anytime'),
                  ]),
                ]),
              ),
              const SizedBox(height: 16),

              // ── Plans / upgrade ──────────────────────────────────────────
              if (_plans.isNotEmpty) ...[
                const Text('Choose your plan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                const Text('Upgrade or switch anytime — your modules update instantly.',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                const SizedBox(height: 14),
                PlanCards(
                  plans: _plans,
                  activeId: _planId,
                  onSelect: _changePlan,
                  ctaLabel: (p) {
                    if (p['id'] == _planId) return 'Current plan';
                    final cur = _plans.where((e) => e['id'] == _planId).toList();
                    final curAmt = cur.isNotEmpty ? ((cur.first['amount'] as num?) ?? 0) : 0;
                    return ((p['amount'] as num?) ?? 0) > curAmt ? 'Upgrade' : 'Switch';
                  },
                  ctaDisabled: (p) => p['id'] == _planId,
                ),
                const SizedBox(height: 20),
              ],

              _historyCard('Invoices', _invoices.isEmpty
                  ? [const _Empty()]
                  : _invoices.map((e) => _lineRow(
                      '${e['invoice_number'] ?? ''}', _fmt(e['due_date'] as String?),
                      _money((e['amount'] as num?) ?? 0), (e['status'] as String?) ?? '')).toList()),
              const SizedBox(height: 16),
              _historyCard('Payments', _payments.isEmpty
                  ? [const _Empty()]
                  : _payments.map((e) => _lineRow(
                      '${e['provider'] ?? ''}', _fmt(e['created_at'] as String?),
                      _money((e['amount'] as num?) ?? 0), (e['status'] as String?) ?? '')).toList()),

              const SizedBox(height: 24),
              _trustBadges(),
              const SizedBox(height: 16),
              Center(
                child: Text('Questions about billing? Email billing@opstationerp.com',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary.withOpacity(0.9))),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Trust badges (card networks + security) ─────────────────────────────
  Widget _trustBadges() => Center(
        child: Column(children: [
          Text('TRUSTED & SECURE PAYMENTS',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2,
                  color: AppTheme.textSecondary.withOpacity(0.8))),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
            _visaBadge(),
            _mastercardBadge(),
            _pill(Icons.lock, '256-bit SSL'),
            _pill(Icons.verified_user_outlined, 'PCI-DSS Compliant'),
            _pill(Icons.shield_outlined, 'Bank-grade security'),
          ]),
        ]),
      );

  Widget _badgeBox({required Widget child}) => Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.border),
        ),
        child: child,
      );

  Widget _pill(IconData icon, String text) => _badgeBox(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: AppTheme.success),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        ]),
      );

  Widget _visaBadge() => _badgeBox(
        child: Text('VISA',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1.5,
                fontStyle: FontStyle.italic, color: const Color(0xFF1A1F71))),
      );

  Widget _mastercardBadge() => _badgeBox(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 30, height: 20,
            child: Stack(children: [
              Positioned(left: 0, child: Container(width: 20, height: 20,
                  decoration: const BoxDecoration(color: Color(0xFFEB001B), shape: BoxShape.circle))),
              Positioned(left: 10, child: Container(width: 20, height: 20,
                  decoration: BoxDecoration(color: const Color(0xFFF79E1B).withOpacity(0.9), shape: BoxShape.circle))),
            ]),
          ),
          const SizedBox(width: 6),
          const Text('Mastercard', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1F2937))),
        ]),
      );

  Widget _historyCard(String title, List<Widget> children) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          ),
          const Divider(height: 1),
          ...children,
        ]),
      );

  Widget _lineRow(String a, String b, String amount, String status) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(children: [
          Expanded(flex: 3, child: Text(a, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          Expanded(flex: 2, child: Text(b, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
          Expanded(flex: 2, child: Text(amount, style: const TextStyle(fontSize: 13))),
          Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: Text(status,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                  color: status == 'paid' || status == 'success' ? AppTheme.success
                      : status == 'failed' ? AppTheme.danger : AppTheme.textSecondary)))),
        ]),
      );
}

class _Trust extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Trust({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      ]);
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(20),
        child: Text('Nothing yet', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      );
}
