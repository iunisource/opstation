import 'dart:async';
import 'dart:typed_data';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;
import 'package:zxing2/qrcode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Shop-floor Job Kiosk. A worker holds a printed job card up to the tablet's
/// camera (or scans it with a hardware QR/barcode scanner). Each scan TOGGLES
/// that job on/off the floor — scan once to Start, scan again to Pause. This is
/// an additional convenience; the per-phone scan flow (/#/f/<token>) is
/// unchanged, and "Finished" stays an explicit action there.
class ErpJobKioskScreen extends ConsumerStatefulWidget {
  const ErpJobKioskScreen({super.key});
  @override
  ConsumerState<ErpJobKioskScreen> createState() => _ErpJobKioskScreenState();
}

enum _Outcome { started, paused, error }

class _KioskResult {
  final _Outcome outcome;
  final String title;
  final String? job;
  final String? product;
  final String? sub;
  _KioskResult(this.outcome, this.title, {this.job, this.product, this.sub});
}

class _ErpJobKioskScreenState extends ConsumerState<ErpJobKioskScreen> {
  bool _busy = false;
  _KioskResult? _result;
  Timer? _clearTimer;

  // hardware scanner / keyboard-wedge capture
  final _wedgeCtrl = TextEditingController();
  final _wedgeFocus = FocusNode();
  Timer? _focusGuard;

  // audio
  Object? _audio;
  bool _soundReady = false;

