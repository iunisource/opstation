import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/auth/auth_controller.dart';
import '../theme/app_theme.dart';

final orgModulesProvider = FutureProvider<Set<String>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null || user.orgId == null) return {};
  try {
    final client = Supabase.instance.client;
    final res = await client
        .from('org_modules')
        .select('module')
        .eq('org_id', user.orgId!)
        .eq('is_enabled', true);
    return {for (final row in res as List) row['module'] as String};
  } catch (_) {
    return {};
  }
});

// Currently selected branch (global ERP context)
final selectedBranchProvider = StateProvider<Map<String, dynamic>?>((ref) => null);

// Branches available to this user
final userBranchesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null || user.orgId == null) return [];
  try {
    final client = Supabase.instance.client;
    if (user.role == WebUserRole.erpUser) {
      final res = await client
          .from('erp_user_branches')
          .select('branches(*)')
          .eq('user_id', user.id);
      return (res as List)
          .where((r) => r['branches'] != null)
          .map((r) => Map<String, dynamic>.from(r['branches'] as Map))
          .toList();
    } else {
      final orgId = user.orgId!;
      return List<Map<String, dynamic>>.from(
          await client.from('branches').select().eq('org_id', orgId).eq('is_active', true).order('name'));
    }
  } catch (_) { return []; }
});

class MainLayout extends ConsumerWidget {
  final Widget child;
  const MainLayout({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final user = auth.valueOrNull;
    return Scaffold(
      body: Row(children: [
        _Sidebar(user: user),
        Expanded(child: child),
      ]),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  final WebUser? user;
  const _Sidebar({this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};

    final isAdminTier = user?.role == WebUserRole.admin ||
        user?.role == WebUserRole.masterAdmin;
    final isDispatch = user?.role == WebUserRole.dispatchManager;
    final isAccountant = user?.role == WebUserRole.accountant;
    final isErpUser = user?.role == WebUserRole.erpUser;

    // Inventory sub-group children
    final inventoryChildren = <Object>[
      if (modules.contains('inventory')) ...[
        _NavItem(icon: Icons.inventory_2_outlined, label: 'Products', path: '/erp/products'),
        _NavItem(icon: Icons.store_outlined, label: 'Branches', path: '/erp/branches'),
        _NavItem(icon: Icons.straighten_outlined, label: 'Units of Measure', path: '/erp/uoms'),
        _NavItem(icon: Icons.stacked_bar_chart_outlined, label: 'Stock Levels', path: '/erp/stock'),
        _NavItem(icon: Icons.label_outline, label: 'Product Classifications', path: '/erp/product-classifications'),
      ],
    ];

    // ERP top-level children
    final erpChildren = <Object>[
      if (inventoryChildren.isNotEmpty)
        _NavGroup(icon: Icons.inventory_2_outlined, label: 'Inventory', children: inventoryChildren),
      if (modules.contains('purchase')) ...[
        _NavItem(icon: Icons.people_outline, label: 'Suppliers', path: '/erp/suppliers'),
        _NavItem(icon: Icons.shopping_cart_outlined, label: 'Purchase', path: '/erp/purchase'),
      ],
      if (modules.contains('sales'))
        _NavItem(icon: Icons.receipt_long_outlined, label: 'Sales', path: '/erp/sales'),
      if (modules.contains('pos'))
        _NavItem(icon: Icons.storefront_outlined, label: 'POS', path: '/erp/pos'),
    ];

    final List<Object> items = [
      if (user?.role == WebUserRole.superAdmin)
        _NavItem(icon: Icons.business, label: 'Organizations', path: '/orgs'),
      if (isDispatch) ...[
        _NavItem(icon: Icons.local_shipping_outlined, label: 'Deliveries', path: '/deliveries'),
        _NavItem(icon: Icons.assignment_outlined, label: 'Dispatch Orders', path: '/dispatch-orders'),
      ],
      if (isAccountant)
        _NavItem(icon: Icons.receipt_long, label: 'Orders', path: '/orders'),
      if (isAdminTier) ...[
        _NavGroup(
          icon: Icons.local_shipping_outlined,
          label: 'Operations',
          children: [
            _NavItem(icon: Icons.dashboard_outlined, label: 'Dashboard', path: '/dashboard'),
            _NavItem(icon: Icons.people_outline, label: 'Team', path: '/team'),
            _NavItem(icon: Icons.store_outlined, label: 'Customers', path: '/customers'),
            _NavItem(icon: Icons.route_outlined, label: 'Routes', path: '/routes'),
            _NavItem(icon: Icons.local_shipping_outlined, label: 'Deliveries', path: '/deliveries'),
            _NavItem(icon: Icons.map_outlined, label: 'Live Map', path: '/live-map'),
            _NavItem(icon: Icons.bar_chart_outlined, label: 'Reports', path: '/reports'),
            _NavItem(icon: Icons.rule, label: 'Compliance', path: '/compliance'),
            if (user?.role == WebUserRole.masterAdmin)
              _NavItem(icon: Icons.settings_outlined, label: 'Settings', path: '/settings'),
          ],
        ),
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
        if (erpChildren.isNotEmpty)
          _NavGroup(
            icon: Icons.account_balance_wallet_outlined,
            label: 'ERP',
            children: erpChildren,
          ),
      ],
      if (isErpUser && erpChildren.isNotEmpty)
        _NavGroup(
          icon: Icons.account_balance_wallet_outlined,
          label: 'ERP',
          children: erpChildren,
        ),
    ];

    return Container(
      width: 240,
      color: AppTheme.sidebar,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(24),
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(8)),
              alignment: Alignment.center,
              child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
            ),
            const SizedBox(width: 10),
            const Text('Opstation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
          ]),
        ),
        if (user?.orgName != null)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.business, color: AppTheme.sidebarText, size: 14),
              const SizedBox(width: 8),
              Expanded(child: Text(user!.orgName!,
                  style: const TextStyle(color: AppTheme.sidebarText, fontSize: 12),
                  overflow: TextOverflow.ellipsis)),
            ]),
          ),
        Builder(builder: (context) {
          final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
          final hasErp = modules.any((m) => ['inventory','purchase','sales','pos'].contains(m));
          if (!hasErp) return const SizedBox.shrink();
          final branches = ref.watch(userBranchesProvider).valueOrNull ?? [];
          final selected = ref.watch(selectedBranchProvider);
          if (branches.isEmpty) return const SizedBox.shrink();
          if (selected == null && branches.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              ref.read(selectedBranchProvider.notifier).state = branches.first;
            });
          }
          return Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selected?['id'] as String?,
                dropdownColor: const Color(0xFF1E293B),
                icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 16),
                isExpanded: true,
                items: branches.map((b) => DropdownMenuItem<String>(
                  value: b['id'] as String,
                  child: Row(children: [
                    const Icon(Icons.store_outlined, color: Colors.white70, size: 14),
                    const SizedBox(width: 6),
                    Expanded(child: Text(b['name'] as String,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        overflow: TextOverflow.ellipsis)),
                  ]),
                )).toList(),
                onChanged: (id) {
                  if (id == null) return;
                  final branch = branches.firstWhere((b) => b['id'] == id);
                  ref.read(selectedBranchProvider.notifier).state = branch;
                },
              ),
            ),
          );
        }),
        const Divider(color: Colors.white12, height: 1),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            children: items.map((entry) {
              if (entry is _NavItem) return _buildNavTile(entry, location, context);
              if (entry is _NavGroup) return _buildNavGroup(entry, location, context);
              return const SizedBox.shrink();
            }).toList(),
          ),
        ),
        const Divider(color: Colors.white12, height: 1),
        ListTile(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: AppTheme.primary,
            child: Text(user?.name.substring(0, 1).toUpperCase() ?? 'U',
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          title: Text(user?.name ?? '',
              style: const TextStyle(color: Colors.white, fontSize: 13),
              overflow: TextOverflow.ellipsis),
          subtitle: Text(user?.role.name ?? '',
              style: const TextStyle(color: AppTheme.sidebarText, fontSize: 11)),
          trailing: IconButton(
            icon: const Icon(Icons.logout, color: AppTheme.sidebarText, size: 18),
            onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
            tooltip: 'Sign out',
          ),
        ),
        const SizedBox(height: 8),
      ]),
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
  final List<Object> children;
  const _NavGroup({required this.icon, required this.label, required this.children});
}

