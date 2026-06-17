import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../retailer_auth_controller.dart';
import '../../../core/theme/app_theme.dart';

/// Retailer portal login. Retailers sign in with their CODE + password
/// (the code maps to a synthetic email behind the scenes). Lives at /r/login.
class RetailerLoginScreen extends ConsumerStatefulWidget {
  const RetailerLoginScreen({super.key});
  @override
  ConsumerState<RetailerLoginScreen> createState() =>
      _RetailerLoginScreenState();
}

class _RetailerLoginScreenState extends ConsumerState<RetailerLoginScreen> {
  final _codeCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _codeFocus = FocusNode();
  final _passFocus = FocusNode();
  bool _obscure = true;

  static const _ink = Color(0xFF111827);

  @override
  void dispose() {
    _codeCtrl.dispose();
    _passCtrl.dispose();
    _codeFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_codeCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      _err('Enter your code and password');
      return;
    }
    await ref.read(retailerAuthControllerProvider.notifier).signIn(
          code: _codeCtrl.text,
          password: _passCtrl.text,
        );
    if (!mounted) return;
    final err = ref.read(retailerAuthControllerProvider).error;
    if (err != null) _err(err.toString().replaceFirst('Exception: ', ''));
  }

  void _err(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  OutlineInputBorder _border([Color? c]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c ?? AppTheme.border),
      );

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(retailerAuthControllerProvider).isLoading;
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
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.all(40),
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
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppTheme.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.storefront_outlined,
                          color: Colors.white),
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
                        Text('Retailer Portal',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.4)),
                      ],
                    ),
                  ]),
                  const SizedBox(height: 36),
                  const Text('Sign in',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: _ink)),
                  const SizedBox(height: 8),
                  const Text('Use the code and password you were given.',
                      style:
                          TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
                  const SizedBox(height: 28),
                  const Text('Code',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _ink)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _codeCtrl,
                    focusNode: _codeFocus,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _passFocus.requestFocus(),
                    style: const TextStyle(fontSize: 14, color: _ink),
                    decoration: InputDecoration(
                      hintText: 'e.g. 767',
                      prefixIcon: const Icon(Icons.badge_outlined,
                          size: 18, color: AppTheme.textSecondary),
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 12),
                      filled: true,
                      fillColor: const Color(0xFFFAFBFC),
                      border: _border(),
                      enabledBorder: _border(),
                      focusedBorder: _border(AppTheme.primary).copyWith(
                          borderSide: const BorderSide(
                              color: AppTheme.primary, width: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text('Password',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _ink)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _passCtrl,
                    focusNode: _passFocus,
                    obscureText: _obscure,
                    onSubmitted: (_) => _submit(),
                    style: const TextStyle(fontSize: 14, color: _ink),
                    decoration: InputDecoration(
                      hintText: '••••••••',
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
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 12),
                      filled: true,
                      fillColor: const Color(0xFFFAFBFC),
                      border: _border(),
                      enabledBorder: _border(),
                      focusedBorder: _border(AppTheme.primary).copyWith(
                          borderSide: const BorderSide(
                              color: AppTheme.primary, width: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: isLoading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        disabledBackgroundColor:
                            AppTheme.primary.withOpacity(0.5),
                      ),
                      child: isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Sign in',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
