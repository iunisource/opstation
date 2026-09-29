// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../layout/main_layout.dart' show orgModulesProvider, userBranchesProvider;
import '../permissions/access_control.dart' show accessProvider;

/// Keeps the server's active org in step with the org shown in THIS tab.
///
/// The active org is stored server-side per login and shared by all of its
/// tabs and devices. Working in two orgs at once (two tabs, or phone + laptop)
/// meant a switch in one silently re-scoped the other: its menu lost modules
/// and lists came back empty until a refresh or re-login. Now the tab you are
/// looking at re-claims its org whenever it becomes visible, and every 30s
/// while visible; if it had to, org-scoped data reloads.
class ActiveOrgGuard extends ConsumerStatefulWidget {
  const ActiveOrgGuard({super.key});
  @override
  ConsumerState<ActiveOrgGuard> createState() => _ActiveOrgGuardState();
}

class _ActiveOrgGuardState extends ConsumerState<ActiveOrgGuard> {
  StreamSubscription<html.Event>? _vis;
  StreamSubscription<html.Event>? _focus;
  Timer? _tick;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _vis = html.document.onVisibilityChange.listen((_) {
      if (html.document.visibilityState == 'visible') _check();
    });
    _focus = html.window.onFocus.listen((_) => _check());
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (html.document.visibilityState == 'visible') _check();
    });
  }

  Future<void> _check() async {
    if (_running || !mounted) return;
    _running = true;
    try {
      final orgId = ref.read(currentUserProvider)?.orgId;
      final changed = await AuthController.reassertActiveOrg(orgId);
      if (changed && mounted) {
        // Anything that loaded while the server pointed at the other org came
        // back empty — reload the org-scoped basics.
        ref.invalidate(orgModulesProvider);
        ref.invalidate(userBranchesProvider);
        ref.invalidate(accessProvider);
        final orgName = ref.read(currentUserProvider)?.orgName ?? 'this organization';
        ScaffoldMessenger.maybeOf(context)
          ?..clearSnackBars()
          ..showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 8),
            content: Text('Another tab or device switched organization. '
                'This tab is back on $orgName — reload to refresh this screen.'),
            action: SnackBarAction(
                label: 'Reload', onPressed: () => html.window.location.reload()),
          ));
      }
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    _vis?.cancel();
    _focus?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
