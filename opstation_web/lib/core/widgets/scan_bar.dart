// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'scan_feedback.dart';
import 'camera_scanner.dart';

/// Finds a product by what a scanner reads: barcode first, then SKU (exact,
/// case-insensitive). Products need 'barcode' / 'sku' keys.
Map<String, dynamic>? findProductByCode(List<Map<String, dynamic>> products, String code) {
  final c = code.trim().toLowerCase();
  if (c.isEmpty) return null;
  for (final p in products) {
    if ('${p['barcode'] ?? ''}'.trim().toLowerCase() == c) return p;
  }
  for (final p in products) {
    if ('${p['sku'] ?? ''}'.trim().toLowerCase() == c) return p;
  }
  return null;
}

/// Courier labels often pack several fields into one code, e.g. a DEX QR:
/// "PK-DEX213512193, 3924.55, B-BTB-PK". True when any part of [scanned] is
/// the [tracking] number (ignoring case, spaces, dashes and a short prefix
/// like "PK-").
bool labelMatches(String scanned, String tracking) {
  String nz(String x) => x.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final t = nz(tracking);
  if (t.length < 5) return false;
  final parts = <String>{nz(scanned), ...scanned.split(RegExp(r'[\s,;|/]+')).map(nz)}..removeWhere((x) => x.isEmpty);
  for (final p in parts) {
    if (p == t) return true;
    if (p.length >= 6 && t.length >= 6 && (p.endsWith(t) || t.endsWith(p))) return true;
  }
  return false;
}

class ScanOutcome {
  final bool ok;
  final String message;
  const ScanOutcome(this.ok, this.message);
}

/// A barcode-scanner input: keeps focus, takes one code per Enter (USB/
/// Bluetooth scanners type the code and press Enter), queues fast scans so
/// none are lost, and shows a green / red result line. An optional "×" box
/// multiplies the next scan (e.g. 12 then scan = 12 pieces).
class ScanBar extends StatefulWidget {
  final Future<ScanOutcome> Function(String code, double qty) onScan;
  final String hint;
  final bool autofocus;
  final bool showQty;
  /// Beep on a right scan; loud buzz + whole screen blinks red on a wrong one.
  final bool strongFeedback;
  /// Show a camera button: scan with the phone / tablet camera.
  final bool camera;
  const ScanBar({super.key, required this.onScan, this.hint = 'Scan barcode (or type code + Enter)',
      this.autofocus = true, this.showQty = true, this.strongFeedback = false, this.camera = false});
  @override
  State<ScanBar> createState() => ScanBarState();
}

