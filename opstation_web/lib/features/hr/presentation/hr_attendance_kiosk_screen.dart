import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Full-screen attendance kiosk. An employee presents their ID card; the QR
/// (which encodes the employee_code) is read by the device camera, a hardware
/// barcode/QR scanner (keyboard-wedge), or typed manually. On a valid code the
/// kiosk punches the employee IN — or OUT if already in — into hr_attendance,
/// writing an audit row as "Kiosk".
///
/// Rules:
///  - No check-in yet            -> punch IN (status present).
///  - Re-scan within 60s         -> blocked ("Already punched in").
///  - Checked in, >60s, no out   -> punch OUT (work_hours recomputed).
///  - Already checked out today  -> blocked ("Already completed"); only an
///                                  admin can re-open from the Attendance screen.
/// Branch is taken from the employee's own record. Success plays a rising beep,
/// blocked plays a low buzz; both show the employee photo, name and code.
class HrAttendanceKioskScreen extends ConsumerStatefulWidget {
  const HrAttendanceKioskScreen({super.key});
  @override
  ConsumerState<HrAttendanceKioskScreen> createState() => _HrAttendanceKioskScreenState();
}

enum _Outcome { checkedIn, checkedOut, blocked, error }

class _Result {
  final _Outcome outcome;
  final String title;
  final String? name;
  final String? code;
  final String? photoUrl;
  final String? time;
  final String? message;
  _Result(this.outcome, this.title, {this.name, this.code, this.photoUrl, this.time, this.message});
}

class _HrAttendanceKioskScreenState extends ConsumerState<HrAttendanceKioskScreen> {
  final Map<String, DateTime> _lastPunch = {}; // empId -> last successful punch (60s debounce)
  _Result? _result;
  Timer? _clearTimer;
  bool _busy = false;
  bool _captureEnabled = false;  // org.kiosk_capture_photo

  // hardware scanner / keyboard-wedge capture
  final _wedgeCtrl = TextEditingController();
  final _wedgeFocus = FocusNode();
  Timer? _focusGuard;      // keeps the wedge armed even if focus is stolen
  bool _manualOpen = false; // don't fight the manual-entry dialog for focus

  // audio
  Object? _audio;            // Web Audio context via JS interop
  bool _soundReady = false;

