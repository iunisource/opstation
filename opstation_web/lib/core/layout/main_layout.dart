// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
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

// Whether the customer sales-targets feature is enabled for this org. Gates the
// Intelligence → Performance menu item (and target widgets elsewhere). Mirrors
// the org.customer_targets_enabled flag read by the targets screens.
final customerTargetsEnabledProvider = FutureProvider<bool>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return false;
  final client = Supabase.instance.client;
  try {
    final res = await client
        .from('app_config')
        .select('value')
        .eq('org_id', user.orgId!)
        .eq('key', 'org.customer_targets_enabled')
        .maybeSingle();
    return (res?['value'] as String?) == 'true';
  } catch (_) {
    return false;
  }
});

// Count of assets with maintenance overdue for the current org (nav badge).
final assetsDueCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cutoff = DateTime.now().add(const Duration(days: 14));
    final c =
        '${cutoff.year.toString().padLeft(4, '0')}-${cutoff.month.toString().padLeft(2, '0')}-${cutoff.day.toString().padLeft(2, '0')}';
    final res = await client
        .from('assets')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('is_active', true)
        .not('next_maintenance_due', 'is', null)
        .lte('next_maintenance_due', c);
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

// Count of facility tasks open & overdue for the current org (nav badge).
final facilityDueCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final res = await client
        .from('facility_tasks')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('status', 'open')
        .lt('due_date', today);
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

// Count of purchase orders awaiting approval for the current org (nav badge).
final poPendingApprovalCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client
        .from('app_config')
        .select('value')
        .eq('org_id', user.orgId!)
        .eq('key', 'org.po_approval_required')
        .maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final res = await client
        .from('purchase_orders')
        .select('id')
        .eq('org_id', user.orgId!)
        .filter('approved_at', 'is', null)
        .filter('voided_at', 'is', null)
        .neq('status', 'received')
        .eq('is_locked', true);
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

// ─── MainLayout ───────────────────────────────────────────────────────────────

// ─── Nav layout mode (top bar ↔ sidebar) ───────────────────────

enum NavLayout { top, side }

final navLayoutProvider = StateProvider<NavLayout>((ref) {
  final saved = html.window.localStorage['op_nav_layout'];
  return saved == 'side' ? NavLayout.side : NavLayout.top;
});

void _setNavLayout(WidgetRef ref, NavLayout layout) {
  ref.read(navLayoutProvider.notifier).state = layout;
  html.window.localStorage['op_nav_layout'] = layout == NavLayout.side ? 'side' : 'top';
}

Widget _navLayoutToggle(WidgetRef ref, NavLayout current) {
  final goingSide = current == NavLayout.top;
  return IconButton(
    tooltip: goingSide ? 'Switch to sidebar menu' : 'Switch to top bar menu',
    icon: Icon(goingSide ? Icons.view_sidebar_outlined : Icons.view_day_outlined,
        color: Colors.white70, size: 20),
    onPressed: () => _setNavLayout(ref, goingSide ? NavLayout.side : NavLayout.top),
  );
}

