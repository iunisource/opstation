import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/presentation/admin_home_screen.dart';
import '../../features/admin_settings/presentation/admin_settings_screen.dart';
import '../../features/auth/models/user_role.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/splash_screen.dart';
import '../../features/auth/providers/auth_controller.dart';
import '../../features/retailer/retailer_auth_controller.dart';
import '../../features/retailer/presentation/retailer_change_password_screen.dart';
import '../../features/retailer/presentation/retailer_home_screen.dart';
import '../../features/retailer/presentation/retailer_login_screen.dart';
import '../../features/retailer/presentation/role_picker_screen.dart';
import '../../features/customers/presentation/customer_detail_screen.dart';
import '../../features/customers/presentation/customer_form_screen.dart';
import '../../features/customers/presentation/customers_list_screen.dart';
import '../../features/customers/presentation/location_wizard_screen.dart';
import '../../features/dispatch/presentation/delivery_detail_screen.dart';
import '../../features/dispatch/presentation/delivery_wizard_screen.dart';
import '../../features/dispatch_manager/presentation/dispatch_delivery_history_screen.dart';
import '../../features/dispatch_manager/presentation/dispatch_home_screen.dart';
import '../../features/driver/presentation/delivery_execution_screen.dart';
import '../../features/driver/presentation/driver_history_screen.dart';
import '../../features/driver/presentation/driver_reports_screen.dart';
import '../../features/driver/presentation/driver_home_screen.dart';
import '../../features/orgs/presentation/org_detail_screen.dart';
import '../../features/master_admin/presentation/master_admin_home_screen.dart';
import '../../features/master_admin/presentation/super_admin_home_screen.dart';
import '../../features/monitoring/presentation/monitoring_screen.dart';
import '../../features/monitoring/presentation/salesperson_monitoring_screen.dart';
import '../../features/audit/presentation/audit_log_screen.dart';
import '../../features/accountant/presentation/accountant_home_screen.dart';
import '../../features/compliance/presentation/compliance_screen.dart';
import '../../features/reports/presentation/coverage_report_screen.dart';
import '../../features/reports/presentation/reports_screen.dart';
import '../../shared/widgets/coming_soon_screen.dart';
import '../../features/admin_settings/presentation/notification_settings_screen.dart';
import '../../features/routes/presentation/route_detail_screen.dart';
import '../../features/routes/presentation/route_form_screen.dart';
import '../../features/routes/presentation/routes_list_screen.dart';
import '../../features/salesperson/presentation/route_history_screen.dart';
import '../../features/salesperson/presentation/route_in_progress_screen.dart';
import '../../features/salesperson/presentation/salesperson_files_screen.dart';
import '../../features/salesperson/presentation/salesperson_home_screen.dart';
import '../../features/surveyor/presentation/surveyor_home_screen.dart';
import '../../features/surveyor/presentation/placement_audit_screen.dart';
import '../../features/surveyor/presentation/competitor_spotting_screen.dart';
import '../../features/team/presentation/change_password_screen.dart';
import '../../features/team/presentation/team_list_screen.dart';
import '../../features/team/presentation/user_detail_screen.dart';
import '../../features/team/presentation/user_form_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    debugLogDiagnostics: false,
    redirect: (context, state) {
      // Two INDEPENDENT sessions coexist here:
      //   - staff    (authControllerProvider)  resolves only from the
      //              'opstation_session' prefs key
      //   - retailer (retailerAuthControllerProvider) resolves only from a live
      //              Supabase session + its own prefs marker
      // Neither can satisfy the other's check, so at most one is ever non-null.
      // Retailers are checked first: a shopkeeper who signs in should never be
      // routed into a staff home even if a stale staff key somehow lingers.
      final auth = ref.read(authControllerProvider);
      final rAuth = ref.read(retailerAuthControllerProvider);

      final loc = state.matchedLocation;
      final atSplash = loc == '/';
      final atPicker = loc == '/pick';
      final atStaffLogin = loc == '/login';
      final atRetailerLogin = loc == '/r/login';
      final atRetailerPassword = loc == '/r/password';

      // While either controller is loading, hold on splash — unless a sign-in
      // is in flight on a login screen, which must stay mounted so it can
      // surface its own error instead of being swapped out (which drops it).
      if (auth.isLoading || rAuth.isLoading) {
        return (atStaffLogin || atRetailerLogin) ? null : '/';
      }

      final retailer = rAuth.valueOrNull;
      final staff = auth.valueOrNull;

      if (retailer != null) {
        // Provisioned with their CODE as the password — force a real one before
        // anything else is reachable.
        if (retailer.mustChangePassword) {
          return atRetailerPassword ? null : '/r/password';
        }
        if (atSplash ||
            atPicker ||
            atStaffLogin ||
            atRetailerLogin ||
            atRetailerPassword) {
          return '/r';
        }
        return null;
      }

      if (staff != null) {
        if (atSplash || atPicker || atStaffLogin || atRetailerLogin) {
          return staff.role.homeRoute;
        }
        return null;
      }

      // Nobody signed in. The picker remembers the last door used, so returning
      // staff are not taxed a tap every day.
      if (atStaffLogin || atRetailerLogin || atPicker) return null;
      return '/pick';
    },
    refreshListenable: _RouterRefresh(ref),
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/pick', builder: (_, __) => const RolePickerScreen()),
      GoRoute(path: '/r/login', builder: (_, __) => const RetailerLoginScreen()),
      GoRoute(path: '/r/password', builder: (_, __) => const RetailerChangePasswordScreen()),
      GoRoute(path: '/r', builder: (_, __) => const RetailerHomeScreen()),
      GoRoute(
        path: '/salesperson',
        builder: (_, __) => const SalespersonHomeScreen(),
        routes: [
          GoRoute(
            path: 'route',
            builder: (_, __) => const RouteInProgressScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/admin',
        builder: (_, __) => const AdminHomeScreen(),
      ),
      GoRoute(
        path: '/master-admin',
        builder: (_, __) => const MasterAdminHomeScreen(),
      ),
      GoRoute(
        path: '/super-admin',
        builder: (_, __) => const SuperAdminHomeScreen(),
      ),
      GoRoute(
        path: '/super-admin/org/:id',
        builder: (_, state) => OrgDetailScreen(
          orgId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/surveyor',
        builder: (_, __) => const SurveyorHomeScreen(),
      ),
      GoRoute(
        path: '/placement-audit',
        builder: (_, __) => const PlacementAuditScreen(),
      ),
      GoRoute(
        path: '/competitor-spotting',
        builder: (_, __) => const CompetitorSpottingScreen(),
      ),
      GoRoute(
        path: '/dispatch',
        builder: (_, __) => const DispatchHomeScreen(),
      ),
      GoRoute(
        path: '/accountant',
        builder: (_, __) => const AccountantHomeScreen(),
      ),
      GoRoute(
        path: '/dispatch/history',
        builder: (_, __) => const DispatchDeliveryHistoryScreen(),
      ),
      GoRoute(
        path: '/dispatch/delivery/new',
        builder: (_, __) => const DeliveryWizardScreen(),
      ),
      GoRoute(
        path: '/dispatch/delivery/:id',
        builder: (_, state) =>
            DeliveryDetailScreen(deliveryId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/dispatch/delivery/:id/edit',
        builder: (_, state) =>
            DeliveryWizardScreen(existingId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/admin/deliveries',
        builder: (_, __) => const DispatchHomeScreen(),
      ),
      GoRoute(
        path: '/driver',
        builder: (_, __) => const DriverHomeScreen(),
      ),
      GoRoute(
        path: '/driver/delivery/:id',
        builder: (_, state) => DeliveryExecutionScreen(
          deliveryId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/driver/history',
        builder: (_, __) => const DriverHistoryScreen(),
      ),
      GoRoute(
        path: '/driver/reports',
        builder: (_, __) => const DriverReportsScreen(),
      ),
      GoRoute(
        path: '/admin/settings',
        builder: (_, __) => const AdminSettingsScreen(),
      ),
      GoRoute(
        path: '/admin/monitoring',
        builder: (_, __) => const MonitoringScreen(),
        routes: [
          GoRoute(
            path: 'user/:id',
            builder: (_, s) =>
                SalespersonMonitoringScreen(userId: s.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: '/admin/routes',
        builder: (_, __) => const RoutesListScreen(),
        routes: [
          GoRoute(
            path: 'new',
            builder: (_, __) => const RouteFormScreen(),
          ),
          GoRoute(
            path: ':id',
            builder: (_, s) =>
                RouteDetailScreen(routeId: s.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'edit',
                builder: (_, s) =>
                    RouteFormScreen(routeId: s.pathParameters['id']),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/admin/reports',
        builder: (_, __) => const ReportsScreen(),
      ),
      GoRoute(
        path: '/admin/coverage',
        builder: (_, __) => const CoverageReportScreen(),
      ),
      GoRoute(
        path: '/admin/compliance',
        builder: (_, __) => const ComplianceScreen(),
      ),
      GoRoute(
        path: '/admin/audit',
        builder: (_, __) => const AuditLogScreen(),
      ),
      GoRoute(
        path: '/admin/storage',
        builder: (_, __) => const ComingSoonScreen(
          title: 'Storage connection',
          heading: 'Google Drive for photos',
          icon: Icons.cloud_outlined,
          description:
              'Each organization connects its own Google Drive account to '
              'store visit and delivery photos, plus any other proof uploads. '
              'Photos captured by salespersons and drivers will queue on the '
              'device and upload to your Drive once online.',
          bullets: [
            'Connect / disconnect a Google account per organization',
            'Per-org root folder with trip-level subfolders',
            'Offline-safe upload queue with retry on reconnect',
            'Admin review can open original files directly in Drive',
            'Works alongside the upcoming delivery module (driver PoD photos)',
          ],
        ),
      ),
      GoRoute(
        path: '/admin/notifications',
        builder: (_, __) => const NotificationSettingsScreen(),
      ),
      GoRoute(
        path: '/salesperson/reports',
        builder: (_, s) => ReportsScreen(
          scopedUserId: s.uri.queryParameters['uid'],
        ),
      ),
      GoRoute(
        path: '/salesperson/history',
        builder: (_, __) => const RouteHistoryScreen(),
      ),
      GoRoute(
        path: '/salesperson/files',
        builder: (_, __) => const SalespersonFilesScreen(),
      ),
      GoRoute(
        path: '/admin/team/drivers',
        builder: (_, __) =>
            const TeamListScreen(initialRoleFilter: UserRole.driver),
      ),
      GoRoute(
        path: '/admin/team',
        builder: (_, __) => const TeamListScreen(),
        routes: [
          GoRoute(
            path: 'new',
            builder: (_, __) => const UserFormScreen(),
          ),
          GoRoute(
            path: ':id',
            builder: (_, s) =>
                UserDetailScreen(userId: s.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'edit',
                builder: (_, s) =>
                    UserFormScreen(userId: s.pathParameters['id']),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/account/password',
        builder: (_, __) => const ChangePasswordScreen(),
      ),
      GoRoute(
        path: '/customers',
        builder: (_, __) => const CustomersListScreen(),
        routes: [
          GoRoute(
            path: 'new',
            builder: (_, __) => const CustomerFormScreen(),
          ),
          GoRoute(
            path: ':id',
            builder: (_, s) =>
                CustomerDetailScreen(customerId: s.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'edit',
                builder: (_, s) => CustomerFormScreen(
                    customerId: s.pathParameters['id']),
              ),
              GoRoute(
                path: 'location',
                builder: (_, s) => LocationWizardScreen(
                    customerId: s.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// Bridges Riverpod auth state into go_router's Listenable-based refresh.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(authControllerProvider, (_, __) => notifyListeners());
    // Without this the router never re-evaluates when a retailer signs in or
    // out, and they would sit on the login screen after a successful sign-in.
    ref.listen(retailerAuthControllerProvider, (_, __) => notifyListeners());
  }
}
