import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/database/app_database_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../retailer/presentation/role_picker_screen.dart' show setLastLoginRole;
import '../models/user_role.dart';
import '../providers/auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;
  bool _rememberMe = true;

  static const _kRememberKey = 'opstation_remember_me';

  @override
  void initState() {
    super.initState();
    _loadRemember();
  }

  Future<void> _loadRemember() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _rememberMe = prefs.getBool(_kRememberKey) ?? true);
  }

  Future<void> _setRemember(bool v) async {
    setState(() => _rememberMe = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRememberKey, v);
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await ref.read(authControllerProvider.notifier).signIn(
          email: _emailCtrl.text,
          password: _passwordCtrl.text,
          rememberMe: _rememberMe,
        );
    // Errors surface via the ref.listen in build(); no need to read here, and
    // reading after the await was unreliable (the screen could be unmounted).
  }

  void _showForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ForgotPasswordSheet(
        prefillEmail: _emailCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Surface auth failures (wrong password, disabled org, data-load errors)
    // as a snackbar. Lives here so it fires whenever the auth state flips to
    // error, independent of _submit's mount timing.
    ref.listen(authControllerProvider, (prev, next) {
      if (next.hasError && !next.isLoading) {
        final msg = next.error.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(msg),
            backgroundColor: AppColors.danger,
          ));
      }
    });
    final auth = ref.watch(authControllerProvider);
    final loading = auth.isLoading;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: loading
                            ? null
                            : () async {
                                await setLastLoginRole(null);
                                if (context.mounted) context.go('/');
                              },
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('Back'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const _Logo(),
                    const SizedBox(height: 24),
                    Text(
                      'Welcome back',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Sign in to your Opstation account',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textSecondaryLight,
                          ),
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Email',
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Enter your email';
                        if (!v.contains('@')) return 'Invalid email';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordCtrl,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        hintText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Enter your password' : null,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _showForgotPassword,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 4),
                        ),
                        child: const Text(
                          'Forgot password?',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Checkbox(
                          value: _rememberMe,
                          onChanged: (v) => _setRemember(v ?? true),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        const Text('Remember me',
                            style: TextStyle(fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: loading ? null : _submit,
                      child: loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Sign in'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Forgot password bottom sheet -------------------------------------

class _ForgotPasswordSheet extends ConsumerStatefulWidget {
  final String prefillEmail;
  const _ForgotPasswordSheet({required this.prefillEmail});

  @override
  ConsumerState<_ForgotPasswordSheet> createState() =>
      _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends ConsumerState<_ForgotPasswordSheet> {
  final _emailCtrl = TextEditingController();
  bool _loading = false;
  _LookupResult? _result;

  @override
  void initState() {
    super.initState();
    _emailCtrl.text = widget.prefillEmail;
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _result = _LookupResult.invalidEmail);
      return;
    }
    setState(() { _loading = true; _result = null; });
    try {
      final db = ref.read(appDatabaseProvider);
      final row = await (db.select(db.users)
            ..where((u) => u.email.equals(email)))
          .getSingleOrNull();
      if (!mounted) return;
      if (row == null) {
        setState(() { _loading = false; _result = _LookupResult.notFound; });
        return;
      }
      // Superadmin: show default credential hint.
      if (row.role == 'superAdmin') {
        setState(() { _loading = false; _result = _LookupResult.isSuperAdmin; });
        return;
      }
      setState(() { _loading = false; _result = _LookupResult.contactAdmin; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _loading = false; _result = _LookupResult.error; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + keyboard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Forgot password',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Enter your email to find your account.',
            style: TextStyle(
                color: AppColors.textSecondaryLight, fontSize: 13),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _lookup(),
            decoration: const InputDecoration(
              hintText: 'Email address',
              prefixIcon: Icon(Icons.mail_outline),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : _lookup,
              child: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Find my account'),
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: 16),
            _ResultCard(result: _result!),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

enum _LookupResult { notFound, contactAdmin, isSuperAdmin, invalidEmail, error }

class _ResultCard extends StatelessWidget {
  final _LookupResult result;
  const _ResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon, title, body) = switch (result) {
      _LookupResult.invalidEmail => (
          AppColors.dangerLight,
          AppColors.dangerDark,
          Icons.error_outline,
          'Invalid email',
          'Please enter a valid email address.',
        ),
      _LookupResult.notFound => (
          AppColors.dangerLight,
          AppColors.dangerDark,
          Icons.person_off_outlined,
          'Account not found',
          'No account is registered with this email. Check for typos or contact your organization admin.',
        ),
      _LookupResult.contactAdmin => (
          AppColors.primaryLight,
          AppColors.primaryDark,
          Icons.admin_panel_settings_outlined,
          'Contact your admin',
          'Your account exists. To reset your password, ask your organization administrator to issue a new one from the Team screen. They can reset it and share the temporary password with you.',
        ),
      _LookupResult.isSuperAdmin => (
          AppColors.warningLight,
          AppColors.warningDark,
          Icons.shield_outlined,
          'Super admin account',
          'This is the system super admin account. The default password is opstation123. If you changed it and forgot it, it can only be recovered by resetting the app data.',
        ),
      _LookupResult.error => (
          AppColors.dangerLight,
          AppColors.dangerDark,
          Icons.error_outline,
          'Something went wrong',
          'Could not look up the account. Please try again.',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Text(body,
                    style: TextStyle(color: fg, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Logo -------------------------------------------------------------

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.route_outlined, color: Colors.white, size: 32),
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  final UserRole role;
  final VoidCallback onTap;

  const _RolePill({required this.role, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          role.label,
          style: const TextStyle(
            color: AppColors.primaryDark,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