class MainLayout extends ConsumerStatefulWidget {
  final Widget child;
  const MainLayout({super.key, required this.child});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout> {
  bool _fullscreen = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _lastLoc;

  static const double kMobileBreakpoint = 768;

  @override
  void initState() {
    super.initState();
    html.document.addEventListener('fullscreenchange', _onFsChange);
  }

  @override
  void dispose() {
    html.document.removeEventListener('fullscreenchange', _onFsChange);
    super.dispose();
  }

  void _onFsChange(html.Event _) {
    final fs = html.document.fullscreenElement != null;
    if (mounted && fs != _fullscreen) setState(() => _fullscreen = fs);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final user = auth.valueOrNull;

    // In browser full-screen, drop the app chrome (top bar / sidebar) entirely
    // so a wall display (e.g. the Attendance Board) shows only its own content.
    if (_fullscreen) {
      return Scaffold(body: widget.child);
    }

    // ── Mobile: hamburger AppBar + slide-in Drawer (nav as inline expanders) ──
    final width = MediaQuery.of(context).size.width;
    if (width < kMobileBreakpoint) {
      // Close the drawer automatically after navigating to a new route.
      final loc = GoRouterState.of(context).matchedLocation;
      if (_lastLoc != null && _lastLoc != loc) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scaffoldKey.currentState?.closeDrawer());
      }
      _lastLoc = loc;
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.sidebar,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          titleSpacing: 0,
          title: InkWell(
            onTap: () => GoRouter.of(context).go('/dashboard'),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 26, height: 26, alignment: Alignment.center,
                decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(6)),
                child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14))),
              const SizedBox(width: 8),
              const Text('Opstation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            ]),
          ),
          actions: [_userMenu(ref, user, const Offset(0, 8)), const SizedBox(width: 6)],
        ),
        drawer: Drawer(
          backgroundColor: AppTheme.sidebar,
          child: SafeArea(child: _mobileDrawer(user)),
        ),
        body: widget.child,
      );
    }

    final layout = ref.watch(navLayoutProvider);
    if (layout == NavLayout.side) {
      return Scaffold(
        body: Row(children: [
          _SideNav(user: user),
          Expanded(child: widget.child),
        ]),
      );
    }
    return Scaffold(
      body: Column(children: [
        _TopNav(user: user),
        Expanded(child: widget.child),
      ]),
    );
  }

  // Drawer body — reuses the shared nav builder, so there is a single source of
  // truth for routes/permissions across top-bar, sidebar and mobile drawer.
  Widget _mobileDrawer(WebUser? user) {
    final location = GoRouterState.of(context).matchedLocation;
    final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
    final navItems = _buildNavItems(context, ref, user, location);
    final show = _showFn(ref, user);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if ((user?.orgName ?? '').isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
          child: Row(children: [
            const Icon(Icons.apartment_rounded, size: 14, color: Colors.white54),
            const SizedBox(width: 6),
            Expanded(child: Text(user?.orgName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13))),
          ]),
        ),
      const Divider(height: 1, color: Colors.white12),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: navItems),
        ),
      ),
      const Divider(height: 1, color: Colors.white12),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Align(alignment: Alignment.centerLeft, child: _branchSelector(ref, modules)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        child: Row(children: [
          _searchButton(context, user, show),
          const Spacer(),
          _userMenu(ref, user, const Offset(0, 8)),
        ]),
      ),
    ]);
  }
}

// ─── Shared role-based nav builders (single source for both layouts) ───────

bool Function(String) _showFn(WidgetRef ref, WebUser? user) {
  final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
  final access = ref.watch(accessSyncProvider);
  return (String route) {
    if (route == '/erp/onboarding') return true; // onboarding guide: visible to all
    final mod = kRouteToModule[route];
    if (mod != null && !modules.contains(mod)) return false;
    final r = user?.role;
    final isAdminTier2 = r == WebUserRole.admin ||
        r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
    if (isAdminTier2) return true;
    if (access == null) return false;
    return access.canAccessRoute(route);
  };
}

