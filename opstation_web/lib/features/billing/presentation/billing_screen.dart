import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Org-facing Billing & Subscription screen (master admin / admin). Shows the
/// trial/subscription status, due date, invoices and payments, the card on
/// file, and an "Add payment method" action.
///
/// PCI note: real card capture goes through the payment gateway's HOSTED
/// tokenization (Safepay/Stripe) — never a raw card form in this app. Until the
/// gateway is connected, "Add payment method" shows how to activate billing.
/// When the gateway is wired, point _addCard() at its hosted checkout/setup.
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
    if (d == null) return 0;
    return d.difference(DateTime.now()).inDays;
  }

  void _addCard() {
    // GATEWAY SEAM: when Safepay/Stripe is live, open its hosted tokenization
    // flow here and save the returned token via a secure endpoint.
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add a payment method'),
        content: const SizedBox(
          width: 380,
          child: Text(
            'Secure online card payment is being enabled for your account. '
            'To activate billing now, contact billing@opstationerp.com and our team '
            'will set up your card securely — you will never be asked to enter full '
            'card details in this app.',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Got it'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final status = (_sub?['status'] as String?) ?? 'active';
    final trialing = status == 'trialing';
    final daysLeft = _daysLeft();

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Billing & Subscription',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
          const SizedBox(height: 4),
          const Text('Your plan, payment method and billing history.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 20),

          // Status banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(trialing ? 'Free trial' : 'Standard plan',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(status, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                trialing
                    ? (daysLeft >= 0
                        ? 'Your trial ends in $daysLeft day(s), on ${_fmt(_sub?['current_period_end'] as String?)}. Add a payment method to keep your workspace active.'
                        : 'Your trial has ended. Add a payment method to reactivate.')
                    : 'Next payment due ${_fmt(_sub?['current_period_end'] as String?)} · ${_money((_sub?['amount'] as num?) ?? 0)}/month.',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          // Payment method
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(children: [
              const Icon(Icons.credit_card, color: AppTheme.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: _card == null
                    ? const Text('No payment method on file',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))
                    : Text('${_card!['brand'] ?? 'Card'} ••••${_card!['last4'] ?? ''}   ·   exp ${_card!['exp_month'] ?? '--'}/${_card!['exp_year'] ?? '--'}',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              ElevatedButton.icon(
                onPressed: _addCard,
                icon: const Icon(Icons.add, size: 18),
                label: Text(_card == null ? 'Add payment method' : 'Update'),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          // Invoices
          _historyCard('Invoices', _invoices.isEmpty
              ? [const _Empty()]
              : _invoices.map((e) => _lineRow(
                  '${e['invoice_number'] ?? ''}',
                  '${_fmt(e['due_date'] as String?)}',
                  _money((e['amount'] as num?) ?? 0),
                  (e['status'] as String?) ?? '')).toList()),
          const SizedBox(height: 16),
          _historyCard('Payments', _payments.isEmpty
              ? [const _Empty()]
              : _payments.map((e) => _lineRow(
                  '${e['provider'] ?? ''}',
                  '${_fmt(e['created_at'] as String?)}',
                  _money((e['amount'] as num?) ?? 0),
                  (e['status'] as String?) ?? '')).toList()),
        ]),
      ),
    );
  }

  Widget _historyCard(String title, List<Widget> children) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
            child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          ),
          const Divider(height: 1),
          ...children,
        ]),
      );

  Widget _lineRow(String a, String b, String amount, String status) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
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

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(18),
        child: Text('Nothing yet', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      );
}
