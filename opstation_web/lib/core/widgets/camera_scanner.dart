// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:zxing2/qrcode.dart';

import 'scan_bar.dart' show ScanOutcome;

/// Continuous scanning with the phone / tablet camera. Every code read is
/// passed to [onCode] (same as a hardware scanner); the result shows on the
/// camera view and the sheet stays open for the next item.
///   • Barcodes (EAN, Code 128 …) + QR: browsers with a built-in detector
///     (Chrome on Android, Edge, Samsung Internet).
///   • QR codes: every browser, including iPhone Safari.
Future<void> showCameraScanner(
  BuildContext context, {
  required Future<ScanOutcome> Function(String code) onCode,
  String title = 'Scan with camera',
}) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(10),
      clipBehavior: Clip.antiAlias,
      child: _CameraScanner(onCode: onCode, title: title),
    ),
  );
}

/// Read ONE code with the camera and return it (null if closed without one) —
/// e.g. to fill a barcode box.
Future<String?> scanOneCode(BuildContext context, {String title = 'Scan barcode'}) async {
  String? got;
  await showCameraScanner(context, title: title, onCode: (code) async {
    if (got == null) {
      got = code;
      Navigator.of(context, rootNavigator: true).pop();
    }
    return ScanOutcome(true, code);
  });
  return got;
}

class _CameraScanner extends StatefulWidget {
  final Future<ScanOutcome> Function(String code) onCode;
  final String title;
  const _CameraScanner({required this.onCode, required this.title});
  @override
  State<_CameraScanner> createState() => _CameraScannerState();
}

