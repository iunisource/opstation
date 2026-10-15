// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Direct label printing (TSC TE200 and other TSPL printers) through the
/// Opstation Print Helper running on the same PC (127.0.0.1:9123).
///
/// Two label sizes at 203 dpi (8 dots per mm):
///   small  1.5" wide × 1" high  (38.1 × 25.4 mm  →  304 × 203 dots)
///   large  2" × 2"              (50.8 × 50.8 mm  →  406 × 406 dots)

enum LabelSize { small, large }

enum LabelCode { barcode, qr }

class LabelData {
  final String name;
  final String? code; // barcode / QR content (product barcode or SKU, asset URL…)
  final String? codeText; // text shown under a QR (e.g. asset code); defaults to code
  final String? batch;
  final String? date;
  final String? qty; // e.g. "12 pcs"
  const LabelData({required this.name, this.code, this.codeText, this.batch, this.date, this.qty});
}

// ── Settings (per PC — the printer belongs to this computer) ────────────────
class LabelPrinterSettings {
  String printer;
  double gapMm;
  int density; // 0–15
  int speed; // inches per second
  int offsetX, offsetY; // dots, to nudge print position
  LabelPrinterSettings({this.printer = '', this.gapMm = 3, this.density = 8, this.speed = 4,
      this.offsetX = 0, this.offsetY = 0});

  static const _key = 'opst_label_printer_v1';

