import 'package:flutter/foundation.dart';

/// What the login page's background video is doing.
enum LoginVideoStatus {
  /// Not playing and not going to: a phone, a slow connection, reduced motion, no video file, or an error.
  /// The still background shows instead.
  off,

  /// Asked for, not started yet.
  loading,
  playing,

  /// The person pressed pause.
  paused,
}

/// The link between the video (on the web) and the pause button (everywhere).
class LoginVideoController {
  final ValueNotifier<LoginVideoStatus> status = ValueNotifier(LoginVideoStatus.off);
  VoidCallback? _toggle;
  VoidCallback? _toggleMute;

  /// True while the sound is off. It starts true: browsers only let a page make sound by itself after the
  /// person has touched it, so the sound comes on at the first click or key press (unless they muted it).
  final ValueNotifier<bool> muted = ValueNotifier(true);

  /// The web video hands over how to pause / resume it.
  void bind(VoidCallback? toggle, [VoidCallback? toggleMute]) {
    _toggle = toggle;
    _toggleMute = toggleMute;
  }

  /// Sound on / off.
  void mute() => _toggleMute?.call();

  /// Pause when it plays, play when it is paused.
  void toggle() => _toggle?.call();

  void dispose() {
    status.dispose();
    muted.dispose();
  }
}

/// Whether the login page should play its background video. It does not on a narrow screen (a phone: the
/// still picture is enough, and no data is spent), when the person's device asks for less motion, when the
/// browser says data saving is on, or on a slow connection. In all of these the still background shows.
bool shouldPlayLoginVideo({
  required double width,
  required bool reducedMotion,
  required bool saveData,
  required bool slowConnection,
  double minWidth = 900,
}) =>
    width >= minWidth && !reducedMotion && !saveData && !slowConnection;

/// The connection types the browser reports as too slow for a background video.
bool isSlowConnectionType(String? effectiveType) => const {'slow-2g', '2g', '3g'}.contains(effectiveType);
