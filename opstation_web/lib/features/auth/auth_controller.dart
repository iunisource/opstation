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

      // Step 3+4: resolve the ACTIVE org among this login's memberships (one
      // login can belong to several orgs via users.account_id) and apply the
      // org + role gates on that org. current_org() returns the server-
      // remembered last-active org, defaulting to the user's own.
      final user = await _buildActiveUser(
        loginEmail: normalized,
        mustChange: row['password_temporary'] as bool? ?? false,
        forceOrg: null,
      );

      // Fresh login → show the support buttons again.
      ref.read(supportButtonsHiddenProvider.notifier).state = false;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('opstation_web_remember_me', rememberMe);
      if (rememberMe) {
        await prefs.setString(_kSessionKey, jsonEncode(user.toJson()));
      }
      return user;
    });
  }

  /// Builds the WebUser for the ACTIVE org among this login's memberships.
  /// [forceOrg] switches to a specific org first (validated server-side by
  /// set_active_org). Applies the org (active/subscription) and role gates on
  /// the active org, so a user's role follows the org they're in.
  Future<WebUser> _buildActiveUser({
    required String loginEmail,
    required bool mustChange,
    String? forceOrg,
  }) async {
    final client = Supabase.instance.client;
    if (forceOrg != null) {
      await client.rpc('set_active_org', params: {'p_org': forceOrg});
    }
    final memRaw = await client.rpc('my_org_memberships');
    final mems = List<Map<String, dynamic>>.from(memRaw as List? ?? const []);
    if (mems.isEmpty) {
      await client.auth.signOut();
      throw Exception('No profile found for this account. Contact an admin.');
    }
    // Active org: forced, else server-remembered (current_org), else first.
    String? activeOrg = forceOrg;
    if (activeOrg == null) {
      try {
        activeOrg = await client.rpc('current_org') as String?;
      } catch (_) {}
    }
    Map<String, dynamic> m = mems.firstWhere(
      (e) => e['org_id'] == activeOrg,
      orElse: () => mems.first,
    );
    if (m['org_id'] != activeOrg) {
      await client.rpc('set_active_org', params: {'p_org': m['org_id']});
    }

    // Org gate on the active org.
    bool subExpired = false;
    final orgId = m['org_id'] as String?;
    if (orgId != null) {
      final orgRows = await client
          .from('orgs')
          .select('is_active, expires_at')
          .eq('id', orgId)
          .limit(1);
      if (orgRows.isNotEmpty) {
        final orgActive = orgRows.first['is_active'] as bool? ?? true;
        if (!orgActive) {
          await client.auth.signOut();
          throw Exception(
              'Your organization has been disabled. Contact support.');
        }
        final expRaw = orgRows.first['expires_at'] as String?;
        if (expRaw != null && DateTime.parse(expRaw).isBefore(DateTime.now())) {
          final roleStr = (m['role'] as String?) ?? '';
          final isAdmin = roleStr == 'masterAdmin' || roleStr == 'admin';
          if (isAdmin) {
            subExpired = true;
          } else {
            await client.auth.signOut();
            throw Exception(
                'Your workspace is paused. Please ask your administrator to renew the subscription.');
          }
        }
      }
    }

    // Role gate.
    final roleStr = (m['role'] as String?) ?? '';
    const allowedWebRoles = [
      'superAdmin', 'masterAdmin', 'admin', 'dispatchManager', 'accountant', 'erpUser'
    ];
    if (!allowedWebRoles.contains(roleStr)) {
      await client.auth.signOut();
      throw Exception('Access denied. Only admins can use the web panel.');
    }

    return WebUser(
      id: (m['user_id'] as String?) ?? '',
      name: (m['user_name'] as String?) ?? '',
      email: loginEmail,
      role: WebUserRole.values.firstWhere((r) => r.name == roleStr),
      orgId: orgId,
      orgName: m['org_name'] as String?,
      mustChangePassword: mustChange,
      subscriptionExpired: subExpired,
    );
  }

  /// Switch the active org mid-session (top-bar org switcher). Re-hydrates the
  /// session for the new org; callers should then invalidate org-scoped
  /// providers so every screen re-queries under the new org.
  Future<void> switchOrg(String orgId) async {
    final cur = state.valueOrNull;
    if (cur == null) return;
    final user = await _buildActiveUser(
      loginEmail: cur.email,
      mustChange: cur.mustChangePassword,
      forceOrg: orgId,
    );
    state = AsyncData(user);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('opstation_web_remember_me') ?? true) {
      await prefs.setString(_kSessionKey, jsonEncode(user.toJson()));
    }
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

/// Orgs the current login can enter. More than one => show the org switcher.
/// Any user linked (via users.account_id) to multiple orgs gets this — an owner
/// with several orgs, or a shared admin the owner added to more than one org.
final orgMembershipsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return const [];
  try {
    final res = await Supabase.instance.client.rpc('my_org_memberships');
    return List<Map<String, dynamic>>.from(res as List? ?? const []);
  } catch (_) {
    return const [];
  }
});

/// Whether the dashboard support buttons (Request a call back / Get the Android
/// app) have been dismissed for this session. Reset to false on every sign-in,
/// so they reappear at the next login.
final supportButtonsHiddenProvider = StateProvider<bool>((ref) => false);
