// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import 'login_video_api.dart';

/// The login page's background video, drawn by the browser behind the Flutter widgets: looping, silent until the person's first touch (browsers require it), then at half volume;
/// starting by itself. It fades in over the still background once it is really playing, and if anything
/// goes wrong (no file, blocked, an error) it simply stays hidden, so signing in never depends on it.
class LoginVideoLayer extends StatefulWidget {
  const LoginVideoLayer({super.key, required this.controller, required this.src});

  final LoginVideoController controller;
  final String src;

  @override
  State<LoginVideoLayer> createState() => _LoginVideoLayerState();
}

class _LoginVideoLayerState extends State<LoginVideoLayer> {
  static int _seq = 0;
  late final String _viewType = 'opstation-login-video-${_seq++}';
  html.VideoElement? _video;
  bool _enabled = false;
  bool _gone = false;
  bool _userMuted = false; // the person pressed the mute button: never switch the sound on again by ourselves
  static const double _volume = 0.5;
  StreamSubscription<dynamic>? _g1, _g2, _g3;

  static bool _reducedMotion() {
    try {
      return html.window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    } catch (_) {
      return false;
    }
  }

  /// The browser's network information (navigator.connection), where it has one (Chrome does, Safari and
  /// Firefox do not).
  static JSObject? _connection() {
    try {
      final nav = globalContext.getProperty<JSAny?>('navigator'.toJS);
      if (nav == null) return null;
      final c = (nav as JSObject).getProperty<JSAny?>('connection'.toJS);
      return c as JSObject?;
    } catch (_) {
      return null;
    }
  }

  static bool _saveData() {
    try {
      final c = _connection();
      if (c == null) return false;
      final v = c.getProperty<JSAny?>('saveData'.toJS);
      return v != null && (v as JSBoolean).toDart;
    } catch (_) {
      return false;
    }
  }

  static bool _slow() {
    try {
      final c = _connection();
      if (c == null) return false;
      final t = c.getProperty<JSAny?>('effectiveType'.toJS);
      return isSlowConnectionType(t == null ? null : (t as JSString).toDart);
    } catch (_) {
      return false;
    }
  }

  void _status(LoginVideoStatus s) {
    // Never while the framework is building or tearing down: the listeners redraw.
    Future.microtask(() {
      if (_gone && s != LoginVideoStatus.off) return;
      try {
        widget.controller.status.value = s;
      } catch (_) {}
    });
  }

  @override
  void initState() {
    super.initState();
    _enabled = shouldPlayLoginVideo(
      width: (html.window.innerWidth ?? 0).toDouble(),
      reducedMotion: _reducedMotion(),
      saveData: _saveData(),
      slowConnection: _slow(),
    );
    if (!_enabled) return;
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final v = html.VideoElement()
        ..autoplay = true
        ..muted = true
        ..loop = true
        ..preload = 'auto'
        ..setAttribute('playsinline', '')
        ..setAttribute('muted', '')
        ..setAttribute('aria-hidden', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.pointerEvents = 'none'
        ..style.border = 'none'
        ..style.opacity = '0'
        ..style.transition = 'opacity 900ms ease';
      final source = html.SourceElement()
        ..src = widget.src
        ..type = 'video/mp4';
      v.append(source);
      source.onError.listen((_) => _fail());
      v.onError.listen((_) => _fail());
      v.onPlaying.listen((_) {
        v.style.opacity = '1';
        _status(LoginVideoStatus.playing);
        _tryUnmute();
      });
      _video = v;
      Future.microtask(() async {
        try {
          await v.play();
        } catch (_) {
          // The browser would not start it by itself: the still background stays.
          _fail();
        }
      });
      return v;
    });
    widget.controller.bind(_toggle, _toggleMute);
    _status(LoginVideoStatus.loading);
    // Sound needs a touch from the person first: on the first click, tap or key press, switch it on.
    _g1 = html.document.onMouseDown.listen((_) => _tryUnmute());
    _g2 = html.document.onKeyDown.listen((_) => _tryUnmute());
    _g3 = html.document.onTouchStart.listen((_) => _tryUnmute());
  }

  void _setMuted(bool m) {
    final v = _video;
    if (v == null) return;
    v.muted = m;
    v.volume = _volume; // half volume
    try {
      widget.controller.muted.value = m;
    } catch (_) {}
  }

  /// Sound on at half volume, if the browser allows it; otherwise the video carries on silently.
  void _tryUnmute() {
    final v = _video;
    if (v == null || _gone || _userMuted || !v.muted || v.paused) return;
    _setMuted(false);
    // A browser that refuses sound pauses the video: put it back to silent playing.
    Future.delayed(const Duration(milliseconds: 250), () {
      if (_gone) return;
      if (v.paused && !_userPaused) {
        _setMuted(true);
        v.play().catchError((_) {});
      }
    });
  }

  bool _userPaused = false;

  void _toggleMute() {
    final v = _video;
    if (v == null) return;
    if (v.muted) {
      _userMuted = false;
      _setMuted(false);
      if (v.paused && !_userPaused) v.play().catchError((_) {});
    } else {
      _userMuted = true;
      _setMuted(true);
    }
  }

  void _fail() {
    _video?.style.opacity = '0';
    _status(LoginVideoStatus.off);
  }

  void _toggle() {
    final v = _video;
    if (v == null) return;
    if (v.paused) {
      _userPaused = false;
      v.play().catchError((_) {});
      _status(LoginVideoStatus.playing);
    } else {
      _userPaused = true;
      v.pause();
      _status(LoginVideoStatus.paused);
    }
  }

  @override
  void dispose() {
    _gone = true;
    widget.controller.bind(null);
    _g1?.cancel();
    _g2?.cancel();
    _g3?.cancel();
    final v = _video;
    if (v != null) {
      v.pause();
      v.removeAttribute('src');
      v.children.clear();
      v.load(); // lets go of the file
    }
    _status(LoginVideoStatus.off);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return const SizedBox.shrink();
    return IgnorePointer(child: HtmlElementView(viewType: _viewType));
  }
}
