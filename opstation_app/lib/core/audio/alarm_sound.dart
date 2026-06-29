import 'package:audioplayers/audioplayers.dart';

/// Plays the distinct "new job" alarm for drivers.
///
/// Uses a single reusable AudioPlayer. The sound is a synthesized two-tone
/// alarm bundled at assets/sounds/new_job_alarm.wav — deliberately different
/// from a normal notification chime so a driver notices a new assignment.
class AlarmSound {
  AlarmSound._();
  static final AlarmSound instance = AlarmSound._();

  final AudioPlayer _player = AudioPlayer();
  bool _ready = false;

  Future<void> _ensure() async {
    if (_ready) return;
    // Low latency = fire-and-forget alert, not media playback.
    await _player.setPlayerMode(PlayerMode.lowLatency);
    await _player.setReleaseMode(ReleaseMode.stop);
    _ready = true;
  }

  /// Play the alarm once. Safe to call from a notification handler —
  /// never throws (audio failures must not break message handling).
  Future<void> play() async {
    try {
      await _ensure();
      await _player.stop(); // restart if already playing
      await _player.play(AssetSource('sounds/new_job_alarm.wav'));
    } catch (_) {
      // Swallow — a missing/again-busy player must not crash the FCM handler.
    }
  }
}
