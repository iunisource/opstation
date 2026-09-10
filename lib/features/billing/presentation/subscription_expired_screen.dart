import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../support/presentation/request_callback_button.dart';
import 'plan_cards.dart';

/// Full-screen wall shown to a master admin / admin when their trial or
/// subscription has lapsed. The router routes here and blocks the rest of the
/// app until it's renewed. Gives a clear path: see plans, add a payment method,
/// request a call back, or sign out — instead of a dead login error.
class SubscriptionExpiredScreen extends ConsumerStatefulWidget {
  const SubscriptionExpiredScreen({super.key});
  @override
  ConsumerState<SubscriptionExpiredScreen> createState() => _State();
}

class _State extends ConsumerState<SubscriptionExpiredScreen> {
  List<Map<String, dynamic>> _plans = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .from('subscription_plans')
          .select('id, name, amount, tagline, badge, highlight, features')
          .eq('is_active', true).order('sort_order');
      if (mounted) setState(() => _plans = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  void _contact() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Add a payment method'),
        content: const SizedBox(width: 380, child: Text(
          'To reactivate your workspace, contact billing@opstationerp.com or request a call back and our team will set up your payment securely.',
          style: TextStyle(fontSize: 13.5, height: 1.5))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    height: 40, width: 40, alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(10)),
                    child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
                  ),
                  const SizedBox(width: 10),
                  const Text('Opstation', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign out'),
                  ),
                ]),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(26),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [Color(0xFF1B45A0), Color(0xFF2F6FED), Color(0xFF4B84F5)],
                    ),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Your trial has ended',
                        style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(
                      'Thanks for trying Opstation${user?.orgName != null ? ', ${user!.orgName}' : ''}! '
                      'To keep your workspace and data active, add a payment method or pick a plan below. '
                      'Everything is exactly where you left it.',
                      style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 14, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                    Wrap(spacing: 12, runSpacing: 12, children: [
                      ElevatedButton.icon(
                        onPressed: _contact,
                        icon: const Icon(Icons.credit_card, size: 18),
                        label: const Text('Add payment method'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppTheme.primary),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => showRequestCallbackDialog(context, ref),
                        icon: const Icon(Icons.support_agent, size: 18, color: Colors.white),
                        label: const Text('Request a call back', style: TextStyle(color: Colors.white)),
                        style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white70)),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(height: 22),
                if (_plans.isNotEmpty) ...[
                  const Text('Our plans', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 12),
                  PlanCards(
                    plans: _plans,
                    activeId: null,
                    onSelect: (_) => _contact(),
                    ctaLabel: (_) => 'Contact us to activate',
                    ctaDisabled: (_) => true,
                  ),
                ],
                const SizedBox(height: 24),
                Center(child: Text('Questions? Email billing@opstationerp.com',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary.withOpacity(0.9)))),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
