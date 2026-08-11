import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/router/app_router.dart';
import 'features/auth/auth_controller.dart';
import 'core/theme/app_theme.dart';

class OpstationWebApp extends ConsumerStatefulWidget {
  const OpstationWebApp({super.key});

  @override
  ConsumerState<OpstationWebApp> createState() => _OpstationWebAppState();
}

class _OpstationWebAppState extends ConsumerState<OpstationWebApp> {
  StreamSubscription<AuthState>? _authSub;
  bool _recoveryOpen = false;

  @override
  void initState() {
    super.initState();
    // Catch the password-recovery deep link. supabase_flutter exchanges the
    // recovery code for a session asynchronously (a network round-trip), so
    // this event lands after the first frame — subscribing here at the root
    // reliably catches it. We then let the user set a new password, which
    // writes auth.users: the single source of truth for both web and mobile.
    _authSub =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.passwordRecovery) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _promptSetNewPassword());
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _promptSetNewPassword() async {
    if (_recoveryOpen) return;
    // Dialogs need a context under the app's Navigator. The root widget sits
    // above MaterialApp, so we borrow the router's navigator context.
    final ctx =
        ref.read(webRouterProvider).routerDelegate.navigatorKey.currentContext;
    if (ctx == null) return;
    _recoveryOpen = true;

    final ctrl = TextEditingController();
    final newPass = await showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) {
        bool obscure = true;
        return StatefulBuilder(
          builder: (dctx, setSt) => AlertDialog(
            title: const Text('Set a new password'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                    'You opened a password reset link. Choose a new password to finish.'),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    hintText: 'New password (min 6 chars)',
                    suffixIcon: IconButton(
                      icon: Icon(
                          obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setSt(() => obscure = !obscure),
                    ),
                  ),
                  onSubmitted: (_) {
                    if (ctrl.text.trim().length >= 6) {
                      Navigator.of(dctx).pop(ctrl.text.trim());
                    }
                  },
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  final v = ctrl.text.trim();
                  if (v.length >= 6) Navigator.of(dctx).pop(v);
                },
                child: const Text('Update password'),
              ),
            ],
          ),
        );
      },
    );

    if (newPass != null && newPass.length >= 6) {
      try {
        await Supabase.instance.client.auth
            .updateUser(UserAttributes(password: newPass));
        // Clear the temporary recovery session so they sign in fresh.
        await Supabase.instance.client.auth.signOut();
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
          const SnackBar(
            content: Text('Password updated. Sign in with your new password.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } catch (e) {
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.danger,
            content: Text(
                'Could not update password: ${e.toString().split("\n").first}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
    _recoveryOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    // When auth state flips to null mid-session (token expired, sign-out),
    // the router's redirect guard will send the user to /login automatically.
    ref.listen<AsyncValue<dynamic>>(authControllerProvider, (prev, next) {
      if (prev?.value != null && next.value == null) {
        ref.read(webRouterProvider).go('/login');
      }
    });
    final router = ref.watch(webRouterProvider);
    return MaterialApp.router(
      title: 'Opstation Admin',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: router,
      // Make all on-screen text selectable + copyable app-wide. Flutter renders
      // to <canvas>, so text isn't natively selectable; SelectionArea provides
      // drag-to-select and Ctrl+C (plus a floating Copy button) everywhere.
      // Text fields, buttons and other gestures keep working — they claim their
      // own gestures ahead of the selection.
      builder: (context, child) =>
          SelectionArea(child: child ?? const SizedBox.shrink()),
    );
  }
}
