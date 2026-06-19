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

  Future<void> _openSignup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _SignupDialog(),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thanks! Your request has been sent. We will be in touch shortly.'),
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
      backgroundColor: Colors.white,
      body: LayoutBuilder(
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
    );
  }

  // ───────────────────────────── brand panel (left) ─────────────────────────
  Widget _brandPanel() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.primary,
            Color.lerp(AppTheme.primary, const Color(0xFF0B1220), 0.55)!,
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(top: -100, left: -80, child: _orb(360, 0.16)),
          Positioned(bottom: -150, right: -110, child: _orb(470, 0.10)),
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
                      color: Colors.white.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.25)),
                    ),
                    alignment: Alignment.center,
                    child: const Text('O',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
                  ),
                  const SizedBox(width: 12),
                  const Text('Opstation',
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                ]),
                const Spacer(),
                const Text(
                  'Run your whole operation\nfrom a single panel.',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                      letterSpacing: -0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'Inventory, sales, POS, manufacturing, financials and facilities — unified across every branch, in real time.',
                  style: TextStyle(color: Colors.white.withOpacity(0.82), fontSize: 15, height: 1.5),
                ),
                const SizedBox(height: 36),
                _brandFeature(Icons.inventory_2_outlined, 'Multi-branch inventory, POS & delivery'),
                _brandFeature(Icons.account_balance_outlined, 'Real-time financials, ledgers & reports'),
                _brandFeature(Icons.precision_manufacturing_outlined, 'Production, assets & facility upkeep'),
                _brandFeature(Icons.verified_user_outlined, 'Role-based access & full audit trail'),
                const Spacer(),
                Text('© 2026 Opstation · All rights reserved',
                    style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _orb(double size, double opacity) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [Colors.white.withOpacity(opacity), Colors.transparent]),
        ),
      );

  Widget _brandFeature(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.95), fontSize: 14.5, fontWeight: FontWeight.w500)),
          ),
        ]),
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
              const Text('Sign in to manage your organization',
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

class _SignupDialog extends StatefulWidget {
  const _SignupDialog();
  @override
  State<_SignupDialog> createState() => _SignupDialogState();
}

class _SignupDialogState extends State<_SignupDialog> {
  final _name = TextEditingController();
  final _org = TextEditingController();
  final _contact = TextEditingController();
  final _email = TextEditingController();
  String? _industry;
  bool _submitting = false;
  String? _error;

  static const _industries = [
    'Manufacturing',
    'Retail',
    'Wholesale & Distribution',
    'Automotive & Parts',
    'Textiles & Apparel',
    'Food & Beverage',
    'Pharmaceuticals & Healthcare',
    'Construction & Building Materials',
    'Electronics & Hardware',
    'Chemicals',
    'Logistics & Transport',
    'Agriculture',
    'Energy & Utilities',
    'Services',
    'Other',
  ];

  @override
  void dispose() {
    _name.dispose();
    _org.dispose();
    _contact.dispose();
    _email.dispose();
    super.dispose();
  }

  bool _looksLikeEmail(String s) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);

  Future<void> _submit() async {
    final name = _name.text.trim();
    final org = _org.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty || org.isEmpty || email.isEmpty) {
      setState(() => _error = 'Name, organization and email are required.');
      return;
    }
    if (!_looksLikeEmail(email)) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      final res = await Supabase.instance.client.functions.invoke('signup-request', body: {
        'name': name,
        'orgName': org,
        'contact': _contact.text.trim(),
        'email': email,
        'industry': _industry ?? '',
      });
      if (res.status != 200) {
        setState(() { _submitting = false; _error = 'Could not submit (status ${res.status}). Please try again.'; });
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = 'Could not submit: ${e.toString().split("\n").first}';
      });
    }
  }

  InputDecoration _dec(String label) =>
      InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sign up'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Tell us a bit about your business and we will get you set up.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
            const SizedBox(height: 16),
            TextField(controller: _name, decoration: _dec('Name *'), textInputAction: TextInputAction.next),
            const SizedBox(height: 12),
            TextField(controller: _org, decoration: _dec('Organization name *'), textInputAction: TextInputAction.next),
            const SizedBox(height: 12),
            TextField(controller: _contact, decoration: _dec('Contact number'),
                keyboardType: TextInputType.phone, textInputAction: TextInputAction.next),
            const SizedBox(height: 12),
            TextField(controller: _email, decoration: _dec('Email address *'),
                keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit()),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _industry,
              isExpanded: true,
              decoration: _dec('Industry'),
              items: [for (final i in _industries) DropdownMenuItem(value: i, child: Text(i))],
              onChanged: (v) => setState(() => _industry = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
                ),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Submit request'),
        ),
      ],
    );
  }
}
