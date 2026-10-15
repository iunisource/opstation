// ignore_for_file: deprecated_member_use
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/permissions/access_control.dart';
import '../../../core/printing/label_printer.dart';
import '../../auth/auth_controller.dart';

/// Manufacturing → Label Printing.
/// Design label layouts (drag items on the preview, or type exact positions in
/// mm) and print any manual label. Layouts are shared by the organisation and
/// are the same ones used by Job Card batch labels, product and asset labels.
/// Editing layouts needs Edit access; printing needs any access to the page.
class ErpLabelPrintingScreen extends ConsumerStatefulWidget {
  const ErpLabelPrintingScreen({super.key});
  @override
  ConsumerState<ErpLabelPrintingScreen> createState() => _ErpLabelPrintingScreenState();
}

class _ErpLabelPrintingScreenState extends ConsumerState<ErpLabelPrintingScreen> {
  List<LabelTemplate> _templates = [for (final id in kBuiltInIds) builtInTemplate(id)];
  String _tid = kBuiltInIds.first;
  String? _elId;
  final Set<String> _dirty = {};
  bool _loading = true, _saving = false;
  bool? _helper;
  LabelPrinterSettings _s = LabelPrinterSettings.load();
  final Map<String, TextEditingController> _ctrls = {};

  // Print form (sample data for the preview too)
  final _name = TextEditingController(text: 'Sample product name');
  final _code = TextEditingController(text: '8964000123456');
  final _codeText = TextEditingController();
  final _batch = TextEditingController(text: 'B-001');
  final _date = TextEditingController();
  final _qty = TextEditingController();
  final _copies = TextEditingController(text: '1');
  final Map<String, TextEditingController> _ask = {};
  List<Map<String, dynamic>> _products = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  bool get _canEdit {
    final r = ref.read(currentUserProvider)?.role;
    if (r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin) return true;
    return ref.read(accessSyncProvider)?.canEditDoc('label_printing') ?? false;
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _date.text = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    _load();
    _checkHelper();
  }

  @override
  void dispose() {
    for (final c in [..._ctrls.values, ..._ask.values, _name, _code, _codeText, _batch, _date, _qty, _copies]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final org = _orgId;
    if (org == null) return;
    final list = await LabelTemplateStore.load(org);
    List<Map<String, dynamic>> prods = [];
    try {
      prods = List<Map<String, dynamic>>.from(await Supabase.instance.client.from('products')
          .select('id, name, sku, barcode').eq('org_id', org).eq('is_active', true).order('name').limit(10000));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _templates = list;
      _products = prods;
      _loading = false;
      if (!list.any((t) => t.id == _tid)) _tid = list.first.id;
    });
  }

  Future<void> _checkHelper() async {
    setState(() => _helper = null);
    final ok = await PrintHelper.isRunning();
    if (mounted) setState(() => _helper = ok);
  }

