// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// Take a photo with the device camera (web). Shows a live preview with
/// Capture / Retake / Use photo, and a front/back switch when the device has
/// more than one camera. Returns JPEG bytes, or null if cancelled / no camera.
Future<Uint8List?> showCameraCapture(BuildContext context, {String title = 'Take photo', bool preferFront = false}) {
  final narrow = MediaQuery.of(context).size.width < 600;
  return showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (_) => narrow
        ? Dialog.fullscreen(child: _CameraCapture(title: title, preferFront: preferFront, fullScreen: true))
        : Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: SizedBox(width: 560, height: 560, child: _CameraCapture(title: title, preferFront: preferFront)),
          ),
  );
}

class _CameraCapture extends StatefulWidget {
  final String title;
  final bool preferFront;
  final bool fullScreen;
  const _CameraCapture({required this.title, required this.preferFront, this.fullScreen = false});
  @override
  State<_CameraCapture> createState() => _CameraCaptureState();
}

class _CameraCaptureState extends State<_CameraCapture> {
  static int _seq = 0;
  late final String _viewType = 'opst-camera-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
  late final html.VideoElement _video;
  html.MediaStream? _stream;
  late String _facing = widget.preferFront ? 'user' : 'environment';
  int _cams = 0;
  String? _error;
  bool _starting = true;
  Uint8List? _shot;

  @override
  void initState() {
    super.initState();
    _video = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover'
      ..style.pointerEvents = 'none'
      ..style.borderRadius = '10px';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video);
    _start();
    _countCams();
  }

  Future<void> _countCams() async {
    try {
      final devices = await html.window.navigator.mediaDevices?.enumerateDevices() ?? const [];
      var n = 0;
      for (final d in devices) {
        if (d is html.MediaDeviceInfo && d.kind == 'videoinput') n++;
      }
      if (mounted) setState(() => _cams = n);
    } catch (_) {}
  }

  Future<void> _start() async {
    setState(() { _starting = true; _error = null; });
    try {
      final media = html.window.navigator.mediaDevices;
      if (media == null) throw 'This browser has no camera access.';
      _stream = await media.getUserMedia({
        'video': {'facingMode': _facing, 'width': {'ideal': 1280}, 'height': {'ideal': 960}},
        'audio': false,
      });
      _video.srcObject = _stream;
      _video.style.transform = _facing == 'user' ? 'scaleX(-1)' : 'none';
      await _video.play();
      if (mounted) setState(() => _starting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = 'Camera not available. Allow camera access for this site in the browser, '
              'or use Upload instead.';
        });
      }
    }
  }

  void _stop() {
    try {
      for (final t in _stream?.getTracks() ?? const <html.MediaStreamTrack>[]) {
        t.stop();
      }
    } catch (_) {}
    _stream = null;
  }

  Future<void> _switch() async {
    _stop();
    _facing = _facing == 'user' ? 'environment' : 'user';
    await _start();
  }

  void _capture() {
    final w = _video.videoWidth, h = _video.videoHeight;
    if (w == 0 || h == 0) return;
    // Keep files small: longest side max 1280px.
    final scale = (w > h ? w : h) > 1280 ? 1280 / (w > h ? w : h) : 1.0;
    final cw = (w * scale).round(), ch = (h * scale).round();
    final canvas = html.CanvasElement(width: cw, height: ch);
    final ctx = canvas.context2D;
    if (_facing == 'user') {
      // Save what the user saw in the (mirrored) preview.
      ctx.translate(cw, 0);
      ctx.scale(-1, 1);
    }
    ctx.drawImageScaled(_video, 0, 0, cw, ch);
    final dataUrl = canvas.toDataUrl('image/jpeg', 0.85);
    setState(() => _shot = base64Decode(dataUrl.split(',').last));
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _close([Uint8List? result]) {
    _stop();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        color: Colors.black,
        child: _shot != null
            ? Image.memory(_shot!, fit: BoxFit.contain)
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                    ),
                  )
                : Stack(fit: StackFit.expand, children: [
                    HtmlElementView(viewType: _viewType),
                    if (_starting) const Center(child: CircularProgressIndicator(color: Colors.white)),
                  ]),
      ),
    );
    final actions = Row(children: [
      if (_shot == null && _cams > 1 && _error == null)
        IconButton(onPressed: _switch, icon: const Icon(Icons.cameraswitch_outlined), tooltip: 'Switch camera'),
      const Spacer(),
      TextButton(onPressed: () => _close(), child: const Text('Cancel')),
      const SizedBox(width: 8),
      if (_shot == null)
        ElevatedButton.icon(
          onPressed: (_starting || _error != null) ? null : _capture,
          icon: const Icon(Icons.camera_alt_outlined, size: 18),
          label: const Text('Capture'),
        )
      else ...[
        OutlinedButton.icon(
          onPressed: () => setState(() => _shot = null),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Retake'),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: () => _close(_shot),
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Use photo'),
        ),
      ],
    ]);
    return Padding(
      padding: EdgeInsets.all(widget.fullScreen ? 12 : 16),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Expanded(child: preview),
          const SizedBox(height: 10),
          actions,
        ]),
      ),
    );
  }
}
