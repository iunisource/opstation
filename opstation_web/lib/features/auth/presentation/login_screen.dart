import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import 'signup_wizard_screen.dart';

/// Destination for the "Partner Retailer Portal" button.
/// Opened in the same tab; swap for any URL (in-app hash route or external).
const String _kRetailerLoginUrl = 'https://opstation-f06c7.web.app/#/r/login';

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

  // Rotating headline word on the brand panel.
  static const _rotWords = ['trading.', 'distribution.', 'manufacturing.', 'retail.', 'your empire.'];
  int _rotIndex = 0;
  Timer? _rotTimer;

  @override
  void initState() {
    super.initState();
    _loadRemember();
    _rotTimer = Timer.periodic(const Duration(milliseconds: 2600), (_) {
      if (mounted) setState(() => _rotIndex = (_rotIndex + 1) % _rotWords.length);
    });
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
    _rotTimer?.cancel();
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

  Future<void> _openSignup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const SignupWizardScreen()),
    );
  }

  OutlineInputBorder _border([Color? c]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c ?? AppTheme.border),
      );

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authControllerProvider).isLoading;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth < 900) return _formPanel(isLoading, showLogo: true);
              return Row(
                children: [
                  Expanded(flex: 6, child: _brandPanel()),
                  SizedBox(width: 520, child: _formPanel(isLoading, showLogo: false)),
                ],
              );
            },
          ),
          Positioned(
            top: 18,
            right: 24,
            child: OutlinedButton.icon(
              onPressed: _openRetailerLogin,
              icon: const Icon(Icons.storefront_outlined, size: 18),
              label: const Text('Partner Retailer Portal'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                backgroundColor: Colors.white,
                side: const BorderSide(color: AppTheme.primary, width: 1.4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openRetailerLogin() {
    html.window.open(_kRetailerLoginUrl, '_self');
  }

  // ───────────────────────────── brand panel (left) ─────────────────────────
  // Dark, premium, quietly animated. The one job: make signing in feel like
  // stepping onto the bridge of the operation.
  Widget _brandPanel() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B1220), Color(0xFF111B33), Color(0xFF16234A)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(top: -120, right: -60, child: _orb(420, 0.16)),
          Positioned(bottom: -180, left: -120, child: _orb(520, 0.10)),
          Positioned(top: 180, left: -140, child: _orb(300, 0.08)),
          Padding(
            padding: const EdgeInsets.all(56),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppTheme.primary, Color(0xFF4B84F5)]),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                            color: AppTheme.primary.withOpacity(0.45),
                            blurRadius: 22,
                            offset: const Offset(0, 6)),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Text('O',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
                  ),
                  const SizedBox(width: 12),
                  const Text('Opstation',
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withOpacity(0.18)),
                    ),
                    child: const Text('ERP',
                        style: TextStyle(
                            color: Color(0xFF9DBBFA),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2)),
                  ),
                ]),
                const Spacer(),
                Text('PLANET\'S BEST ERP FOR TRADING & DISTRIBUTION',
                    style: TextStyle(
                        color: const Color(0xFF9DBBFA).withOpacity(0.9),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.2)),
                const SizedBox(height: 16),
                const Text(
                  'Built to run',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 46,
                      fontWeight: FontWeight.w800,
                      height: 1.08,
                      letterSpacing: -1.2),
                ),
                SizedBox(
                  height: 58,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0, 0.5), end: Offset.zero)
                            .animate(anim),
                        child: child,
                      ),
                    ),
                    child: Text(
                      _rotWords[_rotIndex],
                      key: ValueKey(_rotIndex),
                      style: const TextStyle(
                          color: Color(0xFF4B84F5),
                          fontSize: 46,
                          fontWeight: FontWeight.w800,
                          height: 1.08,
                          letterSpacing: -1.2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Purchase to profit, warehouse to doorstep — every branch, every book,\nlive in one place. Sign in and take the wheel.',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.62),
                      fontSize: 15.5,
                      height: 1.6,
                      fontWeight: FontWeight.w400),
                ),
                const SizedBox(height: 28),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final m in const [
                    'Inventory', 'Sales', 'POS', 'Manufacturing',
                    'Financials', 'Field Sales', 'HR'
                  ])
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.14)),
                      ),
                      child: Text(m,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600)),
                    ),
                ]),
                const Spacer(),
                _reassurance(),
                const SizedBox(height: 18),
                Text('© 2026 Opstation · All rights reserved',
                    style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // A quiet trust line — what matters to someone signing in to run their
  // business, not a feature pitch.
  Widget _reassurance() => Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: Colors.white.withOpacity(0.45)),
          const SizedBox(width: 8),
          Text('Secured & encrypted',
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13, fontWeight: FontWeight.w500)),
          Container(
            width: 3,
            height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.3), shape: BoxShape.circle),
          ),
          Icon(Icons.cloud_done_outlined, size: 16, color: Colors.white.withOpacity(0.45)),
          const SizedBox(width: 8),
          Text('Backed up nightly',
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      );

  Widget _orb(double size, double opacity) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [AppTheme.primary.withOpacity(opacity), Colors.transparent]),
        ),
      );

  // ───────────────────────────── form panel (right) ─────────────────────────
  Widget _formPanel(bool isLoading, {required bool showLogo}) {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showLogo) ...[
                Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppTheme.primary, AppTheme.primary.withOpacity(0.78)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text('O',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
                  ),
                  const SizedBox(width: 12),
                  const Text('Opstation',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink)),
                ]),
                const SizedBox(height: 36),
              ],
              const Text('Welcome back',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      letterSpacing: -0.5,
                      color: _ink)),
              const SizedBox(height: 8),
              const Text('Sign in to your workspace',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
              const SizedBox(height: 36),
              const Text('Email',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
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
                  prefixIcon: const Icon(Icons.email_outlined, size: 18, color: AppTheme.textSecondary),
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
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
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
                  prefixIcon: const Icon(Icons.lock_outline, size: 18, color: AppTheme.textSecondary),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
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
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  InkWell(
                    onTap: () => _setRemember(!_rememberMe),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: Checkbox(
                            value: _rememberMe,
                            onChanged: (v) => _setRemember(v ?? true),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text('Keep me signed in',
                            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      ]),
                    ),
                  ),
                  TextButton(
                    onPressed: isLoading ? null : _forgotPassword,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Forgot password?',
                        style: TextStyle(fontSize: 13, color: AppTheme.primary, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 22),
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
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Sign in',
                                style: TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.2)),
                            SizedBox(width: 8),
                            Icon(Icons.arrow_forward, size: 18),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('New to Opstation?',
                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                  TextButton(
                    onPressed: _openSignup,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Sign up',
                        style: TextStyle(fontSize: 13, color: AppTheme.primary, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock_outline, size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('Secured & encrypted connection.',
                        style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary.withOpacity(0.9)),
                        textAlign: TextAlign.center),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
