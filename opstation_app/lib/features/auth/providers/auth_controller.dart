import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database_provider.dart';
import '../../../core/supabase/supabase_auth_service.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/services/notification_service.dart';
import '../data/mock_auth_repository.dart' hide AuthException;
import '../../admin_settings/providers/org_settings_controller.dart';
import '../models/auth_user.dart' as app;
import '../models/user_role.dart';
import '../../../core/constants/auth_constants.dart';

const _kSessionKey = 'opstation_session';

final supabaseAuthServiceProvider = Provider<SupabaseAuthService>((ref) {
  return SupabaseAuthService(Supabase.instance.client);
});

class AuthController extends AsyncNotifier<app.AuthUser?> {
  @override
  Future<app.AuthUser?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessionKey);
    if (raw == null) return null;

    // ── Supabase session guard ────────────────────────────────────────
    // The app-level session (SharedPreferences) and the Supabase Auth
    // session are SEPARATE. If the server session is dead, RLS rejects
    // every write — silently — while the app still looks signed in. That
    // is exactly how a surveyor can work all day and sync nothing. So a
    // restored app session is only honoured if the server session is
    // alive or refreshable. A dead session (server explicitly rejects
    // the refresh) forces a fresh login, which restores a real JWT.
    // A NETWORK failure keeps the session so offline work continues.
    // Local (Drift) data is untouched either way.
    final sb = Supabase.instance.client;
    var sbSession = sb.auth.currentSession;
    if (sbSession == null || sbSession.isExpired) {
      var dead = sbSession == null;
      try {
        final refreshed = await sb.auth.refreshSession();
        sbSession = refreshed.session;
        dead = sbSession == null;
      } on AuthException {
        dead = true; // server says the stored session is invalid
      } catch (_) {
        dead = false; // network error — tolerate, sync retries later
      }
      if (dead) {
        print('AUTH GUARD: Supabase session dead — forcing re-login');
        await prefs.remove(_kSessionKey);
        return null;
      }
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return app.AuthUser(
        id: map['id'] as String,
        name: map['name'] as String,
        email: map['email'] as String,
        role: UserRoleX.fromKey(map['role'] as String) ?? UserRole.salesperson,
        organizationId: map['organizationId'] as String?,
        organizationName: map['organizationName'] as String?,
      );
    } catch (_) {
      await prefs.remove(_kSessionKey);
      return null;
    }
  }

  Future<void> signIn({
    required String email,
    required String password,
    bool rememberMe = true,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      print('AUTH START: email=$email');
      final localRepo = ref.read(mockAuthRepositoryProvider);
      final supabaseAuth = ref.read(supabaseAuthServiceProvider);
      final pullService = ref.read(supabasePullServiceProvider);
      final db = ref.read(appDatabaseProvider);
      final isSuper = email.trim().toLowerCase() == kSuperAdminEmail;

      app.AuthUser? user;

      if (!isSuper) {
        // Check if user exists locally
        final localUser = await (db.select(db.users)
              ..where((u) => u.email.equals(email.toLowerCase().trim())))
            .getSingleOrNull();
        print('AUTH LOCAL USER: ${localUser == null ? "NOT FOUND" : "FOUND id=${localUser.id}"}');

        if (localUser == null) {
          // Fresh install — authenticate via Supabase, pull data, build session
          bool authSuccess = false;
          String authError = 'Sign in failed. Check your connection.';
          for (int i = 0; i < 3 && !authSuccess; i++) {
            try {
              await supabaseAuth.signIn(email: email, password: password)
                  .timeout(const Duration(seconds: 15));
              authSuccess = true;
            } on SupabaseAuthException catch (e) {
              print('AUTH SUPABASE ERROR (auth): ${e.message}');
              throw Exception(e.message); // wrong password - don't retry
            } catch (e) {
              print('AUTH SUPABASE RETRY $i: $e');
              authError = e.toString().contains('timeout')
                  ? 'Connection timed out. Try again.'
                  : e.toString();
              if (i < 2) await Future.delayed(const Duration(seconds: 2));
            }
          }
          print('AUTH SUPABASE SIGN-IN: success=$authSuccess');
          if (!authSuccess) throw Exception(authError);

          // Pull user record from Supabase users table
          final remoteUser = await supabaseAuth.getUserByEmail(email)
              .timeout(const Duration(seconds: 10));
          print('AUTH REMOTE USER LOOKUP: ${remoteUser == null ? "NULL" : "OK id=${remoteUser['id']} role=${remoteUser['role']} orgId=${remoteUser['org_id']}"}');
          if (remoteUser == null) {
            throw Exception('Account not found in server. Contact your admin.');
          }

          final orgId = remoteUser['org_id'] as String?;

          user = app.AuthUser(
            id: remoteUser['id'] as String,
            name: remoteUser['name'] as String,
            email: remoteUser['email'] as String,
            role: UserRoleX.fromKey(remoteUser['role'] as String) ??
                UserRole.salesperson,
            organizationId: orgId,
            organizationName: null, // resolved after pull below
          );

          // Pull org data — blocking so home screen has data on arrival.
          // No outer catch: if this fails we surface the error so login
          // doesn't silently complete with no data.
          if (orgId != null) {
            print('AUTH PULL: starting for orgId=$orgId');
            try {
              await pullService.pullOrgData(orgId)
                  .timeout(const Duration(seconds: 60));
              print('AUTH PULL: completed');
            } catch (e, st) {
              print('AUTH PULL ERROR: $e');
              print(st);
              throw Exception('Could not load org data: $e');
            }
            // Now resolve org name from freshly-pulled local data
            final resolvedName = await _resolveOrgName(orgId);
            user = app.AuthUser(
              id: user.id,
              name: user.name,
              email: user.email,
              role: user.role,
              organizationId: user.organizationId,
              organizationName: resolvedName,
            );
          } else {
            try {
              await pullService.pullUserRecord(remoteUser)
                  .timeout(const Duration(seconds: 15));
            } catch (e) {
              print('AUTH PULL USER ERROR: $e');
            }
          }
        } else {
          // Returning user — Supabase signIn is REQUIRED (gates RLS).
          // Local hash is no longer trusted as the auth source of truth.
          bool authSuccess = false;
          String authError = 'Sign in failed. Check your connection.';
          for (int i = 0; i < 3 && !authSuccess; i++) {
            try {
              await supabaseAuth.signIn(email: email, password: password)
                  .timeout(const Duration(seconds: 15));
              authSuccess = true;
            } on SupabaseAuthException catch (e) {
              print('AUTH SUPABASE ERROR: ${e.message}');
              throw Exception(e.message); // wrong password — don't retry
            } catch (e) {
              print('AUTH SUPABASE RETRY $i: $e');
              authError = e.toString().contains('timeout')
                  ? 'Connection timed out. Try again.'
                  : e.toString();
              if (i < 2) await Future.delayed(const Duration(seconds: 2));
            }
          }
          print('AUTH SUPABASE SIGN-IN: success=$authSuccess');
          if (!authSuccess) throw Exception(authError);

          // Push stranded local data BEFORE pulling. The pull upserts
          // server rows over local ones, so flushing first protects any
          // offline edits (customer locations, audits, spottings) that
          // accumulated while the server session was dead.
          //
          // This used to be a FULL pushAll, which re-uploaded every local
          // table on every login and made the login screen crawl. Pending
          // rows are all that need protecting from the pull (offline edits
          // are marked pending), so flush only those — with a hard timeout
          // so a slow network can never hang the login. The full pushAll
          // safety net still runs UNAWAITED in the background right after
          // login completes.
          try {
            await ref
                .read(syncControllerProvider.notifier)
                .flushPending()
                .timeout(const Duration(seconds: 20));
          } catch (e) {
            print('AUTH PRE-PULL FLUSH ERROR: $e');
          }

          // Build session from the local user record fetched above.
          user = app.AuthUser(
            id: localUser.id,
            name: localUser.name,
            email: localUser.email,
            role: UserRoleX.fromKey(localUser.role) ?? UserRole.salesperson,
            organizationId: localUser.orgId,
            organizationName: null, // resolved after pull below
          );

          // Pull fresh org data so cached data is current.
          if (user.organizationId != null) {
            try {
              await pullService.pullOrgData(user.organizationId!)
                  .timeout(const Duration(seconds: 60));
              final resolvedName = await _resolveOrgName(user.organizationId!);
              user = app.AuthUser(
                id: user.id,
                name: user.name,
                email: user.email,
                role: user.role,
                organizationId: user.organizationId,
                organizationName: resolvedName,
              );
            } catch (e) {
              print('AUTH PULL ERROR (returning user): $e');
            }
          }
        }
      } else {
        // Superadmin path - Path B: Supabase is the source of truth.
        // Mirrors the returning-user branch: Supabase signIn is REQUIRED,
        // the local users row is just a cache for the session record.
        print('AUTH SUPERADMIN: starting');
        bool authSuccess = false;
        String authError = 'Sign in failed. Check your connection.';
        for (int i = 0; i < 3 && !authSuccess; i++) {
          try {
            await supabaseAuth.signIn(email: email, password: password)
                .timeout(const Duration(seconds: 15));
            authSuccess = true;
          } on SupabaseAuthException catch (e) {
            print('AUTH SUPERADMIN SUPABASE ERROR: ${e.message}');
            throw Exception(e.message);
          } catch (e) {
            print('AUTH SUPERADMIN SUPABASE RETRY $i: $e');
            authError = e.toString().contains('timeout')
                ? 'Connection timed out. Try again.'
                : e.toString();
            if (i < 2) await Future.delayed(const Duration(seconds: 2));
          }
        }
        print('AUTH SUPERADMIN SUPABASE SIGN-IN: success=$authSuccess');
        if (!authSuccess) throw Exception(authError);

        // Build session from the local superadmin record (seeded at app boot).
        final localSuperAdmin = await (db.select(db.users)
              ..where((u) => u.id.equals(kSuperAdminLocalId)))
            .getSingleOrNull();
        if (localSuperAdmin == null) {
          throw Exception('Local superadmin record missing. Restart the app.');
        }
        user = app.AuthUser(
          id: localSuperAdmin.id,
          name: localSuperAdmin.name,
          email: email.trim().toLowerCase(),
          role: UserRoleX.fromKey(localSuperAdmin.role) ?? UserRole.superAdmin,
          organizationId: null,
          organizationName: null,
        );

        try {
          await ref.read(supabasePullServiceProvider).pullAllOrgs();
        } catch (e) {
          print('AUTH SUPERADMIN PULL ALL ORGS ERROR: $e');
        }
      }

      // Org-level gate: deactivated org or expired access blocks login.
      // Super admins bypass (they have no org). Network errors don't
      // hard-block — sync will surface staleness later.
      if (!isSuper && user?.organizationId != null) {
        try {
          final orgRow = await Supabase.instance.client
              .from('orgs')
              .select('is_active, expires_at')
              .eq('id', user!.organizationId!)
              .maybeSingle();
          if (orgRow != null) {
            final orgActive = orgRow['is_active'] as bool? ?? true;
            if (!orgActive) {
              throw Exception('Your organization has been disabled. Contact support.');
            }
            final expRaw = orgRow['expires_at'] as String?;
            if (expRaw != null) {
              final expiry = DateTime.parse(expRaw);
              if (expiry.isBefore(DateTime.now())) {
                throw Exception('Your organization access has expired. Contact support.');
              }
            }
          }
        } catch (e) {
          if (e.toString().contains('Your organization')) rethrow;
          // Network/other error — skip the gate, sync resolves later
        }
      }

      // Persist session (skipped if "Remember me" off)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('opstation_remember_me', rememberMe);
      if (rememberMe) {
      await prefs.setString(_kSessionKey, jsonEncode({
        'id': user!.id,
        'name': user.name,
        'email': user.email,
        'role': user.role.name,
        'organizationId': user.organizationId,
        'organizationName': user.organizationName,
      }));
      }

      ref.invalidate(orgSettingsProvider);

      Future.microtask(() async {
        try {
          ref.read(syncControllerProvider.notifier).pushAll(user!.organizationId);
        } catch (_) {}
        try {
          await ref.read(notificationServiceProvider).initialize(user!.id);
        } catch (_) {}
      });

      final session = user!;
      print('AUTH SESSION: id=${session.id} role=${session.role.name} orgId=${session.organizationId ?? "null"}');
      return session;
    });
  }

  Future<String?> _resolveOrgName(String orgId) async {
    try {
      final db = ref.read(appDatabaseProvider);
      final row = await (db.select(db.orgs)
            ..where((o) => o.id.equals(orgId)))
          .getSingleOrNull();
      return row?.name;
    } catch (_) {
      return null;
    }
  }

  Future<void> signOut() async {
    final supabaseAuth = ref.read(supabaseAuthServiceProvider);
    final localRepo = ref.read(mockAuthRepositoryProvider);
    await supabaseAuth.signOut();
    await localRepo.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionKey);
    state = const AsyncData(null);
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, app.AuthUser?>(AuthController.new);

final orgIdProvider = Provider<String?>((ref) {
  return ref.watch(authControllerProvider).valueOrNull?.organizationId;
});