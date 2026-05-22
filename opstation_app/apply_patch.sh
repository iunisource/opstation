#!/bin/bash
# Opstation Slice 1 — compile fix patch
#
# Run this from INSIDE your opstation_app folder (the one with pubspec.yaml in it).
# It fixes three compile errors by replacing two source files.
#
# Usage:
#   cd /path/to/opstation_app
#   bash apply_patch.sh

set -e

if [ ! -f pubspec.yaml ] || ! grep -q "name: opstation" pubspec.yaml; then
  echo "ERROR: Run this from inside the opstation_app folder (where pubspec.yaml lives)."
  exit 1
fi

echo "Patching lib/core/router/app_router.dart ..."
cat > lib/core/router/app_router.dart <<'DART'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/presentation/admin_home_screen.dart';
import '../../features/auth/models/user_role.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/splash_screen.dart';
import '../../features/auth/providers/auth_controller.dart';
import '../../features/dispatch_manager/presentation/dispatch_home_screen.dart';
import '../../features/driver/presentation/driver_home_screen.dart';
import '../../features/master_admin/presentation/master_admin_home_screen.dart';
import '../../features/salesperson/presentation/salesperson_home_screen.dart';
import '../../features/surveyor/presentation/surveyor_home_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    debugLogDiagnostics: false,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loggedIn = auth.valueOrNull != null;
      final loc = state.matchedLocation;

      if (auth.isLoading) return '/';

      final atSplash = loc == '/';
      final atLogin = loc == '/login';

      if (!loggedIn) {
        return atLogin ? null : '/login';
      }

      if (atSplash || atLogin) {
        return auth.value!.role.homeRoute;
      }

      return null;
    },
    refreshListenable: _RouterRefresh(ref),
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/salesperson',
        builder: (_, __) => const SalespersonHomeScreen(),
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
        path: '/surveyor',
        builder: (_, __) => const SurveyorHomeScreen(),
      ),
      GoRoute(
        path: '/dispatch',
        builder: (_, __) => const DispatchHomeScreen(),
      ),
      GoRoute(
        path: '/driver',
        builder: (_, __) => const DriverHomeScreen(),
      ),
    ],
  );
});

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(authControllerProvider, (_, __) => notifyListeners());
  }
}
DART

echo "Patching lib/core/theme/app_theme.dart ..."
# Replace CardTheme( with CardThemeData( — works on both light and dark theme blocks.
# Using Python for safe in-place edit across platforms.
python3 - <<'PY'
import pathlib
p = pathlib.Path('lib/core/theme/app_theme.dart')
s = p.read_text()
s = s.replace('cardTheme: CardTheme(', 'cardTheme: CardThemeData(')
p.write_text(s)
PY

echo
echo "Patch applied. Now run:"
echo "  flutter run -d emulator-5554"
echo "or:"
echo "  flutter run -d macos"
