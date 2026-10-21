import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../features/admin/providers/admin_dashboard_stats.dart';
import '../../features/admin/providers/admin_dashboard_realtime.dart';
import 'role_home_scaffold.dart';
import 'section_label.dart';
import 'temp_password_banner.dart';

/// Shared org-level admin dashboard body.
///
/// Used by both Admin and Master Admin. They render identically;
/// Master Admin gets a few extra Master-only tiles when [isMasterAdmin] is true.
///
/// The key permission differences (enforced in data layer, not UI):
///   - Admin cannot create or block other Admins.
///   - Only Master Admin can edit app-level preferences (cut-off, geofence, bands).
///   - Only Master Admin can connect/disconnect Google Drive.
///   - Only Master Admin can edit notification template overrides.
class AdminDashboardBody extends ConsumerWidget {
  final String firstName;
  final String subtitle;
  final bool isMasterAdmin;

  const AdminDashboardBody({
    super.key,
    required this.firstName,
    required this.subtitle,
    required this.isMasterAdmin,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Holding this alive opens the Realtime channel; disposing the screen closes
    // it. The stats then refresh themselves whenever a rep in the field marks a
    // visit — no polling, no pull-to-refresh, no logout.
    ref.watch(adminDashboardRealtimeProvider);
    final statsAsync = ref.watch(adminDashboardStatsProvider);
    final stats = statsAsync.valueOrNull;
    final day = ref.watch(dashboardDayProvider);
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final isToday = !day.isBefore(today);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        const SizedBox(height: 8),
        Text(
          'Hi, $firstName',
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 20),

        const TempPasswordBanner(),

        // Today header banner
        Material(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: () => context.push('/admin/monitoring'),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _DayStepper(
                    day: day,
                    isToday: isToday,
                    onPrev: () => ref.read(dashboardDayProvider.notifier).state =
                        day.subtract(const Duration(days: 1)),
                    onNext: isToday
                        ? null
                        : () => ref.read(dashboardDayProvider.notifier).state =
                            day.add(const Duration(days: 1)),
                    onPick: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: day,
                        firstDate: DateTime(2024),
                        lastDate: today,
                      );
                      if (d != null) {
                        ref.read(dashboardDayProvider.notifier).state =
                            DateTime(d.year, d.month, d.day);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  // Scales down instead of overflowing on narrow phones.
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _SummaryStat(
                          value: stats == null
                              ? '--'
                              : '${isToday ? stats.activeRoutesToday : stats.routesOnDay}',
                          label: isToday ? 'Active routes' : 'Routes',
                        ),
                        const SizedBox(width: 16),
                        _SummaryStat(
                          value: stats == null ? '--' : '${stats.shopsToday}',
                          label: 'Shops',
                        ),
                        const SizedBox(width: 16),
                        _SummaryStat(
                          value: stats == null
                              ? 'Rs --'
                              : 'Rs ${_fmtNumber(stats.amountToday)}',
                          label: 'Amount',
                        ),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Stat grid — Customers and Routes only
        Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.storefront_outlined,
                iconBg: AppColors.accentLight,
                iconFg: AppColors.accent,
                value: stats == null ? '--' : _fmtNumber(stats.customerCount),
                label: 'Customers',
                onTap: () => context.push('/customers'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                icon: Icons.route_outlined,
                iconBg: AppColors.successLight,
                iconFg: AppColors.successDark,
                value: stats == null ? '--' : '${stats.totalRoutes}',
                label: 'Total routes',
                onTap: () => context.push('/admin/routes'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        const SectionLabel('Management'),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.people_outline,
          title: 'Team',
          subtitle: 'Salespersons, surveyors, drivers',
          onTap: () => context.push('/admin/team'),
        ),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.storefront_outlined,
          title: 'Customers',
          subtitle: 'Vendors, shops & locations',
          onTap: () => context.push('/customers'),
        ),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.route_outlined,
          title: 'Route templates',
          subtitle: 'Create & manage route blueprints',
          onTap: () => context.push('/admin/routes'),
        ),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.local_shipping_outlined,
          title: 'Deliveries',
          subtitle: 'Track driver-assigned routes',
          onTap: () => context.push('/admin/deliveries'),
        ),
        const SizedBox(height: 24),

        const SectionLabel('Analytics'),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.dashboard_outlined,
          title: 'Dashboard',
          subtitle: 'Live activity & leaderboard',
          onTap: () => context.push('/admin/monitoring'),
        ),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.picture_as_pdf_outlined,
          title: 'Reports',
          subtitle: 'Export PDF reports',
          onTap: () => context.push('/admin/reports'),
        ),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.insights_outlined,
          title: 'Coverage report',
          subtitle: 'Period-level route + team coverage',
          onTap: () => context.push('/admin/coverage'),
        ),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.route_outlined,
          title: 'Combined trip summary',
          subtitle: 'Multi-date distance sheet for reimbursement',
          onTap: () => context.push('/admin/combined-summary'),
        ),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.verified_user_outlined,
          title: 'Compliance',
          subtitle: 'Spoofing detection & visit integrity',
          onTap: () => context.push('/admin/compliance'),
        ),
        const SizedBox(height: 24),

        const SectionLabel('Settings'),
        const SizedBox(height: 10),
        ManagementTile(
          icon: Icons.history,
          title: 'Audit logs',
          subtitle: 'Track all system changes',
          onTap: () => context.push('/admin/audit'),
        ),

        // Master-admin-only section
        if (isMasterAdmin) ...[
          const SizedBox(height: 24),
          const SectionLabel('Master admin'),
          const SizedBox(height: 10),
          ManagementTile(
            icon: Icons.tune_outlined,
            title: 'App preferences',
            subtitle: 'Cut-off, geofence radius, performance bands',
            onTap: () => context.push('/admin/settings'),
          ),
          const SizedBox(height: 10),
          ManagementTile(
            icon: Icons.cloud_outlined,
            title: 'Storage connection',
            subtitle: 'Google Drive for photos & proof',
            onTap: () => context.push('/admin/storage'),
          ),
          const SizedBox(height: 10),
          ManagementTile(
            icon: Icons.notifications_outlined,
            title: 'Notification templates',
            subtitle: 'Override app-level defaults',
            onTap: () => context.push('/admin/notifications'),
          ),
        ],
      ],
    );
  }
}

