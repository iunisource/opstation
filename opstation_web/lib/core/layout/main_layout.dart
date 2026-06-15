// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/auth/auth_controller.dart';
import '../theme/app_theme.dart';
import '../permissions/access_control.dart';
import '../permissions/permission_registry.dart';
import 'erp_global_search.dart';

// ─── Providers ────────────────────────────────────────────────────────────────

final orgModulesProvider = FutureProvider<Set<String>>((ref) async {
  // Await full auth resolution so the restored session's JWT is attached before
  // querying; otherwise a cold-start refresh races and returns empty modules,
  // blanking the whole menu.
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return {};
  final client = Supabase.instance.client;
  Future<Set<String>> fetch() async {
    final res = await client
        .from('org_modules')
        .select('module')
        .eq('org_id', user.orgId!)
        .eq('is_enabled', true);
    return {for (final row in res as List) row['module'] as String};
  }
  try {
    var mods = await fetch();
    // Empty = likely the session race (every active org has modules) — retry once.
    if (mods.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 400));
      mods = await fetch();
    }
    return mods;
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

// Count of overdue open CRM follow-ups for the current org (sidebar badge).
final crmOverdueCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final res = await client
        .from('customer_activities')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('status', 'open')
        .not('due_date', 'is', null)
        .lt('due_date', today);
    return (res as List).length;
  } catch (_) {
    return 0;
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
    final access = ref.watch(accessSyncProvider);
    final crmOverdue = ref.watch(crmOverdueCountProvider).valueOrNull ?? 0;
    bool show(String route) {
      final mod = kRouteToModule[route];
      if (mod != null && !modules.contains(mod)) return false;
      final r = user?.role;
      final isAdminTier2 = r == WebUserRole.admin ||
          r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
      if (isAdminTier2) return true;
      if (access == null) return false;
      return access.canAccessRoute(route);
    }

    final isAdminTier = user?.role == WebUserRole.admin || user?.role == WebUserRole.masterAdmin;
    final isDispatch = user?.role == WebUserRole.dispatchManager;
    final isAccountant = user?.role == WebUserRole.accountant;
    final isErpUser = user?.role == WebUserRole.erpUser;

    // ── ERP Inventory submenu ─────────────────────────────────────────────
    final inventoryItems = <Widget>[
      if (modules.contains('inventory')) ...[
        if (show('/erp/products')) _menuItem(context, 'Products', Icons.inventory_2_outlined, '/erp/products', location),
        if (show('/erp/branches')) _menuItem(context, 'Branches', Icons.store_outlined, '/erp/branches', location),
        if (show('/erp/uoms')) _menuItem(context, 'Units of Measure', Icons.straighten_outlined, '/erp/uoms', location),
        if (show('/erp/stock')) _menuItem(context, 'Stock Levels', Icons.stacked_bar_chart_outlined, '/erp/stock', location),
        if (show('/erp/low-stock-report')) _menuItem(context, 'Low Stock Report', Icons.warning_amber_outlined, '/erp/low-stock-report', location),
        if (show('/erp/stock-value-report')) _menuItem(context, 'Stock Value Report', Icons.payments_outlined, '/erp/stock-value-report', location),
        if (show('/erp/product-classifications')) _menuItem(context, 'Product Classifications', Icons.label_outline, '/erp/product-classifications', location),
        if (show('/erp/opening-stock')) _menuItem(context, 'Opening Stock', Icons.open_in_new_outlined, '/erp/opening-stock', location),
        if (show('/erp/stock-transfers')) _menuItem(context, 'Stock Transfers', Icons.swap_horiz_outlined, '/erp/stock-transfers', location),
        if (show('/erp/stock-adjustment')) _menuItem(context, 'Stock Adjustment', Icons.tune_outlined, '/erp/stock-adjustment', location),
      ],
    ];

    // ── ERP Ledger submenu ────────────────────────────────────────────────
    final ledgerItems = <Widget>[
      if (modules.contains('purchase'))
        if (show('/erp/supplier-ledger')) _menuItem(context, 'Supplier Ledger', Icons.people_outline, '/erp/supplier-ledger', location),
      if (modules.contains('sales') || modules.contains('pos'))
        if (show('/erp/customer-ledger')) _menuItem(context, 'Customer Ledger', Icons.store_outlined, '/erp/customer-ledger', location),
      if (modules.contains('inventory'))
        if (show('/erp/inventory-ledger')) _menuItem(context, 'Inventory Ledger', Icons.inventory_2_outlined, '/erp/inventory-ledger', location),
      if (modules.contains('sales') || modules.contains('pos'))
        if (show('/erp/customer-aging')) _menuItem(context, 'Customer Aging', Icons.hourglass_bottom_outlined, '/erp/customer-aging', location),
      if (modules.contains('purchase'))
        if (show('/erp/supplier-aging')) _menuItem(context, 'Supplier Aging', Icons.hourglass_bottom_outlined, '/erp/supplier-aging', location),
    ];

    // ── Per-section item lists ───────────────────────────────────────────
    final purchaseItems = <Widget>[
      if (modules.contains('purchase')) ...[
        if (show('/erp/suppliers')) _menuItem(context, 'Suppliers',               Icons.people_outline,            '/erp/suppliers',                location),
        if (show('/erp/purchase')) _menuItem(context, 'Purchase Orders',          Icons.shopping_cart_outlined,     '/erp/purchase',                 location),
        if (show('/erp/grn')) _menuItem(context, 'GRN',                      Icons.move_to_inbox_outlined,     '/erp/grn',                      location),
        if (show('/erp/purchase-invoices')) _menuItem(context, 'Purchase Invoices',        Icons.receipt_outlined,           '/erp/purchase-invoices',        location),
        _menuDivider(),
        if (show('/erp/purchase-returns')) _menuItem(context, 'Purchase Return Notes',    Icons.assignment_return_outlined, '/erp/purchase-returns',         location),
        if (show('/erp/purchase-return-vouchers')) _menuItem(context, 'Purchase Return Invoices', Icons.description_outlined,       '/erp/purchase-return-vouchers', location),
        _menuDivider(),
      ],
    ];

    final salesItems = <Widget>[
      if (modules.contains('sales')) ...[
        if (show('/erp/sales')) _menuItem(context, 'Sales Orders',         Icons.receipt_long_outlined,      '/erp/sales',                 location),
        if (show('/erp/delivery-orders')) _menuItem(context, 'Delivery Orders',       Icons.local_shipping_outlined,    '/erp/delivery-orders',       location),
        if (show('/erp/sales-invoices')) _menuItem(context, 'Sales Invoices',        Icons.receipt_outlined,           '/erp/sales-invoices',        location),
        _menuDivider(),
        if (show('/erp/sales-returns')) _menuItem(context, 'Sales Return Notes',    Icons.assignment_return_outlined, '/erp/sales-returns',         location),
        if (show('/erp/sales-return-invoices')) _menuItem(context, 'Sales Return Invoices', Icons.receipt_long_outlined,      '/erp/sales-return-invoices', location),
        _menuDivider(),
        
      ],
    ];

    final posItems = <Widget>[
      if (modules.contains('pos')) ...[
        if (show('/erp/pos-config')) _menuItem(context, 'Configuration', Icons.tune_outlined, '/erp/pos-config', location),
        if (show('/erp/promoters')) _menuItem(context, 'Promoters', Icons.badge_outlined, '/erp/promoters', location),
        if (show('/erp/pos')) _menuItem(context, 'POS',         Icons.storefront_outlined, '/erp/pos',         location),
        if (show('/erp/pos-catalog')) _menuItem(context, 'POS Catalog',    Icons.list_alt_outlined,     '/erp/pos-catalog',           location),
        if (show('/erp/pos-customer-history')) _menuItem(context, 'Customer History', Icons.manage_accounts_outlined, '/erp/pos-customer-history', location),
        if (show('/erp/pos-held-bills')) _menuItem(context, 'Bills on Hold',       Icons.pause_circle_outlined,    '/erp/pos-held-bills',          location),
        if (show('/erp/pos-expense-management')) _menuItem(context, 'Expense Management',  Icons.receipt_outlined,          '/erp/pos-expense-management',  location),
      ],
    ];

    final manufacturingItems = <Widget>[
      if (show('/manufacturing/production-floor')) _menuItem(context, 'Production Floor',           Icons.dashboard_outlined,               '/manufacturing/production-floor',           location),
      if (show('/manufacturing/product-assembly')) _menuItem(context, 'Product Assembly (BOM)',    Icons.account_tree_outlined,            '/manufacturing/product-assembly',           location),
      if (show('/manufacturing/production-voucher')) _menuItem(context, 'Production Voucher',         Icons.precision_manufacturing_outlined, '/manufacturing/production-voucher',         location),
      if (show('/manufacturing/job-card')) _menuItem(context, 'Job Card',                   Icons.assignment_outlined,              '/manufacturing/job-card',                   location),
      if (show('/manufacturing/qc-checkpoints')) _menuItem(context, 'QC Checkpoints',             Icons.fact_check_outlined,              '/manufacturing/qc-checkpoints',             location),
      if (show('/manufacturing/production-inverse-voucher')) _menuItem(context, 'Production Inverse Voucher', Icons.undo_outlined,                    '/manufacturing/production-inverse-voucher', location),
      if (show('/manufacturing/damage-stock-voucher')) _menuItem(context, 'Damage Stock Voucher',       Icons.report_gmailerrorred_outlined,    '/manufacturing/damage-stock-voucher',       location),
      if (show('/manufacturing/claim-processing-voucher')) _menuItem(context, 'Claim Processing Voucher',   Icons.assignment_return_outlined,       '/manufacturing/claim-processing-voucher',   location),
      if (show('/manufacturing/production-waste-report')) _menuItem(context, 'Production Waste Report',    Icons.recycling_outlined,               '/manufacturing/production-waste-report',    location),
    ];

    final hrItems = <Widget>[
      if (show('/hr/employees')) _menuItem(context, 'Employee Directory', Icons.groups_outlined, '/hr/employees', location),
      if (show('/hr/attendance')) _menuItem(context, 'Attendance', Icons.fact_check_outlined, '/hr/attendance', location),
      if (show('/hr/leave')) _menuItem(context, 'Leave', Icons.beach_access_outlined, '/hr/leave', location),
    ];

    final financialItems = <Widget>[
      if (show('/erp/chart-of-accounts')) _menuItem(context, 'Chart of Accounts',  Icons.account_tree_outlined,    '/erp/chart-of-accounts',          location),
      if (show('/financials/journal-vouchers')) _menuItem(context, 'Journal Vouchers',   Icons.edit_note_outlined,          '/financials/journal-vouchers',    location),
      if (show('/financials/opening-journal')) _menuItem(context, 'Opening Journal', Icons.flag_outlined, '/financials/opening-journal', location),
      if (show('/erp/payment-vouchers')) _menuItem(context, 'Payment Vouchers', Icons.receipt_long_outlined, '/erp/payment-vouchers', location),
      if (show('/erp/receipt-vouchers')) _menuItem(context, 'Receipt Vouchers', Icons.payments_outlined,     '/erp/receipt-vouchers',      location),
      if (show('/erp/pdc-voucher')) _menuItem(context, 'PDC Voucher', Icons.account_balance_wallet_outlined, '/erp/pdc-voucher', location),
      if (show('/financials/trial-balance')) _menuItem(context, 'Trial Balance',    Icons.account_balance_outlined, '/financials/trial-balance',  location),
      if (show('/financials/account-activity')) _menuItem(context, 'Account Activity', Icons.receipt_long_outlined, '/financials/account-activity', location),
      if (show('/financials/profit-loss')) _menuItem(context, 'Profit & Loss',    Icons.trending_up_outlined,     '/financials/profit-loss',    location),
      if (show('/financials/balance-sheet')) _menuItem(context, 'Balance Sheet',    Icons.balance_outlined,         '/financials/balance-sheet',  location),
    ];

    final erpAdminItems = <Widget>[
      if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
        _menuItem(context, 'ERP Users', Icons.manage_accounts_outlined, '/erp/users', location),
      if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
        _menuItem(context, 'Audit Trail', Icons.history_toggle_off_outlined, '/erp/audit-log', location),
      if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
        _menuItem(context, 'Admin Settings', Icons.admin_panel_settings_outlined, '/erp/admin-settings', location),
    ];

    // Legacy combined list (still used for isNotEmpty guards)
    final erpMenuItems = <Widget>[
      ...inventoryItems, ...purchaseItems, ...salesItems, ...posItems,
      ...ledgerItems, ...financialItems, ...manufacturingItems, ...hrItems, ...erpAdminItems,
    ];

    List<Widget> splitErpMenus() => [
      if (_hasItems(inventoryItems))
        _navMenu(context, 'Inventory', Icons.inventory_2_outlined, location,
          ['/erp/products', '/erp/branches', '/erp/uoms', '/erp/stock', '/erp/low-stock-report', '/erp/stock-value-report',
           '/erp/product-classifications', '/erp/opening-stock', '/erp/stock-transfers', '/erp/stock-adjustment'],
          _trimDividers(inventoryItems)),
      if (_hasItems(purchaseItems))
        _navMenu(context, 'Purchase', Icons.shopping_cart_outlined, location,
          ['/erp/suppliers', '/erp/purchase', '/erp/grn', '/erp/purchase-invoices',
           '/erp/purchase-returns', '/erp/purchase-return-vouchers', '/erp/payment-vouchers'],
          _trimDividers(purchaseItems)),
      if (_hasItems(salesItems))
        _navMenu(context, 'Sales', Icons.receipt_long_outlined, location,
          ['/erp/sales', '/erp/delivery-orders', '/erp/sales-invoices',
           '/erp/sales-returns', '/erp/sales-return-invoices'],
          _trimDividers(salesItems)),
      if (_hasItems(posItems))
        _navMenu(context, 'POS', Icons.storefront_outlined, location,
          ['/erp/pos', '/erp/pos-catalog', '/erp/pos-config', '/erp/pos-customer-history', '/erp/pos-held-bills', '/erp/pos-expense-management'], _trimDividers(posItems)),
      if (_hasItems(ledgerItems))
        _navMenu(context, 'Ledgers', Icons.analytics_outlined, location,
          ['/erp/supplier-ledger', '/erp/customer-ledger', '/erp/inventory-ledger',
           '/erp/customer-aging', '/erp/supplier-aging'],
          _trimDividers(ledgerItems)),
      _navMenu(context, 'Reports', Icons.summarize_outlined, location,
        ['/reports/margin', '/reports/customer-balance'],
        [_menuItem(context, 'Margin Report', Icons.trending_up, '/reports/margin', location),
         _menuItem(context, 'Customer Balance Report', Icons.account_balance_wallet_outlined, '/reports/customer-balance', location)]),
      if (_hasItems(manufacturingItems))
        _navMenu(context, 'Manufacturing', Icons.precision_manufacturing_outlined, location,
          ['/manufacturing/production-floor', '/manufacturing/product-assembly', '/manufacturing/production-voucher', '/manufacturing/job-card', '/manufacturing/qc-checkpoints',
           '/manufacturing/production-inverse-voucher', '/manufacturing/damage-stock-voucher',
           '/manufacturing/claim-processing-voucher', '/manufacturing/production-waste-report'],
          _trimDividers(manufacturingItems)),
      if (_hasItems(financialItems))
        _navMenu(context, 'Financials', Icons.account_balance_outlined, location,
          ['/erp/chart-of-accounts', '/erp/payment-vouchers', '/erp/receipt-vouchers', '/erp/pdc-voucher'],
          _trimDividers(financialItems)),
      if (_hasItems(hrItems))
        _navMenu(context, 'HR', Icons.badge_outlined, location,
          ['/hr/employees', '/hr/attendance', '/hr/leave'], _trimDividers(hrItems)),
      if (_hasItems(erpAdminItems))
        _navMenu(context, 'ERP', Icons.manage_accounts_outlined, location,
          ['/erp/users', '/erp/admin-settings', '/erp/audit-log'], _trimDividers(erpAdminItems)),
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

        // ── Navigation items (role-based, horizontally scrollable) ───────────
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
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
          _navMenu(context, 'CRM', Icons.contacts_outlined, location,
            ['/crm/customers', '/crm/follow-ups', '/crm/pipeline'],
            [
              _menuItem(context, 'Customers', Icons.store_outlined, '/crm/customers', location),
              _menuItem(context, 'Pipeline', Icons.view_kanban_outlined, '/crm/pipeline', location),
              _menuItem(context, 'Follow-ups', Icons.task_alt_outlined, '/crm/follow-ups', location, badge: crmOverdue),
            ],
            badge: crmOverdue,
          ),
          _navMenu(context, 'Intelligence', Icons.insights_outlined, location,
            ['/products', '/competitor-categories', '/intelligence/placement', '/intelligence/competitors', '/intelligence/report-builder'],
            [
              _menuItem(context, 'Products', Icons.inventory_2_outlined, '/products', location),
              _menuItem(context, 'Competitor Categories', Icons.category_outlined, '/competitor-categories', location),
              _menuItem(context, 'Placement Audit', Icons.checklist_outlined, '/intelligence/placement', location),
              _menuItem(context, 'Competitor Spotting', Icons.flag_outlined, '/intelligence/competitors', location),
              _menuItem(context, 'Report Builder', Icons.table_chart_outlined, '/intelligence/report-builder', location),
            ],
          ),
          ...splitErpMenus(),
        ],

        if (isErpUser && erpMenuItems.isNotEmpty)
          ...splitErpMenus(),
            ]),
          ),
        ),

        // ── Global search ────────────────────────────────────────────────────
        IconButton(
          tooltip: 'Search products, customers, suppliers, vouchers, entries',
          icon: const Icon(Icons.search, color: Colors.white70, size: 20),
          onPressed: () {
            final oid = user?.orgId;
            if (oid != null) showGlobalSearch(context, orgId: oid, can: show);
          },
        ),
        const SizedBox(width: 4),

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
                  ScaffoldMessenger.of(ctx)
                    ..clearSnackBars()
                    ..showSnackBar(SnackBar(
                      content: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.check_circle, color: Colors.white, size: 18),
                        const SizedBox(width: 10),
                        Text('Switched to ${branch['name']}'),
                      ]),
                      duration: const Duration(milliseconds: 1500),
                      behavior: SnackBarBehavior.floating,
                      width: 280,
                      backgroundColor: AppTheme.success,
                    ));
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
  List<Widget> items, {
  int badge = 0,
}) {
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
            if (badge > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.danger,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(badge > 99 ? '99+' : '$badge',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700)),
              ),
            ],
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

