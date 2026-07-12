import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import '../retailer_auth_controller.dart';

/// Forced on first login. Retailers are provisioned with their CODE as the
/// temporary password (see the web provisioning flow), so leaving it unchanged
/// means anyone who knows the shop's code can sign in as them. The router sends
/// them here whenever `mustChangePassword` is set, and there is no way past it
/// except setting a new password.
class RetailerChangePasswordScreen extends ConsumerStatefulWidget {
  const RetailerChangePasswordScreen({super.key});

  @override
  ConsumerState<RetailerChangePasswordScreen> createState() =>
      _RetailerChangePasswordScreenState();
}

class _RetailerChangePasswordScreenState
    extends ConsumerState<RetailerChangePasswordScreen> {
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  @override
  void dispose() {
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save(T t) async {
    final p1 = _newCtrl.text;
    final p2 = _confirmCtrl.text;
    if (p1.length < 6) {
      _err(t.passwordTooShort);
      return;
    }
    if (p1 != p2) {
      _err(t.passwordsDoNotMatch);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(retailerAuthControllerProvider.notifier)
          .changePassword(p1);
      // The router reacts to mustChangePassword flipping false and moves on.
    } catch (e) {
      _err(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
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
                      const Align(
                        alignment: Alignment.centerRight,
                        child: LanguageToggle(),
                      ),
                      const SizedBox(height: 28),
                      Icon(Icons.lock_reset,
                          size: 40, color: AppColors.primary),
                      const SizedBox(height: 16),
                      Text(t.setNewPassword,
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(t.setNewPasswordSub,
                          style: TextStyle(
                              fontSize: 13.5,
                              height: 1.4,
                              color: AppColors.textSecondaryLight)),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _newCtrl,
                        obscureText: _obscure,
                        autofocus: true,
                        style: const TextStyle(fontSize: 18),
                        decoration: InputDecoration(
                          labelText: t.newPassword,
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
                      const SizedBox(height: 14),
                      TextField(
                        controller: _confirmCtrl,
                        obscureText: _obscure,
                        style: const TextStyle(fontSize: 18),
                        onSubmitted: (_) => _saving ? null : _save(t),
                        decoration: InputDecoration(
                          labelText: t.confirmPassword,
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 22),
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _saving ? null : () => _save(t),
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(t.save,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700)),
                        ),
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
