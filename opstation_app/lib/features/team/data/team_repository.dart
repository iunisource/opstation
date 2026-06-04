import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/password_hasher.dart';
import '../../../core/database/app_database.dart';
import '../../../core/supabase/supabase_sync_service.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../models/team_user.dart';

/// Default password for seeded demo accounts. First-run migration sets this;
/// users can change it via the Change Password flow.
const kDefaultDemoPassword = 'opstation123';

class TeamRepository {
  final AppDatabase _db;
  final String? _orgId;
  SupabaseSyncService? _sync;
  TeamRepository(this._db, {String? orgId, SupabaseSyncService? sync}) : _orgId = orgId, _sync = sync;

  // ---- Seeding --------------------------------------------------------

  /// Insert the bootstrap user list on first run (idempotent — uses
  /// insertOnConflictUpdate but only for NEW rows to avoid stomping
  /// password changes).
  Future<void> seedIfEmpty() async {
    final count = await (_db.select(_db.users)..limit(1)).get();
    if (count.isNotEmpty) return;

    // Only seed the super admin — all other users are created through
    // the admin UI per org. Demo accounts removed for production use.
    final now = DateTime.now();
    final salt = PasswordHasher.newSalt();
    final hash = PasswordHasher.hash(kDefaultDemoPassword, salt);
    await _db.into(_db.users).insertOnConflictUpdate(
          UsersCompanion.insert(
            id: 'u_super',
            name: 'Super Admin',
            email: 'superadmin@opstation.app',
            role: UserRole.superAdmin.name,
            createdAt: now,
            passwordHash: Value(hash),
            passwordSalt: Value(salt),
            passwordTemporary: const Value(false),
          ),
        );
  }

  // ---- Reads ----------------------------------------------------------

  Future<List<TeamUser>> all({bool includeInactive = true}) async {
    final q = _db.select(_db.users);
    if (!includeInactive) q.where((u) => u.isActive.equals(true));
    // Super admin has no orgId — always visible to themselves.
    // Other users: filter to the current org only.
    if (_orgId != null) {
      // Exact-org match only. The old `u.orgId.isNull()` allowance let any
      // null-org row show in every org's team (the cross-org team leak).
      q.where((u) =>
          u.orgId.equals(_orgId!) |
          u.role.equals(UserRole.superAdmin.name));
    }
    q.orderBy([(u) => OrderingTerm.asc(u.name)]);
    final rows = await q.get();
    return rows.map(_fromRow).toList();
  }

