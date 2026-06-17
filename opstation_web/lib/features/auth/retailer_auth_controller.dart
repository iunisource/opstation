import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Staff session key (see AuthController). Cleared on retailer sign-in so a
// lingering staff session in the same browser can't shadow a retailer login.
const _kStaffSessionKey = 'opstation_web_session';

/// Retailer-side auth, deliberately separate from the staff [AuthController].
///
/// A retailer signs in with a CODE + password. The code maps to a synthetic
/// email (`retailer_login_email` RPC) which is what Supabase Auth actually
/// authenticates. After the session exists we hydrate from `retailer_me()`
/// (SECURITY DEFINER, resolves by JWT email) and confirm role == 'retailer'.
///
/// Mutual exclusion with staff: a staff session makes `retailer_me()` return a
/// non-retailer role, so this controller yields null for them; the staff
/// controller requires its own prefs key, which a retailer never sets. So at
/// most one of the two controllers ever resolves to a user.
class RetailerUser {
  final String userId; // public.users.id (user_<ts>)
  final String name;
  final String orgId;
  final String customerId;
  final bool mustChangePassword; // password_temporary
  const RetailerUser({
    required this.userId,
    required this.name,
    required this.orgId,
    required this.customerId,
    required this.mustChangePassword,
  });

  RetailerUser copyWith({bool? mustChangePassword}) => RetailerUser(
        userId: userId,
        name: name,
        orgId: orgId,
        customerId: customerId,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      );
}

class RetailerAuthController extends AsyncNotifier<RetailerUser?> {
  @override
  Future<RetailerUser?> build() async {
    final client = Supabase.instance.client;
    if (client.auth.currentSession == null) return null;
    return _hydrate();
  }

  /// Reads the current account via retailer_me(); returns null unless it is a
  /// retailer (so a staff session resolves to null here).
  Future<RetailerUser?> _hydrate() async {
    try {
      final me = await Supabase.instance.client.rpc('retailer_me');
      if (me == null) return null;
      final m = Map<String, dynamic>.from(me as Map);
      if (m['role'] != 'retailer') return null;
      final custId = m['customer_id'] as String?;
      if (custId == null) return null;
      return RetailerUser(
        userId: m['id'] as String,
        name: (m['name'] as String?) ?? 'Retailer',
        orgId: m['org_id'] as String,
        customerId: custId,
        mustChangePassword: (m['password_temporary'] as bool?) ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> signIn({required String code, required String password}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final client = Supabase.instance.client;

      // Drop any stale staff session marker in this browser so it can't
      // shadow the retailer session after sign-in.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kStaffSessionKey);

      // 1) code -> synthetic email
      final email = await client.rpc('retailer_login_email', params: {
        'p_code': code.trim(),
      }) as String?;
      if (email == null || email.isEmpty) {
        throw Exception('No retailer login found for that code.');
      }

      // 2) Supabase Auth
      try {
        await client.auth.signInWithPassword(email: email, password: password);
      } on AuthException catch (_) {
        throw Exception('Invalid code or password.');
      }

      // 3) hydrate + confirm retailer
      final user = await _hydrate();
      if (user == null) {
        await client.auth.signOut();
        throw Exception('This login is not a retailer account.');
      }
      return user;
    });
  }

  /// Forced first-login password change. Updates the auth password, clears the
  /// password_temporary flag, and updates local state.
  Future<void> changePassword(String newPassword) async {
    final client = Supabase.instance.client;
    await client.auth.updateUser(UserAttributes(password: newPassword));
    await client.rpc('retailer_set_password_changed');
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(mustChangePassword: false));
    }
  }

  Future<void> signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
    state = const AsyncData(null);
  }
}

final retailerAuthControllerProvider =
    AsyncNotifierProvider<RetailerAuthController, RetailerUser?>(
        RetailerAuthController.new);

final currentRetailerProvider = Provider<RetailerUser?>((ref) {
  return ref.watch(retailerAuthControllerProvider).valueOrNull;
});