List<Widget> _buildNavItems(BuildContext context, WidgetRef ref, WebUser? user, String location) {
  final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
  final crmOverdue = ref.watch(crmOverdueCountProvider).valueOrNull ?? 0;
  final assetsDue = ref.watch(assetsDueCountProvider).valueOrNull ?? 0;
  final facilityDue = ref.watch(facilityDueCountProvider).valueOrNull ?? 0;
  final poPending = ref.watch(poPendingApprovalCountProvider).valueOrNull ?? 0;
  final targetsOn = ref.watch(customerTargetsEnabledProvider).valueOrNull ?? false;
  final show = _showFn(ref, user);

  final isAdminTier = user?.role == WebUserRole.admin || user?.role == WebUserRole.masterAdmin;
  final isDispatch = user?.role == WebUserRole.dispatchManager;
  final isAccountant = user?.role == WebUserRole.accountant;
  final isErpUser = user?.role == WebUserRole.erpUser;

    // ── ERP Inventory submenu ─────────────────────────────────────────────
    final inventoryItems = <Widget>[
      if (modules.contains('inventory')) ...[
        if (show('/erp/products')) _menuItem(context, 'Products', Icons.inventory_2_outlined, '/erp/products', location),
        if (show('/erp/stock')) _menuItem(context, 'Stock Levels', Icons.stacked_bar_chart_outlined, '/erp/stock', location),
        if (show('/erp/low-stock-report')) _menuItem(context, 'Low Stock Report', Icons.warning_amber_outlined, '/erp/low-stock-report', location),
        if (show('/erp/stock-value-report')) _menuItem(context, 'Stock Value Report', Icons.payments_outlined, '/erp/stock-value-report', location),
        if (show('/erp/stock-balance-report')) _menuItem(context, 'Stock Balance Report', Icons.inventory_outlined, '/erp/stock-balance-report', location),
        if (show('/erp/stock-aging-report')) _menuItem(context, 'Stock Aging Report', Icons.hourglass_bottom_outlined, '/erp/stock-aging-report', location),
        if (show('/erp/product-classifications')) _menuItem(context, 'Product Classifications', Icons.label_outline, '/erp/product-classifications', location),
        if (show('/erp/opening-stock')) _menuItem(context, 'Opening Stock', Icons.open_in_new_outlined, '/erp/opening-stock', location),
        if (show('/erp/stock-transfers')) _menuItem(context, 'Stock Transfers', Icons.swap_horiz_outlined, '/erp/stock-transfers', location),
        if (show('/erp/stock-adjustment')) _menuItem(context, 'Stock Adjustment', Icons.tune_outlined, '/erp/stock-adjustment', location),
        if (show('/erp/inventory-ledger')) _menuItem(context, 'Inventory Ledger', Icons.inventory_2_outlined, '/erp/inventory-ledger', location),
        if (show('/erp/demand-plan')) _menuItem(context, 'Demand Planner', Icons.insights_outlined, '/erp/demand-plan', location),
      ],
    ];

    // ── Per-section item lists ───────────────────────────────────────────
    final purchaseItems = <Widget>[
      if (modules.contains('purchase')) ...[
        if (show('/erp/purchase-dashboard')) _menuItem(context, 'Purchase Dashboard',      Icons.dashboard_outlined,         '/erp/purchase-dashboard',       location),
        if (show('/erp/purchase-report')) _menuItem(context, 'Purchase Report', Icons.summarize_outlined, '/erp/purchase-report', location),
        if (show('/erp/suppliers')) _menuItem(context, 'Suppliers',               Icons.people_outline,            '/erp/suppliers',                location),
        if (show('/erp/purchase')) _menuItem(context, 'Purchase Orders',          Icons.shopping_cart_outlined,     '/erp/purchase',                 location, badge: poPending),
        if (show('/erp/grn')) _menuItem(context, 'Goods Receipt Note (GRN)', Icons.move_to_inbox_outlined,     '/erp/grn',                      location),
        if (show('/erp/purchase-invoices')) _menuItem(context, 'Purchase Invoices',        Icons.receipt_outlined,           '/erp/purchase-invoices',        location),
        _menuDivider(),
        if (show('/erp/purchase-returns')) _menuItem(context, 'Purchase Return Notes',    Icons.assignment_return_outlined, '/erp/purchase-returns',         location),
        if (show('/erp/purchase-return-vouchers')) _menuItem(context, 'Purchase Return Invoices', Icons.description_outlined,       '/erp/purchase-return-vouchers', location),
        _menuDivider(),
        if (show('/erp/supplier-ledger')) _menuItem(context, 'Supplier Ledger', Icons.people_outline, '/erp/supplier-ledger', location),
        if (show('/erp/supplier-aging')) _menuItem(context, 'Supplier Aging', Icons.hourglass_bottom_outlined, '/erp/supplier-aging', location),
      ],
    ];

    final salesItems = <Widget>[
      if (modules.contains('sales')) ...[
        if (show('/erp/sales-dashboard')) _menuItem(context, 'Sales Dashboard',         Icons.dashboard_outlined,         '/erp/sales-dashboard',          location),
        if (show('/customers')) _menuItem(context, 'Customers',             Icons.store_outlined,             '/customers',                 location),
        if (show('/erp/sales')) _menuItem(context, 'Sales Orders',         Icons.receipt_long_outlined,      '/erp/sales',                 location),
        if (show('/erp/field-orders')) _menuItem(context, 'Field Orders',         Icons.tablet_android_outlined,    '/erp/field-orders',          location),
        if (show('/erp/delivery-orders')) _menuItem(context, 'Delivery Orders',       Icons.local_shipping_outlined,    '/erp/delivery-orders',       location),
        if (show('/erp/sales-invoices')) _menuItem(context, 'Sales Invoices',        Icons.receipt_outlined,           '/erp/sales-invoices',        location),
        _menuDivider(),
        if (show('/erp/sales-returns')) _menuItem(context, 'Sales Return Notes',    Icons.assignment_return_outlined, '/erp/sales-returns',         location),
        if (show('/erp/sales-return-invoices')) _menuItem(context, 'Sales Return Invoices', Icons.receipt_long_outlined,      '/erp/sales-return-invoices', location),
        if (show('/erp/sales-report')) _menuItem(context, 'Sales Report',         Icons.assessment_outlined,        '/erp/sales-report',          location),
        _menuDivider(),
        if (show('/erp/customer-ledger')) _menuItem(context, 'Customer Ledger', Icons.store_outlined, '/erp/customer-ledger', location),
        if (show('/erp/customer-aging')) _menuItem(context, 'Customer Aging', Icons.hourglass_bottom_outlined, '/erp/customer-aging', location),
        
      ],
    ];

    final posItems = <Widget>[
      if (modules.contains('pos')) ...[
        if (show('/erp/pos-config')) _menuItem(context, 'Configuration', Icons.tune_outlined, '/erp/pos-config', location),
        if (show('/erp/promoters')) _menuItem(context, 'Promoters', Icons.badge_outlined, '/erp/promoters', location),
        if (show('/erp/promoter-ledger')) _menuItem(context, 'Promoter Ledger', Icons.account_balance_wallet_outlined, '/erp/promoter-ledger', location),
        if (show('/erp/pos')) _menuItem(context, 'POS',         Icons.storefront_outlined, '/erp/pos',         location),
        if (show('/erp/pos-catalog')) _menuItem(context, 'POS Catalog',    Icons.list_alt_outlined,     '/erp/pos-catalog',           location),
        if (show('/erp/pos-customer-history')) _menuItem(context, 'Customer History', Icons.manage_accounts_outlined, '/erp/pos-customer-history', location),
        if (show('/erp/pos-held-bills')) _menuItem(context, 'Bills on Hold',       Icons.pause_circle_outlined,    '/erp/pos-held-bills',          location),
        if (show('/erp/pos-expense-management')) _menuItem(context, 'Expense Management',  Icons.receipt_outlined,          '/erp/pos-expense-management',  location),
      ],
    ];

    // Top-level production items (non-voucher)
    final mfgTopItems = <Widget>[
      if (show('/manufacturing/production-floor')) _menuItem(context, 'Production Floor', Icons.dashboard_outlined, '/manufacturing/production-floor', location),
      if (show('/manufacturing/production-plan')) _menuItem(context, 'Production Material Planner', Icons.account_tree_outlined, '/manufacturing/production-plan', location),
      if (show('/manufacturing/job-card')) _menuItem(context, 'Job Card', Icons.assignment_outlined, '/manufacturing/job-card', location),
      if (show('/manufacturing/qc-checkpoints')) _menuItem(context, 'QC Checkpoints', Icons.fact_check_outlined, '/manufacturing/qc-checkpoints', location),
    ];
    final mfgVoucherItems = <Widget>[
      if (show('/manufacturing/product-assembly')) _menuItem(context, 'Product Assembly (BOM)', Icons.account_tree_outlined, '/manufacturing/product-assembly', location),
      if (show('/manufacturing/production-voucher')) _menuItem(context, 'Production Voucher', Icons.precision_manufacturing_outlined, '/manufacturing/production-voucher', location),
      if (show('/manufacturing/damage-stock-voucher')) _menuItem(context, 'Damage Stock Voucher', Icons.report_gmailerrorred_outlined, '/manufacturing/damage-stock-voucher', location),
      if (show('/manufacturing/production-inverse-voucher')) _menuItem(context, 'Production Inverse Voucher', Icons.undo_outlined, '/manufacturing/production-inverse-voucher', location),
      if (show('/manufacturing/claim-processing-voucher')) _menuItem(context, 'Claim Processing Voucher', Icons.assignment_return_outlined, '/manufacturing/claim-processing-voucher', location),
    ];
    final mfgReportItems = <Widget>[
      if (show('/manufacturing/production-waste-report')) _menuItem(context, 'Production Waste Report', Icons.recycling_outlined, '/manufacturing/production-waste-report', location),
      if (show('/manufacturing/overheads-summary')) _menuItem(context, 'Overheads Summary', Icons.summarize_outlined, '/manufacturing/overheads-summary', location),
    ];
    final manufacturingItems = <Widget>[
      ...mfgTopItems,
      if (mfgVoucherItems.isNotEmpty) _menuLabel('Voucher'),
      ...mfgVoucherItems,
      if (mfgReportItems.isNotEmpty) _menuLabel('Reports'),
      ...mfgReportItems,
    ];

    final hrItems = <Widget>[
      if (show('/hr/employees')) _menuItem(context, 'Employee Directory', Icons.groups_outlined, '/hr/employees', location),
      if (show('/hr/attendance')) _menuItem(context, 'Attendance', Icons.fact_check_outlined, '/hr/attendance', location),
      if (show('/hr/attendance-kiosk')) _menuItem(context, 'Attendance Kiosk', Icons.qr_code_scanner_outlined, '/hr/attendance-kiosk', location),
      if (show('/hr/attendance-board')) _menuItem(context, 'Attendance Board', Icons.grid_view_outlined, '/hr/attendance-board', location),
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
      ...financialItems, ...manufacturingItems, ...hrItems, ...erpAdminItems,
    ];

    List<Widget> splitErpMenus() => [
      if (_hasItems(inventoryItems))
        _navMenu(context, 'Inventory', Icons.inventory_2_outlined, location,
          ['/erp/products', '/erp/stock', '/erp/low-stock-report', '/erp/stock-value-report',
           '/erp/stock-balance-report', '/erp/stock-aging-report',
           '/erp/product-classifications', '/erp/opening-stock', '/erp/stock-transfers', '/erp/stock-adjustment', '/erp/inventory-ledger', '/erp/demand-plan'],
          _trimDividers(inventoryItems)),
      if (_hasItems(purchaseItems))
        _navMenu(context, 'Purchase', Icons.shopping_cart_outlined, location,
          ['/erp/suppliers', '/erp/purchase', '/erp/grn', '/erp/purchase-invoices',
           '/erp/purchase-returns', '/erp/purchase-return-vouchers', '/erp/payment-vouchers', '/erp/purchase-report',
           '/erp/supplier-ledger', '/erp/supplier-aging'],
          _trimDividers(purchaseItems), badge: poPending),
      if (_hasItems(salesItems))
        _navMenu(context, 'Sales', Icons.receipt_long_outlined, location,
          ['/customers', '/erp/sales', '/erp/field-orders', '/erp/delivery-orders', '/erp/sales-invoices',
           '/erp/sales-returns', '/erp/sales-return-invoices', '/erp/sales-report',
           '/erp/customer-ledger', '/erp/customer-aging'],
          _trimDividers(salesItems)),
      if (_hasItems(posItems))
        _navMenu(context, 'POS', Icons.storefront_outlined, location,
          ['/erp/pos', '/erp/pos-catalog', '/erp/pos-config', '/erp/pos-customer-history', '/erp/pos-held-bills', '/erp/pos-expense-management', '/erp/promoters', '/erp/promoter-ledger'], _trimDividers(posItems)),
      _navMenu(context, 'Reports', Icons.summarize_outlined, location,
        ['/reports/margin', '/reports/customer-balance', '/intelligence/report-builder'],
        [_menuItem(context, 'Margin Report', Icons.trending_up, '/reports/margin', location),
         _menuItem(context, 'Customer Balance Report', Icons.account_balance_wallet_outlined, '/reports/customer-balance', location),
         _menuItem(context, 'Report Builder', Icons.table_chart_outlined, '/intelligence/report-builder', location)]),
      if (_hasItems(manufacturingItems))
        _navMenu(context, 'Manufacturing', Icons.precision_manufacturing_outlined, location,
          ['/manufacturing/production-floor', '/manufacturing/production-plan', '/manufacturing/product-assembly', '/manufacturing/production-voucher', '/manufacturing/job-card', '/manufacturing/qc-checkpoints',
           '/manufacturing/production-inverse-voucher', '/manufacturing/damage-stock-voucher',
           '/manufacturing/claim-processing-voucher', '/manufacturing/production-waste-report', '/manufacturing/overheads-summary'],
          _trimDividers(manufacturingItems)),
      if (_hasItems(financialItems))
        _navMenu(context, 'Financials', Icons.account_balance_outlined, location,
          ['/erp/chart-of-accounts', '/erp/payment-vouchers', '/erp/receipt-vouchers', '/erp/pdc-voucher'],
          _trimDividers(financialItems)),
      if (_hasItems(hrItems))
        _navMenu(context, 'HR', Icons.badge_outlined, location,
          ['/hr/employees', '/hr/attendance', '/hr/attendance-kiosk', '/hr/attendance-board', '/hr/leave'], _trimDividers(hrItems)),
      _navMenu(context, 'ERP', Icons.manage_accounts_outlined, location,
        ['/erp/onboarding', '/erp/branches', '/erp/users', '/erp/admin-settings', '/erp/audit-log'],
        [
          _menuItem(context, 'Onboarding Guide', Icons.menu_book_outlined, '/erp/onboarding', location),
          if (show('/erp/branches')) _menuItem(context, 'Branches', Icons.store_outlined, '/erp/branches', location),
          if (_hasItems(erpAdminItems)) _menuDivider(),
          ..._trimDividers(erpAdminItems),
        ]),
    ];

  return <Widget>[
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
            ['/dashboard', '/team', '/customers', '/routes', '/deliveries', '/live-map', '/reports', '/compliance', '/operations/files', '/operations/notifications', '/operations/retailers', '/settings'],
            [
              _menuItem(context, 'Dashboard', Icons.dashboard_outlined, '/dashboard', location),
              _menuItem(context, 'Team', Icons.people_outline, '/team', location),
              _menuItem(context, 'Customers', Icons.store_outlined, '/customers', location),
              _menuItem(context, 'Routes', Icons.route_outlined, '/routes', location),
              _menuItem(context, 'Deliveries', Icons.local_shipping_outlined, '/deliveries', location),
              _menuItem(context, 'Live Map', Icons.map_outlined, '/live-map', location),
              _menuItem(context, 'Reports', Icons.bar_chart_outlined, '/reports', location),
              _menuItem(context, 'Compliance', Icons.rule, '/compliance', location),
              _menuItem(context, 'Files', Icons.folder_shared_outlined, '/operations/files', location),
              _menuItem(context, 'Notifications', Icons.campaign_outlined, '/operations/notifications', location),
              _menuItem(context, 'Retailers', Icons.storefront_outlined, '/operations/retailers', location),
              if (user?.role == WebUserRole.masterAdmin)
                _menuItem(context, 'App Settings', Icons.settings_outlined, '/settings', location),
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
            ['/products', '/competitor-categories', '/intelligence/placement', '/intelligence/competitors',
             if (targetsOn) '/intelligence/performance'],
            [
              _menuItem(context, 'Products', Icons.inventory_2_outlined, '/products', location),
              _menuItem(context, 'Competitor Categories', Icons.category_outlined, '/competitor-categories', location),
              _menuItem(context, 'Placement Audit', Icons.checklist_outlined, '/intelligence/placement', location),
              _menuItem(context, 'Competitor Spotting', Icons.flag_outlined, '/intelligence/competitors', location),
              if (targetsOn)
                _menuItem(context, 'Performance', Icons.leaderboard_outlined, '/intelligence/performance', location),
            ],
          ),
          if (show('/assets') || show('/facility'))
            _navMenu(context, 'Management', Icons.domain_outlined, location,
              ['/assets', '/facility'],
              [
                if (show('/assets'))
                  _menuItem(context, 'Assets', Icons.chair_outlined, '/assets', location, badge: assetsDue),
                if (show('/facility'))
                  _menuItem(context, 'Facility', Icons.cleaning_services_outlined, '/facility', location, badge: facilityDue),
              ],
              badge: assetsDue + facilityDue,
            ),
          ...splitErpMenus(),
        ],

        if (isErpUser && erpMenuItems.isNotEmpty)
          ...splitErpMenus(),
  ];
}

