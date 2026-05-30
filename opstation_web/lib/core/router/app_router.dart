import '../../features/erp/presentation/erp_trial_balance_screen.dart';
import '../../features/erp/presentation/erp_journal_voucher_screen.dart';
import '../../features/erp/presentation/erp_profit_loss_screen.dart';
import '../../features/erp/presentation/erp_balance_sheet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/team/presentation/team_screen.dart';
import '../../features/customers/presentation/customers_screen.dart';
import '../../features/products/presentation/products_screen.dart';
import '../../features/competitor_categories/presentation/competitor_categories_screen.dart';
import '../../features/intelligence/presentation/intelligence_placement_screen.dart';
import '../../features/intelligence/presentation/intelligence_competitors_screen.dart';
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
import '../layout/main_layout.dart';
import '../../features/erp/presentation/erp_placeholder_screen.dart';
import '../../features/erp/presentation/erp_payment_voucher_screen.dart';
import '../../features/erp/presentation/erp_products_screen.dart';
import '../../features/erp/presentation/erp_branches_screen.dart';
import '../../features/erp/presentation/erp_uoms_screen.dart';
import '../../features/erp/presentation/erp_stock_screen.dart';
import '../../features/erp/presentation/erp_po_screen.dart';
import '../../features/erp/presentation/erp_grn_screen.dart';
import '../../features/erp/presentation/erp_pi_screen.dart';
import '../../features/erp/presentation/erp_sales_screen.dart';
import '../../features/erp/presentation/erp_pos_screen.dart';
import '../../features/erp/presentation/erp_chart_of_accounts_screen.dart';
import '../../features/erp/presentation/erp_chart_of_accounts_screen.dart';
import '../../features/erp/presentation/erp_suppliers_screen.dart';
import '../../features/erp/presentation/erp_product_classifications_screen.dart';
import '../../features/erp/presentation/erp_users_screen.dart';
import '../../features/erp/presentation/erp_opening_stock_screen.dart';
import '../../features/erp/presentation/erp_stock_transfers_screen.dart';
import '../../features/erp/presentation/erp_payment_vouchers_screen.dart';
import '../../features/erp/presentation/erp_receipt_vouchers_screen.dart';
import '../../features/erp/presentation/erp_supplier_ledger_screen.dart';
import '../../features/erp/presentation/erp_customer_ledger_screen.dart';
import '../../features/erp/presentation/erp_inventory_ledger_screen.dart';
import '../../features/erp/presentation/erp_pos_catalog_screen.dart';
import '../../features/erp/presentation/erp_pos_config_screen.dart';
import '../../features/erp/presentation/erp_pos_customer_history_screen.dart';
import '../../features/erp/presentation/erp_receipt_vouchers_screen.dart';
import '../../features/erp/presentation/erp_pos_held_bills_screen.dart';
import '../../features/erp/presentation/erp_pos_expense_management_screen.dart';
import '../../features/erp/presentation/erp_customer_aging_screen.dart';
import '../../features/erp/presentation/erp_supplier_aging_screen.dart';
import '../../features/erp/presentation/erp_sales_returns_screen.dart';
import '../../features/erp/presentation/erp_purchase_returns_screen.dart';
import '../../features/erp/presentation/erp_sales_return_invoices_screen.dart';
import '../../features/erp/presentation/erp_purchase_return_vouchers_screen.dart';