  static LabelPrinterSettings load() {
    try {
      final raw = html.window.localStorage[_key];
      if (raw == null) return LabelPrinterSettings();
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return LabelPrinterSettings(
        printer: '${m['printer'] ?? ''}',
        gapMm: (m['gap'] as num?)?.toDouble() ?? 3,
        density: (m['density'] as num?)?.toInt() ?? 8,
        speed: (m['speed'] as num?)?.toInt() ?? 4,
        offsetX: (m['ox'] as num?)?.toInt() ?? 0,
        offsetY: (m['oy'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return LabelPrinterSettings();
    }
  }

  void save() {
    try {
      html.window.localStorage[_key] = jsonEncode({
        'printer': printer, 'gap': gapMm, 'density': density, 'speed': speed, 'ox': offsetX, 'oy': offsetY,
      });
    } catch (_) {}
  }
}

// ── Helper client ────────────────────────────────────────────────────────────
class PrintHelper {
  static const base = 'http://127.0.0.1:9123';
  static const downloadPath = '/downloads/OpstationPrint-Windows.zip';

  static Future<bool> isRunning() async {
    try {
      final r = await html.HttpRequest.request('$base/health').timeout(const Duration(seconds: 2));
      return r.status == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<List<String>> printers() async {
    final r = await html.HttpRequest.request('$base/printers').timeout(const Duration(seconds: 5));
    final m = jsonDecode(r.responseText ?? '{}') as Map<String, dynamic>;
    return [for (final p in (m['printers'] as List? ?? const [])) '$p'];
  }

  /// Sends raw printer commands. Throws a readable message on failure.
  static Future<void> send(String printer, String data, {String job = 'Opstation labels'}) async {
    html.HttpRequest r;
    try {
      r = await html.HttpRequest.request('$base/print',
              method: 'POST',
              requestHeaders: {'Content-Type': 'application/json'},
              sendData: jsonEncode({'printer': printer, 'data': data, 'job_name': job}))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw 'The printer did not answer in time.';
    } catch (e) {
      // A non-2xx status also lands here; try to read the helper's message.
      if (e is html.ProgressEvent && e.target is html.HttpRequest) {
        final t = (e.target as html.HttpRequest).responseText ?? '';
        try {
          final msg = (jsonDecode(t) as Map)['error'];
          if (msg != null) throw '$msg';
        } catch (inner) {
          if (inner is String) rethrow;
        }
      }
      throw 'Could not reach the Opstation Print Helper on this PC.';
    }
    if (r.status != 200) throw 'Printing failed (${r.status}).';
  }
}

// ── TSPL builder ─────────────────────────────────────────────────────────────
class Tspl {
  static String _clean(String s) => s
      .replaceAll('—', '-').replaceAll('–', '-').replaceAll('·', '-')
      .replaceAll('"', "'")
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '')
      .trim();

  static List<String> _wrap(String text, int maxChars, int maxLines) {
    final words = _clean(text).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final lines = <String>[];
    var cur = '';
    for (final w0 in words) {
      var w = w0;
      while (w.length > maxChars) {
        if (cur.isNotEmpty) { lines.add(cur); cur = ''; }
        lines.add(w.substring(0, maxChars));
        w = w.substring(maxChars);
      }
      if (cur.isEmpty) {
        cur = w;
      } else if (cur.length + 1 + w.length <= maxChars) {
        cur = '$cur $w';
      } else {
        lines.add(cur);
        cur = w;
      }
    }
    if (cur.isNotEmpty) lines.add(cur);
    if (lines.length > maxLines) {
      final kept = lines.take(maxLines).toList();
      final last = kept.last;
      kept[maxLines - 1] = last.length >= maxChars ? '${last.substring(0, maxChars - 2)}..' : '$last..';
      return kept;
    }
    return lines;
  }

  static String _cut(String s, int max) {
    final c = _clean(s);
    return c.length <= max ? c : '${c.substring(0, max - 2)}..';
  }

  static String _text(int x, int y, String font, String s) => 'TEXT $x,$y,"$font",0,1,1,"${_clean(s)}"';

  /// Code 128 width in dots ≈ (11 × chars + 35) × narrow.
  static int _barcodeWidth(String code, int narrow) => (11 * code.length + 35) * narrow;

  static String build(LabelData d, LabelSize size, LabelCode codeType, int copies, LabelPrinterSettings s) {
    final small = size == LabelSize.small;
    final w = small ? 304 : 406;
    final out = <String>[
      small ? 'SIZE 38.1 mm,25.4 mm' : 'SIZE 50.8 mm,50.8 mm',
      'GAP ${s.gapMm.toStringAsFixed(1)} mm,0 mm',
      'DIRECTION 1,0',
      'REFERENCE ${s.offsetX},${s.offsetY}',
      'SET TEAR ON',
      'DENSITY ${s.density.clamp(0, 15)}',
      'SPEED ${s.speed.clamp(2, 6)}',
      'CLS',
    ];
    final code = _clean(d.code ?? '');
    final codeText = _clean(d.codeText ?? d.code ?? '');
    final hasCode = code.isNotEmpty;
    final batch = (d.batch ?? '').trim();
    final date = (d.date ?? '').trim();
    final qty = (d.qty ?? '').trim();

    if (small) {
      if (codeType == LabelCode.qr && hasCode) {
        final cell = code.length <= 30 ? 4 : 3;
        out.add('QRCODE 8,${code.length <= 30 ? 40 : 45},M,$cell,A,0,"$code"');
        const x = 132; // text column to the right of the QR
        var y = 8;
        for (final l in _wrap(d.name, 14, 3)) { out.add(_text(x, y, '2', l)); y += 22; }
        y += 4;
        if (codeText.isNotEmpty && codeText != code) { out.add(_text(x, y, '1', _cut(codeText, 20))); y += 18; }
        if (batch.isNotEmpty) { out.add(_text(x, y, '1', _cut('B: $batch', 20))); y += 18; }
        if (date.isNotEmpty) { out.add(_text(x, y, '1', _cut(date, 20))); }
      } else {
        var y = 6;
        for (final l in _wrap(d.name, 24, 2)) { out.add(_text(8, y, '2', l)); y += 22; }
        if (hasCode) {
          final narrow = _barcodeWidth(code, 2) <= w - 16 ? 2 : 1;
          final bw = _barcodeWidth(code, narrow);
          final x = ((w - bw) / 2).round().clamp(4, w);
          out.add('BARCODE $x,54,"128",58,1,0,$narrow,$narrow,"$code"');
        }
        final bottom = [if (batch.isNotEmpty) 'B:$batch', if (date.isNotEmpty) date].join('  ');
        if (bottom.isNotEmpty) out.add(_text(8, 178, '1', _cut(bottom, 36)));
      }
    } else {
      var y = 12;
      for (final l in _wrap(d.name, 23, 2)) { out.add(_text(12, y, '3', l)); y += 30; }
      if (qty.isNotEmpty) out.add(_text(12, 76, '3', _cut('Qty: $qty', 23)));
      if (hasCode) {
        if (codeType == LabelCode.qr) {
          final cell = code.length <= 30 ? 7 : 5;
          final modules = code.length <= 14 ? 21 : code.length <= 26 ? 25 : code.length <= 42 ? 29 : 33;
          final qw = modules * cell;
          out.add('QRCODE ${((w - qw) / 2).round().clamp(4, w)},112,M,$cell,A,0,"$code"');
          if (codeText.isNotEmpty && codeText != code) out.add(_text(12, 112 + qw + 6, '2', _cut(codeText, 31)));
        } else {
          final narrow = _barcodeWidth(code, 3) <= w - 24 ? 3 : (_barcodeWidth(code, 2) <= w - 24 ? 2 : 1);
          final bw = _barcodeWidth(code, narrow);
          out.add('BARCODE ${((w - bw) / 2).round().clamp(4, w)},120,"128",110,1,0,$narrow,$narrow,"$code"');
        }
      }
      if (batch.isNotEmpty) out.add(_text(12, 318, '3', _cut('Batch: $batch', 23)));
      if (date.isNotEmpty) out.add(_text(12, 352, '2', _cut(date, 31)));
    }
    out.add('PRINT 1,${copies.clamp(1, 9999)}');
    return '${out.join('\r\n')}\r\n';
  }
}

// ── Dialogs ──────────────────────────────────────────────────────────────────

/// One-stop "Print labels" window. [items] usually holds one label design
/// (printed [copies] times); several items print one after another.
Future<void> showLabelPrintDialog(
  BuildContext context, {
  required List<LabelData> items,
  int defaultCopies = 1,
  LabelSize defaultSize = LabelSize.small,
  LabelCode defaultCode = LabelCode.barcode,
  bool allowQtyEdit = true,
  String title = 'Print labels',
}) async {
  await showDialog(
    context: context,
    builder: (_) => _LabelPrintDialog(
      items: items, defaultCopies: defaultCopies, defaultSize: defaultSize,
      defaultCode: defaultCode, allowQtyEdit: allowQtyEdit, title: title),
  );
}

class _LabelPrintDialog extends StatefulWidget {
  final List<LabelData> items;
  final int defaultCopies;
  final LabelSize defaultSize;
  final LabelCode defaultCode;
  final bool allowQtyEdit;
  final String title;
  const _LabelPrintDialog({required this.items, required this.defaultCopies, required this.defaultSize,
      required this.defaultCode, required this.allowQtyEdit, required this.title});
  @override
  State<_LabelPrintDialog> createState() => _LabelPrintDialogState();
}

class _LabelPrintDialogState extends State<_LabelPrintDialog> {
  late LabelSize _size = widget.defaultSize;
  late LabelCode _code = widget.defaultCode;
  late final _copiesCtrl = TextEditingController(text: '${widget.defaultCopies < 1 ? 1 : widget.defaultCopies}');
  late final _qtyCtrl = TextEditingController(text: widget.items.isNotEmpty ? (widget.items.first.qty ?? '') : '');
  LabelPrinterSettings _s = LabelPrinterSettings.load();
  bool? _helper; // null = checking
  bool _printing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _helper = null);
    final ok = await PrintHelper.isRunning();
    if (mounted) setState(() => _helper = ok);
  }

  LabelData _withQty(LabelData d) => LabelData(
      name: d.name, code: d.code, codeText: d.codeText, batch: d.batch, date: d.date,
      qty: widget.allowQtyEdit ? _qtyCtrl.text.trim() : d.qty);

  Future<void> _print() async {
    final copies = int.tryParse(_copiesCtrl.text.trim()) ?? 0;
    if (copies < 1) { setState(() => _error = 'Enter how many labels to print.'); return; }
    if (_s.printer.isEmpty) { setState(() => _error = 'Pick the label printer first (gear icon).'); return; }
    setState(() { _printing = true; _error = null; });
    try {
      final data = widget.items.map((d) => Tspl.build(_withQty(d), _size, _code, copies, _s)).join();
      await PrintHelper.send(_s.printer, data, job: widget.title);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Sent ${copies * widget.items.length} label${copies * widget.items.length == 1 ? '' : 's'} to ${_s.printer}'),
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) setState(() { _printing = false; _error = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.items.isNotEmpty ? widget.items.first : const LabelData(name: '');
    final hasCode = (first.code ?? '').isNotEmpty;
    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text(widget.title)),
        IconButton(
          tooltip: 'Label printer setup',
          icon: const Icon(Icons.settings_outlined),
          onPressed: _helper == true
              ? () async {
                  final s = await showLabelPrinterSetup(context);
                  if (s != null) setState(() => _s = s);
                }
              : null,
        ),
      ]),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _helperBanner(),
          const SizedBox(height: 12),
          const Text('Label size', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          SegmentedButton<LabelSize>(
            segments: const [
              ButtonSegment(value: LabelSize.small, label: Text('1.5" × 1"')),
              ButtonSegment(value: LabelSize.large, label: Text('2" × 2"')),
            ],
            selected: {_size},
            onSelectionChanged: (v) => setState(() => _size = v.first),
          ),
          if (hasCode) ...[
            const SizedBox(height: 12),
            const Text('Code', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            SegmentedButton<LabelCode>(
              segments: const [
                ButtonSegment(value: LabelCode.barcode, label: Text('Barcode'), icon: Icon(Icons.view_week_outlined, size: 16)),
                ButtonSegment(value: LabelCode.qr, label: Text('QR code'), icon: Icon(Icons.qr_code_2, size: 16)),
              ],
              selected: {_code},
              onSelectionChanged: (v) => setState(() => _code = v.first),
            ),
          ],
          const SizedBox(height: 14),
          Row(children: [
            SizedBox(width: 140, child: TextField(
              controller: _copiesCtrl, keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: widget.items.length > 1 ? 'Copies of each' : 'Number of labels',
                  isDense: true, border: const OutlineInputBorder()),
            )),
            if (widget.allowQtyEdit && _size == LabelSize.large) ...[
              const SizedBox(width: 10),
              Expanded(child: TextField(
                controller: _qtyCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Qty on label (optional)', hintText: 'e.g. 12 pcs',
                    isDense: true, border: OutlineInputBorder()),
              )),
            ],
          ]),
          const SizedBox(height: 14),
          _preview(_withQty(first)),
          if (widget.items.length > 1)
            Padding(padding: const EdgeInsets.only(top: 6),
                child: Text('${widget.items.length} different labels', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5))),
        ])),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('Cancel')),
        FilledButton.icon(
          icon: _printing
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.print_outlined, size: 18),
          label: const Text('Print'),
          onPressed: _helper == true && !_printing ? _print : null,
        ),
      ],
    );
  }

  Widget _helperBanner() {
    if (_helper == null) {
      return const Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 8),
        Text('Looking for the label printer…', style: TextStyle(fontSize: 12.5)),
      ]);
    }
    if (_helper == true) {
      final has = _s.printer.isNotEmpty;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
            color: (has ? Colors.green : Colors.orange).withOpacity(0.08), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(has ? Icons.check_circle_outline : Icons.info_outline, size: 18,
              color: has ? Colors.green.shade700 : Colors.orange.shade800),
          const SizedBox(width: 8),
          Expanded(child: Text(has ? 'Printer: ${_s.printer}' : 'Connected. Pick the label printer with the gear icon.',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.orange.withOpacity(0.08), borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withOpacity(0.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Opstation Print Helper is not running on this PC',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('1. On the PC with the label printer: download, unzip and double-click OpstationPrint.exe '
            '(a message confirms "Installed and running").\n'
            '2. Press Retry. If Chrome asks to allow access to devices on your local network, press Allow.\n'
            'Blocked it earlier? Click the icon left of the address bar → Site settings → Local network access → Allow, then reload.',
            style: TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('Download helper (Windows)'),
            onPressed: () => html.window.open(PrintHelper.downloadPath, '_blank'),
          ),
          TextButton.icon(icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry'), onPressed: _check),
        ]),
      ]),
    );
  }

  // A rough on-screen picture of the label (not exact printer output).
  Widget _preview(LabelData d) {
    final small = _size == LabelSize.small;
    final w = small ? 216.0 : 180.0;
    final h = small ? 144.0 : 180.0;
    final hasCode = (d.code ?? '').isNotEmpty;
    final codeBox = !hasCode
        ? const SizedBox.shrink()
        : _code == LabelCode.qr
            ? Icon(Icons.qr_code_2, size: small ? 64 : 84)
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Container(height: small ? 30 : 44, width: small ? 150 : 140,
                    decoration: const BoxDecoration(gradient: LinearGradient(colors: [
                      Colors.black, Colors.white, Colors.black, Colors.black, Colors.white, Colors.black, Colors.white, Colors.black,
                    ], stops: [0, .12, .2, .35, .45, .6, .8, 1]))),
                Text(d.code!, style: const TextStyle(fontSize: 8)),
              ]);
    final lines = <Widget>[
      Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: small ? 10 : 11.5, fontWeight: FontWeight.w700)),
      if (!small && (d.qty ?? '').isNotEmpty) Text('Qty: ${d.qty}', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
    ];
    final meta = [if ((d.batch ?? '').isNotEmpty) 'B: ${d.batch}', if ((d.date ?? '').isNotEmpty) d.date!].join('  ');
    return Center(
      child: Container(
        width: w, height: h, padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.border),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6)]),
        child: small && _code == LabelCode.qr && hasCode
            ? Row(children: [
                codeBox,
                const SizedBox(width: 4),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  ...lines,
                  if ((d.codeText ?? '').isNotEmpty && d.codeText != d.code) Text(d.codeText!, style: const TextStyle(fontSize: 8.5)),
                  if (meta.isNotEmpty) Text(meta, style: const TextStyle(fontSize: 8.5)),
                ])),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ...lines,
                const Spacer(),
                Center(child: codeBox),
                const Spacer(),
                if (meta.isNotEmpty) Text(meta, style: const TextStyle(fontSize: 8.5)),
              ]),
      ),
    );
  }
}