// ─── Shared chrome (logo/search/branch/user reused by both layouts) ───────

Widget _searchButton(BuildContext context, WebUser? user, bool Function(String) show) {
  return         IconButton(
          tooltip: 'Search products, customers, suppliers, vouchers, entries',
          icon: const Icon(Icons.search, color: Colors.white70, size: 20),
          onPressed: () {
            final oid = user?.orgId;
            if (oid != null) showGlobalSearch(context, orgId: oid, can: show);
          },
        );
}

Widget _branchSelector(WidgetRef ref, Set<String> modules) {
  return         Builder(builder: (ctx) {
          final hasErp = modules.any((m) => ['inventory', 'purchase', 'sales', 'pos'].contains(m));
          if (!hasErp) return const SizedBox.shrink();
          final branches = ref.watch(userBranchesProvider).valueOrNull ?? [];
          final selected = ref.watch(selectedBranchProvider);
          if (branches.isEmpty) return const SizedBox.shrink();
          if (selected == null && branches.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ref.read(selectedBranchProvider) != null) return;
              final savedId = html.window.localStorage['op_selected_branch_id'];
              Map<String, dynamic>? restored;
              if (savedId != null) {
                for (final b in branches) {
                  if (b['id'] == savedId) { restored = Map<String, dynamic>.from(b); break; }
                }
              }
              ref.read(selectedBranchProvider.notifier).state = restored ?? branches.first;
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
                dropdownColor: AppTheme.sidebarPanel,
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
                  html.window.localStorage['op_selected_branch_id'] = id;
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
        });
}

