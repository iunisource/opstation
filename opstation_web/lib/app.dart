import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/app_router.dart';
import 'features/auth/auth_controller.dart';
import 'core/theme/app_theme.dart';

class OpstationWebApp extends ConsumerWidget {
  const OpstationWebApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    );
  }
}
