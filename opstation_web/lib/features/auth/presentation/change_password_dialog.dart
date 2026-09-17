import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/auth/password_hasher.dart';
import '../auth_controller.dart';

/// Self-service password change for ANY signed-in user (including admins).
/// Additive — this does not touch the forced first-login flow
/// (ChangePasswordScreen / password_temporary). It updates the real Supabase
/// Auth credential and keeps the `users` hash mirror (used by mobile/code
/// login) in sync, exactly like the forced flow does.
Future<void> showSelfPasswordChangeDialog(BuildContext context, WebUser user) {
  return showDialog(
    context: context,
    builder: (_) => _ChangePasswordDialog(user: user),
  );
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.user});
  final WebUser user;
  @override
  State<_ChangePasswordDialog> createState() => _State();
}

class _State extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final cur = _current.text;
    final p = _new.text;
    final c = _confirm.text;
    if (p.length < 8) { setState(() => _error = 'Use at least 8 characters.'); return; }
    if (p != c) { setState(() => _error = 'The two new passwords do not match.'); return; }
    setState(() { _busy = true; _error = null; });
    try {
      final client = Supabase.instance.client;

      // Verify the current password against the stored hash mirror when we have
      // one (no re-auth, so the session is never disturbed). If no hash is on
      // file we skip — the active session already proves identity.
      final row = await client.from('users')
          .select('password_hash, password_salt').eq('id', widget.user.id).maybeSingle();
      final storedHash = row?['password_hash'] as String?;
      final storedSalt = row?['password_salt'] as String?;
      if (storedHash != null && storedHash.isNotEmpty && storedSalt != null && storedSalt.isNotEmpty) {
        if (cur.isEmpty) { setState(() { _busy = false; _error = 'Enter your current password.'; }); return; }
        if (PasswordHasher.hash(cur, storedSalt) != storedHash) {
          setState(() { _busy = false; _error = 'Current password is incorrect.'; }); return;
        }
        if (cur == p) { setState(() { _busy = false; _error = 'New password must be different from the current one.'; }); return; }
      }

      // 1) update the real credential (Supabase Auth)
      await client.auth.updateUser(UserAttributes(password: p));
      // 2) keep the mobile/code-login hash in sync
      final salt = PasswordHasher.newSalt();
      final hash = PasswordHasher.hash(p, salt);
      await client.from('users').update({
        'password_hash': hash,
        'password_salt': salt,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.user.id);

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated.')),
      );
    } catch (e) {
      setState(() { _busy = false; _error = 'Could not update password: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget pwField(String label, TextEditingController c, {bool submit = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: !_show,
        onSubmitted: submit ? (_) => _busy ? null : _submit() : null,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );

    return AlertDialog(
      title: Row(children: const [
        Icon(Icons.lock_reset, color: AppTheme.primary, size: 22),
        SizedBox(width: 8),
        Text('Change password', style: TextStyle(fontSize: 17)),
      ]),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Signed in as ${widget.user.email}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 14),
          pwField('Current password', _current),
          pwField('New password', _new),
          pwField('Confirm new password', _confirm, submit: true),
          Row(children: [
            Checkbox(value: _show, visualDensity: VisualDensity.compact, onChanged: (v) => setState(() => _show = v ?? false)),
            const Text('Show passwords', style: TextStyle(fontSize: 12)),
          ]),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
          child: _busy
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Update password'),
        ),
      ],
    );
  }
}
