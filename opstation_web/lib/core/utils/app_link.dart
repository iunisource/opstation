// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// True when Opstation runs as an installed app (Add to Home Screen / Install
/// app) rather than in a browser tab.
bool get isInstalledApp {
  try {
    for (final m in const ['standalone', 'fullscreen', 'minimal-ui', 'window-controls-overlay']) {
      if (html.window.matchMedia('(display-mode: $m)').matches) return true;
    }
  } catch (_) {}
  return false;
}

/// Opens an in-app screen link such as '/financials/journal-vouchers?id=JV-1'.
/// In a browser tab it opens a new tab (as before). In the installed app a new
/// tab would jump out to the browser, so it opens inside the app instead
/// (Back returns to where you were).
void openAppLink(BuildContext context, String path) {
  final p = path.startsWith('/') ? path : '/$path';
  if (isInstalledApp) {
    GoRouter.of(context).push(p);
    return;
  }
  html.window.open('${html.window.location.origin}/#$p', '_blank');
}
