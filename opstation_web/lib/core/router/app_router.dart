import '../../features/inventory/erp_stock_adjustment_screen.dart';
import '../../features/erp/presentation/erp_trial_balance_screen.dart';
import '../../features/erp/presentation/erp_journal_voucher_screen.dart';
import '../../features/erp/presentation/erp_cash_book_screen.dart';
import '../../features/erp/presentation/erp_opening_journal_screen.dart';
import '../../features/erp/presentation/erp_account_activity_screen.dart';
import '../../features/erp/presentation/erp_profit_loss_screen.dart';
import '../../features/erp/presentation/erp_balance_sheet_screen.dart';
import '../../features/erp/presentation/erp_onboarding_screen.dart';
import '../../features/erp/presentation/erp_product_assembly_screen.dart';
import '../../features/erp/presentation/erp_production_voucher_screen.dart';
import '../../features/erp/presentation/erp_production_inverse_voucher_screen.dart';
import '../../features/erp/presentation/erp_damage_stock_voucher_screen.dart';
import '../../features/erp/presentation/erp_claim_processing_voucher_screen.dart';
import '../../features/erp/presentation/erp_production_waste_report_screen.dart';
import '../../features/erp/presentation/erp_overheads_summary_screen.dart';
import '../../features/erp/presentation/erp_job_card_screen.dart';
import '../../features/erp/presentation/erp_qc_checkpoints_screen.dart';
import '../../features/erp/presentation/erp_qc_station_screen.dart';
import '../../features/erp/presentation/erp_production_floor_screen.dart';
import '../../features/erp/presentation/erp_production_plan_screen.dart';
import '../../features/erp/presentation/erp_report_builder_screen.dart';
import '../../features/erp/presentation/reports_center_screen.dart';
import '../../features/erp/presentation/erp_margin_report_screen.dart';
import '../../features/erp/presentation/erp_customer_balance_report_screen.dart';
import '../../features/erp/presentation/erp_supplier_balance_report_screen.dart';
import '../../features/erp/presentation/erp_skipped_receipts_report_screen.dart';
import '../../features/erp/presentation/erp_super_summary_screen.dart';
import '../../features/hr/presentation/hr_employees_screen.dart';
import '../../features/hr/presentation/hr_attendance_board_screen.dart';
import '../../features/hr/presentation/hr_attendance_kiosk_screen.dart';
import '../../features/hr/presentation/hr_attendance_screen.dart';
import '../../features/hr/presentation/hr_leave_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:animations/animations.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/team/presentation/team_screen.dart';
import '../../features/customers/presentation/customers_screen.dart';
import '../../features/customers/presentation/follow_ups_screen.dart';
import '../../features/customers/presentation/crm_pipeline_screen.dart';
import '../../features/customers/presentation/erp_tasks_screen.dart';
import '../../features/customers/presentation/erp_supplier_360_screen.dart';
import '../../features/products/presentation/products_screen.dart';
import '../../features/competitor_categories/presentation/competitor_categories_screen.dart';
import '../../features/competitor_categories/presentation/competitor_brand_aliases_screen.dart';
import '../../features/intelligence/presentation/intelligence_placement_screen.dart';
import '../../features/intelligence/presentation/intelligence_dashboard_screen.dart';
import '../../features/intelligence/presentation/intelligence_competitors_screen.dart';
import '../../features/intelligence/presentation/intelligence_performance_screen.dart';
import '../../features/routes/presentation/routes_screen.dart';
import '../../features/customers/presentation/bulk_import_customers_screen.dart';
import '../../features/routes/presentation/bulk_import_routes_screen.dart';
import '../../features/reports/presentation/reports_screen.dart';
import '../../features/deliveries/presentation/deliveries_screen.dart';
import '../../features/deliveries/presentation/delivery_detail_screen.dart';
import '../../features/dispatch_orders/presentation/dispatch_orders_screen.dart';
import '../../features/orders/presentation/orders_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/superadmin/presentation/orgs_screen.dart';
import '../../features/live_map/presentation/live_map_screen.dart';
import '../../features/compliance/presentation/compliance_screen.dart';
import '../../features/operations/presentation/retailer_files_screen.dart';
import '../../features/operations/presentation/notifications_composer_screen.dart';
import '../../features/operations/presentation/retailers_admin_screen.dart';
import '../../features/assets/presentation/erp_assets_screen.dart';
import '../../features/facility/presentation/erp_facility_screen.dart';
import '../layout/main_layout.dart';
import '../../features/auth/retailer_auth_controller.dart';
import '../../features/auth/presentation/retailer_login_screen.dart';
import '../../features/retailer/presentation/retailer_portal_screen.dart';
import '../permissions/access_control.dart';
import '../permissions/permission_registry.dart';
import '../../features/erp/presentation/erp_placeholder_screen.dart';
import '../../features/erp/presentation/erp_payment_voucher_screen.dart';
import '../../features/erp/presentation/erp_products_screen.dart';
import '../../features/erp/presentation/erp_low_stock_report_screen.dart';
import '../../features/erp/presentation/erp_stock_value_report_screen.dart';
import '../../features/erp/presentation/erp_stock_balance_report_screen.dart';
import '../../features/erp/presentation/erp_inventory_integrity_screen.dart';
import '../../features/erp/presentation/erp_stock_aging_report_screen.dart';
import '../../features/erp/presentation/erp_branches_screen.dart';
import '../../features/erp/presentation/erp_uoms_screen.dart';
import '../../features/erp/presentation/erp_stock_screen.dart';
import '../../features/erp/presentation/erp_po_screen.dart';
import '../../features/erp/presentation/erp_grn_screen.dart';
import '../../features/erp/presentation/erp_pi_screen.dart';
import '../../features/erp/presentation/erp_sales_screen.dart';
import '../../features/erp/presentation/erp_field_orders_screen.dart';
import '../../features/erp/presentation/erp_retailer_orders_screen.dart';
import '../../features/erp/presentation/erp_sales_report_screen.dart';
import '../../features/erp/presentation/erp_sales_return_report_screen.dart';
import '../../features/erp/presentation/erp_flow_dashboard_screen.dart';
import '../../features/erp/presentation/erp_pos_screen.dart';
import '../../features/erp/presentation/erp_promoters_screen.dart';
import '../../features/erp/presentation/erp_promoter_ledger_screen.dart';
import '../../features/erp/presentation/erp_chart_of_accounts_screen.dart';
import '../../features/erp/presentation/erp_chart_of_accounts_screen.dart';
import '../../features/erp/presentation/erp_suppliers_screen.dart';
import '../../features/erp/presentation/erp_purchase_report_screen.dart';
import '../../features/erp/presentation/erp_purchase_variance_screen.dart';
import '../../features/erp/presentation/erp_product_classifications_screen.dart';
import '../../features/erp/presentation/erp_users_screen.dart';
import '../../features/erp/presentation/erp_admin_settings_screen.dart';
import '../../features/erp/presentation/erp_pdc_voucher_screen.dart';
import '../../features/erp/presentation/erp_home_screen.dart';
import '../../features/erp/presentation/erp_opening_stock_screen.dart';
import '../../features/erp/presentation/erp_stock_transfers_screen.dart';
import '../../features/erp/presentation/erp_payment_vouchers_screen.dart';
import '../../features/erp/presentation/erp_receipt_vouchers_screen.dart';
import '../../features/erp/presentation/erp_supplier_ledger_screen.dart';
import '../../features/erp/presentation/erp_customer_ledger_screen.dart';
import '../../features/erp/presentation/erp_inventory_ledger_screen.dart';
import '../../features/erp/presentation/erp_quotation_screen.dart';
import '../../features/erp/presentation/erp_demand_plan_screen.dart';
import '../../features/erp/presentation/erp_pos_catalog_screen.dart';
import '../../features/erp/presentation/erp_pos_config_screen.dart';
import '../../features/erp/presentation/erp_pos_customer_history_screen.dart';
import '../../features/erp/presentation/erp_receipt_vouchers_screen.dart';
import '../../features/erp/presentation/erp_pos_held_bills_screen.dart';
import '../../features/erp/presentation/erp_pos_expense_management_screen.dart';
import '../../features/erp/presentation/erp_customer_aging_screen.dart';
import '../../features/erp/presentation/erp_audit_log_screen.dart';
import '../../features/erp/presentation/erp_supplier_aging_screen.dart';
import '../../features/erp/presentation/erp_sales_returns_screen.dart';
import '../../features/erp/presentation/erp_purchase_returns_screen.dart';
import '../../features/erp/presentation/erp_sales_return_invoices_screen.dart';
import '../../features/erp/presentation/erp_purchase_return_vouchers_screen.dart';

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
      final onLogin = loc == '/login';
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
        bool allowed() {
          if (role == WebUserRole.superAdmin) {
            return loc == '/orgs';
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
            if (!inErp && !permScopedCrm && !permScopedCustomers && !permScopedReportBuilder) return false;
            if (loc == '/erp/admin-settings') return false; // admin-tier only
            // Always-available to every ERP user regardless of grants: their
            // landing home, the onboarding guide, and the no-access page (so a
            // denied route redirects here without looping).
            if (loc == '/erp/no-access' ||
                loc == '/erp/home' ||
                loc == '/erp/onboarding') return true;
            if (access == null) return true;
            final it = kRouteToPerm[loc];
            // Unregistered ERP-area route => no access. Was `return true`, the
            // fail-open leak that let one grant expose whole unrelated menus.
            if (it == null) return false;
            // Branch-scoped: a route is only reachable if granted at the
            // ACTIVE branch (or globally). Null branch (still restoring after
            // refresh) falls back to any-branch reachability.
            final branchId =
                ref.read(selectedBranchProvider)?['id'] as String?;
            return access.canAccessRouteAt(loc, branchId);
          }
          // admin / masterAdmin — everything except super admin's /orgs
          return loc != '/orgs';
        }
        if (onLogin) return home();
        if (!allowed()) return home();
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        path: '/r/login',
        builder: (_, __) => const RetailerLoginScreen(),
      ),
      GoRoute(
        path: '/r',
        builder: (_, __) => const RetailerPortalScreen(),
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
          GoRoute(path: '/dashboard', builder: (_, __) => const DashboardScreen()),
          GoRoute(path: '/team', builder: (_, __) => const TeamScreen()),
          GoRoute(path: '/customers', builder: (_, state) => CustomersScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/crm/customers', builder: (_, __) => const CustomersScreen(crmMode: true)),
          GoRoute(path: '/customers/import', builder: (_, __) => const BulkImportCustomersScreen()),
          GoRoute(path: '/crm/follow-ups', builder: (_, __) => const FollowUpsScreen()),
          GoRoute(path: '/crm/pipeline', builder: (_, __) => const CrmPipelineScreen()),
          GoRoute(path: '/crm/tasks', builder: (_, __) => const ErpTasksScreen()),
          GoRoute(path: '/crm/supplier-profile', builder: (_, __) => const ErpSupplier360Screen()),
          GoRoute(path: '/products', builder: (_, __) => const ProductsScreen()),
          GoRoute(path: '/competitor-categories', builder: (_, __) => const CompetitorCategoriesScreen()),
          GoRoute(path: '/competitor-brand-aliases', builder: (_, __) => const CompetitorBrandAliasesScreen()),
          GoRoute(path: '/intelligence/dashboard', builder: (_, __) => const IntelligenceDashboardScreen()),
          GoRoute(path: '/intelligence/placement', builder: (_, __) => const IntelligencePlacementScreen()),
          GoRoute(path: '/intelligence/competitors', builder: (_, __) => const IntelligenceCompetitorsScreen()),
          GoRoute(path: '/intelligence/performance', builder: (_, __) => const IntelligencePerformanceScreen()),
          GoRoute(path: '/routes', builder: (_, __) => const RoutesScreen()),
          GoRoute(path: '/routes/import', builder: (_, __) => const BulkImportRoutesScreen()),
          GoRoute(path: '/deliveries', builder: (_, __) => const DeliveriesScreen()),
          GoRoute(
            path: '/deliveries/:id',
            builder: (_, state) => DeliveryDetailScreen(deliveryId: state.pathParameters['id']!),
          ),
          GoRoute(path: '/live-map', builder: (_, __) => const LiveMapScreen()),
          GoRoute(path: '/dispatch-orders', builder: (_, __) => const DispatchOrdersScreen()),
          GoRoute(path: '/orders', builder: (_, __) => const OrdersScreen()),
          GoRoute(path: '/reports', builder: (_, __) => const ReportsScreen()),
          GoRoute(path: '/compliance', builder: (_, __) => const ComplianceScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
          GoRoute(path: '/operations/files', builder: (_, __) => const RetailerFilesScreen()),
          // Read-only Files view for ERP users — same screen, audience-filtered.
          GoRoute(path: '/erp/files', builder: (_, __) => const RetailerFilesScreen(audience: 'erpUser')),
          GoRoute(path: '/operations/notifications', builder: (_, __) => const NotificationsComposerScreen()),
          GoRoute(path: '/operations/retailers', builder: (_, __) => const RetailersAdminScreen()),
          GoRoute(path: '/assets', builder: (_, __) => const ErpAssetsScreen()),
          GoRoute(path: '/facility', builder: (_, __) => const ErpFacilityScreen()),
          GoRoute(path: '/orgs', builder: (_, __) => const OrgsScreen()),
          GoRoute(path: '/erp/products',  builder: (_, state) => ErpProductsScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/low-stock-report', builder: (_, __) => const ErpLowStockReportScreen()),
          GoRoute(path: '/erp/stock-value-report', builder: (_, __) => const ErpStockValueReportScreen()),
          GoRoute(path: '/erp/stock-balance-report', builder: (_, __) => const ErpStockBalanceReportScreen()),
          GoRoute(path: '/erp/stock-aging-report', builder: (_, __) => const ErpStockAgingReportScreen()),
          GoRoute(path: '/erp/inventory-integrity', builder: (_, __) => const ErpInventoryIntegrityScreen()),
          GoRoute(path: '/erp/product-classifications', builder: (_, __) => const ErpProductClassificationsScreen()),
          GoRoute(path: '/erp/users', builder: (_, __) => const ErpUsersScreen()),
          GoRoute(path: '/erp/admin-settings', builder: (_, __) => const ErpAdminSettingsScreen()),
          GoRoute(path: '/erp/audit-log', builder: (_, __) => const ErpAuditLogScreen()),
          GoRoute(path: '/erp/super-summary', builder: (_, __) => const ErpSuperSummaryScreen()),
          GoRoute(path: '/erp/onboarding', builder: (_, __) => const ErpOnboardingScreen()),
          GoRoute(path: '/erp/home', builder: (_, __) => const ErpHomeScreen()),
          GoRoute(path: '/erp/no-access', builder: (_, __) => const _NoAccessScreen()),
          GoRoute(path: '/erp/opening-stock', builder: (_, __) => const ErpOpeningStockScreen()),
          GoRoute(path: '/erp/stock-transfers', builder: (_, state) => ErpStockTransfersScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/stock-adjustment', builder: (_, __) => const ErpStockAdjustmentScreen()),
          GoRoute(path: '/erp/payment-vouchers', builder: (_, __) => const ErpPaymentVoucherScreen()),
          GoRoute(path: '/erp/receipt-vouchers', builder: (_, __) => const ErpReceiptVouchersScreen()),
          GoRoute(path: '/erp/pdc-voucher', builder: (_, __) => const ErpPdcVoucherScreen()),
          GoRoute(path: '/erp/supplier-ledger', builder: (_, __) => const ErpSupplierLedgerScreen()),
                GoRoute(path: '/financials/journal-vouchers', builder: (_, __) => const ErpJournalVoucherScreen()),
                GoRoute(path: '/financials/opening-journal', builder: (_, __) => const ErpOpeningJournalScreen()),
        GoRoute(path: '/financials/trial-balance',  builder: (_, __) => const ErpTrialBalanceScreen()),
        GoRoute(path: '/financials/account-activity', builder: (_, __) => const ErpAccountActivityScreen()),
        GoRoute(path: '/financials/cash-book', builder: (_, __) => const ErpCashBookScreen()),
      GoRoute(path: '/financials/profit-loss',     builder: (_, __) => const ErpProfitLossScreen()),
      GoRoute(path: '/financials/balance-sheet',   builder: (_, __) => const ErpBalanceSheetScreen()),
      GoRoute(path: '/manufacturing/product-assembly', builder: (_, __) => const ErpProductAssemblyScreen()),
      GoRoute(path: '/manufacturing/production-voucher', builder: (_, state) => ErpProductionVoucherScreen(focusId: state.uri.queryParameters['focus'])),
      GoRoute(path: '/manufacturing/job-card', builder: (_, __) => const ErpJobCardScreen()),
      GoRoute(path: '/manufacturing/qc-checkpoints', builder: (_, __) => const ErpQcCheckpointsScreen()),
      GoRoute(path: '/manufacturing/qc-station', builder: (_, __) => const ErpQcStationScreen()),
      GoRoute(path: '/manufacturing/production-floor', builder: (_, __) => const ErpProductionFloorScreen()),
      // Registered in the permission registry (so it rendered as a menu item)
      // but had no GoRoute — same pre-existing gap as the HR attendance screens.
      GoRoute(path: '/manufacturing/production-plan', builder: (_, __) => const ErpProductionPlanScreen()),
      GoRoute(path: '/intelligence/report-builder', builder: (_, __) => const ErpReportBuilderScreen()),
      GoRoute(path: '/reports/center', builder: (_, __) => const ReportsCenterScreen()),
      GoRoute(path: '/reports/margin', builder: (_, __) => const ErpMarginReportScreen()),
      GoRoute(path: '/reports/customer-balance', builder: (_, __) => const ErpCustomerBalanceReportScreen()),
      GoRoute(path: '/reports/supplier-balance', builder: (_, __) => const ErpSupplierBalanceReportScreen()),
      GoRoute(path: '/reports/skipped-receipts', builder: (_, __) => const ErpSkippedReceiptsReportScreen()),
      GoRoute(path: '/manufacturing/production-inverse-voucher', builder: (_, __) => const ErpProductionInverseVoucherScreen()),
      GoRoute(path: '/manufacturing/damage-stock-voucher', builder: (_, __) => const ErpDamageStockVoucherScreen()),
      GoRoute(path: '/manufacturing/claim-processing-voucher', builder: (_, __) => const ErpClaimProcessingVoucherScreen()),
      GoRoute(path: '/manufacturing/production-waste-report', builder: (_, __) => const ErpProductionWasteReportScreen()),
      GoRoute(path: '/manufacturing/overheads-summary', builder: (_, __) => const ErpOverheadsSummaryScreen()),
      GoRoute(path: '/hr/employees', builder: (_, __) => const HrEmployeesScreen()),
      GoRoute(path: '/hr/attendance', builder: (_, __) => const HrAttendanceScreen()),
      // These two screens existed and were registered in the permission registry
      // (so they rendered as menu items) but had no GoRoute — clicking them threw
      // "no routes for location". Pre-existing gap, not introduced by the Files work.
      GoRoute(path: '/hr/attendance-kiosk', builder: (_, __) => const HrAttendanceKioskScreen()),
      GoRoute(path: '/hr/attendance-board', builder: (_, __) => const HrAttendanceBoardScreen()),
      GoRoute(path: '/hr/leave', builder: (_, __) => const HrLeaveScreen()),
      GoRoute(path: '/erp/customer-ledger', builder: (_, __) => const ErpCustomerLedgerScreen()),
          GoRoute(path: '/erp/inventory-ledger', builder: (_, __) => const ErpInventoryLedgerScreen()),
          GoRoute(path: '/erp/quotation', builder: (_, __) => const ErpQuotationScreen()),
          GoRoute(path: '/erp/demand-plan', builder: (_, __) => const ErpDemandPlanScreen()),
          GoRoute(path: '/erp/pos-config', builder: (_, __) => const ErpPosConfigScreen()),
          GoRoute(path: '/erp/pos-catalog', builder: (_, __) => const ErpPosCatalogScreen()),
          GoRoute(path: '/erp/pos-customer-history', builder: (_, __) => const ErpPosCustomerHistoryScreen()),
          GoRoute(path: '/erp/pos-held-bills', builder: (_, __) => const ErpPosHeldBillsScreen()),
          GoRoute(path: '/erp/pos-expense-management', builder: (_, __) => const ErpPosExpenseManagementScreen()),
          GoRoute(path: '/erp/delivery-orders', builder: (_, state) => ErpDeliveryOrdersScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/sales-invoices', builder: (_, state) => ErpSalesInvoicesScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/grn', builder: (_, state) => ErpGrnScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/purchase-invoices', builder: (_, state) => ErpPurchaseInvoicesScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/branches', builder: (_, __) => const ErpBranchesScreen()),
          GoRoute(path: '/erp/uoms',      builder: (_, __) => const ErpUomsScreen()),
          GoRoute(path: '/erp/stock',     builder: (_, __) => const ErpStockScreen()),
          GoRoute(path: '/erp/suppliers', builder: (_, state) => ErpSuppliersScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/purchase',  builder: (_, state) => ErpPurchaseScreen(
            focusId: state.uri.queryParameters['focus'],
            seedProductId: state.uri.queryParameters['seedProduct'],
            seedQty: state.uri.queryParameters['seedQty'],
            seedBranchId: state.uri.queryParameters['seedBranch'])),
          GoRoute(path: '/erp/sales',     builder: (_, state) => ErpSalesScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/field-orders', builder: (_, __) => const ErpFieldOrdersScreen()),
          GoRoute(path: '/erp/retailer-orders', builder: (_, __) => const ErpRetailerOrdersScreen()),
          GoRoute(path: '/erp/sales-report', builder: (_, __) => const ErpSalesReportScreen()),
          GoRoute(path: '/erp/sales-return-report', builder: (_, __) => const ErpSalesReturnReportScreen()),
          GoRoute(path: '/erp/sales-dashboard', builder: (_, __) => const ErpSalesDashboardScreen()),
          GoRoute(path: '/erp/purchase-dashboard', builder: (_, __) => const ErpPurchaseDashboardScreen()),
          GoRoute(path: '/erp/purchase-report', builder: (_, __) => const ErpPurchaseReportScreen()),
          GoRoute(path: '/erp/purchase-variance', builder: (_, __) => const ErpPurchaseVarianceScreen()),
          GoRoute(path: '/erp/sales-returns', builder: (_, __) => const ErpSalesReturnsScreen()),
          GoRoute(path: '/erp/purchase-returns', builder: (_, __) => const ErpPurchaseReturnsScreen()),
          GoRoute(path: '/erp/sales-return-invoices', builder: (_, __) => const ErpSalesReturnInvoicesScreen()),
          GoRoute(path: '/erp/purchase-return-vouchers', builder: (_, state) => ErpPurchaseReturnVouchersScreen(focusId: state.uri.queryParameters['focus'])),
          GoRoute(path: '/erp/customer-aging', builder: (_, __) => const ErpCustomerAgingScreen()),
          GoRoute(path: '/erp/supplier-aging', builder: (_, __) => const ErpSupplierAgingScreen()),
          GoRoute(path: '/erp/pos',       builder: (_, __) => const ErpPosScreen()),
          GoRoute(path: '/erp/promoters', builder: (_, __) => const ErpPromotersScreen()),
          GoRoute(path: '/erp/promoter-ledger', builder: (_, __) => const ErpPromoterLedgerScreen()),
          GoRoute(path: '/erp/chart-of-accounts', builder: (_, __) => const ErpChartOfAccountsScreen()),
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
