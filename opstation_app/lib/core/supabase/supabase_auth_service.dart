import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseAuthService {
  final SupabaseClient _client;
  SupabaseAuthService(this._client);

  bool get hasSession => _client.auth.currentSession != null;
  String? get currentUserId => _client.auth.currentUser?.id;

  Future<void> signIn({required String email, required String password}) async {
    try {
      final res = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      if (res.session == null) {
        throw const SupabaseAuthException('Sign in failed — no session returned.');
      }
    } on AuthException catch (e) {
      throw SupabaseAuthException(_friendlyMessage(e.message));
    }
    // Network/socket errors bubble up as-is so caller can fall back to local.
  }

  Future<void> signOut() async {
    try { await _client.auth.signOut(); } catch (_) {}
  }

  Future<void> createUser({required String email, required String password}) async {
    try {
      await _client.auth.signUp(email: email, password: password);
    } on AuthException catch (e) {
      throw SupabaseAuthException(_friendlyMessage(e.message));
    }
  }

  /// Fetch user record from Supabase users table by email.
  Future<Map<String, dynamic>?> getUserByEmail(String email) async {
    try {
      final res = await _client
          .from('users')
          .select()
          .eq('email', email.toLowerCase().trim())
          .maybeSingle();
      return res;
    } catch (_) {
      return null;
    }
  }

  Future<void> updatePassword(String newPassword) async {
    try {
      await _client.auth.updateUser(UserAttributes(password: newPassword));
    } on AuthException catch (e) {
      throw SupabaseAuthException(_friendlyMessage(e.message));
    }
  }

  String _friendlyMessage(String raw) {
    final r = raw.toLowerCase();
    if (r.contains('invalid login') || r.contains('invalid credentials')) {
      return 'Invalid email or password.';
    }
    if (r.contains('email not confirmed')) return 'Email not confirmed. Check your inbox.';
    if (r.contains('user already registered')) return 'An account with this email already exists.';
    if (r.contains('network') || r.contains('socket') || r.contains('connection')) {
      return 'Network error. Check your connection.';
    }
    return raw;
  }
}

class SupabaseAuthException implements Exception {
  final String message;
  const SupabaseAuthException(this.message);
  @override
  String toString() => message;
}