class AuthNotifier extends ChangeNotifier {
  AuthNotifier(this._ref) {
    _ref.listen(authControllerProvider, (_, __) => notifyListeners());
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
      if (auth.isLoading) return null;
      final user = auth.valueOrNull;
      final loggedIn = user != null;
      final loc = state.matchedLocation;
      final onLogin = loc == '/login';
      if (!loggedIn && !onLogin) return '/login';
      if (loggedIn) {
        final role = user.role;
        String home() {
          if (role == WebUserRole.superAdmin) return '/orgs';
          if (role == WebUserRole.dispatchManager) return '/deliveries';
          if (role == WebUserRole.accountant) return '/orders';
          if (role == WebUserRole.erpUser) return '/erp/products';
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
            return loc.startsWith('/erp/');
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
      ShellRoute(
        builder: (context, state, child) => MainLayout(child: child),
        routes: [
          GoRoute(path: '/dashboard', builder: (_, __) => const DashboardScreen()),
          GoRoute(path: '/team', builder: (_, __) => const TeamScreen()),
          GoRoute(path: '/customers', builder: (_, __) => const CustomersScreen()),
          GoRoute(path: '/customers/import', builder: (_, __) => const BulkImportCustomersScreen()),
          GoRoute(path: '/products', builder: (_, __) => const ProductsScreen()),
          GoRoute(path: '/competitor-categories', builder: (_, __) => const CompetitorCategoriesScreen()),
          GoRoute(path: '/intelligence/placement', builder: (_, __) => const IntelligencePlacementScreen()),
          GoRoute(path: '/intelligence/competitors', builder: (_, __) => const IntelligenceCompetitorsScreen()),
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
          GoRoute(path: '/orgs', builder: (_, __) => const OrgsScreen()),
          GoRoute(path: '/erp/products',  builder: (_, __) => const ErpProductsScreen()),
          GoRoute(path: '/erp/product-classifications', builder: (_, __) => const ErpProductClassificationsScreen()),
          GoRoute(path: '/erp/users', builder: (_, __) => const ErpUsersScreen()),
          GoRoute(path: '/erp/opening-stock', builder: (_, __) => const ErpOpeningStockScreen()),
          GoRoute(path: '/erp/stock-transfers', builder: (_, __) => const ErpStockTransfersScreen()),
          GoRoute(path: '/erp/payment-vouchers', builder: (_, __) => const ErpPaymentVoucherScreen()),
          GoRoute(path: '/erp/receipt-vouchers', builder: (_, __) => const ErpReceiptVouchersScreen()),
          GoRoute(path: '/erp/supplier-ledger', builder: (_, __) => const ErpSupplierLedgerScreen()),
                GoRoute(path: '/financials/journal-vouchers', builder: (_, __) => const ErpJournalVoucherScreen()),
        GoRoute(path: '/financials/trial-balance',  builder: (_, __) => const ErpTrialBalanceScreen()),
      GoRoute(path: '/financials/profit-loss',     builder: (_, __) => const ErpProfitLossScreen()),
      GoRoute(path: '/financials/balance-sheet',   builder: (_, __) => const ErpBalanceSheetScreen()),
      GoRoute(path: '/erp/customer-ledger', builder: (_, __) => const ErpCustomerLedgerScreen()),
          GoRoute(path: '/erp/inventory-ledger', builder: (_, __) => const ErpInventoryLedgerScreen()),
          GoRoute(path: '/erp/pos-config', builder: (_, __) => const ErpPosConfigScreen()),
          GoRoute(path: '/erp/pos-catalog', builder: (_, __) => const ErpPosCatalogScreen()),
          GoRoute(path: '/erp/pos-customer-history', builder: (_, __) => const ErpPosCustomerHistoryScreen()),
          GoRoute(path: '/erp/pos-held-bills', builder: (_, __) => const ErpPosHeldBillsScreen()),
          GoRoute(path: '/erp/pos-expense-management', builder: (_, __) => const ErpPosExpenseManagementScreen()),
          GoRoute(path: '/erp/delivery-orders', builder: (_, __) => const ErpDeliveryOrdersScreen()),
          GoRoute(path: '/erp/sales-invoices', builder: (_, __) => const ErpSalesInvoicesScreen()),
          GoRoute(path: '/erp/grn', builder: (_, __) => const ErpGrnScreen()),
          GoRoute(path: '/erp/purchase-invoices', builder: (_, __) => const ErpPurchaseInvoicesScreen()),
          GoRoute(path: '/erp/branches', builder: (_, __) => const ErpBranchesScreen()),
          GoRoute(path: '/erp/uoms',      builder: (_, __) => const ErpUomsScreen()),
          GoRoute(path: '/erp/stock',     builder: (_, __) => const ErpStockScreen()),
          GoRoute(path: '/erp/suppliers', builder: (_, __) => const ErpSuppliersScreen()),
          GoRoute(path: '/erp/purchase',  builder: (_, __) => const ErpPurchaseScreen()),
          GoRoute(path: '/erp/sales',     builder: (_, __) => const ErpSalesScreen()),
          GoRoute(path: '/erp/sales-returns', builder: (_, __) => const ErpSalesReturnsScreen()),
          GoRoute(path: '/erp/purchase-returns', builder: (_, __) => const ErpPurchaseReturnsScreen()),
          GoRoute(path: '/erp/sales-return-invoices', builder: (_, __) => const ErpSalesReturnInvoicesScreen()),
          GoRoute(path: '/erp/purchase-return-vouchers', builder: (_, __) => const ErpPurchaseReturnVouchersScreen()),
          GoRoute(path: '/erp/customer-aging', builder: (_, __) => const ErpCustomerAgingScreen()),
          GoRoute(path: '/erp/supplier-aging', builder: (_, __) => const ErpSupplierAgingScreen()),
          GoRoute(path: '/erp/pos',       builder: (_, __) => const ErpPosScreen()),
          GoRoute(path: '/erp/chart-of-accounts', builder: (_, __) => const ErpChartOfAccountsScreen()),
        ],
      ),
    ],
  );
});
