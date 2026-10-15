// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../../features/auth/auth_controller.dart';
import 'label_templates.dart';

export 'label_templates.dart';

/// Direct label printing (TSC TE200 and other TSPL printers) through the
/// Opstation Print Helper running on the same PC (127.0.0.1:9123).
///
/// Two label sizes at 203 dpi (8 dots per mm):
///   small  1.5" wide × 1" high  (38.1 × 25.4 mm  →  304 × 203 dots)
///   large  2" × 2"              (50.8 × 50.8 mm  →  406 × 406 dots)

enum LabelSize { small, large }

enum LabelCode { barcode, qr }

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

  /// Fallback when the browser won't let this page call the helper: open the
  /// helper's own page in a small window (a normal navigation, which browsers
  /// allow). That page prints and closes itself. Must run inside the click.
  static void openJobWindow(String printer, String data, String job) {
    final payload = base64Url.encode(utf8.encode(jsonEncode({'printer': printer, 'data': data, 'job_name': job})));
    html.window.open('$base/job#$payload', 'opstation_print', 'width=440,height=280');
  }

  static void openSetupPage() => html.window.open('$base/', '_blank');

  /// Remember the printer inside the helper too (used by the window fallback).
  static Future<void> saveDefault(String printer) async {
    try {
      await html.HttpRequest.request('$base/config', method: 'POST',
              requestHeaders: {'Content-Type': 'application/json'}, sendData: jsonEncode({'printer': printer}))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

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

// ── Print dialog ─────────────────────────────────────────────────────────────

/// One-stop "Print labels" window. [items] usually holds one label (printed
/// [copies] times); several items print one after another. The layout comes
/// from the organisation's label templates (Manufacturing → Label Printing).
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
      items: items, defaultCopies: defaultCopies,
      defaultTemplateId: '${defaultSize == LabelSize.small ? 'small' : 'large'}_${defaultCode == LabelCode.qr ? 'qr' : 'barcode'}',
      allowQtyEdit: allowQtyEdit, title: title),
  );
}

/// Sends labels: silently when the browser lets this page reach the helper,
/// otherwise through the helper's own small window. Call from a click handler
/// (the window fallback must open inside the click). Returns a status line.
Future<String> sendLabels({required bool helperReachable, required String tspl, required String job,
    required int count, required LabelPrinterSettings settings}) async {
  final what = '$count label${count == 1 ? '' : 's'}';
  if (!helperReachable) {
    PrintHelper.openJobWindow(settings.printer, tspl, job);
    return 'Printing $what through the helper window…';
  }
  try {
    await PrintHelper.send(settings.printer, tspl, job: job);
    return 'Sent $what to ${settings.printer.isEmpty ? 'the label printer' : settings.printer}';
  } catch (e) {
    if ('$e'.startsWith('Could not reach')) {
      PrintHelper.openJobWindow(settings.printer, tspl, job);
      return 'Printing $what through the helper window…';
    }
    rethrow;
  }
}

class _LabelPrintDialog extends ConsumerStatefulWidget {
  final List<LabelData> items;
  final int defaultCopies;
  final String defaultTemplateId;
  final bool allowQtyEdit;
  final String title;
  const _LabelPrintDialog({required this.items, required this.defaultCopies, required this.defaultTemplateId,
      required this.allowQtyEdit, required this.title});
  @override
  ConsumerState<_LabelPrintDialog> createState() => _LabelPrintDialogState();
}

