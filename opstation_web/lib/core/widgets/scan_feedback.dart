// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:js_util' as js_util;

import 'package:flutter/material.dart';

/// Sound + flash feedback for scanning stations (works with the scanner's
/// own Enter key, no mouse needed):
///   • ok()    — short high beep
///   • wrong() — loud low buzz, three pulses, and the whole screen blinks red
///   • done()  — rising three-note chime (order complete / fulfilled)
/// One shared audio context, unlocked on the first key / click (browsers block
/// sound before any interaction).
class ScanFeedback {
  ScanFeedback._();

  static const String _js =
      '(function(){'
      'if(window.__scanFx)return;'
      'var F=window.AudioContext||window.webkitAudioContext;var ctx=null;'
      'function get(){if(!ctx&&F){try{ctx=new F();}catch(e){return null;}}return ctx;}'
      'function unlock(){var c=get();if(c&&c.state==="suspended"){try{c.resume();}catch(e){}}}'
      'function tone(freq,dur,type,when,gain){var c=get();if(!c)return;'
      'if(c.state==="suspended"){try{c.resume();}catch(e){}}'
      'try{var t0=c.currentTime+(when||0);var o=c.createOscillator();var g=c.createGain();'
      'o.connect(g);g.connect(c.destination);o.type=type||"sine";o.frequency.value=freq;'
      'g.gain.setValueAtTime(0.0001,t0);g.gain.exponentialRampToValueAtTime(gain||0.3,t0+0.01);'
      'g.gain.setValueAtTime(gain||0.3,t0+dur*0.7);g.gain.exponentialRampToValueAtTime(0.0001,t0+dur);'
      'o.start(t0);o.stop(t0+dur+0.02);}catch(e){}}'
      'function ok(){tone(1320,0.09,"sine",0,0.35);}'
      'function wrong(){for(var i=0;i<3;i++){tone(150,0.22,"square",i*0.28,0.6);tone(220,0.22,"sawtooth",i*0.28,0.35);}}'
      'function done(){tone(880,0.12,"sine",0,0.35);tone(1175,0.12,"sine",0.13,0.35);tone(1568,0.25,"sine",0.26,0.4);}'
      '["pointerdown","keydown","touchstart","mousedown"].forEach(function(ev){'
      'window.addEventListener(ev,unlock,{passive:true});});'
      'window.__scanFx={unlock:unlock,ok:ok,wrong:wrong,done:done};'
      '})();';

  static bool _installed = false;

  /// Call once when a scanning screen opens.
  static void install() {
    if (_installed) return;
    try {
      js_util.callMethod(js_util.globalThis, 'eval', [_js]);
      _installed = true;
    } catch (_) {}
  }

  static void _play(String fn) {
    install();
    try { js_util.callMethod(js_util.globalThis, 'eval', ['window.__scanFx&&window.__scanFx.$fn()']); } catch (_) {}
  }

  static void ok() => _play('ok');
  static void done() => _play('done');

  static OverlayEntry? _flash;

  /// Loud buzz + the entire screen blinks red.
  static void wrong(BuildContext context) {
    _play('wrong');
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _flash?.remove();
    late final OverlayEntry e;
    e = OverlayEntry(builder: (_) => _RedBlink(onDone: () {
      if (_flash == e) { e.remove(); _flash = null; }
    }));
    _flash = e;
    overlay.insert(e);
  }
}

class _RedBlink extends StatefulWidget {
  final VoidCallback onDone;
  const _RedBlink({required this.onDone});
  @override
  State<_RedBlink> createState() => _RedBlinkState();
}

class _RedBlinkState extends State<_RedBlink> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..addStatusListener((s) { if (s == AnimationStatus.completed) widget.onDone(); })
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          // Three blinks: on/off ×3.
          final phase = (_c.value * 3) % 1.0;
          final on = phase < 0.55;
          return Container(
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(on ? 0.45 : 0.0),
              border: Border.all(color: Colors.red.withOpacity(on ? 0.9 : 0.0), width: 14),
            ),
          );
        },
      ),
    );
  }
}
