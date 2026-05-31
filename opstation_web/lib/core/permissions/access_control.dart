import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/auth/auth_controller.dart';
import 'permission_registry.dart';

/// Resolved access for the logged-in user. Consulted by the menu, the router,
/// and individual screens.
///
/// Rules:
///  - superAdmin / masterAdmin / admin  => full access (incl. delete).
///  - everyone else  => governed by granted permission rows in user_permissions.
///  - Delete is NEVER a per-user grant; it is role-gated to admins.
///  - Org modules gate everyone (a disabled module hides its whole section).
class AccessControl {
  final WebUserRole? role;
  final Set<String> orgModules; // enabled modules for the org
  final Set<String> perms; // granted permission keys (non-admins)
  final Set<String> branchIds; // allocated branches (admins => all)
  const AccessControl({
    this.role,
    this.orgModules = const {},
    this.perms = const {},
    this.branchIds = const {},
  });

  bool get isSuperAdmin => role == WebUserRole.superAdmin;
  bool get isAdmin =>
      role == WebUserRole.superAdmin ||
      role == WebUserRole.masterAdmin ||
      role == WebUserRole.admin;

  bool hasModule(String m) => isSuperAdmin ? true : orgModules.contains(m);

  bool canAddDoc(String key) => isAdmin || perms.contains('doc.$key.add');
  bool canEditDoc(String key) => isAdmin || perms.contains('doc.$key.edit');
  bool canDelete() => isAdmin; // role-gated, never a per-user toggle
  bool canViewReport(String key) => isAdmin || perms.contains('report.$key.view');

  /// A doc screen is visible if the user can add OR edit it.
  bool canSeeDoc(String key) => canAddDoc(key) || canEditDoc(key);

  /// Route-level gate used by the menu and the router.
  bool canAccessRoute(String route) {
    if (isAdmin) return true;
    final it = kRouteToPerm[route];
    if (it == null) return true; // not a gated ERP doc/report
    final mod = kRouteToModule[route];
    if (mod != null && !hasModule(mod)) return false;
    return it.kind == PermKind.report
        ? canViewReport(it.key)
        : canSeeDoc(it.key);
  }
}

final accessProvider = FutureProvider<AccessControl>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return const AccessControl();
  final client = Supabase.instance.client;

  // Org modules (gates everyone, including admins, for menu visibility).
  Set<String> modules = {};
  if (user.orgId != null) {
    try {
      final res = await client
          .from('org_modules')
          .select('module')
          .eq('org_id', user.orgId!)
          .eq('is_enabled', true);
      modules = {for (final r in res as List) r['module'] as String};
    } catch (_) {}
  }

  final role = user.role;
  if (role == WebUserRole.superAdmin ||
      role == WebUserRole.masterAdmin ||
      role == WebUserRole.admin) {
    return AccessControl(role: role, orgModules: modules);
  }

  // Non-admin: load granted permissions + branch allocations.
  Set<String> perms = {};
  Set<String> branches = {};
  try {
    final p = await client
        .from('user_permissions')
        .select('permission')
        .eq('user_id', user.id);
    perms = {for (final r in p as List) r['permission'] as String};
  } catch (_) {}
  try {
    final b = await client
        .from('erp_user_branches')
        .select('branch_id')
        .eq('user_id', user.id);
    branches = {for (final r in b as List) r['branch_id'] as String};
  } catch (_) {}

  return AccessControl(
    role: role,
    orgModules: modules,
    perms: perms,
    branchIds: branches,
  );
});

/// Synchronous accessor for widgets/router. Returns null while (re)loading —
/// notably during a page refresh — so the router treats access as "unknown"
/// and does NOT bounce the user off their current route while perms reload.
/// (Without this, Riverpod hands back the previous/empty value during the
/// reload, which looked like "loaded with no access" and forced a redirect.)
final accessSyncProvider = Provider<AccessControl?>((ref) {
  final a = ref.watch(accessProvider);
  if (a.isLoading) return null;
  return a.valueOrNull;
});