Widget _userMenu(WidgetRef ref, WebUser? user, Offset offset) {
  return         PopupMenuButton<String>(
          offset: offset,
          color: AppTheme.sidebarPanel,
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
        );
}

// ─── Top Navigation Bar ────────────────────────────────────────

class _TopNav extends ConsumerWidget {
  final WebUser? user;
  const _TopNav({this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
    final navItems = _buildNavItems(context, ref, user, location);
    final show = _showFn(ref, user);

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
          child: Tooltip(
            message: 'Go to Dashboard',
            child: InkWell(
              onTap: () => GoRouter.of(context).go('/dashboard'),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
            ),
          ),
        ),
        if ((user?.orgName ?? '').isNotEmpty) ...[
          Container(width: 1, height: 28, color: Colors.white12),
          const SizedBox(width: 10),
          const Icon(Icons.apartment_rounded, size: 15, color: Colors.white54),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(user?.orgName ?? '',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          const SizedBox(width: 6),
        ],
        Container(width: 1, height: 28, color: Colors.white12),
        const SizedBox(width: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: navItems),
          ),
        ),
        _searchButton(context, user, show),
        _navLayoutToggle(ref, NavLayout.top),
        const SizedBox(width: 4),
        _branchSelector(ref, modules),
        Container(width: 1, height: 28, color: Colors.white12),
        _userMenu(ref, user, const Offset(0, 52)),
      ]),
    );
  }
}