class _CameraScannerState extends State<_CameraScanner> {
  static int _seq = 0;
  late final String _viewType = 'opstation-camera-scan-${_seq++}';
  html.VideoElement? _video;
  html.CanvasElement? _canvas;
  Object? _detector;
  bool _native = false;
  bool _barcodes = false; // native detector can read 1D barcodes
  bool _on = false;
  String? _error;
  Timer? _loop;
  bool _busy = false;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);
  ScanOutcome? _last;
  int _count = 0;
  bool _torch = false;
  final _zxing = QRCodeReader();

  @override
  void initState() {
    super.initState();
    _video = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video!);
    _init();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final ctor = js_util.getProperty(html.window, 'BarcodeDetector');
      if (ctor != null) {
        var formats = <String>['qr_code'];
        try {
          final supported = await js_util.promiseToFuture(js_util.callMethod(ctor, 'getSupportedFormats', const []));
          final list = (js_util.dartify(supported) as List?)?.map((e) => '$e').toList() ?? const <String>[];
          if (list.isNotEmpty) formats = list;
        } catch (_) {}
        _detector = js_util.callConstructor(ctor, [js_util.jsify({'formats': formats})]);
        _native = true;
        _barcodes = formats.any((f) => f != 'qr_code');
      }
    } catch (_) {
      _native = false;
    }
    try {
      final media = html.window.navigator.mediaDevices;
      if (media == null) throw 'no camera';
      final stream = await media.getUserMedia({
        'video': {'facingMode': 'environment', 'width': {'ideal': 1280}, 'height': {'ideal': 720}},
      });
      _video!.srcObject = stream;
      await _video!.play();
      _on = true;
      _loop = Timer.periodic(const Duration(milliseconds: 200), (_) => _frame());
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = 'Camera not available — allow camera access for this site, or use a scanner.');
    }
  }

  void _stop() {
    _loop?.cancel();
    try {
      final s = _video?.srcObject;
      if (s is html.MediaStream) { for (final t in s.getTracks()) { t.stop(); } }
      _video?.srcObject = null;
    } catch (_) {}
    _on = false;
  }

  Future<void> _toggleTorch() async {
    try {
      final s = _video?.srcObject;
      if (s is! html.MediaStream) return;
      final track = s.getVideoTracks().first;
      _torch = !_torch;
      await js_util.promiseToFuture(js_util.callMethod(track, 'applyConstraints', [
        js_util.jsify({'advanced': [{'torch': _torch}]}),
      ]));
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _torch = false);
    }
  }

  Future<void> _frame() async {
    if (_busy || !_on || _video == null) return;
    String? raw;
    try {
      if (_native && _detector != null) {
        final res = await js_util.promiseToFuture(js_util.callMethod(_detector!, 'detect', [_video]));
        final len = js_util.getProperty(res, 'length');
        if (len is int && len > 0) {
          final v = js_util.getProperty(js_util.getProperty(res, '0'), 'rawValue');
          if (v is String) raw = v;
        }
      } else {
        raw = _qr();
      }
    } catch (_) {}
    if (raw == null || raw.trim().isEmpty) return;
    final code = raw.trim();
    // The same code still in front of the lens isn't counted twice — move
    // it away (or wait a moment) to count it again.
    if (code == _lastCode && DateTime.now().difference(_lastAt).inMilliseconds < 1800) {
      _lastAt = DateTime.now();
      return;
    }
    _lastCode = code;
    _lastAt = DateTime.now();
    _busy = true;
    ScanOutcome r;
    try {
      r = await widget.onCode(code);
    } catch (e) {
      r = ScanOutcome(false, '$e');
    }
    if (!mounted) return;
    setState(() { _last = r; if (r.ok) _count++; });
    _busy = false;
  }

  String? _qr() {
    final v = _video!;
    final vw = v.videoWidth, vh = v.videoHeight;
    if (vw == 0 || vh == 0) return null;
    final scale = vw > 640 ? 640 / vw : 1.0;
    final w = (vw * scale).round(), h = (vh * scale).round();
    _canvas ??= html.CanvasElement();
    _canvas!..width = w..height = h;
    final ctx = _canvas!.context2D;
    ctx.drawImageScaled(v, 0, 0, w, h);
    final data = ctx.getImageData(0, 0, w, h).data;
    final px = Int32List(w * h);
    for (var i = 0, p = 0; p < px.length; i += 4, p++) {
      px[p] = (0xFF << 24) | (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
    }
    try {
      return _zxing.decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(w, h, px)))).text;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final last = _last;
    final c = last == null ? Colors.white : (last.ok ? Colors.green : Colors.red);
    return SizedBox(
      width: size.width > 560 ? 520 : size.width,
      height: size.height * 0.8,
      child: Column(children: [
        Container(
          color: Colors.black,
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
          child: Row(children: [
            const Icon(Icons.qr_code_scanner, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
            if (_on)
              IconButton(
                tooltip: 'Torch',
                icon: Icon(_torch ? Icons.flash_on : Icons.flash_off, color: Colors.white),
                onPressed: _toggleTorch,
              ),
            TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Done', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
        Expanded(child: Stack(fit: StackFit.expand, children: [
          Container(color: Colors.black),
          if (_error == null) HtmlElementView(viewType: _viewType),
          if (_error != null)
            Center(child: Padding(padding: const EdgeInsets.all(20),
                child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)))),
          // aiming frame
          if (_error == null)
            IgnorePointer(child: Center(child: Container(
              width: size.width > 560 ? 340 : size.width * 0.75, height: 160,
              decoration: BoxDecoration(border: Border.all(color: c.withOpacity(0.9), width: 3), borderRadius: BorderRadius.circular(12)),
            ))),
        ])),
        Container(
          width: double.infinity,
          color: last == null ? Colors.black87 : (last.ok ? Colors.green.shade700 : Colors.red.shade700),
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(
              last?.message ?? (_native && _barcodes
                  ? 'Point at the barcode or QR code on the item.'
                  : 'Point at the QR code on the item. (This browser reads QR codes only — use QR labels or a scanner for barcodes.)'),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
            ),
            if (_count > 0)
              Text('$_count scanned', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}
