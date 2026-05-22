import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _kSessionKey = 'opstation_web_session';

enum WebUserRole { superAdmin, masterAdmin, admin, dispatchManager, accountant }

class WebUser {
  final String id;
  final String name;
  final String email;
  final WebUserRole role;
  final String? orgId;
  final String? orgName;
  const WebUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.orgId,
    this.orgName,
  });
  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'email': email,
    'role': role.name, 'orgId': orgId, 'orgName': orgName,
  };
  factory WebUser.fromJson(Map<String, dynamic> m) => WebUser(
    id: m['id'], name: m['name'], email: m['email'],
    role: WebUserRole.values.firstWhere((r) => r.name == m['role']),
    orgId: m['orgId'], orgName: m['orgName'],
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
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessionKey);
    if (raw == null) return null;
    try {
      // Verify we still have a live Supabase session — if it expired
      // while the browser was closed, force the user back to login so
      // RLS-scoped requests don't silently return empty results.
      if (Supabase.instance.client.auth.currentSession == null) {
        await prefs.remove(_kSessionKey);
        return null;
      }
      return WebUser.fromJson(jsonDecode(raw));
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
          .select('id, name, email, role, org_id, is_active')
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
      if (orgId != null) {
        final orgRows = await client
            .from('orgs')
            .select('name, is_active, expires_at')
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
          if (expRaw != null) {
            final expiry = DateTime.parse(expRaw);
            if (expiry.isBefore(DateTime.now())) {
              await client.auth.signOut();
              throw Exception(
                  'Your organization access has expired. Contact support.');
            }
          }
          orgName = orgRows.first['name'] as String?;
        }
      }

      // Step 4: role gate. Mobile-only roles get bounced from the web.
      final role = row['role'] as String;
      const allowedWebRoles = [
        'superAdmin', 'masterAdmin', 'admin', 'dispatchManager', 'accountant'
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
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('opstation_web_remember_me', rememberMe);
      if (rememberMe) {
        await prefs.setString(_kSessionKey, jsonEncode(user.toJson()));
      }
      return user;
    });
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