/// Pick the printer + fine-tune; returns the saved settings (or null).
Future<LabelPrinterSettings?> showLabelPrinterSetup(BuildContext context) async {
  final s = LabelPrinterSettings.load();
  List<String> printers = [];
  String? err;
  try {
    printers = await PrintHelper.printers();
  } catch (e) {
    err = 'Could not list printers: $e';
  }
  if (!context.mounted) return null;
  final gap = TextEditingController(text: s.gapMm.toString());
  final ox = TextEditingController(text: '${s.offsetX}');
  final oy = TextEditingController(text: '${s.offsetY}');
  String? sel = printers.contains(s.printer) ? s.printer
      : (printers.firstWhere((p) => p.toLowerCase().contains('tsc') || p.toLowerCase().contains('te200'),
          orElse: () => printers.isNotEmpty ? printers.first : ''));
  if (sel == '') sel = null;
  int density = s.density, speed = s.speed;
  String? msg;
  return showDialog<LabelPrinterSettings>(
    context: context,
    builder: (dlg) => StatefulBuilder(builder: (dlg, setD) {
      LabelPrinterSettings current() => LabelPrinterSettings(
            printer: sel ?? '', gapMm: double.tryParse(gap.text.trim()) ?? 3, density: density, speed: speed,
            offsetX: int.tryParse(ox.text.trim()) ?? 0, offsetY: int.tryParse(oy.text.trim()) ?? 0);
      return AlertDialog(
        title: const Text('Label printer setup'),
        content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (err != null) Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
          DropdownButtonFormField<String>(
            value: sel, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Printer', isDense: true),
            items: [for (final p in printers) DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setD(() => sel = v),
          ),
          if (printers.isEmpty && err == null)
            const Padding(padding: EdgeInsets.only(top: 6),
                child: Text('No printers found. Install the TSC driver and check the printer shows in Windows "Printers & scanners".',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: gap, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Gap between labels (mm)', isDense: true))),
            const SizedBox(width: 10),
            Expanded(child: DropdownButtonFormField<int>(
              value: speed, isDense: true,
              decoration: const InputDecoration(labelText: 'Speed', isDense: true),
              items: [for (final v in [2, 3, 4, 5, 6]) DropdownMenuItem(value: v, child: Text('$v in/s'))],
              onChanged: (v) => setD(() => speed = v ?? 4),
            )),
          ]),
          const SizedBox(height: 12),
          Text('Darkness: $density', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          Slider(value: density.toDouble(), min: 0, max: 15, divisions: 15, label: '$density',
              onChanged: (v) => setD(() => density = v.round())),
          Row(children: [
            Expanded(child: TextField(controller: ox, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Shift right (dots)', helperText: '8 dots = 1 mm', isDense: true))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: oy, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Shift down (dots)', isDense: true))),
          ]),
          if (msg != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(msg!, style: const TextStyle(fontSize: 12.5))),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(), child: const Text('Cancel')),
          OutlinedButton(
            onPressed: sel == null ? null : () async {
              setD(() => msg = 'Printing test label…');
              try {
                await PrintHelper.send(sel!, Tspl.build(
                    const LabelData(name: 'Opstation test label', code: 'TEST-12345', batch: 'B-001', date: 'Today'),
                    LabelSize.small, LabelCode.barcode, 1, current()), job: 'Opstation test');
                setD(() => msg = 'Test label sent. If it prints off-centre, adjust the shift values.');
              } catch (e) {
                setD(() => msg = '$e');
              }
            },
            child: const Text('Test print'),
          ),
          FilledButton(
            onPressed: sel == null ? null : () {
              final c = current()..save();
              Navigator.of(dlg, rootNavigator: true).pop(c);
            },
            child: const Text('Save'),
          ),
        ],
      );
    }),
  );
}