  // camera
  static const _viewType = 'job-kiosk-camera-view';
  html.VideoElement? _video;
  Object? _detector;              // native BarcodeDetector (Chrome/Android) if present
  bool _useNative = false;
  html.CanvasElement? _canvas;    // scratch canvas for the zxing fallback
  final _zxing = QRCodeReader();  // pure-Dart QR decoder — works in every browser
  Timer? _scanLoop;
  bool _cameraOn = false;
  bool _cameraSupported = false;  // true once getUserMedia succeeds (camera works)
  DateTime _camCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _registerCameraView();
    WidgetsBinding.instance.addPostFrameCallback((_) => _armFocus());
    _focusGuard = Timer.periodic(const Duration(seconds: 2), (_) => _refocusWedge());
    _initCamera();
  }

  @override
  void dispose() {
    _clearTimer?.cancel();
    _scanLoop?.cancel();
    _focusGuard?.cancel();
    _stopCamera();
    _wedgeCtrl.dispose();
    _wedgeFocus.dispose();
    super.dispose();
  }

  void _armFocus() {
    for (final ms in [0, 120, 350, 700, 1200, 2000]) {
      Future.delayed(Duration(milliseconds: ms), _refocusWedge);
    }
  }

  void _refocusWedge() {
    if (!mounted) return;
    if (!_wedgeFocus.hasFocus) _wedgeFocus.requestFocus();
  }

  void _onWedgeSubmitted(String value) {
    final code = value.trim();
    _wedgeCtrl.clear();
    _refocusWedge();
    if (code.isNotEmpty) _process(code);
  }

  // ── sound ──────────────────────────────────────────────────────────────────
  void _ensureAudio() {
    try {
      if (_audio == null) {
        var ctor = js_util.getProperty(html.window, 'AudioContext');
        ctor ??= js_util.getProperty(html.window, 'webkitAudioContext');
        if (ctor == null) { _soundReady = false; return; }
        _audio = js_util.callConstructor(ctor, const []);
      }
      final ctx = _audio;
      if (ctx != null && js_util.getProperty(ctx, 'state') == 'suspended') {
        js_util.callMethod(ctx, 'resume', const []);
      }
      _soundReady = true;
    } catch (_) { _soundReady = false; }
  }

  void _beep({required bool ok}) {
    if (!_soundReady) return;
    final ctx = _audio;
    if (ctx == null) return;
    try {
      final now = js_util.getProperty(ctx, 'currentTime') as num;
      final dest = js_util.getProperty(ctx, 'destination');
      void tone(double freq, double start, double dur, double vol) {
        final osc = js_util.callMethod(ctx, 'createOscillator', const []);
        final gain = js_util.callMethod(ctx, 'createGain', const []);
        js_util.callMethod(osc, 'connect', [gain]);
        js_util.callMethod(gain, 'connect', [dest]);
        js_util.setProperty(osc, 'type', ok ? 'square' : 'sawtooth');
        js_util.setProperty(js_util.getProperty(osc, 'frequency'), 'value', freq);
        js_util.setProperty(js_util.getProperty(gain, 'gain'), 'value', vol);
        final t0 = now + start;
        js_util.callMethod(osc, 'start', [t0]);
        js_util.callMethod(osc, 'stop', [t0 + dur]);
      }
      if (ok) { tone(880, 0.0, 0.12, 0.5); tone(1175, 0.13, 0.16, 0.5); }
      else { tone(196, 0.0, 0.45, 0.5); }
    } catch (_) { }
  }

  // ── camera (browser-native BarcodeDetector) ──────────────────────────────────
  void _registerCameraView() {
    try {
      _video = html.VideoElement()
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.borderRadius = '16px';
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video!);
    } catch (_) { }
  }

  Future<void> _initCamera() async {
    // Use the browser's native QR detector when it exists (fast); otherwise fall
    // back to the bundled zxing decoder so the camera still works everywhere
    // (Firefox, Safari, older Chrome — none of which ship BarcodeDetector).
    try {
      final ctor = js_util.getProperty(html.window, 'BarcodeDetector');
      if (ctor != null) {
        _detector = js_util.callConstructor(ctor, [js_util.jsify({'formats': ['qr_code']})]);
        _useNative = true;
      }
    } catch (_) { _useNative = false; }
    await _startCamera();
  }

  Future<void> _startCamera() async {
    if (_cameraOn) return;
    try {
      final media = html.window.navigator.mediaDevices;
      if (media == null) { setState(() => _cameraSupported = false); return; }
      // Ask for a higher-resolution feed — QR codes resolve from further away,
      // so workers don't have to hold the card right against the lens.
      final stream = await media.getUserMedia({
        'video': {
          'facingMode': 'environment',
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
        }
      });
      _video?.srcObject = stream;
      await _video?.play();
      // Mirror the PREVIEW when the camera faces the user — laptops fall back
      // to the front cam even though we asked for 'environment', and an
      // unmirrored front-cam view feels inverted (moving the card left moves
      // it right on screen), which is what made aiming so hard. Decoding is
      // untouched: both detectors read raw frames, not the mirrored display.
      try {
        String? facing;
        final tracks = stream.getVideoTracks();
        if (tracks.isNotEmpty) {
          facing = tracks.first.getSettings()['facingMode'] as String?;
        }
        _video?.style.transform =
            (facing == 'environment') ? '' : 'scaleX(-1)';
      } catch (_) {
        _video?.style.transform = 'scaleX(-1)';
      }
      _cameraOn = true;
      _cameraSupported = true;
      _scanLoop?.cancel();
      // Faster loop: a code held briefly in frame is caught sooner.
      _scanLoop = Timer.periodic(const Duration(milliseconds: 250), (_) => _scanFrame());
      if (mounted) setState(() {});
    } catch (_) {
      // Only a real camera failure (no device / permission denied) lands here.
      _cameraOn = false;
      if (mounted) setState(() => _cameraSupported = false);
    }
  }

  void _stopCamera() {
    _scanLoop?.cancel();
    _scanLoop = null;
    try {
      final stream = _video?.srcObject;
      if (stream is html.MediaStream) { for (final t in stream.getTracks()) { t.stop(); } }
      _video?.srcObject = null;
    } catch (_) { }
    _cameraOn = false;
  }

  Future<void> _scanFrame() async {
    if (_busy || _video == null || !_cameraOn) return;
    if (DateTime.now().isBefore(_camCooldownUntil)) return;
    String? raw;
    try {
      if (_useNative && _detector != null) {
        final res = await js_util.promiseToFuture(js_util.callMethod(_detector!, 'detect', [_video]));
        final len = js_util.getProperty(res, 'length');
        if (len is int && len > 0) {
          final v = js_util.getProperty(js_util.getProperty(res, '0'), 'rawValue');
          if (v is String) raw = v;
        }
      } else {
        raw = _decodeWithZxing();
      }
    } catch (_) { /* frame not ready / no code — ignore */ }
    if (raw != null && raw.trim().isNotEmpty) {
      _camCooldownUntil = DateTime.now().add(const Duration(seconds: 4));
      _process(raw.trim());
    }
  }

  // Grab the current video frame and decode any QR in it with the pure-Dart
  // zxing reader. Returns the QR text, or null if none found this frame.
  String? _decodeWithZxing() {
    final vw = _video!.videoWidth, vh = _video!.videoHeight;
    if (vw == 0 || vh == 0) return null;
    // Downscale to keep decoding fast; 640px balances speed with enough
    // detail to read a code held at arm's length.
    final scale = vw > 640 ? 640 / vw : 1.0;
    final w = (vw * scale).round(), h = (vh * scale).round();
    _canvas ??= html.CanvasElement();
    _canvas!..width = w..height = h;
    final ctx = _canvas!.context2D;
    ctx.drawImageScaled(_video!, 0, 0, w, h);
    final data = ctx.getImageData(0, 0, w, h).data; // RGBA Uint8ClampedList
    final pixels = Int32List(w * h);
    for (var i = 0, p = 0; p < pixels.length; i += 4, p++) {
      final r = data[i], g = data[i + 1], b = data[i + 2];
      pixels[p] = (0xFF << 24) | (r << 16) | (g << 8) | b;
    }
    try {
      final source = RGBLuminanceSource(w, h, pixels);
      final bitmap = BinaryBitmap(HybridBinarizer(source));
      final result = _zxing.decode(bitmap);
      return result.text;
    } catch (_) {
      return null; // no QR in this frame
    }
  }

  // Extract the floor token from a scanned QR: either a full URL that contains
  // "/f/<token>" or the raw token itself.
  String? _tokenFrom(String raw) {
    final m = RegExp(r'/f/([0-9a-fA-F]{16,64})').firstMatch(raw);
    if (m != null) return m.group(1);
    if (RegExp(r'^[0-9a-fA-F]{16,64}$').hasMatch(raw)) return raw;
    return null;
  }

  Future<void> _process(String rawCode) async {
    _ensureAudio();
    if (_busy) return;
    final token = _tokenFrom(rawCode.trim());
    if (token == null) {
      _show(_KioskResult(_Outcome.error, 'Not a job code', sub: 'Hold the job card QR steady in the frame.'));
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.functions
          .invoke('floor-action', body: {'token': token, 'action': 'toggle'});
      final d = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
      if (d['ok'] != true) {
        final code = d['error'] as String?;
        final msg = code == 'closed'
            ? 'This job is already completed or closed.'
            : (code == 'not_found' || code == 'bad_token')
                ? 'Job code not recognized.'
                : 'Could not update the job. Try again.';
        _show(_KioskResult(_Outcome.error, 'Not done', job: d['job_number'] as String?, sub: msg));
        return;
      }
      final onFloor = d['on_floor'] == true;
      _show(_KioskResult(
        onFloor ? _Outcome.started : _Outcome.paused,
        onFloor ? 'STARTED' : 'PAUSED',
        job: d['job_number'] as String?,
        product: d['product'] as String?,
        sub: onFloor ? 'On the floor now' : 'Off the floor — scan again to resume',
      ));
    } catch (_) {
      _show(_KioskResult(_Outcome.error, 'Connection problem', sub: 'Check the network and scan again.'));
    }
  }

  void _show(_KioskResult r) {
    _beep(ok: r.outcome != _Outcome.error);
    if (!mounted) { _busy = false; return; }
    setState(() { _result = r; _busy = false; });
    _clearTimer?.cancel();
    _clearTimer = Timer(const Duration(seconds: 5), () { if (mounted) setState(() => _result = null); });
    _refocusWedge();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      // Any tap re-arms the hardware-scanner input.
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _refocusWedge(),
        child: SafeArea(child: Stack(children: [
        // Keyboard-wedge sink for hardware barcode/QR scanners. Kept laid-out
        // (1x1, transparent) rather than Offstage — an unpainted input cannot
        // grab focus at load, which made USB scanners dead until a click.
        Positioned(
          left: 0, top: 0, width: 1, height: 1,
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: _wedgeCtrl, focusNode: _wedgeFocus, autofocus: true,
              onSubmitted: _onWedgeSubmitted,
              inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            ),
          ),
        ),
        Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(width: 40, height: 40, alignment: Alignment.center,
                decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(11)),
                child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20))),
              const SizedBox(width: 12),
              const Text('Job Kiosk', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 6),
            const Text('Scan a job card to start it — scan again to pause.',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 20),
            // Camera viewfinder
            AspectRatio(aspectRatio: 4 / 3, child: Container(
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white24)),
              clipBehavior: Clip.antiAlias,
              child: _cameraSupported
                  ? Stack(fit: StackFit.expand, children: [
                      const HtmlElementView(viewType: _viewType),
                      // framing guide
                      Center(child: Container(width: 200, height: 200,
                        decoration: BoxDecoration(border: Border.all(color: Colors.white.withOpacity(0.6), width: 3), borderRadius: BorderRadius.circular(16)))),
                    ])
                  : const Center(child: Padding(padding: EdgeInsets.all(24), child: Text(
                      'Camera not available on this device.\nUse a USB / Bluetooth QR scanner instead — just scan the job card.',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 14)))),
            )),
            const SizedBox(height: 8),
            if (_cameraSupported)
              const Text('Hold the QR steady inside the box, 15–25 cm from the camera — or use a USB scanner.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            _resultCard(),
          ])),
        )),
      ])),
      ),
    );
  }

  Widget _resultCard() {
    final r = _result;
    if (r == null) {
      return Container(
        width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(14)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          else const Icon(Icons.qr_code_scanner, color: Colors.white54, size: 22),
          const SizedBox(width: 10),
          Text(_busy ? 'Reading…' : 'Ready to scan', style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
      );
    }
    final Color c; final IconData ic;
    switch (r.outcome) {
      case _Outcome.started: c = const Color(0xFF22C55E); ic = Icons.play_circle_fill; break;
      case _Outcome.paused: c = const Color(0xFFF59E0B); ic = Icons.pause_circle_filled; break;
      case _Outcome.error: c = const Color(0xFFEF4444); ic = Icons.error; break;
    }
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(16), border: Border.all(color: c.withOpacity(0.6), width: 2)),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(ic, color: c, size: 34), const SizedBox(width: 12),
          Text(r.title, style: TextStyle(color: c, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 1)),
        ]),
        if (r.job != null) ...[
          const SizedBox(height: 8),
          Text(r.job!, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
        ],
        if (r.product != null && r.product!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(r.product!, style: const TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
        ],
        if (r.sub != null) ...[
          const SizedBox(height: 8),
          Text(r.sub!, style: TextStyle(color: c, fontSize: 14, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
        ],
      ]),
    );
  }
}
