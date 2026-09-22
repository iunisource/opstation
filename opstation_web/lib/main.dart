// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';

const _sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');

/// Dump a fatal error straight into the page DOM (bypassing Flutter's canvas),
/// so it is visible even when the app has gone blank. Idempotent: replaces any
/// earlier dump. Never throws.
int _domFatalCount = 0;
void _domFatal(Object error, StackTrace? stack) {
  try {
    _domFatalCount++;
    var el = html.document.getElementById('opstation-fatal');
    if (el == null) {
      el = html.DivElement()
        ..id = 'opstation-fatal'
        ..style.position = 'fixed'
        ..style.left = '0'
        ..style.right = '0'
        ..style.bottom = '0'
        ..style.maxHeight = '55%'
        ..style.overflow = 'auto'
        ..style.zIndex = '2147483647'
        ..style.background = '#7f0000'
        ..style.color = '#ffffff'
        ..style.font = '12px/1.45 monospace'
        ..style.padding = '12px 14px'
        ..style.whiteSpace = 'pre-wrap'
        ..text = 'OPSTATION ERROR LOG (copy this and send it) — newest at top\n';
      html.document.body?.append(el);
    }
    // Keep every error (newest first) so navigating away never loses the one
    // that mattered. Only the first ~12 stack frames are kept per error.
    final frames = (stack ?? StackTrace.empty).toString().split('\n').take(12).join('\n');
    final entry = html.DivElement()
      ..style.borderTop = '1px solid #ff8080'
      ..style.margin = '8px 0 0'
      ..style.padding = '8px 0 0'
      ..text = '#$_domFatalCount  ${html.window.location.hash}\n$error\n$frames';
    el.insertBefore(entry, el.firstChild?.nextNode);
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Render build/layout errors as readable on-screen text instead of a blank
  // white page, and keep the crash contained to the failing widget subtree so
  // the rest of the app stays usable. The message is shown so it can be reported.
  // Crash-proof error widget. It depends on NOTHING above it (no Material,
  // MediaQuery, Scrollable or DefaultTextStyle), so it renders even when the
  // failing widget is at/above MaterialApp — otherwise the replacement itself
  // double-faults and the page just goes blank.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: const TextStyle(fontSize: 13, color: Color(0xFF222222), decoration: TextDecoration.none),
        child: Container(
          color: const Color(0xFFFFFFFF),
          alignment: Alignment.topLeft,
          padding: const EdgeInsets.all(24),
          child: Text(
            'Something went wrong on this screen.\n'
            'Please screenshot this and send it, then go back and try again.\n\n'
            '${details.exceptionAsString()}\n\n'
            'Where: ${details.context ?? '-'}\n'
            'Library: ${details.library ?? '-'}',
            style: const TextStyle(fontSize: 13, color: Color(0xFFC62828), decoration: TextDecoration.none),
          ),
        ),
      ),
    );
  };

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

      // Surface every fatal error in the page DOM: framework (build/paint)
      // errors via FlutterError.onError, and uncaught async errors via a
      // guarded zone. Chains onto Sentry's existing handler.
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails d) {
        _domFatal(d.exception, d.stack);
        prevOnError?.call(d);
      };
      runZonedGuarded(
        () => runApp(const ProviderScope(child: OpstationWebApp())),
        (Object e, StackTrace st) => _domFatal(e, st),
      );
    },
  );
}