  // camera
  static const _viewType = 'kiosk-camera-view';
  html.VideoElement? _video;
  Object? _detector;
  Timer? _scanLoop;
  bool _cameraOn = false;
  bool _cameraSupported = false;
  DateTime _camCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _registerCameraView();
    WidgetsBinding.instance.addPostFrameCallback((_) => _armFocus());
    // Camera/view registration and async layout can steal focus during the
    // first second, so keep a lightweight guard re-arming the wedge.
    _focusGuard = Timer.periodic(const Duration(seconds: 2), (_) => _refocusWedge());
    _loadConfig();
    _initCamera();
  }

  // Request focus repeatedly across the first ~2s so the scanner is live the
  // moment the screen settles — no click or first manual punch needed.
  void _armFocus() {
    for (final ms in [0, 120, 350, 700, 1200, 2000]) {
      Future.delayed(Duration(milliseconds: ms), _refocusWedge);
    }
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

  Future<void> _loadConfig() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final row = await Supabase.instance.client.from('app_config')
          .select('value').eq('org_id', orgId).eq('key', 'org.kiosk_capture_photo').maybeSingle();
      if (mounted) setState(() => _captureEnabled = (row?['value'] as String?) == 'true');
    } catch (_) { }
  }

  // Punch photos are split into two phases so they never slow the punch:
  //  1. _captureFrameBytes — grab the current camera frame IN MEMORY (local,
  //     effectively instant) before the punch.
  //  2. _attachPunchPhoto — AFTER the punch result is already on screen,
  //     upload the frame and write its URL onto the attendance row in the
  //     background. Best-effort: any failure is swallowed; the punch stands.
  Uint8List? _captureFrameBytes() {
    if (!_captureEnabled || !_cameraOn || _video == null) return null;
    try {
      final vw = _video!.videoWidth;
      final vh = _video!.videoHeight;
      if (vw == 0 || vh == 0) return null;
      final canvas = html.CanvasElement(width: vw, height: vh);
      canvas.context2D.drawImage(_video!, 0, 0);
      final dataUrl = canvas.toDataUrl('image/jpeg', 0.7);
      return base64Decode(dataUrl.split(',').last);
    } catch (_) { return null; }
  }

  Future<void> _attachPunchPhoto(
      Uint8List bytes, String attendanceId, String direction, String empCode) async {
    try {
      final client = Supabase.instance.client;
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final path =
          'att/$today/${empCode}_${direction}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await client.storage.from('kiosk-punches').uploadBinary(path, bytes,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'));
      final url = client.storage.from('kiosk-punches').getPublicUrl(path);
      await client.from('hr_attendance').update({
        direction == 'in' ? 'punch_in_photo' : 'punch_out_photo': url,
      }).eq('id', attendanceId);
    } catch (_) {/* photo is best-effort — never surface to the kiosk */}
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
      if (ok) {
        tone(880, 0.0, 0.12, 0.5);
        tone(1175, 0.13, 0.16, 0.5);
      } else {
        tone(196, 0.0, 0.45, 0.5);
      }
    } catch (_) { }
  }

  // ── keyboard-wedge ───────────────────────────────────────────────────────────
  void _refocusWedge() {
    if (!mounted || _manualOpen) return; // don't steal focus from the dialog
    if (!_wedgeFocus.hasFocus) _wedgeFocus.requestFocus();
  }

  void _onWedgeSubmitted(String value) {
    final code = value.trim();
    _wedgeCtrl.clear();
    _refocusWedge();
    if (code.isNotEmpty) _process(code);
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
        ..style.borderRadius = '12px';
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video!);
    } catch (_) { }
  }

  Future<void> _initCamera() async {
    // Feature-detect BarcodeDetector; only enable camera if present.
    try {
      final ctor = js_util.getProperty(html.window, 'BarcodeDetector');
      if (ctor == null) { setState(() => _cameraSupported = false); return; }
      _detector = js_util.callConstructor(ctor, [
        js_util.jsify({'formats': ['qr_code']})
      ]);
      _cameraSupported = true;
      await _startCamera();
    } catch (_) {
      setState(() => _cameraSupported = false);
    }
  }

  Future<void> _startCamera() async {
    if (!_cameraSupported || _cameraOn) return;
    try {
      final media = html.window.navigator.mediaDevices;
      if (media == null) { setState(() => _cameraSupported = false); return; }
      final stream = await media.getUserMedia({
        'video': {'facingMode': 'environment'}
      });
      _video?.srcObject = stream;
      await _video?.play();
      _cameraOn = true;
      _scanLoop?.cancel();
      _scanLoop = Timer.periodic(const Duration(milliseconds: 350), (_) => _scanFrame());
      if (mounted) setState(() {});
    } catch (_) {
      _cameraOn = false;
      if (mounted) setState(() => _cameraSupported = false);
    }
  }

  void _stopCamera() {
    _scanLoop?.cancel();
    _scanLoop = null;
    try {
      final stream = _video?.srcObject;
      if (stream is html.MediaStream) {
        for (final t in stream.getTracks()) { t.stop(); }
      }
      _video?.srcObject = null;
    } catch (_) { }
    _cameraOn = false;
  }

  Future<void> _scanFrame() async {
    if (_busy || _detector == null || _video == null) return;
    if (DateTime.now().isBefore(_camCooldownUntil)) return;
    try {
      final res = await js_util.promiseToFuture(
          js_util.callMethod(_detector!, 'detect', [_video]));
      final len = js_util.getProperty(res, 'length');
      if (len is int && len > 0) {
        final first = js_util.getProperty(res, '0');
        final raw = js_util.getProperty(first, 'rawValue');
        if (raw is String && raw.trim().isNotEmpty) {
          _camCooldownUntil = DateTime.now().add(const Duration(seconds: 3));
          _process(raw.trim());
        }
      }
    } catch (_) { /* frame not ready / detect failed — ignore */ }
  }

  // ── punch logic (in/out rules + work hours now live in the kiosk_punch RPC) ──
  Future<void> _process(String rawCode) async {
    _ensureAudio();
    if (_busy) return;
    final code = rawCode.trim();
    if (code.isEmpty) return;

    // Local 60s debounce per code (instant feedback; the RPC also enforces one
    // server-side across every kiosk device).
    final now = DateTime.now();
    final last = _lastPunch[code];
    if (last != null && now.difference(last) < const Duration(seconds: 60)) {
      _beep(ok: false);
      _show(_Result(_Outcome.blocked, 'Please wait',
          message: 'Scanned moments ago — try again in a minute.'));
      return;
    }

    setState(() => _busy = true);
    try {
      final client = Supabase.instance.client;
      // Snapshot the camera frame locally (instant) — uploaded AFTER the
      // result shows, so the punch never waits on the network for a photo.
      final frame = _captureFrameBytes();
      // The whole punch runs in kiosk_punch (SECURITY DEFINER, anon-callable):
      // it resolves the employee ACROSS ORGS from the card/code, applies the
      // in/out/blocked rules, writes attendance + audit, and returns the
      // display payload. This is what makes the kiosk a public, login-free
      // URL that serves every org from one bookmark.
      final res = await client.rpc('kiosk_punch', params: {'p_code': code});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final outcome = switch (m['outcome'] as String? ?? 'error') {
        'checked_in' => _Outcome.checkedIn,
        'checked_out' => _Outcome.checkedOut,
        'blocked' => _Outcome.blocked,
        _ => _Outcome.error,
      };
      final ok = outcome == _Outcome.checkedIn || outcome == _Outcome.checkedOut;
      if (ok) _lastPunch[code] = now;
      _beep(ok: ok);
      _show(_Result(outcome, m['title'] as String? ?? 'Punch failed',
          name: m['name'] as String?,
          code: m['code'] as String?,
          photoUrl: m['photo_url'] as String?,
          time: m['time'] as String?,
          message: m['message'] as String?));
      // Background photo attach — result is already on screen.
      final attId = m['attendance_id'] as String?;
      final dir = m['direction'] as String?;
      if (ok && frame != null && attId != null && dir != null) {
        unawaited(_attachPunchPhoto(
            frame, attId, dir, m['code'] as String? ?? code));
      }
    } catch (e) {
      _beep(ok: false);
      _show(_Result(_Outcome.error, 'Punch failed',
          message: e.toString().split('\n').first));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(_Result r) {
    _clearTimer?.cancel();
    if (mounted) setState(() => _result = r);
    _clearTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _result = null);
      _refocusWedge();
    });
  }

  Future<void> _manualEntry() async {
    _ensureAudio();
    _manualOpen = true;
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter employee code'),
        content: TextField(
          controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'e.g. EMP-0003', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Punch')),
        ],
      ),
    );
    _manualOpen = false;
    _refocusWedge();
    if (code != null && code.trim().isNotEmpty) _process(code.trim());
  }

  // ── UI ────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      // Any tap re-arms the scanner (also covers returning from a dialog).
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _refocusWedge(),
        child: Stack(children: [
        // Keyboard-wedge capture: scanners type the code + Enter here. Kept
        // laid-out (1x1, transparent) rather than Offstage — an unpainted
        // input cannot grab focus at load, which is why the scanner used to
        // need a click first.
        Positioned(
          left: 0, top: 0, width: 1, height: 1,
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: _wedgeCtrl, focusNode: _wedgeFocus, autofocus: true,
              onSubmitted: _onWedgeSubmitted,
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                _clock(),
                const SizedBox(height: 18),
                _cameraSupported ? _cameraBox() : _noCameraBox(),
                const SizedBox(height: 18),
                _result != null ? _resultCard(_result!) : _prompt(),
                const SizedBox(height: 18),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24)),
                    onPressed: _manualEntry,
                    icon: const Icon(Icons.keyboard),
                    label: const Text('Enter code manually'),
                  ),
                  const SizedBox(width: 12),
                  if (!_soundReady)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24)),
                      onPressed: () { _ensureAudio(); setState(() {}); },
                      icon: const Icon(Icons.volume_up_outlined),
                      label: const Text('Enable sound'),
                    ),
                ]),
              ]),
            ),
          ),
        ),
      ]),
      ),
    );
  }

  Widget _clock() {
    return Column(children: [
      Text(DateFormat('hh:mm a').format(DateTime.now()),
          style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800)),
      Text(DateFormat('EEEE, d MMMM yyyy').format(DateTime.now()),
          style: const TextStyle(color: Colors.white60, fontSize: 14)),
    ]);
  }

  Widget _cameraBox() {
    return Container(
      width: 460, height: 360,
      decoration: BoxDecoration(
        color: Colors.black26, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      clipBehavior: Clip.antiAlias,
      child: _cameraOn
          ? const HtmlElementView(viewType: _viewType)
          : const Center(child: CircularProgressIndicator(color: Colors.white54)),
    );
  }

  Widget _noCameraBox() {
    return Container(
      width: 280, padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white24)),
      child: const Column(children: [
        Icon(Icons.qr_code_scanner, color: Colors.white54, size: 48),
        SizedBox(height: 8),
        Text('Use the handheld scanner\nor enter the code manually',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 13)),
      ]),
    );
  }

  Widget _prompt() {
    return const Text('Scan your card to punch in / out',
        style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w600));
  }

  Widget _resultCard(_Result r) {
    final color = switch (r.outcome) {
      _Outcome.checkedIn => const Color(0xFF2E9E5B),
      _Outcome.checkedOut => const Color(0xFF2563EB),
      _Outcome.blocked => const Color(0xFFD9822B),
      _Outcome.error => const Color(0xFFD64545),
    };
    final icon = switch (r.outcome) {
      _Outcome.checkedIn => Icons.login,
      _Outcome.checkedOut => Icons.logout,
      _Outcome.blocked => Icons.block,
      _Outcome.error => Icons.error_outline,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        if (r.photoUrl != null && r.photoUrl!.isNotEmpty)
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle, color: Colors.white24,
              image: DecorationImage(image: NetworkImage(r.photoUrl!), fit: BoxFit.cover),
            ),
          )
        else
          CircleAvatar(radius: 36, backgroundColor: Colors.white24, child: Icon(icon, color: Colors.white, size: 32)),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(r.title + (r.time != null ? '  ·  ${r.time}' : ''),
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
          ]),
          if (r.name != null) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${r.name}${r.code != null ? '   ·   ${r.code}' : ''}',
                style: const TextStyle(color: Colors.white, fontSize: 16)),
          ),
          if (r.message != null) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(r.message!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ])),
      ]),
    );
  }
}