// ─── Side Navigation Bar ──────────────────────────────────────

class _SideNav extends ConsumerWidget {
  final WebUser? user;
  const _SideNav({this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
    final navItems = _buildNavItems(context, ref, user, location);
    final show = _showFn(ref, user);

    return Container(
      width: 232,
      decoration: const BoxDecoration(
        color: AppTheme.sidebar,
        border: Border(right: BorderSide(color: Colors.white12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 10),
          child: Row(children: [
            Expanded(
              child: Tooltip(
                message: 'Go to Dashboard',
                child: InkWell(
                  onTap: () => GoRouter.of(context).go('/dashboard'),
                  borderRadius: BorderRadius.circular(6),
                  child: Row(children: [
                    Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(6)),
                      alignment: Alignment.center,
                      child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                    ),
                    const SizedBox(width: 8),
                    const Flexible(child: Text('Opstation', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14))),
                  ]),
                ),
              ),
            ),
            _navLayoutToggle(ref, NavLayout.side),
          ]),
        ),
        if ((user?.orgName ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 10),
            child: Row(children: [
              const Icon(Icons.apartment_rounded, size: 14, color: Colors.white54),
              const SizedBox(width: 6),
              Expanded(
                child: Text(user?.orgName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
              ),
            ]),
          ),
        const Divider(height: 1, color: Colors.white12),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: navItems),
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(children: [
            _searchButton(context, user, show),
            const Spacer(),
            _userMenu(ref, user, const Offset(0, 8)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Align(alignment: Alignment.centerLeft, child: _branchSelector(ref, modules)),
        ),
      ]),
    );
  }
}


