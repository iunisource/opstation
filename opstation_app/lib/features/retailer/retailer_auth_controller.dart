import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Staff session key (see AuthController). The staff controller resolves ONLY
/// from this key — never from Supabase's session — so a retailer signing in can
/// never satisfy it. We still clear it on retailer sign-in as a belt-and-braces
/// guard against a stale staff session on a shared device.
const _kStaffSessionKey = 'opstation_session';

/// Marks that the live Supabase session belongs to a retailer. Without it, a
/// retailer session would be indistinguishable from a stale staff auth session
/// on cold start.
const _kRetailerSessionKey = 'opstation_retailer_session';

/// Retailer-side auth, deliberately separate from the staff [AuthController] —
/// mirroring the web app's split.
///
/// A retailer signs in with a CODE + password. The code maps to a synthetic
/// email (`retailer_login_email` RPC) which is what Supabase Auth actually
/// authenticates. After the session exists we hydrate from `retailer_me()`
/// (SECURITY DEFINER, resolves by JWT email) and confirm role == 'retailer'.
///
/// Retailers are ONLINE-ONLY: no Drift, no pull service, no sync controller.
/// Dragging the offline-first staff machinery in here would mean seeding a
/// local DB for a party who only ever reads live catalogue and balance data.
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
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kRetailerSessionKey) == null) return null;
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kStaffSessionKey);

      // 1) code -> synthetic email (server-side lookup; the shopkeeper never
      //    needs to know the org or the synthetic address)
      final email = await client.rpc('retailer_login_email', params: {
        'p_code': code.trim(),
      }) as String?;
      if (email == null || email.isEmpty) {
        throw Exception('No retailer account found for that code.');
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
      await prefs.setString(_kRetailerSessionKey, user.customerId);
      return user;
    });
  }

  /// Forced first-login password change. Updates the auth password and clears
  /// the password_temporary flag.
  Future<void> changePassword(String newPassword) async {
    final client = Supabase.instance.client;
    final cur = state.valueOrNull;
    if (cur == null) throw Exception('Not signed in.');
    await client.auth.updateUser(UserAttributes(password: newPassword));
    await client
        .from('users')
        .update({'password_temporary': false}).eq('id', cur.userId);
    state = AsyncData(cur.copyWith(mustChangePassword: false));
  }

  Future<void> signOut() async {
    final client = Supabase.instance.client;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRetailerSessionKey);
    await client.auth.signOut();
    state = const AsyncData(null);
  }
}

final retailerAuthControllerProvider =
    AsyncNotifierProvider<RetailerAuthController, RetailerUser?>(
        RetailerAuthController.new);
