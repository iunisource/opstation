// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_util' as js_util;

/// A short "ding" for a new floating alert, made with the browser's Web Audio (no
/// sound file). Browsers keep audio locked until the person has clicked or typed
/// once, so [unlock] is called on the first gesture; before that [play] is silent.
class AlertChime {
  AlertChime._();

  static Object? _ctx;
  static bool _unlocked = false;
  static DateTime? _last;
  static const _muteKey = 'opstation_alert_mute';

  /// This device's own switch (the bell's speaker button). Beats the Admin Settings choice.
  static bool get muted {
    try {
      return html.window.localStorage[_muteKey] == '1';
    } catch (_) {
      return false;
    }
  }

  static set muted(bool v) {
    try {
      if (v) {
        html.window.localStorage[_muteKey] = '1';
      } else {
        html.window.localStorage.remove(_muteKey);
      }
    } catch (_) {}
  }

  static void unlock() {
    try {
      if (_ctx == null) {
        var ctor = js_util.getProperty(html.window, 'AudioContext');
        ctor ??= js_util.getProperty(html.window, 'webkitAudioContext');
        if (ctor == null) return;
        _ctx = js_util.callConstructor(ctor, const []);
      }
      final c = _ctx;
      if (c != null && js_util.getProperty(c, 'state') == 'suspended') {
        js_util.callMethod(c, 'resume', const []);
      }
      _unlocked = true;
    } catch (_) {}
  }

  /// Plays the ding unless this device is muted or audio is still locked. Alerts
  /// that arrive together share one ding.
  static void play({double volume = 0.16}) {
    if (muted || !_unlocked) return;
    final now = DateTime.now();
    if (_last != null && now.difference(_last!) < const Duration(milliseconds: 1200)) return;
    _last = now;
    final ctx = _ctx;
    if (ctx == null) return;
    try {
      final t0 = (js_util.getProperty(ctx, 'currentTime') as num).toDouble();
      final dest = js_util.getProperty(ctx, 'destination');
      void tone(double freq, double dur, double vol) {
        final osc = js_util.callMethod(ctx, 'createOscillator', const []);
        final gain = js_util.callMethod(ctx, 'createGain', const []);
        js_util.setProperty(osc, 'type', 'sine');
        js_util.setProperty(js_util.getProperty(osc, 'frequency'), 'value', freq);
        final g = js_util.getProperty(gain, 'gain');
        js_util.callMethod(g, 'setValueAtTime', [0.0001, t0]);
        js_util.callMethod(g, 'linearRampToValueAtTime', [vol, t0 + 0.012]);
        js_util.callMethod(g, 'exponentialRampToValueAtTime', [0.0001, t0 + dur]);
        js_util.callMethod(osc, 'connect', [gain]);
        js_util.callMethod(gain, 'connect', [dest]);
        js_util.callMethod(osc, 'start', [t0]);
        js_util.callMethod(osc, 'stop', [t0 + dur + 0.02]);
      }

      tone(1318.5, 0.55, volume); // E6: the ding
      tone(2637.0, 0.28, volume * 0.35); // its bright overtone
    } catch (_) {}
  }
}
