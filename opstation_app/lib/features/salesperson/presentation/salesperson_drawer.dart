import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import 'my_orders_screen.dart';
import 'salesperson_performance_screen.dart';

/// Whether the customer sales-targets feature is on for this org. Gates the
/// Performance drawer entry (My Orders is independent and always shown).
final salespersonTargetsEnabledProvider =
    FutureProvider<bool>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  final orgId = user?.organizationId;
  if (orgId == null) return false;
  try {
    final res = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('org_id', orgId)
        .eq('key', 'org.customer_targets_enabled')
        .maybeSingle();
    return (res?['value'] as String?) == 'true';
  } catch (_) {
    return false;
  }
});

/// Salesperson navigation drawer. Attaches via RoleHomeScaffold's `drawer:`
/// slot on the salesperson home screen.
class SalespersonDrawer extends ConsumerWidget {
  const SalespersonDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final rawName = user?.name;
    final name = (rawName != null && rawName.trim().isNotEmpty)
        ? rawName.trim()
        : 'Salesperson';
    final targetsOn =
        ref.watch(salespersonTargetsEnabledProvider).valueOrNull ?? false;

    return Drawer(
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Row(children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.primaryLight,
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : 'S',
                  style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text('Salesperson',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondaryLight)),
                  ],
                ),
              ),
            ]),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          if (targetsOn)
            _tile(
              context,
              icon: Icons.leaderboard_outlined,
              label: 'Performance',
              subtitle: 'Your sales-target progress',
              onTap: () => _go(context, const SalespersonPerformanceScreen()),
            ),
          _tile(
            context,
            icon: Icons.receipt_long_outlined,
            label: 'My Orders',
            subtitle: 'Orders you submitted',
            onTap: () => _go(context, const MyOrdersScreen()),
          ),
          const Divider(height: 1),
          _tile(
            context,
            icon: Icons.history,
            label: 'Route History',
            subtitle: 'Your past routes',
            onTap: () => _goPath(context, '/salesperson/history'),
          ),
          _tile(
            context,
            icon: Icons.picture_as_pdf_outlined,
            label: 'Reports',
            subtitle: 'Export your activity',
            onTap: () {
              final userId =
                  ref.read(authControllerProvider).valueOrNull?.id;
              Navigator.pop(context); // close the drawer first
              if (userId != null) {
                context.push('/salesperson/reports?uid=$userId');
              }
            },
          ),
        ]),
      ),
    );
  }

  void _go(BuildContext context, Widget screen) {
    Navigator.pop(context); // close the drawer first
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
  }

  void _goPath(BuildContext context, String path) {
    Navigator.pop(context); // close the drawer first
    context.push(path);
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppColors.primary),
      title: Text(label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
      onTap: onTap,
    );
  }
}