class ScanBarState extends State<ScanBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _qty = TextEditingController(text: '1');
  final List<(String, double)> _queue = [];
  bool _working = false;
  ScanOutcome? _last;
  int _count = 0;

  // ── Scanner stations (autofocus bars) ────────────────────────────────────
  // A hardware scanner just types. If the cursor has wandered off the scan box
  // (a button was clicked, a warning flashed…), its keystrokes are caught here
  // and fed into the box anyway, so nobody has to click the field first.
  static final List<ScanBarState> _stations = [];
  bool _station = false;
  bool _capturing = false;
  Timer? _captureIdle;
  final List<Timer> _refocusTimers = [];
  // Keys pressed while the box looks focused. If the box never receives them,
  // the browser's typing link to it has dropped — they are put in by hand.
  final List<String> _pending = [];
  String? _pendingBase;
  Timer? _pendingTimer;

  @override
  void initState() {
    super.initState();
    if (widget.strongFeedback) ScanFeedback.install();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _focus.requestFocus(); });
      _station = true;
      _stations.add(this);
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
    }
  }

  void _clearPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pending.clear();
    _pendingBase = null;
  }

  /// The box shows as focused but typing isn't reaching it: drop the cursor
  /// and take it again so the browser links up afresh.
  void _reconnect() {
    _focus.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (_mayTakeFocus()) _focus.requestFocus(); });
  }

  /// True when the scan box may take the cursor: this screen is on top and the
  /// user isn't typing in some other text field.
  bool _mayTakeFocus() {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (_focus.hasFocus) return true;
    final other = FocusManager.instance.primaryFocus?.context;
    if (other != null && other.findAncestorWidgetOfExactType<EditableText>() != null) return false;
    return true;
  }

  bool _onHardwareKey(KeyEvent e) {
    if (!mounted || e is! KeyDownEvent) return false;
    if (_stations.isEmpty || _stations.last != this) return false;
    final kb = HardwareKeyboard.instance;
    final key = e.logicalKey;
    final isEnter = key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;
    final chr = e.character;
    final printable = chr != null && chr.isNotEmpty && chr.codeUnitAt(0) >= 32 &&
        !(kb.isControlPressed || kb.isMetaPressed || kb.isAltPressed);
    // The box has the cursor: the browser types into it by itself. Only watch
    // that the keys really arrive, and step in if they don't.
    if (_focus.hasFocus && !_capturing) {
      if (isEnter) {
        if (_pending.isNotEmpty && _ctrl.text == _pendingBase) {
          final code = '${_pendingBase ?? ''}${_pending.join()}';
          _clearPending();
          _submit(code);
          _reconnect();
          return true;
        }
        _clearPending();
        return false;
      }
      if (!printable) { _clearPending(); return false; }
      _pendingBase ??= _ctrl.text;
      _pending.add(chr);
      _pendingTimer?.cancel();
      _pendingTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted && _pending.isNotEmpty && _ctrl.text == _pendingBase) {
          _ctrl.text = '${_pendingBase ?? ''}${_pending.join()}';
          _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
          _clearPending();
          _reconnect();
        } else {
          _clearPending();
        }
      });
      return false;
    }
    if (!_capturing && !_mayTakeFocus()) return false;
    if (kb.isControlPressed || kb.isMetaPressed || kb.isAltPressed) return false;
    if (isEnter) {
      if (!_capturing) return false;
      _endCapture();
      _submit(_ctrl.text);
      return true;
    }
    final ch = e.character;
    if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 32) return false;
    if (!_capturing && ch == ' ') return false; // Space on a focused button stays a click
    if (!_capturing) { _capturing = true; _ctrl.clear(); }
    _ctrl.text = _ctrl.text + ch;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    // No Enter shortly after the last key: someone is typing by hand — hand
    // the cursor to the box and let them carry on.
    _captureIdle?.cancel();
    _captureIdle = Timer(const Duration(milliseconds: 500), () {
      _endCapture();
      if (mounted && _mayTakeFocus()) _focus.requestFocus();
    });
    return true;
  }

  void _endCapture() {
    _captureIdle?.cancel();
    _captureIdle = null;
    _capturing = false;
  }

  @override
  void dispose() {
    if (_station) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
      _stations.remove(this);
    }
    _captureIdle?.cancel();
    _pendingTimer?.cancel();
    for (final t in _refocusTimers) { t.cancel(); }
    _ctrl.dispose();
    _focus.dispose();
    _qty.dispose();
    super.dispose();
  }

  void _submit(String v) {
    _clearPending();
    final code = v.trim();
    _ctrl.clear();
    _focus.requestFocus();
    if (code.isEmpty) return;
    final q = double.tryParse(_qty.text.trim()) ?? 1;
    _queue.add((code, q <= 0 ? 1 : q));
    if (widget.showQty) _qty.text = '1';
    _drain();
  }

  Future<void> _drain() async {
    if (_working) return;
    _working = true;
    while (_queue.isNotEmpty) {
      final (code, q) = _queue.removeAt(0);
      await _handle(code, q);
      if (!mounted) return;
    }
    _working = false;
    if (mounted) setState(() {});
  }

  /// One scan (scanner, typed, or camera): run it, show + sound the result.
  Future<ScanOutcome> _handle(String code, double q) async {
    ScanOutcome r;
    try {
      r = await widget.onScan(code, q);
    } catch (e) {
      r = ScanOutcome(false, '$e');
    }
    if (!mounted) return r;
    setState(() { _last = r; if (r.ok) _count++; });
    if (widget.strongFeedback) {
      if (r.ok) { ScanFeedback.ok(); } else { ScanFeedback.wrong(context); }
    } else if (!r.ok) {
      SystemSound.play(SystemSoundType.alert);
    }
    // After every scan — right or wrong — the cursor goes back to the scan
    // box, ready for the next one (hardware scanner stations only; on phones
    // this would pop the keyboard up).
    if (_station) _refocus();
    return r;
  }

  /// Put the cursor back now, on the next frame, and again once any warning
  /// flash has finished — whatever took it away, it comes back.
  void _refocus() {
    void go() { if (_mayTakeFocus() && !_focus.hasFocus) _focus.requestFocus(); }
    for (final t in _refocusTimers) { t.cancel(); }
    _refocusTimers.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) => go());
    for (final ms in const [150, 500, 1100]) {
      _refocusTimers.add(Timer(Duration(milliseconds: ms), go));
    }
  }

  /// Put the cursor in the scan box (for a hardware scanner).
  void focusInput() => _focus.requestFocus();

  Future<void> openCamera() async {
    await showCameraScanner(context, onCode: (code) async {
      final q = double.tryParse(_qty.text.trim()) ?? 1;
      final r = await _handle(code, q <= 0 ? 1 : q);
      if (widget.showQty && mounted) _qty.text = '1';
      return r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    final color = last == null ? AppTheme.border : (last.ok ? Colors.green : Colors.red);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: last == null ? Colors.white : color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(last == null ? 1 : 0.6), width: last == null ? 1 : 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (widget.showQty) ...[
            SizedBox(width: 70, child: TextField(
              controller: _qty,
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: const InputDecoration(labelText: '×', isDense: true, border: OutlineInputBorder()),
              onSubmitted: (_) => _focus.requestFocus(),
            )),
            const SizedBox(width: 8),
          ],
          Expanded(child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            autofocus: widget.autofocus,
            textInputAction: TextInputAction.done,
            // Enter (the scanner's own) must not drop the cursor out of the box.
            onEditingComplete: () {},
            decoration: InputDecoration(
              hintText: widget.hint, isDense: true, border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.qr_code_scanner, size: 20),
              suffixIcon: _working
                  ? const Padding(padding: EdgeInsets.all(12),
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
                  : widget.camera
                      ? IconButton(tooltip: 'Scan with camera', icon: const Icon(Icons.photo_camera_outlined), onPressed: openCamera)
                      : null,
            ),
            onSubmitted: _submit,
          )),
        ]),
        if (last != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(last.ok ? Icons.check_circle : Icons.error_outline, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(child: Text(last.message,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: last.ok ? Colors.green.shade800 : Colors.red.shade700))),
              if (_count > 0) Text('$_count scanned', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ]),
          ),
      ]),
    );
  }
}
