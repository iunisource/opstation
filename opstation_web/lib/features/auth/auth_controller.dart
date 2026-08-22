import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _kSessionKey = 'opstation_web_session';

enum WebUserRole { superAdmin, masterAdmin, admin, dispatchManager, accountant, erpUser }

class WebUser {
  final String id;
  final String name;
  final String email;
  final WebUserRole role;
  final String? orgId;
  final String? orgName;
  final bool mustChangePassword;
  final bool subscriptionExpired;
  const WebUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.orgId,
    this.orgName,
    this.mustChangePassword = false,
    this.subscriptionExpired = false,
  });
  WebUser copyWith({bool? mustChangePassword, bool? subscriptionExpired}) => WebUser(
    id: id, name: name, email: email, role: role,
    orgId: orgId, orgName: orgName,
    mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    subscriptionExpired: subscriptionExpired ?? this.subscriptionExpired,
  );
  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'email': email,
    'role': role.name, 'orgId': orgId, 'orgName': orgName,
    'mustChangePassword': mustChangePassword,
    'subscriptionExpired': subscriptionExpired,
  };
  factory WebUser.fromJson(Map<String, dynamic> m) => WebUser(
    id: m['id'], name: m['name'], email: m['email'],
    role: WebUserRole.values.firstWhere((r) => r.name == m['role']),
    orgId: m['orgId'], orgName: m['orgName'],
    mustChangePassword: m['mustChangePassword'] as bool? ?? false,
    subscriptionExpired: m['subscriptionExpired'] as bool? ?? false,
  );
}

