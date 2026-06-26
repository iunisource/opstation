import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'opstation_header.dart';

/// Common scaffold used by all role home screens.
/// Provides the Opstation header bar with sound/theme/logout actions.
class RoleHomeScaffold extends StatelessWidget {
  final String appBarTitle;
  final Widget body;
  final Widget? floatingActionButton;
  /// Optional navigation drawer. When provided, the AppBar automatically
  /// shows a hamburger that opens it. Null for roles that don't use one.
  final Widget? drawer;
  /// When provided, wraps the body in a RefreshIndicator so the user
  /// can drag-down to reload stats and lists.
  final Future<void> Function()? onRefresh;

  const RoleHomeScaffold({
    super.key,
    required this.appBarTitle,
    required this.body,
    this.floatingActionButton,
    this.drawer,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final content = SafeArea(top: false, child: body);
    return Scaffold(
      drawer: drawer,
      appBar: AppBar(
        title: Text(
          appBarTitle,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
        ),
        actions: [
          if (onRefresh != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: onRefresh,
            ),
          const OpstationHeaderActions(),
          const SizedBox(width: 8),
        ],
      ),
      body: onRefresh != null
          ? RefreshIndicator(onRefresh: onRefresh!, child: content)
          : content,
      floatingActionButton: floatingActionButton,
    );
  }
}

/// Simple tile with icon, title, subtitle, chevron — used on dashboards.
class ManagementTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const ManagementTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
                          ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20, color: AppColors.textTertiaryLight),
            ],
          ),
        ),
      ),
    );
  }
}

/// KPI card showing an icon, a big number, and a label.
class StatTile extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconFg;
  final String value;
  final String label;
  final VoidCallback? onTap;

  const StatTile({
    super.key,
    required this.icon,
    required this.iconBg,
    required this.iconFg,
    required this.value,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: iconFg, size: 20),
              ),
              const SizedBox(height: 12),
              Text(
                value,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withOpacity(0.7),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
