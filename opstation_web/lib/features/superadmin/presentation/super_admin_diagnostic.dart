import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';

/// Shown under a "Super Admin only" error: who the app is signed in as, and what the database's two
/// super-admin checks say for THIS session. It tells a wrong login from a wrong rule at a glance.
class SuperAdminDiagnostic extends StatefulWidget {
  const SuperAdminDiagnostic({super.key, this.runner});

  /// Replaces the real lookups (for tests).
  final Future<List<String>> Function()? runner;

  @override
  State<SuperAdminDiagnostic> createState() => _SuperAdminDiagnosticState();
}

class _SuperAdminDiagnosticState extends State<SuperAdminDiagnostic> {
  late final Future<List<String>> _f = (widget.runner ?? _run)();

  static Future<List<String>> _run() async {
    final c = Supabase.instance.client;
    final user = c.auth.currentUser;
    Future<String> check(String fn) async {
      try {
        return '${await c.rpc(fn)}';
      } catch (_) {
        return 'could not run';
      }
    }

    return [
      'Signed in as: ${user?.email ?? '(not signed in)'}',
      'Login id: ${user?.id ?? '-'}',
      'is_super_admin(): ${await check('is_super_admin')}',
      '_is_super_admin(): ${await check('_is_super_admin')}',
    ];
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _f,
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.only(top: 8), child: Text('Checking this login...', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)));
        }
        final lines = snap.data ?? const ['Could not check this login.'];
        return Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('This login', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            for (final l in lines) SelectableText(l, style: const TextStyle(fontSize: 11.5)),
          ]),
        );
      },
    );
  }
}