class _LabelPrintDialogState extends ConsumerState<_LabelPrintDialog> {
  List<LabelTemplate> _templates = [for (final id in kBuiltInIds) builtInTemplate(id)];
  late String _tid = widget.defaultTemplateId;
  late final _copiesCtrl = TextEditingController(text: '${widget.defaultCopies < 1 ? 1 : widget.defaultCopies}');
  late final _qtyCtrl = TextEditingController(text: widget.items.isNotEmpty ? (widget.items.first.qty ?? '') : '');
  final Map<String, TextEditingController> _ask = {};
  LabelPrinterSettings _s = LabelPrinterSettings.load();
  bool? _helper; // null = checking
  bool _printing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    final org = ref.read(currentUserProvider)?.orgId;
    if (org == null) return;
    final list = await LabelTemplateStore.load(org);
    if (!mounted) return;
    setState(() {
      _templates = list;
      if (!list.any((t) => t.id == _tid)) _tid = list.first.id;
    });
  }

  Future<void> _check() async {
    setState(() => _helper = null);
    final ok = await PrintHelper.isRunning();
    if (mounted) setState(() => _helper = ok);
  }

  LabelTemplate get _t => _templates.firstWhere((t) => t.id == _tid, orElse: () => _templates.first);

  TextEditingController _askCtrl(LabelElement e) => _ask.putIfAbsent(e.id, () => TextEditingController(text: e.text));

  LabelData _prepare(LabelData d) => d.copyWith(
        qty: widget.allowQtyEdit ? _qtyCtrl.text.trim() : d.qty,
        custom: {...d.custom, for (final e in _t.askFields) e.id: _askCtrl(e).text},
      );

  Future<void> _print() async {
    final copies = int.tryParse(_copiesCtrl.text.trim()) ?? 0;
    if (copies < 1) { setState(() => _error = 'Enter how many labels to print.'); return; }
    final t = _t;
    final tspl = widget.items
        .map((d) => buildTspl(t, _prepare(d), copies,
            density: _s.density, speed: _s.speed, offsetX: _s.offsetX, offsetY: _s.offsetY))
        .join();
    final count = copies * widget.items.length;
    final reachable = _helper == true;
    if (reachable) setState(() { _printing = true; _error = null; });
    try {
      final msg = await sendLabels(helperReachable: reachable, tspl: tspl, job: widget.title, count: count, settings: _s);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
    } catch (e) {
      if (mounted) setState(() { _printing = false; _error = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.items.isNotEmpty ? widget.items.first : const LabelData(name: '');
    final t = _t;
    final hasQty = t.elements.any((e) => e.kind == 'text' && e.source == 'qty');
    final ppm = t.widthMm > 45 ? 4.4 : 6.0;
    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text(widget.title)),
        IconButton(
          tooltip: 'Label printer setup',
          icon: const Icon(Icons.settings_outlined),
          onPressed: _helper == null
              ? null
              : _helper == true
                  ? () async {
                      final s = await showLabelPrinterSetup(context);
                      if (s != null) setState(() => _s = s);
                    }
                  : PrintHelper.openSetupPage,
        ),
      ]),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _helperBanner(),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _tid, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Label layout', isDense: true, border: OutlineInputBorder()),
            items: [for (final x in _templates)
              DropdownMenuItem(value: x.id, child: Text('${x.name}  ·  ${x.widthMm.toStringAsFixed(1)}×${x.heightMm.toStringAsFixed(1)} mm',
                  overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _tid = v ?? _tid),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: [
            SizedBox(width: 140, child: TextField(
              controller: _copiesCtrl, keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: widget.items.length > 1 ? 'Copies of each' : 'Number of labels',
                  isDense: true, border: const OutlineInputBorder()),
            )),
            if (widget.allowQtyEdit && hasQty)
              SizedBox(width: 200, child: TextField(
                controller: _qtyCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Qty on label (optional)', hintText: 'e.g. 12 pcs',
                    isDense: true, border: OutlineInputBorder()),
              )),
            for (final e in t.askFields)
              SizedBox(width: 200, child: TextField(
                controller: _askCtrl(e),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: e.prefix.trim().isEmpty ? 'Text' : e.prefix.trim(),
                    isDense: true, border: const OutlineInputBorder()),
              )),
          ]),
          const SizedBox(height: 14),
          Center(child: LabelPreview(template: t, data: _prepare(first), pxPerMm: ppm)),
          for (final w in labelWarnings(t, _prepare(first)))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(w, style: const TextStyle(fontSize: 11.5, color: Colors.red)),
            ),
          const SizedBox(height: 4),
          const Center(child: Text('Preview — adjust layouts in Manufacturing → Label Printing',
              style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary))),
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
          onPressed: _helper != null && !_printing ? _print : null,
        ),
      ],
    );
  }

  Widget _helperBanner() => LabelHelperBanner(reachable: _helper, printer: _s.printer, onRetry: _check);
}

/// Status strip: checking / connected / will print through the helper window.
class LabelHelperBanner extends StatelessWidget {
  final bool? reachable;
  final String printer;
  final VoidCallback onRetry;
  const LabelHelperBanner({super.key, required this.reachable, required this.printer, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (reachable == null) {
      return const Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 8),
        Text('Looking for the label printer…', style: TextStyle(fontSize: 12.5)),
      ]);
    }
    if (reachable == true) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: Colors.green.withOpacity(0.08), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(Icons.check_circle_outline, size: 18, color: Colors.green.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text(printer.isNotEmpty ? 'Printer: $printer' : 'Connected — prints to the printer chosen in the helper.',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.orange.withOpacity(0.08), borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withOpacity(0.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Printing will open a small helper window',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('It sends the labels and closes itself. Allow pop-ups for Opstation if the browser asks. '
            'First time on this PC? Download and double-click OpstationPrint.exe, then use "Printer setup".',
            style: TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.settings_outlined, size: 16),
            label: const Text('Printer setup'),
            onPressed: PrintHelper.openSetupPage,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('Download helper'),
            onPressed: () => html.window.open(PrintHelper.downloadPath, '_blank'),
          ),
          TextButton.icon(icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry'), onPressed: onRetry),
        ]),
      ]),
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
                decoration: const InputDecoration(labelText: 'Gap for test label (mm)', isDense: true))),
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
                final c = current();
                await PrintHelper.send(sel!, buildTspl(builtInTemplate('small_barcode')..gapMm = c.gapMm,
                    const LabelData(name: 'Opstation test label', code: 'TEST-12345', batch: 'B-001', date: 'Today'), 1,
                    density: c.density, speed: c.speed, offsetX: c.offsetX, offsetY: c.offsetY), job: 'Opstation test');
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
              PrintHelper.saveDefault(c.printer);
              Navigator.of(dlg, rootNavigator: true).pop(c);
            },
            child: const Text('Save'),
          ),
        ],
      );
    }),
  );
}
