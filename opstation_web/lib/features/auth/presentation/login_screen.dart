import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../auth_controller.dart';
import '../../../core/theme/app_theme.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _emailFocus = FocusNode();
  final _passFocus = FocusNode();
  bool _obscure = true;
  bool _rememberMe = true;

  static const _kRememberKey = 'opstation_web_remember_me';
  static const _ink = Color(0xFF111827);

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

  Future<void> _forgotPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter your email above first, then tap Forgot password.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
      _emailFocus.requestFocus();
      return;
    }
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'https://opstation-f06c7.web.app',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Password reset link sent to $email. Check your inbox (and spam).'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not send reset link: ${e.toString().split("\n").first}'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _emailFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_emailCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Email and password are required'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await ref.read(authControllerProvider.notifier).signIn(
          email: _emailCtrl.text,
          password: _passCtrl.text,
          rememberMe: _rememberMe,
        );
    if (!mounted) return;
    final err = ref.read(authControllerProvider).error;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err.toString()),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  OutlineInputBorder _border([Color? c]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c ?? AppTheme.border),
      );

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authControllerProvider).isLoading;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppTheme.primary.withOpacity(0.06),
              const Color(0xFFF8FAFC),
              AppTheme.primary.withOpacity(0.04),
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
        child: Stack(
          children: [
            // Decorative blurred orbs
            Positioned(
              top: -120,
              right: -120,
              child: Container(
                width: 420,
                height: 420,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [AppTheme.primary.withOpacity(0.10), Colors.transparent],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -160,
              left: -120,
              child: Container(
                width: 500,
                height: 500,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [AppTheme.primary.withOpacity(0.06), Colors.transparent],
                  ),
                ),
              ),
            ),
            // Card
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 440),
                  padding: const EdgeInsets.all(48),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.border, width: 0.5),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primary.withOpacity(0.06),
                        blurRadius: 40,
                        offset: const Offset(0, 12),
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 24,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [AppTheme.primary, AppTheme.primary.withOpacity(0.78)],
                            ),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.primary.withOpacity(0.3),
                                blurRadius: 14,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: const Text('O',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 22)),
                        ),
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Opstation',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    height: 1,
                                    color: _ink)),
                            SizedBox(height: 4),
                            Text('Admin Panel',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textSecondary,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.4)),
                          ],
                        ),
                      ]),
                      const SizedBox(height: 40),
                      const Text('Welcome back',
                          style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              height: 1.1,
                              letterSpacing: -0.5,
                              color: _ink)),
                      const SizedBox(height: 8),
                      const Text('Sign in to manage your organization',
                          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
                      const SizedBox(height: 36),
                      const Text('Email',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _emailCtrl,
                        focusNode: _emailFocus,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _passFocus.requestFocus(),
                        style: const TextStyle(fontSize: 14, color: _ink),
                        decoration: InputDecoration(
                          hintText: 'name@company.com',
                          hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                          prefixIcon: const Icon(Icons.email_outlined,
                              size: 18, color: AppTheme.textSecondary),
                          contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                          filled: true,
                          fillColor: const Color(0xFFFAFBFC),
                          border: _border(),
                          enabledBorder: _border(),
                          focusedBorder: _border(AppTheme.primary).copyWith(
                              borderSide: const BorderSide(color: AppTheme.primary, width: 1.5)),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text('Password',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _passCtrl,
                        focusNode: _passFocus,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                        style: const TextStyle(fontSize: 14, color: _ink),
                        decoration: InputDecoration(
                          hintText: '••••••••',
                          hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                          prefixIcon: const Icon(Icons.lock_outline,
                              size: 18, color: AppTheme.textSecondary),
                          suffixIcon: IconButton(
                            icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                size: 18,
                                color: AppTheme.textSecondary),
                            onPressed: () => setState(() => _obscure = !_obscure),
                            tooltip: _obscure ? 'Show password' : 'Hide password',
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                          filled: true,
                          fillColor: const Color(0xFFFAFBFC),
                          border: _border(),
                          enabledBorder: _border(),
                          focusedBorder: _border(AppTheme.primary).copyWith(
                              borderSide: const BorderSide(color: AppTheme.primary, width: 1.5)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      InkWell(
                        onTap: () => _setRemember(!_rememberMe),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                          child: Row(children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: Checkbox(
                                value: _rememberMe,
                                onChanged: (v) => _setRemember(v ?? true),
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text('Keep me signed in',
                                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: isLoading ? null : _forgotPassword,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Forgot password?',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.primary,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: isLoading ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            disabledBackgroundColor: AppTheme.primary.withOpacity(0.5),
                          ),
                          child: isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text('Sign in',
                                        style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: 0.2)),
                                    SizedBox(width: 8),
                                    Icon(Icons.arrow_forward, size: 18),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  '© 2026 Opstation · All rights reserved',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary.withOpacity(0.7)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
