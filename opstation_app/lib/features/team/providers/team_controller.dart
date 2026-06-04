import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../audit/data/audit_repository.dart';
import '../../auth/providers/auth_controller.dart' show supabaseAuthServiceProvider;
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../../auth/models/auth_user.dart' as app;
import '../data/team_repository.dart';
import '../models/team_user.dart';

/// Filters applied to the team list.
class TeamFilters {
  final String query;
  final bool includeInactive;
  final UserRole? roleFilter;

  const TeamFilters({
    this.query = '',
    this.includeInactive = false,
    this.roleFilter,
  });

  TeamFilters copyWith({
    String? query,
    bool? includeInactive,
    UserRole? roleFilter,
    bool clearRole = false,
  }) {
    return TeamFilters(
      query: query ?? this.query,
      includeInactive: includeInactive ?? this.includeInactive,
      roleFilter: clearRole ? null : (roleFilter ?? this.roleFilter),
    );
  }

  bool get isDefault =>
      query.isEmpty && !includeInactive && roleFilter == null;
}

class TeamState {
  final List<TeamUser> all;
  final TeamFilters filters;

  const TeamState({
    this.all = const [],
    this.filters = const TeamFilters(),
  });

  TeamState copyWith({List<TeamUser>? all, TeamFilters? filters}) {
    return TeamState(
      all: all ?? this.all,
      filters: filters ?? this.filters,
    );
  }

  List<TeamUser> get filtered {
    final q = filters.query.trim().toLowerCase();
    return all.where((u) {
      if (!filters.includeInactive && !u.isActive) return false;
      if (filters.roleFilter != null && u.role != filters.roleFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      return u.name.toLowerCase().contains(q) ||
          u.email.toLowerCase().contains(q) ||
          u.phone.toLowerCase().contains(q);
    }).toList();
  }

  /// Count by role (for the list header chips).
  Map<UserRole, int> get countByRole {
    final map = <UserRole, int>{};
    for (final u in all.where((u) => u.isActive)) {
      map[u.role] = (map[u.role] ?? 0) + 1;
    }
    return map;
  }
}

class TeamController extends AsyncNotifier<TeamState> {
  TeamRepository get _repo => ref.read(teamRepositoryProvider);

  /// Current user's org ID — used when CREATING users so they inherit the
  /// admin's org. Null for super admin. (Display scoping is _scopeToOrg.)
  String? get _orgId =>
      ref.read(authControllerProvider).valueOrNull?.organizationId;

  /// Scope the full local user list to what the current viewer may see.
  ///   • auth not resolved yet (null): show NOTHING. During login
  ///     valueOrNull is briefly null; returning the full list in that window
  ///     was the real cross-org leak — the team dumped every device-local
  ///     user regardless of org until auth caught up.
  ///   • super admin: sees everyone.
  ///   • org user: exact-org match only — a null-org or other-org row can
  ///     never appear in another org's team.
  List<TeamUser> _scopeToOrg(List<TeamUser> all, app.AuthUser? auth) {
    if (auth == null) return const [];
    if (auth.role == UserRole.superAdmin) return all;
    final orgId = auth.organizationId;
    if (orgId == null) return const [];
    return all
        .where((u) => u.role != UserRole.superAdmin && u.orgId == orgId)
        .toList();
  }

  @override
  Future<TeamState> build() async {
    // WATCH (not read) auth: the instant login resolves the user/org this
    // controller re-runs and re-scopes. Reading would freeze the empty
    // null-auth result taken during the login window.
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final all = _scopeToOrg(await _repo.all(includeInactive: true), auth);
    return TeamState(all: all);
  }

  Future<void> refresh() async {
    final auth = ref.read(authControllerProvider).valueOrNull;
    final all = _scopeToOrg(await _repo.all(includeInactive: true), auth);
    final current = state.valueOrNull;
    state = AsyncData((current ?? const TeamState()).copyWith(all: all));
  }

