import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Slim countdown banner shown on the dashboard while an org is on trial, so the
/// master admin sees the trial winding down without opening Billing. Turns
/// urgent (amber) in the last few days. Hidden for non-trial orgs / non-admins.
class TrialBanner extends ConsumerStatefulWidget {
  const TrialBanner({super.key});
  @override
  ConsumerState<TrialBanner> createState() => _State();
}

class _State extends ConsumerState<TrialBanner> {
  bool _loaded = false;
  String? _status;
  int _daysLeft = 999;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() => _loaded = true); return; }
    try {
      final row = await Supabase.instance.client
          .from('org_subscriptions')
          .select('status, current_period_end')
          .eq('org_id', orgId).maybeSingle();
      _status = row?['status'] as String?;
      final iso = row?['current_period_end'] as String?;
      final d = iso == null ? null : DateTime.tryParse(iso);
      if (d != null) _daysLeft = d.difference(DateTime.now()).inDays;
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserProvider)?.role;
    final isAdmin = role == WebUserRole.masterAdmin || role == WebUserRole.admin;
    if (!isAdmin || !_loaded || _status != 'trialing') return const SizedBox.shrink();
    if (GoRouterState.of(context).matchedLocation != '/dashboard') return const SizedBox.shrink();

    final urgent = _daysLeft <= 3;
    final bg = urgent ? const Color(0xFFFEF3C7) : AppTheme.primary.withOpacity(0.08);
    final fg = urgent ? const Color(0xFF92400E) : AppTheme.primary;
    final label = _daysLeft <= 0
        ? 'Your free trial ends today'
        : 'Your free trial ends in $_daysLeft day${_daysLeft == 1 ? '' : 's'}';

    return Material(
      color: bg,
      child: InkWell(
        onTap: () => context.go('/billing'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          child: Row(children: [
            Icon(urgent ? Icons.warning_amber_rounded : Icons.info_outline, size: 18, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Text('$label — add a payment method to keep your workspace active.',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
            ),
            const SizedBox(width: 12),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Add payment method', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
              Icon(Icons.chevron_right, size: 18, color: fg),
            ]),
          ]),
        ),
      ),
    );
  }
}