/// ‹ Today › — move the banner a day back / forward, tap the label to pick.
class _DayStepper extends StatelessWidget {
  final DateTime day;
  final bool isToday;
  final VoidCallback onPrev;
  final VoidCallback? onNext;
  final VoidCallback onPick;
  const _DayStepper({
    required this.day,
    required this.isToday,
    required this.onPrev,
    required this.onNext,
    required this.onPick,
  });

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    final yesterday = DateTime(n.year, n.month, n.day).subtract(const Duration(days: 1));
    final label = isToday
        ? 'Today'
        : day == yesterday
            ? 'Yesterday'
            : '${day.day} ${_months[day.month - 1]}';
    Widget arrow(IconData i, VoidCallback? f) => InkResponse(
          onTap: f,
          radius: 18,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(i, size: 22, color: f == null ? Colors.white38 : Colors.white),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      arrow(Icons.chevron_left, onPrev),
      InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(label,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
        ),
      ),
      arrow(Icons.chevron_right, onNext),
    ]);
  }
}

class _SummaryStat extends StatelessWidget {
  final String value;
  final String label;

  const _SummaryStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 11),
        ),
      ],
    );
  }
}

/// Simple thousands-separator formatter — "2591" -> "2,591".
String _fmtNumber(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  int count = 0;
  for (int i = s.length - 1; i >= 0; i--) {
    buf.write(s[i]);
    count++;
    if (count % 3 == 0 && i != 0) buf.write(',');
  }
  return buf.toString().split('').reversed.join();
}
