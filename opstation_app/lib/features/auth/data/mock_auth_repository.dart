import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';
import '../models/auth_user.dart';
import '../models/user_role.dart';

/// DB-backed authentication.
///
/// Keeps the legacy class name [MockAuthRepository] so existing providers
/// and screens don't need rewiring. The "mock" prefix now just reflects
/// that this is still local-only — a real backend identity provider will
/// replace it in a future slice.
class MockAuthRepository {
  MockAuthRepository(this._team, this._db);
  final TeamRepository _team;
  final AppDatabase _db;

  Future<AuthUser> signIn({
    required String email,
    required String password,
  }) async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (email.trim().isEmpty) throw const AuthException('Email cannot be empty');
    if (password.isEmpty) throw const AuthException('Password cannot be empty');
    final TeamUser? user;
    try {
      user = await _team.authenticate(email: email, password: password);
    } on StateError catch (e) {
      throw AuthException(e.message);
    }
    if (user == null) throw const AuthException('Invalid email or password');
    return AuthUser(
      id: user.id,
      name: user.name,
      email: user.email,
      role: user.role,
      organizationId: user.orgId,
      organizationName: await _resolveOrgName(user),
    );
  }

  Future<String?> _resolveOrgName(TeamUser user) async {
    if (user.role == UserRole.superAdmin || user.orgId == null) return null;
    final row = await (_db.select(_db.orgs)
          ..where((o) => o.id.equals(user.orgId!)))
        .getSingleOrNull();
    return row?.name;
  }

  Future<void> signOut() async {
    await Future.delayed(const Duration(milliseconds: 200));
  }

  /// Demo credentials shown on the login screen. Reads directly from DB
  /// so newly-created users show up too (handy during development).
  Future<List<DemoCredential>> demoCredentials() async {
    final users = await _team.all(includeInactive: false);
    return users
        .map((u) => DemoCredential(email: u.email, role: u.role))
        .toList();
  }
}

/// Provider exposing the auth repository. Pulls the team repository
/// from DI so both share the same DB handle.
final mockAuthRepositoryProvider = Provider<MockAuthRepository>((ref) {
  final team = ref.watch(teamRepositoryProvider);
  final db = ref.watch(appDatabaseProvider);
  return MockAuthRepository(team, db);
});

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => message;
}

class DemoCredential {
  final String email;
  final UserRole role;
  const DemoCredential({required this.email, required this.role});
}