// ─── Nav helpers ──────────────────────────────────────────────────────────────

Widget _navButton(BuildContext context, String label, IconData icon, String path, String location, {int badge = 0}) {
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
          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
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
                    color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
          ),
        ],
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
  // On phones the nav lives in a Drawer, where a hover/click popup is poor UX.
  // Render an inline expand/collapse section instead.
  if (MediaQuery.of(context).size.width < _MainLayoutState.kMobileBreakpoint) {
    return _DrawerNavMenu(
      label: label, icon: icon, location: location,
      activePaths: activePaths, items: items, badge: badge,
    );
  }
  return _HoverNavMenu(
    label: label,
    icon: icon,
    location: location,
    activePaths: activePaths,
    items: items,
    badge: badge,
  );
}

/// Inline expand/collapse nav section used inside the mobile Drawer. Expands by
/// default when one of its routes is active.
class _DrawerNavMenu extends StatefulWidget {
  final String label;
  final IconData icon;
  final String location;
  final List<String> activePaths;
  final List<Widget> items;
  final int badge;
  const _DrawerNavMenu({
    required this.label,
    required this.icon,
    required this.location,
    required this.activePaths,
    required this.items,
    this.badge = 0,
  });
  @override
  State<_DrawerNavMenu> createState() => _DrawerNavMenuState();
}

