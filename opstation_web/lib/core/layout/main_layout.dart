import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/auth_controller.dart';
import '../theme/app_theme.dart';

class MainLayout extends ConsumerWidget {
  final Widget child;
  const MainLayout({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    // Hard refresh on a deep URL: auth is still hydrating.
    // Show a spinner until it resolves so child screens never mount with a null user.
    if (auth.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final user = auth.valueOrNull;
    return Scaffold(
      body: Row(
        children: [
          _Sidebar(user: user),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  final WebUser? user;
  const _Sidebar({this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;

    final isAdminTier = user?.role == WebUserRole.admin ||
        user?.role == WebUserRole.masterAdmin;
    final isDispatch = user?.role == WebUserRole.dispatchManager;
    final isAccountant = user?.role == WebUserRole.accountant;
    final List<Object> items = [
      if (user?.role == WebUserRole.superAdmin)
        _NavItem(icon: Icons.business, label: 'Organizations', path: '/orgs'),
      if (isDispatch) ...[
        _NavItem(icon: Icons.local_shipping_outlined, label: 'Deliveries', path: '/deliveries'),
        _NavItem(icon: Icons.assignment_outlined, label: 'Dispatch Orders', path: '/dispatch-orders'),
      ],
      if (isAccountant) ...[
        _NavItem(icon: Icons.receipt_long, label: 'Orders', path: '/orders'),
      ],
      if (isAdminTier) ...[
        _NavItem(icon: Icons.dashboard_outlined, label: 'Dashboard', path: '/dashboard'),
        _NavItem(icon: Icons.people_outline, label: 'Team', path: '/team'),
        _NavItem(icon: Icons.store_outlined, label: 'Customers', path: '/customers'),
        _NavItem(icon: Icons.route_outlined, label: 'Routes', path: '/routes'),
        _NavItem(icon: Icons.local_shipping_outlined, label: 'Deliveries', path: '/deliveries'),
        _NavItem(icon: Icons.map_outlined, label: 'Live Map', path: '/live-map'),
        _NavItem(icon: Icons.bar_chart_outlined, label: 'Reports', path: '/reports'),
        _NavGroup(
          icon: Icons.insights_outlined,
          label: 'Intelligence',
          children: [
            _NavItem(icon: Icons.inventory_2_outlined, label: 'Products', path: '/products'),
            _NavItem(icon: Icons.category_outlined, label: 'Competitor Categories', path: '/competitor-categories'),
            _NavItem(icon: Icons.checklist_outlined, label: 'Placement Audit', path: '/intelligence/placement'),
            _NavItem(icon: Icons.flag_outlined, label: 'Competitor Spotting', path: '/intelligence/competitors'),
          ],
        ),
        _NavItem(icon: Icons.rule, label: 'Compliance', path: '/compliance'),
        if (user?.role == WebUserRole.masterAdmin)
          _NavItem(icon: Icons.settings_outlined, label: 'Settings', path: '/settings'),
      ],
    ];

    return Container(
      width: 240,
      color: AppTheme.sidebar,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(8)),
                  alignment: Alignment.center,
                  child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
                ),
                const SizedBox(width: 10),
                const Text('Opstation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
              ],
            ),
          ),
          if (user?.orgName != null)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  const Icon(Icons.business, color: AppTheme.sidebarText, size: 14),
                  const SizedBox(width: 8),
                  Expanded(child: Text(user!.orgName!, style: const TextStyle(color: AppTheme.sidebarText, fontSize: 12), overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: items.map((entry) {
                if (entry is _NavItem) {
                  return _buildNavTile(entry, location, context);
                } else if (entry is _NavGroup) {
                  return _buildNavGroup(entry, location, context);
                }
                return const SizedBox.shrink();
              }).toList(),
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          ListTile(
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primary,
              child: Text(user?.name.substring(0, 1).toUpperCase() ?? 'U', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
            title: Text(user?.name ?? '', style: const TextStyle(color: Colors.white, fontSize: 13), overflow: TextOverflow.ellipsis),
            subtitle: Text(user?.role.name ?? '', style: const TextStyle(color: AppTheme.sidebarText, fontSize: 11)),
            trailing: IconButton(
              icon: const Icon(Icons.logout, color: AppTheme.sidebarText, size: 18),
              onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
              tooltip: 'Sign out',
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  final String path;
  const _NavItem({required this.icon, required this.label, required this.path});
}

class _NavGroup {
  final IconData icon;
  final String label;
  final List<_NavItem> children;
  const _NavGroup({required this.icon, required this.label, required this.children});
}

Widget _buildNavTile(
  _NavItem item,
  String location,
  BuildContext context, {
  bool indented = false,
}) {
  final isActive = location == item.path;
  return Container(
    margin: const EdgeInsets.only(bottom: 2),
    child: ListTile(
      contentPadding: indented
          ? const EdgeInsets.only(left: 28, right: 16)
          : null,
      leading: Icon(
        item.icon,
        color: isActive ? Colors.white : AppTheme.sidebarText,
        size: indented ? 18 : 20,
      ),
      title: Text(
        item.label,
        style: TextStyle(
          color: isActive ? Colors.white : AppTheme.sidebarText,
          fontSize: indented ? 13 : 14,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      tileColor: isActive ? AppTheme.sidebarActive : Colors.transparent,
      hoverColor: Colors.white10,
      onTap: () => context.go(item.path),
      dense: true,
    ),
  );
}

Widget _buildNavGroup(
  _NavGroup group,
  String location,
  BuildContext context,
) {
  final hasActiveChild = group.children.any((c) => location == c.path);
  return Container(
    margin: const EdgeInsets.only(bottom: 2),
    child: Theme(
      // Kill ExpansionTile's default top/bottom dividers and ripple
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: ExpansionTile(
        key: PageStorageKey<String>('sidebar_group_${group.label}'),
        initiallyExpanded: hasActiveChild,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Icon(group.icon, color: AppTheme.sidebarText, size: 20),
        title: Text(
          group.label,
          style: const TextStyle(
            color: AppTheme.sidebarText,
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
        ),
        iconColor: AppTheme.sidebarText,
        collapsedIconColor: AppTheme.sidebarText,
        childrenPadding: EdgeInsets.zero,
        children: group.children
            .map((sub) => _buildNavTile(sub, location, context, indented: true))
            .toList(),
      ),
    ),
  );
}
