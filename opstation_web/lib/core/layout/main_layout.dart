import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/auth/auth_controller.dart';
import '../theme/app_theme.dart';

// ─── Providers ────────────────────────────────────────────────────────────────

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
  } catch (_) {
    return [];
  }
});

// ─── MainLayout ───────────────────────────────────────────────────────────────

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
      body: Column(children: [
        _TopNav(user: user),
        Expanded(child: child),
      ]),
    );
  }
}

// ─── Top Navigation Bar ───────────────────────────────────────────────────────

class _TopNav extends ConsumerWidget {
  final WebUser? user;
  const _TopNav({this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};

    final isAdminTier = user?.role == WebUserRole.admin || user?.role == WebUserRole.masterAdmin;
    final isDispatch = user?.role == WebUserRole.dispatchManager;
    final isAccountant = user?.role == WebUserRole.accountant;
    final isErpUser = user?.role == WebUserRole.erpUser;

    // ── ERP Inventory submenu ─────────────────────────────────────────────
    final inventoryItems = <Widget>[
      if (modules.contains('inventory')) ...[
        _menuItem(context, 'Products', Icons.inventory_2_outlined, '/erp/products', location),
        _menuItem(context, 'Branches', Icons.store_outlined, '/erp/branches', location),
        _menuItem(context, 'Units of Measure', Icons.straighten_outlined, '/erp/uoms', location),
        _menuItem(context, 'Stock Levels', Icons.stacked_bar_chart_outlined, '/erp/stock', location),
        _menuItem(context, 'Product Classifications', Icons.label_outline, '/erp/product-classifications', location),
        _menuItem(context, 'Opening Stock', Icons.open_in_new_outlined, '/erp/opening-stock', location),
        _menuItem(context, 'Stock Transfers', Icons.swap_horiz_outlined, '/erp/stock-transfers', location),
      ],
    ];

    // ── ERP Ledger submenu ────────────────────────────────────────────────
    final ledgerItems = <Widget>[
      if (modules.contains('purchase'))
        _menuItem(context, 'Supplier Ledger', Icons.people_outline, '/erp/supplier-ledger', location),
      if (modules.contains('sales') || modules.contains('pos'))
        _menuItem(context, 'Customer Ledger', Icons.store_outlined, '/erp/customer-ledger', location),
      if (modules.contains('inventory'))
        _menuItem(context, 'Inventory Ledger', Icons.inventory_2_outlined, '/erp/inventory-ledger', location),
      if (modules.contains('sales') || modules.contains('pos'))
        _menuItem(context, 'Customer Aging', Icons.hourglass_bottom_outlined, '/erp/customer-aging', location),
      if (modules.contains('purchase'))
        _menuItem(context, 'Supplier Aging', Icons.hourglass_bottom_outlined, '/erp/supplier-aging', location),
    ];

    // ── Per-section item lists ───────────────────────────────────────────
    final purchaseItems = <Widget>[
      if (modules.contains('purchase')) ...[
        _menuItem(context, 'Suppliers',               Icons.people_outline,            '/erp/suppliers',                location),
        _menuItem(context, 'Purchase Orders',          Icons.shopping_cart_outlined,     '/erp/purchase',                 location),
        _menuItem(context, 'GRN',                      Icons.move_to_inbox_outlined,     '/erp/grn',                      location),
        _menuItem(context, 'Purchase Invoices',        Icons.receipt_outlined,           '/erp/purchase-invoices',        location),
        _menuDivider(),
        _menuItem(context, 'Purchase Return Notes',    Icons.assignment_return_outlined, '/erp/purchase-returns',         location),
        _menuItem(context, 'Purchase Return Invoices', Icons.description_outlined,       '/erp/purchase-return-vouchers', location),
        _menuDivider(),
        _menuItem(context, 'Payments',                 Icons.payment_outlined,           '/erp/payment-vouchers',         location),
      ],
    ];

    final salesItems = <Widget>[
      if (modules.contains('sales')) ...[
        _menuItem(context, 'Sales Orders',         Icons.receipt_long_outlined,      '/erp/sales',                 location),
        _menuItem(context, 'Delivery Orders',       Icons.local_shipping_outlined,    '/erp/delivery-orders',       location),
        _menuItem(context, 'Sales Invoices',        Icons.receipt_outlined,           '/erp/sales-invoices',        location),
        _menuDivider(),
        _menuItem(context, 'Sales Return Notes',    Icons.assignment_return_outlined, '/erp/sales-returns',         location),
        _menuItem(context, 'Sales Return Invoices', Icons.receipt_long_outlined,      '/erp/sales-return-invoices', location),
        _menuDivider(),
        _menuItem(context, 'Receipts',              Icons.payments_outlined,          '/erp/receipt-vouchers',      location),
      ],
    ];

    final posItems = <Widget>[
      if (modules.contains('pos')) ...[
        _menuItem(context, 'POS',         Icons.storefront_outlined, '/erp/pos',         location),
        _menuItem(context, 'POS Catalog', Icons.list_alt_outlined,   '/erp/pos-catalog', location),
      ],
    ];

    final erpAdminItems = <Widget>[
      if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
        _menuItem(context, 'ERP Users', Icons.manage_accounts_outlined, '/erp/users', location),
    ];

    // Legacy combined list (still used for isNotEmpty guards)
    final erpMenuItems = <Widget>[
      ...inventoryItems, ...purchaseItems, ...salesItems, ...posItems,
      ...ledgerItems, ...erpAdminItems,
    ];

    List<Widget> splitErpMenus() => [
      if (inventoryItems.isNotEmpty)
        _navMenu(context, 'Inventory', Icons.inventory_2_outlined, location,
          ['/erp/products', '/erp/branches', '/erp/uoms', '/erp/stock',
           '/erp/product-classifications', '/erp/opening-stock', '/erp/stock-transfers'],
          inventoryItems),
      if (purchaseItems.isNotEmpty)
        _navMenu(context, 'Purchase', Icons.shopping_cart_outlined, location,
          ['/erp/suppliers', '/erp/purchase', '/erp/grn', '/erp/purchase-invoices',
           '/erp/purchase-returns', '/erp/purchase-return-vouchers', '/erp/payment-vouchers'],
          purchaseItems),
      if (salesItems.isNotEmpty)
        _navMenu(context, 'Sales', Icons.receipt_long_outlined, location,
          ['/erp/sales', '/erp/delivery-orders', '/erp/sales-invoices',
           '/erp/sales-returns', '/erp/sales-return-invoices', '/erp/receipt-vouchers'],
          salesItems),
      if (posItems.isNotEmpty)
        _navMenu(context, 'POS', Icons.storefront_outlined, location,
          ['/erp/pos', '/erp/pos-catalog'], posItems),
      if (ledgerItems.isNotEmpty)
        _navMenu(context, 'Ledgers', Icons.analytics_outlined, location,
          ['/erp/supplier-ledger', '/erp/customer-ledger', '/erp/inventory-ledger',
           '/erp/customer-aging', '/erp/supplier-aging'],
          ledgerItems),
      if (erpAdminItems.isNotEmpty)
        _navMenu(context, 'ERP', Icons.manage_accounts_outlined, location,
          ['/erp/users'], erpAdminItems),
    ];

    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: AppTheme.sidebar,
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(children: [
        // ── Logo ────────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(6)),
              alignment: Alignment.center,
              child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            const SizedBox(width: 8),
            const Text('Opstation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
          ]),
        ),
        Container(width: 1, height: 28, color: Colors.white12),
        const SizedBox(width: 4),

        // ── Navigation items (role-based) ────────────────────────────────────
        if (user?.role == WebUserRole.superAdmin)
          _navButton(context, 'Organizations', Icons.business, '/orgs', location),

        if (isDispatch) ...[
          _navButton(context, 'Deliveries', Icons.local_shipping_outlined, '/deliveries', location),
          _navButton(context, 'Dispatch Orders', Icons.assignment_outlined, '/dispatch-orders', location),
        ],

        if (isAccountant)
          _navButton(context, 'Orders', Icons.receipt_long, '/orders', location),

        if (isAdminTier) ...[
          _navMenu(context, 'Operations', Icons.local_shipping_outlined, location,
            ['/dashboard', '/team', '/customers', '/routes', '/deliveries', '/live-map', '/reports', '/compliance', '/settings'],
            [
              _menuItem(context, 'Dashboard', Icons.dashboard_outlined, '/dashboard', location),
              _menuItem(context, 'Team', Icons.people_outline, '/team', location),
              _menuItem(context, 'Customers', Icons.store_outlined, '/customers', location),
              _menuItem(context, 'Routes', Icons.route_outlined, '/routes', location),
              _menuItem(context, 'Deliveries', Icons.local_shipping_outlined, '/deliveries', location),
              _menuItem(context, 'Live Map', Icons.map_outlined, '/live-map', location),
              _menuItem(context, 'Reports', Icons.bar_chart_outlined, '/reports', location),
              _menuItem(context, 'Compliance', Icons.rule, '/compliance', location),
              if (user?.role == WebUserRole.masterAdmin)
                _menuItem(context, 'Settings', Icons.settings_outlined, '/settings', location),
            ],
          ),
          _navMenu(context, 'Intelligence', Icons.insights_outlined, location,
            ['/products', '/competitor-categories', '/intelligence/placement', '/intelligence/competitors'],
            [
              _menuItem(context, 'Products', Icons.inventory_2_outlined, '/products', location),
              _menuItem(context, 'Competitor Categories', Icons.category_outlined, '/competitor-categories', location),
              _menuItem(context, 'Placement Audit', Icons.checklist_outlined, '/intelligence/placement', location),
              _menuItem(context, 'Competitor Spotting', Icons.flag_outlined, '/intelligence/competitors', location),
            ],
          ),
          ...splitErpMenus(),
        ],

        if (isErpUser && erpMenuItems.isNotEmpty)
          ...splitErpMenus(),

        const Spacer(),

        // ── Branch selector ──────────────────────────────────────────────────
        Builder(builder: (ctx) {
          final hasErp = modules.any((m) => ['inventory', 'purchase', 'sales', 'pos'].contains(m));
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
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white24),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selected?['id'] as String?,
                dropdownColor: const Color(0xFF1E293B),
                icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 14),
                isDense: true,
                items: branches.map((b) => DropdownMenuItem<String>(
                  value: b['id'] as String,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.store_outlined, color: Colors.white70, size: 13),
                    const SizedBox(width: 6),
                    Text(b['name'] as String, style: const TextStyle(color: Colors.white, fontSize: 12)),
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

        // ── User / logout menu ───────────────────────────────────────────────
        Container(width: 1, height: 28, color: Colors.white12),
        PopupMenuButton<String>(
          offset: const Offset(0, 52),
          color: const Color(0xFF1E293B),
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Colors.white12),
          ),
          onSelected: (v) {
            if (v == 'logout') ref.read(authControllerProvider.notifier).signOut();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(user?.name ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                Text(user?.role.name ?? '', style: const TextStyle(color: AppTheme.sidebarText, fontSize: 11)),
              ]),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'logout',
              child: Row(children: [
                Icon(Icons.logout, size: 15, color: AppTheme.sidebarText),
                SizedBox(width: 8),
                Text('Sign out', style: TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: AppTheme.primary,
                child: Text(
                  user?.name.substring(0, 1).toUpperCase() ?? 'U',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                user?.name.split(' ').first ?? '',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 14),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─── Nav helpers ──────────────────────────────────────────────────────────────

Widget _navButton(BuildContext context, String label, IconData icon, String path, String location) {
  final isActive = location == path || location.startsWith('$path/');
  return InkWell(
    onTap: () => GoRouter.of(context).go(path),
    borderRadius: BorderRadius.circular(6),
    hoverColor: Colors.white10,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: isActive
          ? BoxDecoration(color: AppTheme.primary.withOpacity(0.3), borderRadius: BorderRadius.circular(6))
          : null,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: isActive ? Colors.white : AppTheme.sidebarText),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(
          color: isActive ? Colors.white : AppTheme.sidebarText,
          fontSize: 13,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
        )),
      ]),
    ),
  );
}

