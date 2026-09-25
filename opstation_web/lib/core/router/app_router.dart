import 'dart:html' as html;
import '../../features/inventory/erp_stock_adjustment_screen.dart' deferred as _s001;
import '../../features/erp/presentation/erp_trial_balance_screen.dart' deferred as _s002;
import '../../features/erp/presentation/erp_journal_voucher_screen.dart' deferred as _s003;
import '../../features/erp/presentation/erp_cash_book_screen.dart' deferred as _s004;
import '../../features/erp/presentation/erp_opening_journal_screen.dart' deferred as _s005;
import '../../features/erp/presentation/erp_account_activity_screen.dart' deferred as _s006;
import '../../features/erp/presentation/erp_profit_loss_screen.dart' deferred as _s007;
import '../../features/erp/presentation/erp_balance_sheet_screen.dart' deferred as _s008;
import '../../features/erp/presentation/erp_onboarding_screen.dart' deferred as _s009;
import '../../features/erp/presentation/erp_product_assembly_screen.dart' deferred as _s010;
import '../../features/erp/presentation/erp_production_voucher_screen.dart' deferred as _s011;
import '../../features/erp/presentation/erp_production_inverse_voucher_screen.dart' deferred as _s012;
import '../../features/erp/presentation/erp_damage_stock_voucher_screen.dart' deferred as _s013;
import '../../features/erp/presentation/erp_claim_processing_voucher_screen.dart' deferred as _s014;
import '../../features/erp/presentation/erp_production_waste_report_screen.dart' deferred as _s015;
import '../../features/erp/presentation/erp_overheads_summary_screen.dart' deferred as _s016;
import '../../features/erp/presentation/erp_job_card_screen.dart' deferred as _s017;
import '../../features/erp/presentation/erp_qc_checkpoints_screen.dart' deferred as _s018;
import '../../features/erp/presentation/erp_qc_station_screen.dart' deferred as _s019;
import '../../features/erp/presentation/erp_job_kiosk_screen.dart' deferred as _s020;
import '../../features/erp/presentation/erp_production_floor_screen.dart' deferred as _s021;
import '../../features/erp/presentation/erp_production_plan_screen.dart' deferred as _s022;
import '../../features/erp/presentation/erp_report_builder_screen.dart' deferred as _s023;
import '../../features/erp/presentation/reports_center_screen.dart' deferred as _s024;
import '../../features/erp/presentation/erp_margin_report_screen.dart' deferred as _s025;
import '../../features/erp/presentation/erp_customer_balance_report_screen.dart' deferred as _s026;
import '../../features/erp/presentation/erp_supplier_balance_report_screen.dart' deferred as _s027;
import '../../features/erp/presentation/erp_skipped_receipts_report_screen.dart' deferred as _s028;
import '../../features/erp/presentation/erp_super_summary_screen.dart' deferred as _s029;
import '../../features/hr/presentation/hr_employees_screen.dart' deferred as _s030;
import '../../features/hr/presentation/hr_employee_attendance_screen.dart' deferred as _s031;
import '../../features/hr/presentation/hr_attendance_review_screen.dart' deferred as _s032;
import '../../features/hr/presentation/hr_payroll_screen.dart' deferred as _s033;
import '../../features/hr/presentation/hr_attendance_board_screen.dart' deferred as _s034;
import '../../features/hr/presentation/hr_attendance_kiosk_screen.dart' deferred as _s035;
import '../../features/hr/presentation/hr_attendance_screen.dart' deferred as _s036;
import '../../features/hr/presentation/hr_leave_screen.dart' deferred as _s037;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:animations/animations.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/auth/presentation/login_screen.dart' deferred as _s038;
import '../../features/auth/presentation/signup_wizard_screen.dart' deferred as _s039;
import '../../features/auth/presentation/change_password_screen.dart' deferred as _s040;
import '../../features/dashboard/presentation/dashboard_screen.dart' deferred as _s041;
import '../../features/team/presentation/team_screen.dart' deferred as _s042;
import '../../features/customers/presentation/customers_screen.dart' deferred as _s043;
import '../../features/customers/presentation/follow_ups_screen.dart' deferred as _s044;
import '../../features/customers/presentation/crm_pipeline_screen.dart' deferred as _s045;
import '../../features/customers/presentation/erp_tasks_screen.dart' deferred as _s046;
import '../../features/customers/presentation/erp_supplier_360_screen.dart' deferred as _s047;
import '../../features/products/presentation/products_screen.dart' deferred as _s048;
import '../../features/competitor_categories/presentation/competitor_categories_screen.dart' deferred as _s049;
import '../../features/competitor_categories/presentation/competitor_brand_aliases_screen.dart' deferred as _s050;
import '../../features/intelligence/presentation/intelligence_placement_screen.dart' deferred as _s051;
import '../../features/intelligence/presentation/intelligence_dashboard_screen.dart' deferred as _s052;
import '../../features/intelligence/presentation/intelligence_competitors_screen.dart' deferred as _s053;
import '../../features/intelligence/presentation/intelligence_performance_screen.dart' deferred as _s054;
import '../../features/routes/presentation/routes_screen.dart' deferred as _s055;
import '../../features/customers/presentation/bulk_import_customers_screen.dart' deferred as _s056;
import '../../features/routes/presentation/bulk_import_routes_screen.dart' deferred as _s057;
import '../../features/reports/presentation/reports_screen.dart' deferred as _s058;
import '../../features/reports/presentation/combined_trip_summary_screen.dart' deferred as _s140;
import '../../features/erp/presentation/erp_payment_advice_screen.dart' deferred as _s141;
import '../../features/deliveries/presentation/deliveries_screen.dart' deferred as _s059;
import '../../features/deliveries/presentation/delivery_detail_screen.dart' deferred as _s060;
import '../../features/dispatch_orders/presentation/dispatch_orders_screen.dart' deferred as _s061;
import '../../features/orders/presentation/orders_screen.dart' deferred as _s062;
import '../../features/settings/presentation/settings_screen.dart' deferred as _s063;
import '../../features/superadmin/presentation/orgs_screen.dart' deferred as _s064;
import '../../features/superadmin/presentation/subscriptions_screen.dart' deferred as _s065;
import '../../features/settings/presentation/org_access_screen.dart' deferred as _s066;
import '../../features/billing/presentation/billing_screen.dart' deferred as _s067;
import '../../features/billing/presentation/subscription_expired_screen.dart' deferred as _s068;
import '../../features/live_map/presentation/live_map_screen.dart' deferred as _s069;
import '../../features/compliance/presentation/compliance_screen.dart' deferred as _s070;
import '../../features/operations/presentation/retailer_files_screen.dart' deferred as _s071;
import '../../features/operations/presentation/notifications_composer_screen.dart' deferred as _s072;
import '../../features/operations/presentation/retailers_admin_screen.dart' deferred as _s073;
import '../../features/assets/presentation/erp_assets_screen.dart' deferred as _s074;
import '../../features/facility/presentation/erp_facility_screen.dart' deferred as _s075;
import '../layout/main_layout.dart';
import '../../features/auth/retailer_auth_controller.dart';
import '../../features/auth/presentation/retailer_login_screen.dart' deferred as _s076;
import '../../features/retailer/presentation/retailer_portal_screen.dart' deferred as _s077;
import '../../features/erp/presentation/floor_scan_screen.dart' deferred as _s078;
import '../permissions/access_control.dart';
import '../permissions/permission_registry.dart';
import '../../features/erp/presentation/erp_placeholder_screen.dart' deferred as _s079;
import '../../features/erp/presentation/erp_payment_voucher_screen.dart' deferred as _s080;
import '../../features/erp/presentation/erp_products_screen.dart' deferred as _s081;
import '../../features/erp/presentation/erp_low_stock_report_screen.dart' deferred as _s082;
import '../../features/erp/presentation/erp_stock_value_report_screen.dart' deferred as _s083;
import '../../features/erp/presentation/erp_stock_balance_report_screen.dart' deferred as _s084;
import '../../features/erp/presentation/erp_inventory_integrity_screen.dart' deferred as _s085;
import '../../features/erp/presentation/erp_stock_aging_report_screen.dart' deferred as _s086;
import '../../features/erp/presentation/erp_branches_screen.dart' deferred as _s087;
import '../../features/erp/presentation/erp_uoms_screen.dart' deferred as _s088;
import '../../features/erp/presentation/erp_stock_screen.dart' deferred as _s089;
import '../../features/erp/presentation/erp_po_screen.dart' deferred as _s090;
import '../../features/erp/presentation/erp_grn_screen.dart' deferred as _s091;
import '../../features/erp/presentation/erp_pi_screen.dart' deferred as _s092;
import '../../features/erp/presentation/erp_sales_screen.dart' deferred as _s093;
import '../../features/erp/presentation/erp_field_orders_screen.dart' deferred as _s094;
import '../../features/erp/presentation/erp_retailer_orders_screen.dart' deferred as _s095;
import '../../features/erp/presentation/erp_sales_report_screen.dart' deferred as _s096;
import '../../features/erp/presentation/erp_sales_return_report_screen.dart' deferred as _s097;
import '../../features/erp/presentation/erp_flow_dashboard_screen.dart' deferred as _s098;
import '../../features/erp/presentation/erp_pos_screen.dart' deferred as _s099;
import '../../features/erp/presentation/erp_promoters_screen.dart' deferred as _s100;
import '../../features/erp/presentation/erp_promoter_ledger_screen.dart' deferred as _s101;
import '../../features/erp/presentation/erp_chart_of_accounts_screen.dart' deferred as _s102;
import '../../features/erp/presentation/erp_suppliers_screen.dart' deferred as _s103;
import '../../features/erp/presentation/erp_purchase_report_screen.dart' deferred as _s104;
import '../../features/erp/presentation/erp_purchase_variance_screen.dart' deferred as _s105;
import '../../features/erp/presentation/erp_product_classifications_screen.dart' deferred as _s106;
import '../../features/erp/presentation/erp_users_screen.dart' deferred as _s107;
import '../../features/erp/presentation/erp_admin_settings_screen.dart' deferred as _s108;
import '../../features/erp/presentation/erp_mcp_connector_screen.dart' deferred as _s109;
import '../../features/erp/presentation/erp_pdc_voucher_screen.dart' deferred as _s110;
import '../../features/erp/presentation/erp_home_screen.dart' deferred as _s111;
import '../../features/erp/presentation/erp_opening_stock_screen.dart' deferred as _s112;
import '../../features/erp/presentation/erp_stock_transfers_screen.dart' deferred as _s113;
import '../../features/erp/presentation/erp_processor_tracker_screen.dart' deferred as _s114;
import '../../features/erp/presentation/erp_processor_jobwork_screen.dart' deferred as _s115;
import '../../features/erp/presentation/erp_payment_vouchers_screen.dart' deferred as _s116;
import '../../features/erp/presentation/erp_receipt_vouchers_screen.dart' deferred as _s117;
import '../../features/erp/presentation/erp_supplier_ledger_screen.dart' deferred as _s118;
import '../../features/erp/presentation/erp_customer_ledger_screen.dart' deferred as _s119;
import '../../features/erp/presentation/erp_inventory_ledger_screen.dart' deferred as _s120;
import '../../features/erp/presentation/erp_fg_without_bom_screen.dart' deferred as _s121;
import '../../features/erp/presentation/erp_price_list_screen.dart' deferred as _s122;
import '../../features/erp/presentation/erp_quotation_screen.dart' deferred as _s123;
import '../../features/erp/presentation/erp_schemes_screen.dart' deferred as _s124;
import '../../features/erp/presentation/erp_dispatch_summary_screen.dart' deferred as _s125;
import '../../features/erp/presentation/erp_schemes_report_screen.dart' deferred as _s126;
import '../../features/erp/presentation/erp_demand_plan_screen.dart' deferred as _s127;
import '../../features/erp/presentation/erp_pos_catalog_screen.dart' deferred as _s128;
import '../../features/erp/presentation/erp_pos_config_screen.dart' deferred as _s129;
import '../../features/erp/presentation/erp_pos_customer_history_screen.dart' deferred as _s130;
import '../../features/erp/presentation/erp_pos_held_bills_screen.dart' deferred as _s131;
import '../../features/erp/presentation/erp_pos_expense_management_screen.dart' deferred as _s132;
import '../../features/erp/presentation/erp_customer_aging_screen.dart' deferred as _s133;
import '../../features/erp/presentation/erp_audit_log_screen.dart' deferred as _s134;
import '../../features/erp/presentation/erp_supplier_aging_screen.dart' deferred as _s135;
import '../../features/erp/presentation/erp_sales_returns_screen.dart' deferred as _s136;
import '../../features/erp/presentation/erp_purchase_returns_screen.dart' deferred as _s137;
import '../../features/erp/presentation/erp_sales_return_invoices_screen.dart' deferred as _s138;
import '../../features/erp/presentation/erp_purchase_return_vouchers_screen.dart' deferred as _s139;

