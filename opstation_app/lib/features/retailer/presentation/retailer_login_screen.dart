import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import '../retailer_auth_controller.dart';
import 'role_picker_screen.dart';

/// Retailer sign-in: CODE + password.
///
/// Deliberately a different UI from the staff login. A shopkeeper signs in
/// rarely, types a numeric code rather than an email, and may not read English
/// comfortably — so: larger type, a numeric keypad by default, and the language
/// toggle visible BEFORE sign-in rather than behind it.
class RetailerLoginScreen extends ConsumerStatefulWidget {
  const RetailerLoginScreen({super.key});

  @override
  ConsumerState<RetailerLoginScreen> createState() =>
      _RetailerLoginScreenState();
}

class _RetailerLoginScreenState extends ConsumerState<RetailerLoginScreen> {
  final _codeCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit(T t) async {
    if (_codeCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      _err(t.enterCodeAndPassword);
      return;
    }
    await ref.read(retailerAuthControllerProvider.notifier).signIn(
          code: _codeCtrl.text,
          password: _passCtrl.text,
        );
    if (!mounted) return;
    final err = ref.read(retailerAuthControllerProvider).error;
    if (err != null) {
      _err(err.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _err(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final loading = ref.watch(retailerAuthControllerProvider).isLoading;
    return RetailerLocaleScope(
      child: Builder(builder: (context) {
        final t = T.of(context);
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton.icon(
                            onPressed: loading
                                ? null
                                : () async {
                                    await setLastLoginRole(null);
                                    if (context.mounted) context.go('/');
                                  },
                            icon: const Icon(Icons.arrow_back, size: 18),
                            label: Text(t.back),
                          ),
                          const LanguageToggle(),
                        ],
                      ),
                      const SizedBox(height: 20),
                      // Center() so the square is not stretched to full width by
                      // the parent Column's CrossAxisAlignment.stretch — which is
                      // what turned the logo into a wide slab.
                      Center(
                        child: Container(
                          height: 72,
                          width: 72,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(19),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primary.withValues(alpha: 0.28),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.storefront,
                              color: Colors.white, size: 34),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        t.retailerSignIn,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t.askAdminForCode,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13.5,
                            height: 1.4,
                            color: AppColors.textSecondaryLight),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _codeCtrl,
                        autofocus: true,
                        // Codes are numeric in practice — save the shopkeeper a
                        // keyboard switch. Not enforced, so an alphanumeric code
                        // still works if one ever exists.
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.deny(RegExp(r'\s')),
                        ],
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          labelText: t.yourCode,
                          hintText: t.codeHint,
                          prefixIcon: const Icon(Icons.tag),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _passCtrl,
                        obscureText: _obscure,
                        style: const TextStyle(fontSize: 18),
                        onSubmitted: (_) => loading ? null : _submit(t),
                        decoration: InputDecoration(
                          labelText: t.password,
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 22),
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: loading ? null : () => _submit(t),
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: loading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(t.signIn,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextButton(
                        onPressed: () async {
                          await setLastLoginRole(null);
                          if (context.mounted) context.go('/');
                        },
                        child: Text(t.notYou,
                            style: const TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