Widget _navMenu(
  BuildContext context,
  String label,
  IconData icon,
  String location,
  List<String> activePaths,
  List<Widget> items,
) {
  final isActive = activePaths.any((p) => location.startsWith(p));
  return MenuAnchor(
    style: MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(Color(0xFF1E293B)),
      elevation: const WidgetStatePropertyAll(12),
      shadowColor: WidgetStatePropertyAll(Colors.black54),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Colors.white12),
      )),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
    ),
    menuChildren: items,
    builder: (ctx, controller, _) {
      return InkWell(
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        borderRadius: BorderRadius.circular(6),
        hoverColor: Colors.white10,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: isActive
              ? BoxDecoration(color: AppTheme.primary.withOpacity(0.3), borderRadius: BorderRadius.circular(6))
              : null,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: isActive ? Colors.white : AppTheme.sidebarText),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(
              color: isActive ? Colors.white : AppTheme.sidebarText,
              fontSize: 13,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            )),
            const SizedBox(width: 3),
            Icon(
              controller.isOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 13,
              color: isActive ? Colors.white70 : AppTheme.sidebarText,
            ),
          ]),
        ),
      );
    },
  );
}

Widget _menuItem(BuildContext context, String label, IconData icon, String path, String location) {
  final isActive = location == path;
  return MenuItemButton(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (isActive) return AppTheme.primary.withOpacity(0.2);
        if (states.contains(WidgetState.hovered)) return Colors.white.withOpacity(0.08);
        return Colors.transparent;
      }),
      foregroundColor: WidgetStatePropertyAll(isActive ? Colors.white : Colors.white70),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      minimumSize: const WidgetStatePropertyAll(Size(220, 38)),
    ),
    leadingIcon: Icon(icon, size: 15, color: isActive ? Colors.white : Colors.white54),
    onPressed: () => GoRouter.of(context).go(path),
    child: Text(label, style: TextStyle(fontSize: 13, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400)),
  );
}

Widget _subMenu(
  BuildContext context,
  String label,
  IconData icon,
  String location,
  List<Widget> items,
  List<String> paths,
) {
  final isActive = paths.any((p) => location == p);
  return SubmenuButton(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (isActive) return AppTheme.primary.withOpacity(0.2);
        if (states.contains(WidgetState.hovered)) return Colors.white.withOpacity(0.08);
        return Colors.transparent;
      }),
      foregroundColor: WidgetStatePropertyAll(isActive ? Colors.white : Colors.white70),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      minimumSize: const WidgetStatePropertyAll(Size(220, 38)),
    ),
    menuStyle: MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(Color(0xFF1E293B)),
      elevation: const WidgetStatePropertyAll(12),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Colors.white12),
      )),
    ),
    leadingIcon: Icon(icon, size: 15, color: isActive ? Colors.white : Colors.white54),
    menuChildren: items,
    child: Text(label, style: TextStyle(fontSize: 13, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400)),
  );
}

Widget _menuDivider() => const Divider(height: 1, color: Colors.white12, indent: 12, endIndent: 12);

Widget _menuLabel(String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
  child: Text(text.toUpperCase(), style: const TextStyle(
    color: AppTheme.sidebarText,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
  )),
);