/// Web-side auth controller.
///
/// Authenticates via Supabase Auth (signInWithPassword) so every
/// authenticated request carries a JWT that RLS policies can resolve
/// via auth.uid(). After the session is established we hydrate the
/// user's profile from public.users (looked up by email).
///
/// We previously verified password_hash/password_salt directly against
/// public.users, but that flow never established a Supabase Auth
/// session — which made tenant-scoped RLS impossible to enforce on
/// the web admin panel. The custom hash columns are now vestigial;
/// auth.users is the single source of truth for credentials.
class AuthController extends AsyncNotifier<WebUser?> {
  @override
  Future<WebUser?> build() async {
    // Listen for auth events — handles token refresh, forced sign-out, etc.
    final sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      switch (data.event) {
        case AuthChangeEvent.tokenRefreshed:
          // Token silently refreshed — no UI action needed
          break;
        case AuthChangeEvent.signedOut:
        case AuthChangeEvent.userDeleted:
          // Session ended (expired refresh token, revoked, etc.) — kick to login
          final p = await SharedPreferences.getInstance();
          await p.remove(_kSessionKey);
          if (state.value != null) state = const AsyncData(null);
          break;
        default:
          break;
      }
    });
    ref.onDispose(() => sub.cancel());

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessionKey);
    if (raw == null) return null;

    try {
      var session = Supabase.instance.client.auth.currentSession;

      if (session == null) {
        await prefs.remove(_kSessionKey);
        return null;
      }

      // If the JWT is expired or within 5 minutes of expiry, force a refresh
      // now so the first RLS-scoped request doesn't fail.
      final expAt  = session.expiresAt;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (expAt != null && expAt - nowSec < 300) {
        try {
          final res = await Supabase.instance.client.auth.refreshSession();
          if (res.session == null) {
            await prefs.remove(_kSessionKey);
            return null;
          }
        } catch (_) {
          await prefs.remove(_kSessionKey);
          return null;
        }
      }

      return WebUser.fromJson(jsonDecode(raw));
    } catch (_) {
      await prefs.remove(_kSessionKey);
      return null;
    }
  }

  /// Called by screens when an RLS error (42501) is detected mid-session.
  /// Attempts a silent refresh; if that fails, forces re-login.
  Future<bool> tryRefresh() async {
    try {
      final res = await Supabase.instance.client.auth.refreshSession();
      return res.session != null;
    } catch (_) {
      await signOut();
      return false;
    }
  }

  Future<void> signIn({
    required String email,
    required String password,
    bool rememberMe = true,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final client = Supabase.instance.client;
      final normalized = email.trim().toLowerCase();

      // Step 1: Supabase Auth. This is what makes auth.uid() return a
      // real UUID on subsequent table queries — the foundation of RLS.
      try {
        await client.auth.signInWithPassword(
          email: normalized,
          password: password,
        );
      } on AuthException catch (e) {
        // Don't leak which step failed — generic error.
        throw Exception('Invalid email or password.');
      }

      // Step 2: hydrate the profile from public.users. The session is
      // now active so the "Self or same org" RLS policy lets the user
      // read their own row by matching email to auth.users.email.
      final rows = await client
          .from('users')
          .select('id, name, email, role, org_id, is_active, password_temporary')
          .eq('email', normalized)
          .limit(1);
      if (rows.isEmpty) {
        await client.auth.signOut();
        throw Exception(
            'No profile found for this account. Contact an admin.');
      }
      final row = rows.first;

      final isActive = row['is_active'] as bool? ?? true;
      if (!isActive) {
        await client.auth.signOut();
        throw Exception(
            'This account has been deactivated. Contact an admin.');
      }

      // Step 3: org gate.
      final orgId = row['org_id'] as String?;
      String? orgName;
      bool subExpired = false;
      if (orgId != null) {
        final orgRows = await client
            .from('orgs')
            .select('name, is_active, expires_at')
            .eq('id', orgId)
            .limit(1);
        if (orgRows.isNotEmpty) {
          final orgActive = orgRows.first['is_active'] as bool? ?? true;
          if (!orgActive) {
            // Hard disable (super admin) — fully blocked.
            await client.auth.signOut();
            throw Exception(
                'Your organization has been disabled. Contact support.');
          }
          final expRaw = orgRows.first['expires_at'] as String?;
          if (expRaw != null && DateTime.parse(expRaw).isBefore(DateTime.now())) {
            // Trial / subscription lapsed. Admins get in (to a "renew" wall);
            // other users are paused until an admin renews.
            final roleStr = row['role'] as String;
            final isAdmin = roleStr == 'masterAdmin' || roleStr == 'admin';
            if (isAdmin) {
              subExpired = true;
            } else {
              await client.auth.signOut();
              throw Exception(
                  'Your workspace is paused. Please ask your administrator to renew the subscription.');
            }
          }
          orgName = orgRows.first['name'] as String?;
        }
      }

      // Step 4: role gate. Mobile-only roles get bounced from the web.
      final role = row['role'] as String;
      const allowedWebRoles = [
        'superAdmin', 'masterAdmin', 'admin', 'dispatchManager', 'accountant', 'erpUser'
      ];
      if (!allowedWebRoles.contains(role)) {
        await client.auth.signOut();
        throw Exception('Access denied. Only admins can use the web panel.');
      }

      final user = WebUser(
        id: row['id'] as String,
        name: row['name'] as String,
        email: row['email'] as String,
        role: WebUserRole.values.firstWhere((r) => r.name == role),
        orgId: orgId,
        orgName: orgName,
        mustChangePassword: row['password_temporary'] as bool? ?? false,
        subscriptionExpired: subExpired,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('opstation_web_remember_me', rememberMe);
      if (rememberMe) {
        await prefs.setString(_kSessionKey, jsonEncode(user.toJson()));
      }
      return user;
    });
  }

  /// Clears the force-password-change flag in memory + cached session after the
  /// user has set a new password. The router then lets them through to the app.
  Future<void> markPasswordChanged() async {
    final u = state.valueOrNull;
    if (u == null) return;
    final nu = u.copyWith(mustChangePassword: false);
    state = AsyncData(nu);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('opstation_web_remember_me') ?? true) {
      await prefs.setString(_kSessionKey, jsonEncode(nu.toJson()));
    }
  }

  Future<void> signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionKey);
    state = const AsyncData(null);
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, WebUser?>(AuthController.new);

final currentUserProvider = Provider<WebUser?>((ref) {
  return ref.watch(authControllerProvider).valueOrNull;
});
