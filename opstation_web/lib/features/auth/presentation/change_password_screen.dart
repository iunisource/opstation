import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/auth/password_hasher.dart';
import '../auth_controller.dart';

/// Forced password change on first login. Shown when the signed-in user's
/// `password_temporary` flag is set (e.g. self-serve trial orgs that start
/// with the shared default password). The router blocks every other route
/// until the user sets a new password here.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  ConsumerState<ChangePasswordScreen> createState() => _State();
}

class _State extends ConsumerState<ChangePasswordScreen> {
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final p = _pass.text;
    final c = _confirm.text;
    if (p.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }
    if (p == 'trial123') {
      setState(() => _error = 'Please choose a password different from the temporary one.');
      return;
    }
    if (p != c) {
      setState(() => _error = 'The two passwords do not match.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final client = Supabase.instance.client;
      final user = ref.read(currentUserProvider);
      // 1) update the real credential (Supabase Auth)
      await client.auth.updateUser(UserAttributes(password: p));
      // 2) clear the temporary flag + keep the mobile hash in sync
      if (user != null) {
        final salt = PasswordHasher.newSalt();
        final hash = PasswordHasher.hash(p, salt);
        await client.from('users').update({
          'password_temporary': false,
          'password_hash': hash,
          'password_salt': salt,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', user.id);
      }
      // 3) clear the in-memory flag → router lets the user into the app
      await ref.read(authControllerProvider.notifier).markPasswordChanged();
    } catch (e) {
      setState(() { _busy = false; _error = 'Could not update password: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 420,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.border),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.textPrimary.withOpacity(0.06),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 44,
                  width: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.lock_reset, color: AppTheme.primary, size: 24),
                ),
                const SizedBox(height: 16),
                const Text('Set your password',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary)),
                const SizedBox(height: 6),
                const Text(
                    'For your security, please replace the temporary password before continuing.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                const SizedBox(height: 20),
                TextField(
                  controller: _pass,
                  obscureText: !_show,
                  decoration: InputDecoration(
                    labelText: 'New password',
                    suffixIcon: IconButton(
                      icon: Icon(_show ? Icons.visibility_off : Icons.visibility, size: 20),
                      onPressed: () => setState(() => _show = !_show),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirm,
                  obscureText: !_show,
                  onSubmitted: (_) => _busy ? null : _submit(),
                  decoration: const InputDecoration(labelText: 'Confirm new password'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _busy ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _busy
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Save & continue'),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => ref.read(authControllerProvider.notifier).signOut(),
                    child: const Text('Sign out'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
