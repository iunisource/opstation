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
        ],
      ),
    ],
  );
});
