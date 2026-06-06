import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/auth/auth_controller.dart';
import 'permission_registry.dart';

/// Resolved access for the logged-in user. Consulted by the menu, the router,
/// and individual screens.
///
/// Rules:
///  - superAdmin / masterAdmin / admin  => full access (incl. delete), all branches.
///  - everyone else  => governed by granted permission rows in user_permissions.
///  - Delete is NEVER a per-user grant; it is role-gated to admins.
///  - Org modules gate everyone (a disabled module hides its whole section).
///
/// Branch-scoped permissions (Option A):
///  - A user_permissions row with branch_id IS NULL is a GLOBAL grant: it applies
///    at every branch the user operates in.
///  - A row with branch_id = '<branch>' grants that permission ONLY at that branch.
///  - This lets one user be e.g. a purchaser at the backoffice and a salesperson
///    at retail by holding (doc.po.add, backoffice) and (doc.so.add, retail).
///
/// Two flavours of check:
///  - Reachability (no branch arg) — "can the user do this at SOME branch?" Used by
///    the menu and router to decide whether a screen is reachable at all.
///  - At-branch (`...At(key, branchId)`) — "can the user do this AT this branch?"
///    Used by screens to gate Add/Edit/Save against the active (or voucher's) branch.
class AccessControl {
  final WebUserRole? role;
  final Set<String> orgModules; // enabled modules for the org
  final Set<String> globalPerms; // branch_id IS NULL grants (apply everywhere)
  final Map<String, Set<String>> branchPerms; // branchId -> granted permission keys
  final Set<String> branchIds; // allocated branches (admins => all)
  const AccessControl({
    this.role,
    this.orgModules = const {},
    this.globalPerms = const {},
    this.branchPerms = const {},
    this.branchIds = const {},
  });

  /// Backward-compatible view: the union of every permission the user holds
  /// anywhere (global + all branches). Kept so older read-only callers of
  /// `access.perms` keep working.
  Set<String> get perms =>
      {...globalPerms, for (final s in branchPerms.values) ...s};

  bool get isSuperAdmin => role == WebUserRole.superAdmin;
  bool get isAdmin =>
      role == WebUserRole.superAdmin ||
      role == WebUserRole.masterAdmin ||
      role == WebUserRole.admin;

  bool hasModule(String m) => isSuperAdmin ? true : orgModules.contains(m);

  // ---- internal helpers --------------------------------------------------

  /// True if the permission is granted at ANY branch (or globally, or admin).
  bool _hasAnywhere(String p) =>
      isAdmin ||
      globalPerms.contains(p) ||
      branchPerms.values.any((s) => s.contains(p));

  /// True if the permission is granted AT the given branch (global grants count;
  /// admins always pass). A null branch falls back to global-only.
  bool _hasAt(String p, String? branchId) =>
      isAdmin ||
      globalPerms.contains(p) ||
      (branchId != null && (branchPerms[branchId]?.contains(p) ?? false));

  // ---- reachability (menu / router): allowed at SOME branch --------------

  bool canAddDoc(String key) => _hasAnywhere('doc.$key.add');
  bool canEditDoc(String key) => _hasAnywhere('doc.$key.edit');
  bool canViewReport(String key) => _hasAnywhere('report.$key.view');
  bool canDelete() => isAdmin; // role-gated, never a per-user toggle

  /// A doc screen is visible if the user can add OR edit it anywhere.
  bool canSeeDoc(String key) => canAddDoc(key) || canEditDoc(key);

  // ---- at-branch (screens): allowed AT a specific branch -----------------

  bool canAddDocAt(String key, String? branchId) =>
      _hasAt('doc.$key.add', branchId);
  bool canEditDocAt(String key, String? branchId) =>
      _hasAt('doc.$key.edit', branchId);
  bool canViewReportAt(String key, String? branchId) =>
      _hasAt('report.$key.view', branchId);

  /// A doc screen is editable at a branch if the user can add OR edit there.
  bool canSeeDocAt(String key, String? branchId) =>
      canAddDocAt(key, branchId) || canEditDocAt(key, branchId);

  // ---- routing -----------------------------------------------------------

  /// Route-level gate used by the menu and the router. Reachability-based: a
  /// route is open if the user can act on it at any of their branches.
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

  // Non-admin: load granted permissions (split global vs per-branch) + branches.
  final Set<String> globalPerms = {};
  final Map<String, Set<String>> branchPerms = {};
  Set<String> branches = {};
  try {
    final p = await client
        .from('user_permissions')
        .select('permission, branch_id')
        .eq('user_id', user.id);
    for (final r in p as List) {
      final perm = r['permission'] as String?;
      if (perm == null) continue;
      final bid = r['branch_id'] as String?;
      if (bid == null) {
        globalPerms.add(perm);
      } else {
        (branchPerms[bid] ??= <String>{}).add(perm);
      }
    }
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
    globalPerms: globalPerms,
    branchPerms: branchPerms,
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