  void updateFilters(TeamFilters filters) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(filters: filters));
  }

  Future<TeamUser> create({
    required String name,
    required String email,
    required String phone,
    required UserRole role,
    required String password,
    String? orgId,
  }) async {
    // Default to the current admin's org so newly-created users
    // auto-inherit org scope. Super admin (no org) is unaffected.
    final effectiveOrgId = orgId ?? _orgId;

    // Enforce org max_users limit if set. Best-effort — if the network call
    // fails for a reason other than the limit, allow creation (sync resolves
    // mismatches later). If we can verify and we're at limit, block.
    if (effectiveOrgId != null) {
      try {
        final supa = Supabase.instance.client;
        final orgRow = await supa
            .from('orgs')
            .select('max_users')
            .eq('id', effectiveOrgId)
            .maybeSingle();
        final maxUsers = orgRow?['max_users'] as int?;
        if (maxUsers != null) {
          final users = await supa
              .from('users')
              .select('id')
              .eq('org_id', effectiveOrgId);
          if ((users as List).length >= maxUsers) {
            throw Exception('User limit reached for your organization. Contact your super admin to raise the limit.');
          }
        }
      } catch (e) {
        if (e.toString().contains('User limit reached')) rethrow;
        // network / other errors: skip the check
      }
    }

    final user = await _repo.create(
      name: name,
      email: email,
      phone: phone,
      role: role,
      password: password,
      passwordTemporary: true,
      orgId: effectiveOrgId,
    );

    // Also create in Supabase Auth so the user can log in when online.
    // Best-effort — if Supabase is unreachable the user still exists
    // locally and can log in via local fallback until sync catches up.
    try {
      await ref.read(supabaseAuthServiceProvider).createUser(
        email: email,
        password: password,
      );
    } catch (_) {
      // Supabase unavailable or user already exists — safe to ignore.
    }

    await ref.read(auditLoggerProvider).userCreated(user);
    await refresh();
    return user;
  }

  Future<TeamUser> updateProfile({
    required String id,
    required String name,
    required String email,
    required String phone,
    required UserRole role,
  }) async {
    final before = await _repo.byId(id);
    final user = await _repo.updateProfile(
      id: id,
      name: name,
      email: email,
      phone: phone,
      role: role,
    );
    if (before != null) {
      await ref.read(auditLoggerProvider).userUpdated(before, user);
    }
    await refresh();
    return user;
  }

  Future<void> setActive(String id, bool active) async {
    final before = await _repo.byId(id);
    await _repo.setActive(id: id, active: active);
    final after = await _repo.byId(id);
    if (before != null && after != null) {
      await ref.read(auditLoggerProvider).userUpdated(before, after);
    }
    await refresh();
  }

  Future<void> resetPassword(String id, String newPassword) async {
    await _repo.resetPassword(id: id, newPassword: newPassword);

    // Sync new password to Supabase Auth best-effort.
    try {
      await ref.read(supabaseAuthServiceProvider).updatePassword(newPassword);
    } catch (_) {
      // Best-effort — local password is always the fallback.
    }

    await refresh();
  }

  Future<bool> changeOwnPassword({
    required String id,
    required String currentPassword,
    required String newPassword,
  }) async {
    final ok = await _repo.changeOwnPassword(
      id: id,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    if (ok) await refresh();
    return ok;
  }
}

final teamControllerProvider =
    AsyncNotifierProvider<TeamController, TeamState>(TeamController.new);

/// Roles that a given actor is allowed to CREATE. Matches Q3 strict policy:
///   Super Admin   -> Master Admin + all non-admin roles (not Super Admin itself)
///   Master Admin  -> Admin + all non-admin roles (not Master Admin itself)
///   Admin         -> non-admin roles only (Salesperson, Surveyor, Driver, Dispatch, Accountant)
///   Everyone else -> nothing
List<UserRole> assignableRolesFor(UserRole? actor) {
  if (actor == null) return const [];
  switch (actor) {
    case UserRole.superAdmin:
      return const [
        UserRole.masterAdmin,
        UserRole.admin,
        UserRole.salesperson,
        UserRole.surveyor,
        UserRole.dispatchManager,
        UserRole.driver,
        UserRole.accountant,
      ];
    case UserRole.masterAdmin:
      return const [
        UserRole.admin,
        UserRole.salesperson,
        UserRole.surveyor,
        UserRole.dispatchManager,
        UserRole.driver,
        UserRole.accountant,
      ];
    case UserRole.admin:
      return const [
        UserRole.salesperson,
        UserRole.surveyor,
        UserRole.dispatchManager,
        UserRole.driver,
        UserRole.accountant,
      ];
    default:
      return const [];
  }
}

bool canManageTeam(UserRole? role) =>
    assignableRolesFor(role).isNotEmpty;

/// Can [actor] edit the user with [targetRole]?
///   Super Admin — can edit anyone
///   Master Admin — can edit anyone except Super Admin
///   Admin — can edit non-admin roles only
///   Others — never
bool canEditTargetUser({required UserRole? actor, required UserRole targetRole}) {
  if (actor == null) return false;
  switch (actor) {
    case UserRole.superAdmin:
      return true;
    case UserRole.masterAdmin:
      return targetRole != UserRole.superAdmin;
    case UserRole.admin:
      return targetRole != UserRole.superAdmin &&
          targetRole != UserRole.masterAdmin &&
          targetRole != UserRole.admin;
    default:
      return false;
  }
}