  LabelTemplate get _t => _templates.firstWhere((t) => t.id == _tid, orElse: () => _templates.first);
  LabelElement? get _el {
    for (final e in _t.elements) {
      if (e.id == _elId) return e;
    }
    return null;
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  void _changed(VoidCallback fn) {
    setState(() {
      fn();
      _dirty.add(_tid);
    });
  }

  LabelData get _data => LabelData(
        name: _name.text, code: _code.text.trim(), codeText: _codeText.text.trim(),
        batch: _batch.text.trim(), date: _date.text.trim(), qty: _qty.text.trim(),
        custom: {for (final e in _t.askFields) e.id: _askCtrl(e).text},
      );

  TextEditingController _askCtrl(LabelElement e) => _ask.putIfAbsent(e.id, () => TextEditingController(text: e.text));

  // ── number fields bound to the selected element ──────────────────────────
  String _fmt(num v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  TextEditingController _ctrl(String key, num v) => _ctrls.putIfAbsent(key, () => TextEditingController(text: _fmt(v)));
  void _syncCtrl(String key, num v) {
    final c = _ctrls[key];
    if (c != null && c.text != _fmt(v)) c.text = _fmt(v);
  }

  // ── actions ───────────────────────────────────────────────────────────────
  Future<void> _save() async {
    final org = _orgId;
    if (org == null) return;
    setState(() => _saving = true);
    try {
      await LabelTemplateStore.save(org, _t);
      setState(() => _dirty.remove(_tid));
      _snack('Layout "${_t.name}" saved');
    } catch (e) {
      _snack('Could not save the layout. This feature may not be set up yet — please contact Opstation support.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetOrDelete() async {
    final t = _t;
    final org = _orgId;
    if (org == null) return;
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: Text(t.builtIn ? 'Reset "${t.name}"?' : 'Delete "${t.name}"?'),
      content: Text(t.builtIn
          ? 'The layout goes back to the original positions and sizes.'
          : 'This label layout will be removed for everyone.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
          onPressed: () => Navigator.of(d, rootNavigator: true).pop(true),
          child: Text(t.builtIn ? 'Reset' : 'Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      if (t.saved) await LabelTemplateStore.delete(org, t.id);
      setState(() {
        _dirty.remove(t.id);
        _elId = null;
        _ctrls.clear();
        if (t.builtIn) {
          final i = _templates.indexWhere((x) => x.id == t.id);
          _templates[i] = builtInTemplate(t.id);
        } else {
          _templates.removeWhere((x) => x.id == t.id);
          _tid = _templates.first.id;
        }
      });
    } catch (e) {
      _snack('Could not ${t.builtIn ? 'reset' : 'delete'} the layout.');
    }
  }

  Future<void> _newTemplate({bool duplicate = true}) async {
    final ctrl = TextEditingController(text: duplicate ? '${_t.name} (copy)' : 'New label');
    final name = await showDialog<String>(context: context, builder: (d) => AlertDialog(
      title: Text(duplicate ? 'Duplicate layout' : 'New label layout'),
      content: SizedBox(width: 360, child: TextField(controller: ctrl, autofocus: true,
          decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()))),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(ctrl.text.trim()), child: const Text('Create')),
      ],
    ));
    if (name == null || name.isEmpty) return;
    final id = 'tpl_${DateTime.now().millisecondsSinceEpoch}';
    final t = duplicate
        ? _t.copy(id: id, name: name)
        : LabelTemplate(id: id, name: name, widthMm: 38.1, heightMm: 25.4, elements: [
            LabelElement(id: 'e1', kind: 'text', source: 'custom', text: 'Your text', x: 2, y: 2, font: 3),
          ]);
    setState(() {
      _templates.add(t);
      _tid = id;
      _elId = null;
      _ctrls.clear();
      _dirty.add(id);
    });
  }

  void _addElement(String kind) {
    final t = _t;
    final id = '${kind}_${DateTime.now().millisecondsSinceEpoch}';
    final e = switch (kind) {
      'barcode' => LabelElement(id: id, kind: 'barcode', source: 'code', center: true, y: t.heightMm / 3, height: 7),
      'qr' => LabelElement(id: id, kind: 'qr', source: 'code', x: 1, y: 1),
      'line' => LabelElement(id: id, kind: 'line', x: 1, y: t.heightMm / 2, width: t.widthMm - 2, height: 0.25),
      _ => LabelElement(id: id, kind: 'text', source: 'custom', text: 'Text', x: 1, y: 1, font: 2),
    };
    _changed(() {
      t.elements.add(e);
      _elId = id;
    });
  }

  Future<void> _print({bool test = false}) async {
    final copies = test ? 1 : (int.tryParse(_copies.text.trim()) ?? 0);
    if (copies < 1) { _snack('Enter how many labels to print.'); return; }
    final tspl = buildTspl(_t, _data, copies,
        density: _s.density, speed: _s.speed, offsetX: _s.offsetX, offsetY: _s.offsetY);
    try {
      final msg = await sendLabels(helperReachable: _helper == true, tspl: tspl,
          job: 'Opstation · ${_t.name}', count: copies, settings: _s);
      _snack(msg);
    } catch (e) {
      _snack('$e');
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 1100;
    final canEdit = _canEdit;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : narrow
            ? ListView(padding: const EdgeInsets.all(12), children: [
                _templateList(canEdit, compact: true),
                const SizedBox(height: 12),
                _designer(canEdit),
                const SizedBox(height: 12),
                if (canEdit && _el != null) ...[_elementPanel(_el!), const SizedBox(height: 12)],
                _printPanel(),
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 240, child: _templateList(canEdit)),
                const SizedBox(width: 14),
                Expanded(child: SingleChildScrollView(child: _designer(canEdit))),
                const SizedBox(width: 14),
                SizedBox(width: 320, child: SingleChildScrollView(child: Column(children: [
                  if (canEdit && _el != null) ...[_elementPanel(_el!), const SizedBox(height: 12)],
                  _printPanel(),
                ]))),
              ]);
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 8 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Label Printing', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800))),
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
        Text(canEdit
                ? 'Design label layouts (drag items on the label, or type exact positions) and print any label.'
                : 'Print any label. Layouts are managed by users with Edit access.',
            style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 14),
        Expanded(child: body),
      ]),
    );
  }

  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(14)}) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: child,
      );

  Widget _templateList(bool canEdit, {bool compact = false}) {
    if (compact) {
      return _card(child: Row(children: [
        Expanded(child: DropdownButtonFormField<String>(
          value: _tid, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Layout', isDense: true),
          items: [for (final t in _templates)
            DropdownMenuItem(value: t.id, child: Text('${t.name}${_dirty.contains(t.id) ? ' •' : ''}', overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() { _tid = v ?? _tid; _elId = null; _ctrls.clear(); }),
        )),
        if (canEdit) IconButton(tooltip: 'New layout', icon: const Icon(Icons.add), onPressed: () => _newTemplate(duplicate: false)),
      ]));
    }
    return _card(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(14, 4, 6, 4), child: Row(children: [
          const Expanded(child: Text('Layouts', style: TextStyle(fontWeight: FontWeight.w700))),
          if (canEdit) IconButton(tooltip: 'New layout', icon: const Icon(Icons.add, size: 20),
              visualDensity: VisualDensity.compact, onPressed: () => _newTemplate(duplicate: false)),
        ])),
        for (final t in _templates)
          ListTile(
            dense: true,
            selected: t.id == _tid,
            selectedTileColor: AppTheme.primary.withOpacity(0.07),
            leading: Icon(t.hasCode && t.elements.any((e) => e.kind == 'qr') ? Icons.qr_code_2 : Icons.label_outline, size: 18),
            title: Text(t.name, style: const TextStyle(fontSize: 13)),
            subtitle: Text('${t.widthMm.toStringAsFixed(1)} × ${t.heightMm.toStringAsFixed(1)} mm'
                '${t.builtIn ? ' · standard' : ''}${_dirty.contains(t.id) ? ' · unsaved' : ''}',
                style: TextStyle(fontSize: 11, color: _dirty.contains(t.id) ? Colors.orange.shade800 : AppTheme.textSecondary)),
            onTap: () => setState(() { _tid = t.id; _elId = null; _ctrls.clear(); }),
          ),
      ]),
    );
  }

  Widget _designer(bool canEdit) {
    final t = _t;
    final ppm = t.widthMm > 80 ? 4.0 : (t.widthMm > 45 ? 8.0 : 10.0);
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(t.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
        if (canEdit) ...[
          IconButton(tooltip: 'Duplicate', icon: const Icon(Icons.copy_all_outlined, size: 20), onPressed: () => _newTemplate()),
          IconButton(
            tooltip: t.builtIn ? 'Reset to original' : 'Delete layout',
            icon: Icon(t.builtIn ? Icons.restart_alt : Icons.delete_outline, size: 20, color: AppTheme.danger),
            onPressed: _resetOrDelete),
          const SizedBox(width: 6),
          FilledButton.icon(
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(_dirty.contains(t.id) ? 'Save layout' : 'Saved'),
            onPressed: _saving || !_dirty.contains(t.id) ? null : _save,
          ),
        ],
      ]),
      if (canEdit) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (!t.builtIn)
            SizedBox(width: 200, child: TextField(
              controller: _ctrls.putIfAbsent('${t.id}.name', () => TextEditingController(text: t.name)),
              decoration: const InputDecoration(labelText: 'Layout name', isDense: true),
              onChanged: (v) => _changed(() => t.name = v.trim().isEmpty ? t.name : v.trim()),
            )),
          _numField('${t.id}.w', 'Width (mm)', t.widthMm, (v) => _changed(() => t.widthMm = v.clamp(10.0, 110.0)), step: 0.5, width: 110),
          _numField('${t.id}.h', 'Height (mm)', t.heightMm, (v) => _changed(() => t.heightMm = v.clamp(5.0, 200.0)), step: 0.5, width: 110),
          _numField('${t.id}.gap', 'Gap (mm)', t.gapMm, (v) => _changed(() => t.gapMm = v.clamp(0.0, 20.0)), step: 0.5, width: 100),
          PopupMenuButton<List<double>>(
            tooltip: 'Common sizes',
            onSelected: (v) => _changed(() {
              t.widthMm = v[0];
              t.heightMm = v[1];
              _syncCtrl('${t.id}.w', v[0]);
              _syncCtrl('${t.id}.h', v[1]);
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: [38.1, 25.4], child: Text('1.5" × 1"')),
              PopupMenuItem(value: [50.8, 50.8], child: Text('2" × 2"')),
              PopupMenuItem(value: [50.8, 25.4], child: Text('2" × 1"')),
              PopupMenuItem(value: [76.2, 50.8], child: Text('3" × 2"')),
              PopupMenuItem(value: [101.6, 152.4], child: Text('4" × 6"')),
            ],
            child: const Chip(avatar: Icon(Icons.straighten, size: 16), label: Text('Sizes')),
          ),
        ]),
      ],
      const SizedBox(height: 16),
      Center(child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: LabelPreview(
            template: t, data: _data, pxPerMm: ppm, selectedId: canEdit ? _elId : null,
            onSelect: canEdit ? (id) => setState(() { _elId = id; }) : null,
            onMove: canEdit
                ? (el, x, y) => _changed(() {
                      el.x = x;
                      el.y = y;
                      _syncCtrl('${el.id}.x', x);
                      _syncCtrl('${el.id}.y', y);
                    })
                : null,
            onResize: canEdit ? _resize : null,
            onResizeLabel: canEdit
                ? (w, h) => _changed(() {
                      double snap(double v) => (v * 2).round() / 2; // 0.5 mm
                      t.widthMm = snap(w).clamp(10.0, 110.0);
                      t.heightMm = snap(h).clamp(5.0, 200.0);
                      _syncCtrl('${t.id}.w', t.widthMm);
                      _syncCtrl('${t.id}.h', t.heightMm);
                    })
                : null,
          ),
        ),
      )),
      for (final w in labelWarnings(t, _data))
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.red),
            const SizedBox(width: 6),
            Expanded(child: Text(w, style: const TextStyle(fontSize: 12, color: Colors.red))),
          ]),
        ),
      if (canEdit) ...[
        const SizedBox(height: 6),
        const Center(child: Text('Click an item to edit it · drag to move · drag its corner square to resize · '
            'drag the label\'s grey corner to change the label size',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(icon: const Icon(Icons.title, size: 16), label: const Text('Text'), onPressed: () => _addElement('text')),
          OutlinedButton.icon(icon: const Icon(Icons.view_week_outlined, size: 16), label: const Text('Barcode'), onPressed: () => _addElement('barcode')),
          OutlinedButton.icon(icon: const Icon(Icons.qr_code_2, size: 16), label: const Text('QR code'), onPressed: () => _addElement('qr')),
          OutlinedButton.icon(icon: const Icon(Icons.horizontal_rule, size: 16), label: const Text('Line'), onPressed: () => _addElement('line')),
        ]),
        const SizedBox(height: 12),
        const Text('Items on this label', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in t.elements)
            ChoiceChip(
              label: Text(e.title, overflow: TextOverflow.ellipsis),
              selected: e.id == _elId,
              onSelected: (_) => setState(() => _elId = e.id),
            ),
        ]),
      ],
    ]));
  }

  // Corner-handle resize → the matching settings of each kind of item.
  void _resize(LabelElement e, double wMm, double hMm) {
    final k = e.id;
    _changed(() {
      switch (e.kind) {
        case 'line':
          e.width = ((wMm * 4).round() / 4).clamp(1.0, _t.widthMm);
          e.height = ((hMm * 8).round() / 8).clamp(0.125, 20.0);
          _syncCtrl('$k.w', e.width);
          _syncCtrl('$k.h', e.height);
          break;
        case 'barcode':
          // Height → bar height; width → bar thickness (1–4 dots).
          final digits = e.human ? 22 / kDotsPerMm : 0.0;
          e.height = ((hMm - digits) * 4).round() / 4;
          if (e.height < 2) e.height = 2;
          final code = labelClean(_data.value(e));
          if (code.isNotEmpty) {
            e.narrow = ((wMm * kDotsPerMm) / (11 * code.length + 35)).round().clamp(1, 4);
          }
          _syncCtrl('$k.h', e.height);
          break;
        case 'qr':
          final data = labelClean(_data.value(e));
          if (data.isNotEmpty) {
            final ecc = 'LMQH'.contains(e.ecc) && e.ecc.isNotEmpty ? e.ecc : 'M';
            final size = math.max(wMm, hMm) * kDotsPerMm;
            e.cell = (size / qrModules(data, ecc)).round().clamp(2, 10);
          }
          break;
        default:
          // Height → font size; width → letters per line.
          final lines = math.max(1, layoutLabel(_t, _data).where((p) => p.el.id == e.id).length);
          final perLine = ((hMm * kDotsPerMm) - (lines - 1) * e.lineGap * kDotsPerMm) / lines;
          const steps = [[1, 1], [2, 1], [3, 1], [4, 1], [5, 1], [4, 2], [5, 2], [5, 3]];
          var best = steps.first;
          for (final st in steps) {
            final h = kTsplFonts[st[0]]![1] * st[1];
            final bh = kTsplFonts[best[0]]![1] * best[1];
            if ((h - perLine).abs() < (bh - perLine).abs()) best = st;
          }
          e.font = best[0];
          e.scale = best[1];
          final cw = kTsplFonts[e.font]![0] * e.scale;
          e.maxChars = ((wMm * kDotsPerMm) / cw).floor().clamp(2, 200);
          _syncCtrl('$k.mc', e.maxChars.toDouble());
      }
    });
  }

  Widget _numField(String key, String label, double value, ValueChanged<double> onChanged,
      {double step = 0.25, double width = 120, double? min}) {
    final c = _ctrl(key, value);
    void bump(double d) {
      var v = ((double.tryParse(c.text) ?? value) + d);
      if (min != null && v < min) v = min;
      v = (v * 100).round() / 100;
      c.text = _fmt(v);
      onChanged(v);
    }
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label, isDense: true,
          suffixIcon: Column(mainAxisSize: MainAxisSize.min, children: [
            InkWell(onTap: () => bump(step), child: const Icon(Icons.arrow_drop_up, size: 18)),
            InkWell(onTap: () => bump(-step), child: const Icon(Icons.arrow_drop_down, size: 18)),
          ]),
          suffixIconConstraints: const BoxConstraints(minWidth: 24, maxHeight: 40),
        ),
        onChanged: (v) {
          final d = double.tryParse(v.trim());
          if (d != null) onChanged(d);
        },
      ),
    );
  }

  Widget _intDrop(String label, int value, List<int> options, ValueChanged<int> onChanged,
      {String Function(int)? text, double width = 120}) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<int>(
        value: options.contains(value) ? value : options.first,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [for (final o in options) DropdownMenuItem(value: o, child: Text(text?.call(o) ?? '$o'))],
        onChanged: (v) => onChanged(v ?? value),
      ),
    );
  }

  Widget _elementPanel(LabelElement e) {
    final t = _t;
    final k = e.id;
    final isText = e.kind == 'text';
    final sources = isText
        ? kLabelSources
        : {for (final s in ['code', 'codeText', 'name', 'batch', 'custom']) s: kLabelSources[s]!};
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(e.title, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
        IconButton(tooltip: 'Duplicate item', icon: const Icon(Icons.copy_outlined, size: 18), visualDensity: VisualDensity.compact,
            onPressed: () => _changed(() {
                  final c = e.copy()
                    ..id = '${e.kind}_${DateTime.now().millisecondsSinceEpoch}'
                    ..y = (e.y + 3).clamp(0.0, t.heightMm - 1);
                  t.elements.add(c);
                  _elId = c.id;
                })),
        IconButton(tooltip: 'Remove item', icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
            visualDensity: VisualDensity.compact,
            onPressed: () => _changed(() {
                  t.elements.removeWhere((x) => x.id == e.id);
                  _elId = null;
                })),
        IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 18), visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _elId = null)),
      ]),
      const SizedBox(height: 8),
      if (e.kind != 'line')
        DropdownButtonFormField<String>(
          value: sources.containsKey(e.source) ? e.source : sources.keys.first,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Shows', isDense: true),
          items: [for (final s in sources.entries) DropdownMenuItem(value: s.key, child: Text(s.value))],
          onChanged: (v) => _changed(() => e.source = v ?? e.source),
        ),
      if (e.source == 'custom' && e.kind != 'line') ...[
        const SizedBox(height: 8),
        TextField(
          controller: _ctrls.putIfAbsent('$k.text', () => TextEditingController(text: e.text)),
          decoration: InputDecoration(labelText: e.askAtPrint ? 'Default value' : 'Text', isDense: true),
          onChanged: (v) => _changed(() {
            e.text = v;
            final a = _ask[e.id];
            if (a != null && !e.askAtPrint) a.text = v;
          }),
        ),
        SwitchListTile(
          dense: true, contentPadding: EdgeInsets.zero,
          title: const Text('Type the value when printing', style: TextStyle(fontSize: 12.5)),
          value: e.askAtPrint,
          onChanged: (v) => _changed(() => e.askAtPrint = v),
        ),
      ],
      if (isText) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _ctrls.putIfAbsent('$k.prefix', () => TextEditingController(text: e.prefix)),
          decoration: InputDecoration(labelText: e.source == 'custom' && e.askAtPrint ? 'Field name (shown when printing)' : 'Text before (e.g. "Batch: ")', isDense: true),
          onChanged: (v) => _changed(() => e.prefix = v),
        ),
      ],
      const SizedBox(height: 10),
      if (e.kind != 'line')
        SwitchListTile(
          dense: true, contentPadding: EdgeInsets.zero,
          title: const Text('Centre across the label', style: TextStyle(fontSize: 12.5)),
          value: e.center,
          onChanged: (v) => _changed(() => e.center = v),
        ),
      Wrap(spacing: 10, runSpacing: 10, children: [
        if (!e.center) _numField('$k.x', 'Left (mm)', e.x, (v) => _changed(() => e.x = v), min: 0),
        _numField('$k.y', 'Top (mm)', e.y, (v) => _changed(() => e.y = v), min: 0),
        if (isText) ...[
          _intDrop('Font', e.font, const [1, 2, 3, 4, 5], (v) => _changed(() => e.font = v),
              text: (o) => const {1: '1 · tiny', 2: '2 · small', 3: '3 · medium', 4: '4 · large', 5: '5 · huge'}[o]!),
          _intDrop('Size ×', e.scale, const [1, 2, 3], (v) => _changed(() => e.scale = v), width: 90),
          _intDrop('Max lines', e.maxLines, const [1, 2, 3, 4, 5], (v) => _changed(() => e.maxLines = v), width: 100),
          _numField('$k.mc', 'Max letters/line', e.maxChars.toDouble(), (v) => _changed(() => e.maxChars = v.round().clamp(0, 200)),
              step: 1, width: 140, min: 0),
          if (e.maxLines > 1)
            _numField('$k.lg', 'Line spacing (mm)', e.lineGap, (v) => _changed(() => e.lineGap = v), min: 0, width: 140),
        ],
        if (e.kind == 'barcode') ...[
          _numField('$k.h', 'Bar height (mm)', e.height, (v) => _changed(() => e.height = v), step: 0.5, min: 1, width: 130),
          _intDrop('Bar width', e.narrow, const [0, 1, 2, 3, 4], (v) => _changed(() => e.narrow = v),
              text: (o) => o == 0 ? 'Auto' : '$o', width: 110),
          SizedBox(width: 160, child: CheckboxListTile(
            dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Digits below', style: TextStyle(fontSize: 12.5)),
            value: e.human, onChanged: (v) => _changed(() => e.human = v ?? true),
          )),
        ],
        if (e.kind == 'qr') ...[
          _intDrop('QR size', e.cell, const [0, 2, 3, 4, 5, 6, 7, 8, 10], (v) => _changed(() => e.cell = v),
              text: (o) => o == 0 ? 'Auto' : '$o', width: 110),
          SizedBox(
            width: 170,
            child: DropdownButtonFormField<String>(
              value: const ['', 'L', 'M', 'Q', 'H'].contains(e.ecc) ? e.ecc : '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Error correction', isDense: true),
              items: const [
                DropdownMenuItem(value: '', child: Text('Auto')),
                DropdownMenuItem(value: 'L', child: Text('L · smallest QR')),
                DropdownMenuItem(value: 'M', child: Text('M · standard')),
                DropdownMenuItem(value: 'Q', child: Text('Q · sturdier')),
                DropdownMenuItem(value: 'H', child: Text('H · sturdiest')),
              ],
              onChanged: (v) => _changed(() => e.ecc = v ?? ''),
            ),
          ),
        ],
        if (e.kind == 'line') ...[
          _numField('$k.w', 'Length (mm)', e.width, (v) => _changed(() => e.width = v), step: 1, min: 1),
          _numField('$k.h', 'Thickness (mm)', e.height, (v) => _changed(() => e.height = v), step: 0.125, min: 0.125),
        ],
      ]),
      const SizedBox(height: 6),
      const Text('Tip: 1 mm = 8 printer dots. Small steps (0.25 mm) help line things up exactly.',
          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    ]));
  }

  Widget _printPanel() {
    final t = _t;
    Widget field(TextEditingController c, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(controller: c, onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder())),
        );
    final used = {for (final e in t.elements) e.source};
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Print this label', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      LabelHelperBanner(reachable: _helper, printer: _s.printer, onRetry: _checkHelper),
      const SizedBox(height: 10),
      if (_products.isNotEmpty && (used.contains('name') || used.contains('code')))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Autocomplete<Map<String, dynamic>>(
            displayStringForOption: (p) => '${p['name'] ?? ''}',
            optionsBuilder: (v) {
              final q = v.text.trim().toLowerCase();
              if (q.isEmpty) return const Iterable.empty();
              return _products.where((p) => '${p['name']} ${p['sku'] ?? ''} ${p['barcode'] ?? ''}'.toLowerCase().contains(q)).take(20);
            },
            onSelected: (p) => setState(() {
              _name.text = '${p['name'] ?? ''}';
              final bc = '${p['barcode'] ?? ''}'.trim();
              _code.text = bc.isNotEmpty ? bc : '${p['sku'] ?? ''}';
            }),
            fieldViewBuilder: (ctx, c, f, onSubmit) => TextField(
              controller: c, focusNode: f,
              decoration: const InputDecoration(labelText: 'Fill from a product (optional)', isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
            ),
          ),
        ),
      if (used.contains('name')) field(_name, 'Name'),
      if (used.contains('code')) field(_code, 'Code (barcode / QR data)'),
      if (used.contains('codeText')) field(_codeText, 'Code text (if different)'),
      if (used.contains('batch')) field(_batch, 'Batch'),
      if (used.contains('date')) field(_date, 'Date'),
      if (used.contains('qty')) field(_qty, 'Quantity (e.g. 12 pcs)'),
      for (final e in t.askFields) field(_askCtrl(e), e.prefix.trim().isEmpty ? 'Text' : e.prefix.trim()),
      Row(children: [
        SizedBox(width: 120, child: TextField(controller: _copies, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Labels', isDense: true, border: OutlineInputBorder()))),
        const Spacer(),
        TextButton(onPressed: _helper == null ? null : () => _print(test: true), child: const Text('Test 1')),
        const SizedBox(width: 6),
        FilledButton.icon(
          icon: const Icon(Icons.print_outlined, size: 18),
          label: const Text('Print'),
          onPressed: _helper == null ? null : () => _print(),
        ),
      ]),
      if (_dirty.contains(t.id))
        const Padding(padding: EdgeInsets.only(top: 8),
            child: Text('Prints with the layout as shown, even before it is saved.',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
    ]));
  }
}
