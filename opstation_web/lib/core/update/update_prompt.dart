// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';

/// Tells web users when a new version of Opstation has been published, with a
/// "Refresh now" button that loads it cleanly (drops the cached app first).
///
/// How it knows: the app's code file (main.dart.js) changes with every build,
/// and the hosting stamps it with an ETag. It is checked when the app starts,
/// every 3 minutes, and whenever the tab comes back into view.
class UpdatePrompt extends StatefulWidget {
  final Widget child;
  const UpdatePrompt({super.key, required this.child});
  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

class _UpdatePromptState extends State<UpdatePrompt> {
  String? _loaded;
  bool _show = false;
  DateTime? _snoozeUntil;
  Timer? _timer;
  StreamSubscription<html.Event>? _vis;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(minutes: 3), (_) => _check());
    _vis = html.document.onVisibilityChange.listen((_) {
      if (html.document.visibilityState == 'visible') _check();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _vis?.cancel();
    super.dispose();
  }

  /// Fingerprint of what the server has now. main.dart.js holds the app's
  /// code and changes with every build; the hosting gives it an ETag (a hash of
  /// the file), read with a light HEAD request. The bootstrap file is added in
  /// case the ETag is missing.
  Future<String?> _signature() async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    String? tag;
    try {
      final r = await html.HttpRequest.request('/main.dart.js?check=$ts', method: 'HEAD',
          requestHeaders: {'Cache-Control': 'no-cache'});
      tag = r.getResponseHeader('etag') ?? r.getResponseHeader('last-modified') ?? r.getResponseHeader('content-length');
    } catch (_) {}
    String? boot;
    try {
      final r = await html.HttpRequest.request('/flutter_bootstrap.js?check=$ts',
          requestHeaders: {'Cache-Control': 'no-cache'});
      final t = r.responseText ?? '';
      if (t.isNotEmpty) {
        var h = 0;
        for (final c in t.codeUnits) {
          h = (h * 31 + c) & 0x7fffffff;
        }
        boot = '${t.length}:$h';
      }
    } catch (_) {}
    if (tag == null && boot == null) return null; // offline — try again later
    return '${tag ?? ''}|${boot ?? ''}';
  }

  Future<void> _check() async {
    if (_show) return;
    final sig = await _signature();
    if (sig == null || !mounted) return;
    if (_loaded == null) {
      _loaded = sig;
      return;
    }
    if (sig != _loaded) {
      if (_snoozeUntil != null && DateTime.now().isBefore(_snoozeUntil!)) return;
      setState(() => _show = true);
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final sw = html.window.navigator.serviceWorker;
      if (sw != null) {
        for (final r in await sw.getRegistrations()) {
          // Keep the push-notification worker; drop the app's cached copy.
          final scope = r.scope ?? '';
          if (!scope.contains('/push/')) await r.unregister();
        }
      }
    } catch (_) {}
    try {
      final caches = html.window.caches;
      if (caches != null) {
        final keys = await caches.keys();
        for (final k in keys) {
          await caches.delete('$k');
        }
      }
    } catch (_) {}
    html.window.location.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      if (_show)
        Positioned(
          left: 12,
          right: 12,
          bottom: 18,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Material(
                elevation: 14,
                shadowColor: Colors.black38,
                borderRadius: BorderRadius.circular(14),
                color: const Color(0xFF0F1B3D),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                  child: Row(children: [
                    const Icon(Icons.system_update_alt_rounded, color: Colors.white),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('A new version of Opstation is out',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                        SizedBox(height: 2),
                        Text('Refresh to start using it. Save any open work first.',
                            style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                      ]),
                    ),
                    TextButton(
                      onPressed: _refreshing
                          ? null
                          : () => setState(() {
                                _show = false;
                                _snoozeUntil = DateTime.now().add(const Duration(minutes: 30));
                              }),
                      child: const Text('Later', style: TextStyle(color: Colors.white70)),
                    ),
                    const SizedBox(width: 4),
                    ElevatedButton(
                      onPressed: _refreshing ? null : _refresh,
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2F6FED), foregroundColor: Colors.white),
                      child: _refreshing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Refresh now'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}
