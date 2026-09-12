import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/org_switch_overlay.dart';
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

  Future<void> _switchTo(String orgId, String orgName) async {
    try {
      showOrgSwitchedAnimation(context, orgName);
      await ref.read(authControllerProvider.notifier).switchOrg(orgId);
      await Future<void>.delayed(const Duration(milliseconds: 1050));
      html.window.location.reload();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not switch organization: $e')));
      }
    }
  }

  /// Multi-org admins who land on this wall (because the org they switched into
  /// has a lapsed trial) still need a way back to their other orgs.
  Widget _buildOrgSwitch(String? currentOrgId) {
    final mems = ref.watch(orgMembershipsProvider).valueOrNull ?? const [];
    if (mems.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PopupMenuButton<String>(
        tooltip: 'Switch organization',
        onSelected: (orgId) {
          if (orgId == currentOrgId) return;
          String name = 'organization';
          for (final m in mems) {
            if (m['org_id'] == orgId) name = (m['org_name'] as String?) ?? name;
          }
          _switchTo(orgId, name);
        },
        itemBuilder: (_) => [
          const PopupMenuItem<String>(
            enabled: false,
            height: 28,
            child: Text('SWITCH ORGANIZATION',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Colors.black45)),
          ),
          for (final m in mems)
            PopupMenuItem<String>(
              value: m['org_id'] as String,
              child: Row(children: [
                Icon(
                    m['org_id'] == currentOrgId
                        ? Icons.check_circle
                        : Icons.apartment_outlined,
                    size: 16,
                    color: m['org_id'] == currentOrgId
                        ? AppTheme.primary
                        : Colors.black45),
                const SizedBox(width: 8),
                Expanded(
                    child: Text((m['org_name'] as String?) ?? 'Organization',
                        overflow: TextOverflow.ellipsis)),
              ]),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: const [
            Icon(Icons.swap_horiz_rounded, size: 18, color: AppTheme.primary),
            SizedBox(width: 6),
            Text('Switch org',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
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
                  _buildOrgSwitch(user?.orgId),
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