Widget _buildNavTile(
  _NavItem item,
  String location,
  BuildContext context, {
  int depth = 0,
}) {
  final isActive = location == item.path;
  EdgeInsetsGeometry? padding;
  double fontSize = 14;
  double iconSize = 20;
  if (depth == 1) {
    padding = const EdgeInsets.only(left: 28, right: 16);
    fontSize = 13;
    iconSize = 18;
  } else if (depth >= 2) {
    padding = const EdgeInsets.only(left: 44, right: 16);
    fontSize = 13;
    iconSize = 16;
  }
  return Container(
    margin: const EdgeInsets.only(bottom: 2),
    child: ListTile(
      contentPadding: padding,
      leading: Icon(item.icon,
          color: isActive ? Colors.white : AppTheme.sidebarText,
          size: iconSize),
      title: Text(item.label,
          style: TextStyle(
            color: isActive ? Colors.white : AppTheme.sidebarText,
            fontSize: fontSize,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          )),
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
  BuildContext context, {
  int depth = 0,
}) {
  bool hasActive(List<Object> children) {
    for (final c in children) {
      if (c is _NavItem && location == c.path) return true;
      if (c is _NavGroup && hasActive(c.children)) return true;
    }
    return false;
  }

  final double leftPad = depth == 0 ? 16 : 28;
  final double iconSize = depth == 0 ? 20 : 18;
  final double fontSize = depth == 0 ? 14 : 13;

  return Container(
    margin: const EdgeInsets.only(bottom: 2),
    child: Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: ExpansionTile(
        key: PageStorageKey<String>('sidebar_group_${group.label}_$depth'),
        initiallyExpanded: hasActive(group.children),
        tilePadding: EdgeInsets.symmetric(horizontal: leftPad),
        leading: Icon(group.icon, color: AppTheme.sidebarText, size: iconSize),
        title: Text(group.label,
            style: TextStyle(
              color: AppTheme.sidebarText,
              fontSize: fontSize,
              fontWeight: FontWeight.w400,
            )),
        iconColor: AppTheme.sidebarText,
        collapsedIconColor: AppTheme.sidebarText,
        childrenPadding: EdgeInsets.zero,
        children: group.children.map((child) {
          if (child is _NavItem) {
            return _buildNavTile(child, location, context, depth: depth + 1);
          } else if (child is _NavGroup) {
            return _buildNavGroup(child, location, context, depth: depth + 1);
          }
          return const SizedBox.shrink();
        }).toList(),
      ),
    ),
  );
}
