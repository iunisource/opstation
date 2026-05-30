// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';

const _sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sentry wraps the rest of init so errors during startup and runtime
  // are both caught. Empty DSN (dev builds without --dart-define) is
  // safe — init is a no-op and events never leave the browser.
  await SentryFlutter.init(
    (options) {
      options.dsn = _sentryDsn;
      options.environment = kReleaseMode ? 'production' : 'development';
      options.tracesSampleRate = 0.2;
      options.attachStacktrace = true;
      options.sendDefaultPii = false;
    },
    appRunner: () async {
      await Supabase.initialize(
        url: 'https://xgptodkasmytddmdnbtb.supabase.co',
        anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhncHRvZGthc215dGRkbWRuYnRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2NzA5MjUsImV4cCI6MjA5MjI0NjkyNX0.pc1VsvsvtnkBHyRzuXzzuspSTJRqU_BQgQulMQ9UCac',
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          autoRefreshToken: true,
        ),
      );
      html.document.addEventListener('contextmenu', (e) => e.preventDefault());
      runApp(const ProviderScope(child: OpstationWebApp()));
    },
  );
}
