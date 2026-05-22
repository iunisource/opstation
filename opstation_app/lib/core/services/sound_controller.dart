import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-app sound preference + playback.
///
/// Uses the `audioplayers` plugin with short WAV tones so we get reliable
/// audio on both emulators and real devices (SystemSound.click isn't
/// routed consistently on emulators).
///
/// Preference is in-memory for Slice 3a; persisted via SharedPreferences in 3b.
class SoundController extends Notifier<bool> {
  late final AudioPlayer _player;

  @override
  bool build() {
    _player = AudioPlayer();
    _player.setReleaseMode(ReleaseMode.stop);
    ref.onDispose(() async {
      try {
        await _player.dispose();
      } catch (_) {}
    });
    return true;
  }

  void toggle() => state = !state;
  void setEnabled(bool v) => state = v;

  /// Play a sound if the user hasn't muted. Fire-and-forget; failures
  /// are swallowed so audio issues never break the UX.
  void play(AppSound sound) {
    if (!state) return;
    _player.stop().catchError((_) {});
    _player.play(AssetSource(_assetFor(sound))).catchError((_) {});
  }

  String _assetFor(AppSound sound) {
    switch (sound) {
      case AppSound.routeStart:
        return 'sounds/route_start.wav';
      case AppSound.visitMarked:
        return 'sounds/visit_marked.wav';
      case AppSound.routeEnd:
        return 'sounds/route_complete.wav';
    }
  }
}

enum AppSound { routeStart, visitMarked, routeEnd }

final soundControllerProvider =
    NotifierProvider<SoundController, bool>(SoundController.new);