class _DrawerNavMenuState extends State<_DrawerNavMenu> {
  late bool _open;
  @override
  void initState() {
    super.initState();
    _open = widget.activePaths.any((p) => widget.location.startsWith(p));
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.activePaths.any((p) => widget.location.startsWith(p));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: isActive
              ? BoxDecoration(color: AppTheme.primary.withOpacity(0.18), borderRadius: BorderRadius.circular(6))
              : null,
          child: Row(children: [
            Icon(widget.icon, size: 16, color: isActive ? Colors.white : AppTheme.sidebarText),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.label, style: TextStyle(
              color: isActive ? Colors.white : AppTheme.sidebarText,
              fontSize: 14, fontWeight: FontWeight.w600))),
            if (widget.badge > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(8)),
                child: Text('${widget.badge}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
            ],
            Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: AppTheme.sidebarText),
          ]),
        ),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.only(left: 14, bottom: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.items),
        ),
    ]);
  }
}

/// Top-nav dropdown that opens on hover and closes shortly after the pointer
/// leaves both the trigger and the panel. Click still toggles it.
class _HoverNavMenu extends StatefulWidget {
  final String label;
  final IconData icon;
  final String location;
  final List<String> activePaths;
  final List<Widget> items;
  final int badge;
  const _HoverNavMenu({
    required this.label,
    required this.icon,
    required this.location,
    required this.activePaths,
    required this.items,
    this.badge = 0,
  });
  @override
  State<_HoverNavMenu> createState() => _HoverNavMenuState();
}

class _HoverNavMenuState extends State<_HoverNavMenu> {
  final MenuController _controller = MenuController();
  Timer? _closeTimer;

  void _openNow() {
    _closeTimer?.cancel();
    if (!_controller.isOpen) _controller.open();
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted && _controller.isOpen) _controller.close();
    });
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    final isActive = widget.activePaths.any((p) => location.startsWith(p));
    return MenuAnchor(
      controller: _controller,
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(AppTheme.sidebarPanel),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: WidgetStatePropertyAll(Colors.black54),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Colors.white12),
        )),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      menuChildren: [
        // Keep the menu open while the pointer is over the panel.
        MouseRegion(
          onEnter: (_) => _closeTimer?.cancel(),
          onExit: (_) => _scheduleClose(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.items,
          ),
        ),
      ],
      builder: (ctx, controller, _) {
        return MouseRegion(
          onEnter: (_) => _openNow(),
          onExit: (_) => _scheduleClose(),
          child: InkWell(
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
                Icon(widget.icon, size: 14, color: isActive ? Colors.white : AppTheme.sidebarText),
                const SizedBox(width: 5),
                Text(widget.label, style: TextStyle(
                  color: isActive ? Colors.white : AppTheme.sidebarText,
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                )),
                if (widget.badge > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppTheme.danger,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(widget.badge > 99 ? '99+' : '${widget.badge}',
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
          ),
        );
      },
    );
  }
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
      backgroundColor: const WidgetStatePropertyAll(AppTheme.sidebarPanel),
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

