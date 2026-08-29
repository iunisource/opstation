import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Spoken confirmations for the retailer ("Your order has been placed/approved").
///
/// TTS only runs while the app is foregrounded — Android won't let a killed app
/// speak — so callers fire this on placement (always foreground) and on approval
/// when the app is open or has just been opened from the notification.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _init = false;
  DateTime? _lastAt;
  String? _lastMsg;

  Future<void> _ensureInit() async {
    if (_init) return;
    _init = true;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (_) {}
  }

  /// Speaks [text]. [lang] is a BCP-47 tag (e.g. en-US, ur-PK); if the device
  /// lacks that voice it's ignored and the default voice is used. Identical
  /// messages within a few seconds are dropped so a push + realtime pair that
  /// both fire don't speak twice.
  Future<void> speak(String text, {String lang = 'en-US'}) async {
    final now = DateTime.now();
    if (_lastMsg == text &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 6)) {
      return;
    }
    _lastMsg = text;
    _lastAt = now;
    try {
      await _ensureInit();
      try {
        await _tts.setLanguage(lang);
      } catch (_) {
        // Fall back to the engine default voice.
      }
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }
}

final ttsProvider = Provider<TtsService>((_) => TtsService());