  Future<TeamUser?> byId(String id) async {
    final row = await (_db.select(_db.users)..where((u) => u.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<TeamUser?> byEmail(String email) async {
    final row = await (_db.select(_db.users)
          ..where((u) => u.email.lower().equals(email.toLowerCase())))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// Fetches a user and verifies the password against the stored hash.
  /// Returns null if email not found, user is inactive, user's org is
  /// disabled, or password is wrong.
  Future<TeamUser?> authenticate({
    required String email,
    required String password,
  }) async {
    final row = await (_db.select(_db.users)
          ..where((u) => u.email.lower().equals(email.toLowerCase().trim())))
        .getSingleOrNull();
    if (row == null) return null;
    if (!row.isActive) return null;
    if (!PasswordHasher.verify(password, row.passwordSalt, row.passwordHash)) {
      return null;
    }
    // Org-level gate. Super admin is not tied to an org (orgId is null)
    // and is always allowed to log in regardless of org status.
    if (row.orgId != null) {
      final orgRow = await (_db.select(_db.orgs)
            ..where((o) => o.id.equals(row.orgId!)))
          .getSingleOrNull();
      if (orgRow != null && !orgRow.isActive) {
        // Surface a specific error string so the UI can distinguish
        // "wrong password" from "your org is disabled". A null return
        // would be indistinguishable from the other denial paths.
        throw StateError(
            'Your organization has been disabled. Contact your administrator.');
      }
    }
    return _fromRow(row);
  }

  TeamUser _fromRow(UsersData r) {
    return TeamUser(
      id: r.id,
      name: r.name,
      email: r.email,
      phone: r.phone,
      role: UserRoleX.fromKey(r.role) ?? UserRole.salesperson,
      isActive: r.isActive,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
      passwordTemporary: r.passwordTemporary,
      orgId: r.orgId,
    );
  }

  // ---- Writes ---------------------------------------------------------

  /// Creates a new user with the given password. Throws if the email is
  /// already taken. [orgId] ties this user to an organization — null is
  /// permitted only for super admins (who are app-level, not org-level).
  Future<TeamUser> create({
    required String name,
    required String email,
    required String phone,
    required UserRole role,
    required String password,
    bool passwordTemporary = true,
    String? orgId,
  }) async {
    final existing = await byEmail(email);
    if (existing != null) {
      throw StateError('A user with this email already exists.');
    }
    final id = 'user_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now();
    final salt = PasswordHasher.newSalt();
    final hash = PasswordHasher.hash(password, salt);
    await _db.into(_db.users).insert(UsersCompanion.insert(
          id: id,
          name: name.trim(),
          email: email.toLowerCase().trim(),
          phone: Value(phone.trim()),
          role: role.name,
          createdAt: now,
          isActive: const Value(true),
          passwordHash: Value(hash),
          passwordSalt: Value(salt),
          passwordTemporary: Value(passwordTemporary),
          orgId: Value(orgId),
        ));
    final created = await byId(id);
    try {
      final row = await (_db.select(_db.users)..where((u) => u.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync?.pushUser(row);
    } catch (_) {}
    return created!;
  }

  Future<TeamUser> updateProfile({
    required String id,
    required String name,
    required String email,
    required String phone,
    required UserRole role,
  }) async {
    // Check for email collision on a different user.
    final existing = await byEmail(email);
    if (existing != null && existing.id != id) {
      throw StateError('A user with this email already exists.');
    }
    final now = DateTime.now();
    await (_db.update(_db.users)..where((u) => u.id.equals(id))).write(
      UsersCompanion(
        name: Value(name.trim()),
        email: Value(email.toLowerCase().trim()),
        phone: Value(phone.trim()),
        role: Value(role.name),
        updatedAt: Value(now),
      ),
    );
    final updated = await byId(id);
    try {
      final row = await (_db.select(_db.users)..where((u) => u.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync?.pushUser(row);
    } catch (_) {}
    return updated!;
  }

  Future<void> setActive({required String id, required bool active}) async {
    final now = DateTime.now();
    await (_db.update(_db.users)..where((u) => u.id.equals(id))).write(
      UsersCompanion(
        isActive: Value(active),
        updatedAt: Value(now),
      ),
    );
    try {
      final row = await (_db.select(_db.users)..where((u) => u.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync?.pushUser(row);
    } catch (_) {}
  }

  /// Admin-triggered password reset. Marks the new password as
  /// [passwordTemporary] so the UI can nudge the user to change it.
  Future<void> resetPassword({
    required String id,
    required String newPassword,
  }) async {
    final salt = PasswordHasher.newSalt();
    final hash = PasswordHasher.hash(newPassword, salt);
    final now = DateTime.now();
    await (_db.update(_db.users)..where((u) => u.id.equals(id))).write(
      UsersCompanion(
        passwordSalt: Value(salt),
        passwordHash: Value(hash),
        passwordTemporary: const Value(true),
        updatedAt: Value(now),
      ),
    );
    // Push to Supabase so the remote hash stays in sync. Without this,
    // the next pull would overwrite local with the stale remote hash and
    // the old password would start working again.
    try {
      final row = await (_db.select(_db.users)..where((u) => u.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync?.pushUser(row);
    } catch (_) {}
  }

  /// User-initiated password change. Verifies the current password first.
  Future<bool> changeOwnPassword({
    required String id,
    required String currentPassword,
    required String newPassword,
  }) async {
    final row = await (_db.select(_db.users)..where((u) => u.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return false;
    if (!PasswordHasher.verify(
        currentPassword, row.passwordSalt, row.passwordHash)) {
      return false;
    }
    final salt = PasswordHasher.newSalt();
    final hash = PasswordHasher.hash(newPassword, salt);
    final now = DateTime.now();
    await (_db.update(_db.users)..where((u) => u.id.equals(id))).write(
      UsersCompanion(
        passwordSalt: Value(salt),
        passwordHash: Value(hash),
        passwordTemporary: const Value(false),
        updatedAt: Value(now),
      ),
    );
    try {
      final row = await (_db.select(_db.users)..where((u) => u.id.equals(id))).getSingleOrNull();
      if (row != null) await _sync?.pushUser(row);
    } catch (_) {}
    return true;
  }
}

// NOTE: TeamRepository intentionally has NO org scoping here.
// It is used by MockAuthRepository during login — at that point
// authControllerProvider has no value yet, so orgIdProvider would
// return null and, worse, create a circular dependency:
//   authController → mockAuthRepo → teamRepo → orgIdProvider → authController
//
// Team list org-filtering is handled inside TeamListScreen via the
// auth controller directly, which already knows the current user's org.
final teamRepositoryProvider = Provider<TeamRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final sync = ref.watch(supabaseSyncServiceProvider);
  return TeamRepository(db, sync: sync);
});
