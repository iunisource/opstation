#!/usr/bin/env python3
# Patches lib/core/router/app_router.dart to wire the retailer portal.
# Run from the web repo root:  python3 patch_app_router.py
import io, sys

P = 'lib/core/router/app_router.dart'
s = open(P, encoding='utf-8').read()
orig = s

def repl(old, new):
    global s
    if old not in s:
        print('ANCHOR NOT FOUND:\n' + old[:80] + ' ...')
        sys.exit(1)
    if s.count(old) != 1:
        print('ANCHOR NOT UNIQUE (%d):\n%s ...' % (s.count(old), old[:80]))
        sys.exit(1)
    s = s.replace(old, new)

# 1) imports
repl(
    "import '../layout/main_layout.dart';",
    "import '../layout/main_layout.dart';\n"
    "import '../../features/auth/retailer_auth_controller.dart';\n"
    "import '../../features/auth/presentation/retailer_login_screen.dart';\n"
    "import '../../features/retailer/presentation/retailer_portal_screen.dart';",
)

# 2) refresh listener also watches the retailer controller
repl(
    "    _ref.listen(authControllerProvider, (_, __) => notifyListeners());\n"
    "    _ref.listen(accessProvider, (_, __) => notifyListeners());",
    "    _ref.listen(authControllerProvider, (_, __) => notifyListeners());\n"
    "    _ref.listen(accessProvider, (_, __) => notifyListeners());\n"
    "    _ref.listen(retailerAuthControllerProvider, (_, __) => notifyListeners());",
)

# 3) redirect: retailer-aware branch before the staff logic
repl(
    "    redirect: (context, state) {\n"
    "      final auth = ref.read(authControllerProvider);\n"
    "      if (auth.isLoading) return null;\n"
    "      final user = auth.valueOrNull;\n"
    "      final loggedIn = user != null;\n"
    "      final loc = state.matchedLocation;\n"
    "      final onLogin = loc == '/login';\n"
    "      if (!loggedIn && !onLogin) return '/login';",
    "    redirect: (context, state) {\n"
    "      final auth = ref.read(authControllerProvider);\n"
    "      final rAuth = ref.read(retailerAuthControllerProvider);\n"
    "      if (auth.isLoading || rAuth.isLoading) return null;\n"
    "\n"
    "      final loc = state.matchedLocation;\n"
    "      final retailer = rAuth.valueOrNull;\n"
    "      final inRetailerArea = loc == '/r' || loc.startsWith('/r/');\n"
    "\n"
    "      // Retailer portal is a separate world from the staff panel.\n"
    "      if (retailer != null) {\n"
    "        if (!inRetailerArea || loc == '/r/login') return '/r';\n"
    "        return null;\n"
    "      }\n"
    "      if (inRetailerArea) {\n"
    "        return loc == '/r/login' ? null : '/r/login';\n"
    "      }\n"
    "\n"
    "      final user = auth.valueOrNull;\n"
    "      final loggedIn = user != null;\n"
    "      final onLogin = loc == '/login';\n"
    "      if (!loggedIn && !onLogin) return '/login';",
)

# 4) routes: add the two retailer routes next to /login (outside the ShellRoute)
repl(
    "      GoRoute(\n"
    "        path: '/login',\n"
    "        builder: (_, __) => const LoginScreen(),\n"
    "      ),",
    "      GoRoute(\n"
    "        path: '/login',\n"
    "        builder: (_, __) => const LoginScreen(),\n"
    "      ),\n"
    "      GoRoute(\n"
    "        path: '/r/login',\n"
    "        builder: (_, __) => const RetailerLoginScreen(),\n"
    "      ),\n"
    "      GoRoute(\n"
    "        path: '/r',\n"
    "        builder: (_, __) => const RetailerPortalScreen(),\n"
    "      ),",
)

if s == orig:
    print('No changes made.'); sys.exit(1)
open(P, 'w', encoding='utf-8').write(s)
print('Patched app_router.dart OK')