class AuthNotifier extends ChangeNotifier {
  AuthNotifier(this._ref) {
    _ref.listen(authControllerProvider, (_, __) => notifyListeners());
    _ref.listen(accessProvider, (_, __) => notifyListeners());
    _ref.listen(retailerAuthControllerProvider, (_, __) => notifyListeners());
  }
  final Ref _ref;
}

final authNotifierProvider = Provider<AuthNotifier>((ref) {
  return AuthNotifier(ref);
});

final webRouterProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(authNotifierProvider);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: notifier,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final rAuth = ref.read(retailerAuthControllerProvider);
      if (auth.isLoading || rAuth.isLoading) return null;

      final loc = state.matchedLocation;

      // Public job-card QR page (/f/<token>) — a factory worker scans the printed
      // job order and lands here with NO login. Always allow it through, whatever
      // the auth state, so it never bounces to /login.
      if (loc.startsWith('/f/')) return null;

      // Public attendance kiosk — a bookmarked tablet/PC opens this with no
      // login; the punch RPC resolves the employee's org itself.
      if (loc == '/kiosk') return null;

      final retailer = rAuth.valueOrNull;
      final inRetailerArea = loc == '/r' || loc.startsWith('/r/');

      // Retailer portal is a separate world from the staff panel.
      if (retailer != null) {
        if (!inRetailerArea || loc == '/r/login') return '/r';
        return null;
      }
      if (inRetailerArea) {
        return loc == '/r/login' ? null : '/r/login';
      }

      final user = auth.valueOrNull;
      final loggedIn = user != null;
      final onLogin = loc == '/login' || loc == '/signup';
      if (!loggedIn && !onLogin) return '/login';
      if (loggedIn) {
        final role = user.role;
        final access = ref.read(accessSyncProvider);
        String home() {
          if (role == WebUserRole.superAdmin) return '/orgs';
          if (role == WebUserRole.dispatchManager) return '/deliveries';
          if (role == WebUserRole.accountant) return '/orders';
          if (role == WebUserRole.erpUser) return '/erp/home';
          return '/dashboard';
        }
        // Forced password change (temporary password) blocks everything else.
        if (user.mustChangePassword) {
          return loc == '/change-password' ? null : '/change-password';
        }
        if (loc == '/change-password') return home();
        // Lapsed trial / subscription — admins are walled here until they renew.
        if (user.subscriptionExpired) {
          return loc == '/subscription-expired' ? null : '/subscription-expired';
        }
        if (loc == '/subscription-expired') return home();
        bool allowed() {
          if (role == WebUserRole.superAdmin) {
            return loc == '/orgs' || loc == '/subscriptions' || loc == '/account-linking';
          }
          if (role == WebUserRole.dispatchManager) {
            return loc == '/deliveries' ||
                loc == '/dispatch-orders' ||
                loc.startsWith('/deliveries/');
          }
          if (role == WebUserRole.accountant) {
            return loc == '/orders' || loc.startsWith('/orders/');
          }
          if (role == WebUserRole.erpUser) {
            final inErp = loc.startsWith('/erp/') ||
                loc.startsWith('/financials/') ||
                loc.startsWith('/manufacturing/') ||
                loc.startsWith('/reports/') ||
                loc.startsWith('/hr/');
            // CRM screens are permission-scoped (registry-gated), not blocked
            // by the ERP path prefix. Let them through to the permission check.
            final permScopedCrm = loc.startsWith('/crm/');
            // Customers (the ERP customer master) is now a Sales sub-permission
            // (registry key doc.customers.*). It lives at /customers (no /erp/
            // prefix), so let it through to the permission check too.
            final permScopedCustomers = loc == '/customers';
            // Report Builder lives under /intelligence/ (the surveyor area) but
            // is a granted report; allow just this exact route, not the whole
            // /intelligence/ prefix.
            final permScopedReportBuilder = loc == '/intelligence/report-builder';
            // Logistics (Deliveries + Dispatch Orders) is registry-gated and
            // lives outside the /erp/ prefix — let it through to the check.
            final permScopedLogistics = loc == '/deliveries' ||
                loc.startsWith('/deliveries/') ||
                loc == '/dispatch-orders';
            if (!inErp && !permScopedCrm && !permScopedCustomers && !permScopedReportBuilder && !permScopedLogistics) return false;
            if (loc == '/erp/admin-settings') return false; // admin-tier only
            if (loc == '/erp/ai-connector') return false; // admin-tier only
            // Always-available to every ERP user regardless of grants: their
            // landing home, the onboarding guide, and the no-access page (so a
            // denied route redirects here without looping).
            if (loc == '/erp/no-access' ||
                loc == '/erp/home' ||
                loc == '/erp/onboarding') return true;
            if (access == null) return true;
            // A delivery detail page (/deliveries/<id>) is covered by the
            // Deliveries grant rather than needing its own registry entry.
            final permLoc = loc.startsWith('/deliveries/') ? '/deliveries' : loc;
            final it = kRouteToPerm[permLoc];
            // Unregistered ERP-area route => no access. Was `return true`, the
            // fail-open leak that let one grant expose whole unrelated menus.
            if (it == null) return false;
            // Branch-scoped: a route is only reachable if granted at the
            // ACTIVE branch (or globally). Null branch (still restoring after
            // refresh) falls back to any-branch reachability.
            final branchId =
                ref.read(selectedBranchProvider)?['id'] as String?;
            return access.canAccessRouteAt(permLoc, branchId);
          }
          // admin / masterAdmin — everything except super admin's /orgs
          return loc != '/orgs';
        }
        if (onLogin) return home();
        // Processor tracker + job-work are Manufacturing-module features — hold
        // them behind that module for every role (admins included).
        if (loc == '/erp/processor-tracker' || loc == '/erp/processor-jobwork') {
          final mods = ref.read(orgModulesProvider).valueOrNull ?? const <String>{};
          if (!mods.contains('production')) return home();
        }
        if (!allowed()) return home();
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, __) => _deferred(_s038.loadLibrary(), () => _s038.LoginScreen()),
      ),
      GoRoute(
        path: '/signup',
        builder: (_, __) => _deferred(_s039.loadLibrary(), () => _s039.SignupWizardScreen()),
      ),
      GoRoute(
        path: '/change-password',
        builder: (_, __) => _deferred(_s040.loadLibrary(), () => _s040.ChangePasswordScreen()),
      ),
      GoRoute(
        path: '/subscription-expired',
        builder: (_, __) => _deferred(_s068.loadLibrary(), () => _s068.SubscriptionExpiredScreen()),
      ),
      GoRoute(
        path: '/f/:token',
        builder: (_, state) => _deferred(_s078.loadLibrary(), () => _s078.FloorScanScreen(token: state.pathParameters['token'] ?? '')),
      ),
      // Public attendance kiosk — bookmarkable, no login. Works for every org:
      // the punched employee's own record supplies the org.
      GoRoute(
        path: '/kiosk',
        builder: (_, __) => _deferred(_s035.loadLibrary(), () => _s035.HrAttendanceKioskScreen()),
      ),
      GoRoute(
        path: '/r/login',
        builder: (_, __) => _deferred(_s076.loadLibrary(), () => _s076.RetailerLoginScreen()),
      ),
      GoRoute(
        path: '/r',
        builder: (_, __) => _deferred(_s077.loadLibrary(), () => _s077.RetailerPortalScreen()),
      ),
      ShellRoute(
        builder: (context, state, child) => MainLayout(
          child: PageTransitionSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (w, primary, secondary) => FadeThroughTransition(
              animation: primary,
              secondaryAnimation: secondary,
              child: w,
            ),
            child: KeyedSubtree(key: ValueKey(state.uri.path), child: child),
          ),
        ),
        routes: [
          GoRoute(path: '/dashboard', builder: (_, __) => _deferred(_s041.loadLibrary(), () => _s041.DashboardScreen())),
          GoRoute(path: '/team', builder: (_, __) => _deferred(_s042.loadLibrary(), () => _s042.TeamScreen())),
          GoRoute(path: '/customers', builder: (_, state) => _deferred(_s043.loadLibrary(), () => _s043.CustomersScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/crm/customers', builder: (_, __) => _deferred(_s043.loadLibrary(), () => _s043.CustomersScreen(crmMode: true))),
          GoRoute(path: '/customers/import', builder: (_, __) => _deferred(_s056.loadLibrary(), () => _s056.BulkImportCustomersScreen())),
          GoRoute(path: '/crm/follow-ups', builder: (_, __) => _deferred(_s044.loadLibrary(), () => _s044.FollowUpsScreen())),
          GoRoute(path: '/crm/pipeline', builder: (_, __) => _deferred(_s045.loadLibrary(), () => _s045.CrmPipelineScreen())),
          GoRoute(path: '/crm/tasks', builder: (_, __) => _deferred(_s046.loadLibrary(), () => _s046.ErpTasksScreen())),
          GoRoute(path: '/crm/supplier-profile', builder: (_, __) => _deferred(_s047.loadLibrary(), () => _s047.ErpSupplier360Screen())),
          GoRoute(path: '/products', builder: (_, __) => _deferred(_s048.loadLibrary(), () => _s048.ProductsScreen())),
          GoRoute(path: '/competitor-categories', builder: (_, __) => _deferred(_s049.loadLibrary(), () => _s049.CompetitorCategoriesScreen())),
          GoRoute(path: '/competitor-brand-aliases', builder: (_, __) => _deferred(_s050.loadLibrary(), () => _s050.CompetitorBrandAliasesScreen())),
          GoRoute(path: '/intelligence/dashboard', builder: (_, __) => _deferred(_s052.loadLibrary(), () => _s052.IntelligenceDashboardScreen())),
          GoRoute(path: '/intelligence/placement', builder: (_, __) => _deferred(_s051.loadLibrary(), () => _s051.IntelligencePlacementScreen())),
          GoRoute(path: '/intelligence/competitors', builder: (_, __) => _deferred(_s053.loadLibrary(), () => _s053.IntelligenceCompetitorsScreen())),
          GoRoute(path: '/intelligence/performance', builder: (_, __) => _deferred(_s054.loadLibrary(), () => _s054.IntelligencePerformanceScreen())),
          GoRoute(path: '/routes', builder: (_, __) => _deferred(_s055.loadLibrary(), () => _s055.RoutesScreen())),
          GoRoute(path: '/routes/import', builder: (_, __) => _deferred(_s057.loadLibrary(), () => _s057.BulkImportRoutesScreen())),
          GoRoute(path: '/deliveries', builder: (_, __) => _deferred(_s059.loadLibrary(), () => _s059.DeliveriesScreen())),
          GoRoute(
            path: '/deliveries/:id',
            builder: (_, state) => _deferred(_s060.loadLibrary(), () => _s060.DeliveryDetailScreen(deliveryId: state.pathParameters['id']!)),
          ),
          GoRoute(path: '/live-map', builder: (_, __) => _deferred(_s069.loadLibrary(), () => _s069.LiveMapScreen())),
          GoRoute(path: '/dispatch-orders', builder: (_, __) => _deferred(_s061.loadLibrary(), () => _s061.DispatchOrdersScreen())),
          GoRoute(path: '/orders', builder: (_, __) => _deferred(_s062.loadLibrary(), () => _s062.OrdersScreen())),
          GoRoute(path: '/reports', builder: (_, __) => _deferred(_s058.loadLibrary(), () => _s058.ReportsScreen())),
          GoRoute(path: '/reports/combined-summary', builder: (_, __) => _deferred(_s140.loadLibrary(), () => _s140.CombinedTripSummaryScreen())),
          GoRoute(path: '/compliance', builder: (_, __) => _deferred(_s070.loadLibrary(), () => _s070.ComplianceScreen())),
          GoRoute(path: '/settings', builder: (_, __) => _deferred(_s063.loadLibrary(), () => _s063.SettingsScreen())),
          GoRoute(path: '/account-linking', builder: (_, __) => _deferred(_s066.loadLibrary(), () => _s066.OrgAccessScreen())),
          GoRoute(path: '/operations/files', builder: (_, __) => _deferred(_s071.loadLibrary(), () => _s071.RetailerFilesScreen())),
          // Read-only Files view for ERP users — same screen, audience-filtered.
          GoRoute(path: '/erp/files', builder: (_, __) => _deferred(_s071.loadLibrary(), () => _s071.RetailerFilesScreen(audience: 'erpUser'))),
          GoRoute(path: '/operations/notifications', builder: (_, __) => _deferred(_s072.loadLibrary(), () => _s072.NotificationsComposerScreen())),
          GoRoute(path: '/operations/retailers', builder: (_, __) => _deferred(_s073.loadLibrary(), () => _s073.RetailersAdminScreen())),
          GoRoute(path: '/assets', builder: (_, __) => _deferred(_s074.loadLibrary(), () => _s074.ErpAssetsScreen())),
          GoRoute(path: '/facility', builder: (_, __) => _deferred(_s075.loadLibrary(), () => _s075.ErpFacilityScreen())),
          GoRoute(path: '/orgs', builder: (_, __) => _deferred(_s064.loadLibrary(), () => _s064.OrgsScreen())),
          GoRoute(path: '/subscriptions', builder: (_, __) => _deferred(_s065.loadLibrary(), () => _s065.SubscriptionsScreen())),
          GoRoute(path: '/billing', builder: (_, __) => _deferred(_s067.loadLibrary(), () => _s067.BillingScreen())),
          GoRoute(path: '/erp/products',  builder: (_, state) => _deferred(_s081.loadLibrary(), () => _s081.ErpProductsScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/low-stock-report', builder: (_, __) => _deferred(_s082.loadLibrary(), () => _s082.ErpLowStockReportScreen())),
          GoRoute(path: '/erp/stock-value-report', builder: (_, __) => _deferred(_s083.loadLibrary(), () => _s083.ErpStockValueReportScreen())),
          GoRoute(path: '/erp/stock-balance-report', builder: (_, __) => _deferred(_s084.loadLibrary(), () => _s084.ErpStockBalanceReportScreen())),
          GoRoute(path: '/erp/stock-aging-report', builder: (_, __) => _deferred(_s086.loadLibrary(), () => _s086.ErpStockAgingReportScreen())),
          GoRoute(path: '/erp/inventory-integrity', builder: (_, __) => _deferred(_s085.loadLibrary(), () => _s085.ErpInventoryIntegrityScreen())),
          GoRoute(path: '/erp/product-classifications', builder: (_, __) => _deferred(_s106.loadLibrary(), () => _s106.ErpProductClassificationsScreen())),
          GoRoute(path: '/erp/users', builder: (_, __) => _deferred(_s107.loadLibrary(), () => _s107.ErpUsersScreen())),
          GoRoute(path: '/erp/admin-settings', builder: (_, __) => _deferred(_s108.loadLibrary(), () => _s108.ErpAdminSettingsScreen())),
          GoRoute(path: '/erp/ai-connector', builder: (_, __) => _deferred(_s109.loadLibrary(), () => _s109.ErpMcpConnectorScreen())),
          GoRoute(path: '/erp/audit-log', builder: (_, __) => _deferred(_s134.loadLibrary(), () => _s134.ErpAuditLogScreen())),
          GoRoute(path: '/erp/super-summary', builder: (_, __) => _deferred(_s029.loadLibrary(), () => _s029.ErpSuperSummaryScreen())),
          GoRoute(path: '/erp/onboarding', builder: (_, __) => _deferred(_s009.loadLibrary(), () => _s009.ErpOnboardingScreen())),
          GoRoute(path: '/erp/home', builder: (_, __) => _deferred(_s111.loadLibrary(), () => _s111.ErpHomeScreen())),
          GoRoute(path: '/erp/no-access', builder: (_, __) => const _NoAccessScreen()),
          GoRoute(path: '/erp/opening-stock', builder: (_, __) => _deferred(_s112.loadLibrary(), () => _s112.ErpOpeningStockScreen())),
          GoRoute(path: '/erp/stock-transfers', builder: (_, state) => _deferred(_s113.loadLibrary(), () => _s113.ErpStockTransfersScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/processor-tracker', builder: (_, __) => _deferred(_s114.loadLibrary(), () => _s114.ErpProcessorTrackerScreen())),
          GoRoute(path: '/erp/processor-jobwork', builder: (_, __) => _deferred(_s115.loadLibrary(), () => _s115.ErpProcessorJobworkScreen())),
          GoRoute(path: '/erp/stock-adjustment', builder: (_, __) => _deferred(_s001.loadLibrary(), () => _s001.ErpStockAdjustmentScreen())),
          GoRoute(path: '/erp/payment-vouchers', builder: (_, __) => _deferred(_s080.loadLibrary(), () => _s080.ErpPaymentVoucherScreen())),
          GoRoute(path: '/erp/receipt-vouchers', builder: (_, __) => _deferred(_s117.loadLibrary(), () => _s117.ErpReceiptVouchersScreen())),
      GoRoute(path: '/financials/payment-advice', builder: (_, __) => _deferred(_s141.loadLibrary(), () => _s141.ErpPaymentAdviceScreen())),
          GoRoute(path: '/erp/pdc-voucher', builder: (_, __) => _deferred(_s110.loadLibrary(), () => _s110.ErpPdcVoucherScreen())),
          GoRoute(path: '/erp/supplier-ledger', builder: (_, __) => _deferred(_s118.loadLibrary(), () => _s118.ErpSupplierLedgerScreen())),
                GoRoute(path: '/financials/journal-vouchers', builder: (_, __) => _deferred(_s003.loadLibrary(), () => _s003.ErpJournalVoucherScreen())),
                GoRoute(path: '/financials/opening-journal', builder: (_, __) => _deferred(_s005.loadLibrary(), () => _s005.ErpOpeningJournalScreen())),
        GoRoute(path: '/financials/trial-balance',  builder: (_, __) => _deferred(_s002.loadLibrary(), () => _s002.ErpTrialBalanceScreen())),
        GoRoute(path: '/financials/account-activity', builder: (_, __) => _deferred(_s006.loadLibrary(), () => _s006.ErpAccountActivityScreen())),
        GoRoute(path: '/financials/cash-book', builder: (_, __) => _deferred(_s004.loadLibrary(), () => _s004.ErpCashBookScreen())),
      GoRoute(path: '/financials/profit-loss',     builder: (_, __) => _deferred(_s007.loadLibrary(), () => _s007.ErpProfitLossScreen())),
      GoRoute(path: '/financials/balance-sheet',   builder: (_, __) => _deferred(_s008.loadLibrary(), () => _s008.ErpBalanceSheetScreen())),
      GoRoute(path: '/manufacturing/product-assembly', builder: (_, __) => _deferred(_s010.loadLibrary(), () => _s010.ErpProductAssemblyScreen())),
      GoRoute(path: '/manufacturing/production-voucher', builder: (_, state) => _deferred(_s011.loadLibrary(), () => _s011.ErpProductionVoucherScreen(focusId: state.uri.queryParameters['focus']))),
      GoRoute(path: '/manufacturing/job-card', builder: (_, __) => _deferred(_s017.loadLibrary(), () => _s017.ErpJobCardScreen())),
      GoRoute(path: '/manufacturing/qc-checkpoints', builder: (_, __) => _deferred(_s018.loadLibrary(), () => _s018.ErpQcCheckpointsScreen())),
      GoRoute(path: '/manufacturing/qc-station', builder: (_, __) => _deferred(_s019.loadLibrary(), () => _s019.ErpQcStationScreen())),
      GoRoute(path: '/manufacturing/job-kiosk', builder: (_, __) => _deferred(_s020.loadLibrary(), () => _s020.ErpJobKioskScreen())),
      GoRoute(path: '/manufacturing/production-floor', builder: (_, __) => _deferred(_s021.loadLibrary(), () => _s021.ErpProductionFloorScreen())),
      // Registered in the permission registry (so it rendered as a menu item)
      // but had no GoRoute — same pre-existing gap as the HR attendance screens.
      GoRoute(path: '/manufacturing/production-plan', builder: (_, __) => _deferred(_s022.loadLibrary(), () => _s022.ErpProductionPlanScreen())),
      GoRoute(path: '/intelligence/report-builder', builder: (_, __) => _deferred(_s023.loadLibrary(), () => _s023.ErpReportBuilderScreen())),
      GoRoute(path: '/reports/center', builder: (_, __) => _deferred(_s024.loadLibrary(), () => _s024.ReportsCenterScreen())),
      GoRoute(path: '/reports/margin', builder: (_, __) => _deferred(_s025.loadLibrary(), () => _s025.ErpMarginReportScreen())),
      GoRoute(path: '/reports/customer-balance', builder: (_, __) => _deferred(_s026.loadLibrary(), () => _s026.ErpCustomerBalanceReportScreen())),
      GoRoute(path: '/reports/supplier-balance', builder: (_, __) => _deferred(_s027.loadLibrary(), () => _s027.ErpSupplierBalanceReportScreen())),
      GoRoute(path: '/reports/skipped-receipts', builder: (_, __) => _deferred(_s028.loadLibrary(), () => _s028.ErpSkippedReceiptsReportScreen())),
      GoRoute(path: '/manufacturing/production-inverse-voucher', builder: (_, __) => _deferred(_s012.loadLibrary(), () => _s012.ErpProductionInverseVoucherScreen())),
      GoRoute(path: '/manufacturing/damage-stock-voucher', builder: (_, __) => _deferred(_s013.loadLibrary(), () => _s013.ErpDamageStockVoucherScreen())),
      GoRoute(path: '/manufacturing/claim-processing-voucher', builder: (_, __) => _deferred(_s014.loadLibrary(), () => _s014.ErpClaimProcessingVoucherScreen())),
      GoRoute(path: '/manufacturing/production-waste-report', builder: (_, __) => _deferred(_s015.loadLibrary(), () => _s015.ErpProductionWasteReportScreen())),
      GoRoute(path: '/manufacturing/overheads-summary', builder: (_, __) => _deferred(_s016.loadLibrary(), () => _s016.ErpOverheadsSummaryScreen())),
      GoRoute(path: '/hr/employees', builder: (_, state) => _deferred(_s030.loadLibrary(), () => _s030.HrEmployeesScreen(focusId: state.uri.queryParameters['focus']))),
      GoRoute(path: '/hr/employee-attendance', builder: (_, state) => _deferred(_s031.loadLibrary(), () => _s031.HrEmployeeAttendanceScreen(empId: state.uri.queryParameters['emp'] ?? ''))),
      GoRoute(path: '/hr/attendance', builder: (_, __) => _deferred(_s036.loadLibrary(), () => _s036.HrAttendanceScreen())),
      GoRoute(path: '/hr/attendance-review', builder: (_, __) => _deferred(_s032.loadLibrary(), () => _s032.HrAttendanceReviewScreen())),
      // These two screens existed and were registered in the permission registry
      // (so they rendered as menu items) but had no GoRoute — clicking them threw
      // "no routes for location". Pre-existing gap, not introduced by the Files work.
      GoRoute(path: '/hr/attendance-kiosk', builder: (_, __) => _deferred(_s035.loadLibrary(), () => _s035.HrAttendanceKioskScreen())),
      GoRoute(path: '/hr/attendance-board', builder: (_, __) => _deferred(_s034.loadLibrary(), () => _s034.HrAttendanceBoardScreen())),
      GoRoute(path: '/hr/leave', builder: (_, __) => _deferred(_s037.loadLibrary(), () => _s037.HrLeaveScreen())),
      GoRoute(path: '/hr/payroll', builder: (_, __) => _deferred(_s033.loadLibrary(), () => _s033.HrPayrollScreen())),
      GoRoute(path: '/erp/customer-ledger', builder: (_, __) => _deferred(_s119.loadLibrary(), () => _s119.ErpCustomerLedgerScreen())),
          GoRoute(path: '/erp/inventory-ledger', builder: (_, s) => _deferred(_s120.loadLibrary(), () => _s120.ErpInventoryLedgerScreen(focusProductId: s.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/price-list', builder: (_, __) => _deferred(_s122.loadLibrary(), () => _s122.ErpPriceListScreen())),
          GoRoute(path: '/erp/fg-without-bom', builder: (_, __) => _deferred(_s121.loadLibrary(), () => _s121.ErpFgWithoutBomScreen())),
          GoRoute(path: '/erp/quotation', builder: (_, __) => _deferred(_s123.loadLibrary(), () => _s123.ErpQuotationScreen())),
          GoRoute(path: '/erp/demand-plan', builder: (_, __) => _deferred(_s127.loadLibrary(), () => _s127.ErpDemandPlanScreen())),
          GoRoute(path: '/erp/pos-config', builder: (_, __) => _deferred(_s129.loadLibrary(), () => _s129.ErpPosConfigScreen())),
          GoRoute(path: '/erp/pos-catalog', builder: (_, __) => _deferred(_s128.loadLibrary(), () => _s128.ErpPosCatalogScreen())),
          GoRoute(path: '/erp/pos-customer-history', builder: (_, __) => _deferred(_s130.loadLibrary(), () => _s130.ErpPosCustomerHistoryScreen())),
          GoRoute(path: '/erp/pos-held-bills', builder: (_, __) => _deferred(_s131.loadLibrary(), () => _s131.ErpPosHeldBillsScreen())),
          GoRoute(path: '/erp/pos-expense-management', builder: (_, __) => _deferred(_s132.loadLibrary(), () => _s132.ErpPosExpenseManagementScreen())),
          GoRoute(path: '/erp/delivery-orders', builder: (_, state) => _deferred(_s093.loadLibrary(), () => _s093.ErpDeliveryOrdersScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/sales-invoices', builder: (_, state) => _deferred(_s093.loadLibrary(), () => _s093.ErpSalesInvoicesScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/grn', builder: (_, state) => _deferred(_s091.loadLibrary(), () => _s091.ErpGrnScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/purchase-invoices', builder: (_, state) => _deferred(_s092.loadLibrary(), () => _s092.ErpPurchaseInvoicesScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/branches', builder: (_, __) => _deferred(_s087.loadLibrary(), () => _s087.ErpBranchesScreen())),
          GoRoute(path: '/erp/uoms',      builder: (_, __) => _deferred(_s088.loadLibrary(), () => _s088.ErpUomsScreen())),
          GoRoute(path: '/erp/stock',     builder: (_, __) => _deferred(_s089.loadLibrary(), () => _s089.ErpStockScreen())),
          GoRoute(path: '/erp/suppliers', builder: (_, state) => _deferred(_s103.loadLibrary(), () => _s103.ErpSuppliersScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/purchase',  builder: (_, state) => _deferred(_s090.loadLibrary(), () => _s090.ErpPurchaseScreen(
            focusId: state.uri.queryParameters['focus'],
            seedProductId: state.uri.queryParameters['seedProduct'],
            seedQty: state.uri.queryParameters['seedQty'],
            seedBranchId: state.uri.queryParameters['seedBranch']))),
          GoRoute(path: '/erp/sales',     builder: (_, state) => _deferred(_s093.loadLibrary(), () => _s093.ErpSalesScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/dispatch-summary', builder: (_, __) => _deferred(_s125.loadLibrary(), () => _s125.ErpDispatchSummaryScreen())),
          GoRoute(path: '/erp/schemes',   builder: (_, __) => _deferred(_s124.loadLibrary(), () => _s124.ErpSchemesScreen())),
          GoRoute(path: '/erp/schemes-report', builder: (_, __) => _deferred(_s126.loadLibrary(), () => _s126.ErpSchemesReportScreen())),
          GoRoute(path: '/erp/field-orders', builder: (_, __) => _deferred(_s094.loadLibrary(), () => _s094.ErpFieldOrdersScreen())),
          GoRoute(path: '/erp/retailer-orders', builder: (_, __) => _deferred(_s095.loadLibrary(), () => _s095.ErpRetailerOrdersScreen())),
          GoRoute(path: '/erp/sales-report', builder: (_, __) => _deferred(_s096.loadLibrary(), () => _s096.ErpSalesReportScreen())),
          GoRoute(path: '/erp/sales-return-report', builder: (_, __) => _deferred(_s097.loadLibrary(), () => _s097.ErpSalesReturnReportScreen())),
          GoRoute(path: '/erp/sales-dashboard', builder: (_, __) => _deferred(_s098.loadLibrary(), () => _s098.ErpSalesDashboardScreen())),
          GoRoute(path: '/erp/purchase-dashboard', builder: (_, __) => _deferred(_s098.loadLibrary(), () => _s098.ErpPurchaseDashboardScreen())),
          GoRoute(path: '/erp/purchase-report', builder: (_, __) => _deferred(_s104.loadLibrary(), () => _s104.ErpPurchaseReportScreen())),
          GoRoute(path: '/erp/purchase-variance', builder: (_, __) => _deferred(_s105.loadLibrary(), () => _s105.ErpPurchaseVarianceScreen())),
          GoRoute(path: '/erp/sales-returns', builder: (_, __) => _deferred(_s136.loadLibrary(), () => _s136.ErpSalesReturnsScreen())),
          GoRoute(path: '/erp/purchase-returns', builder: (_, __) => _deferred(_s137.loadLibrary(), () => _s137.ErpPurchaseReturnsScreen())),
          GoRoute(path: '/erp/sales-return-invoices', builder: (_, __) => _deferred(_s138.loadLibrary(), () => _s138.ErpSalesReturnInvoicesScreen())),
          GoRoute(path: '/erp/purchase-return-vouchers', builder: (_, state) => _deferred(_s139.loadLibrary(), () => _s139.ErpPurchaseReturnVouchersScreen(focusId: state.uri.queryParameters['focus']))),
          GoRoute(path: '/erp/customer-aging', builder: (_, __) => _deferred(_s133.loadLibrary(), () => _s133.ErpCustomerAgingScreen())),
          GoRoute(path: '/erp/supplier-aging', builder: (_, __) => _deferred(_s135.loadLibrary(), () => _s135.ErpSupplierAgingScreen())),
          GoRoute(path: '/erp/pos',       builder: (_, __) => _deferred(_s099.loadLibrary(), () => _s099.ErpPosScreen())),
          GoRoute(path: '/erp/promoters', builder: (_, __) => _deferred(_s100.loadLibrary(), () => _s100.ErpPromotersScreen())),
          GoRoute(path: '/erp/promoter-ledger', builder: (_, __) => _deferred(_s101.loadLibrary(), () => _s101.ErpPromoterLedgerScreen())),
          GoRoute(path: '/erp/chart-of-accounts', builder: (_, __) => _deferred(_s102.loadLibrary(), () => _s102.ErpChartOfAccountsScreen())),
        ],
      ),
    ],
  );
});


class _NoAccessScreen extends StatelessWidget {
  const _NoAccessScreen();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline, size: 48, color: Colors.grey),
          SizedBox(height: 16),
          Text('No access yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          SizedBox(height: 8),
          Text('You do not have permission for any module yet. Ask an administrator to grant access.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ]),
      ),
    );
  }
}


// ── Deferred-screen loader ─────────────────────────────────────────────────
// Each feature screen is imported `deferred as`, so its code (and heavy deps
// like pdf/printing/excel) ships in its own chunk loaded on first navigation,
// keeping the initial bundle small. This wraps a route builder: it triggers
// loadLibrary() and shows a light spinner until the chunk is ready.
Widget _deferred(Future<void> load, Widget Function() make) =>
    _DeferredScreen(load: load, make: make);

class _DeferredScreen extends StatelessWidget {
  final Future<void> load;
  final Widget Function() make;
  const _DeferredScreen({required this.load, required this.make});
  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
        future: load,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            // A deferred code chunk failed to load. Usual cause: this tab (or
            // the service-worker cache) is running an older main.dart.js while
            // the server already has a newer build's chunks — chunk filenames
            // are not content-hashed, so old code + new chunk don't match.
            // Recover automatically ONCE per minute with a clean reload
            // (drops the stale SW); if it happens again right away, fall back
            // to the manual button so we can never loop.
            if (_claimAutoReload()) {
              Future.microtask(_hardReload);
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.refresh, size: 36),
                      const SizedBox(height: 12),
                      const Text(
                        'This screen could not load. Opstation may have been '
                        'updated, or the connection dropped — reload to continue.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _hardReload,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Reload'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          return make();
        },
      );
}

/// True (and records the attempt) if no automatic chunk-recovery reload has
/// happened in the last 60 seconds. Guards against reload loops.
bool _claimAutoReload() {
  const key = 'op_chunk_autoreload_at';
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = int.tryParse(html.window.sessionStorage[key] ?? '') ?? 0;
    if (now - last < 60000) return false;
    html.window.sessionStorage[key] = '$now';
    return true;
  } catch (_) {
    return false;
  }
}

/// Clean reload: drop any app service worker, then reload so the browser
/// fetches the fresh bundle.
Future<void> _hardReload() async {
  try {
    final sw = html.window.navigator.serviceWorker;
    if (sw != null) {
      final regs = await sw.getRegistrations();
      for (final r in regs) {
        await r.unregister();
      }
    }
  } catch (_) {}
  html.window.location.reload();
}