void _openInNewTab(BuildContext context, String path, Offset pos) {
  final href = html.window.location.href;
  final hashIdx = href.indexOf('#');
  final origin = hashIdx != -1 ? href.substring(0, hashIdx) : href;
  final url = '${origin}#${path}';
  showMenu(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
    color: Colors.white,
    items: [
      PopupMenuItem(
        onTap: () => html.window.open(url, '_blank'),
        child: Row(children: [
          const Icon(Icons.open_in_new, size: 15, color: Colors.grey),
          const SizedBox(width: 10),
          const Text('Open in new tab', style: TextStyle(fontSize: 13)),
        ]),
      ),
    ],
  );
}

Widget _menuItem(BuildContext context, String label, IconData icon, String path, String location, {int badge = 0}) {
  final isActive = location == path;
  return GestureDetector(
    onSecondaryTapDown: (d) => _openInNewTab(context, path, d.globalPosition),
    child: MenuItemButton(
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
      trailingIcon: badge > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.danger,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700)),
            )
          : null,
      onPressed: () => GoRouter.of(context).go(path),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400)),
    ),
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

bool _hasItems(List<Widget> items) => items.any((w) => w is! Divider);

List<Widget> _trimDividers(List<Widget> items) {
  final out = <Widget>[];
  for (final w in items) {
    if (w is Divider && (out.isEmpty || out.last is Divider)) continue;
    out.add(w);
  }
  while (out.isNotEmpty && out.last is Divider) {
    out.removeLast();
  }
  return out;
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
