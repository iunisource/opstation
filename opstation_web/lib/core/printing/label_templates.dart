// ignore_for_file: deprecated_member_use
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Configurable label layouts for TSPL label printers (TSC TE200, 203 dpi =
/// 8 dots per mm). Every position and size is in millimetres so a layout is
/// easy to reason about; it is turned into printer commands at print time.
///
/// Layouts are shared by the whole organisation (table label_templates, SQL
/// 369). Four built-ins always exist and can be adjusted (or reset); any number
/// of custom layouts can be added for manual labels.

const double kDotsPerMm = 8;

/// Built-in fonts of the printer: width × height in dots at scale 1.
const Map<int, List<int>> kTsplFonts = {
  1: [8, 12],
  2: [12, 20],
  3: [16, 24],
  4: [24, 32],
  5: [32, 48],
};

/// What fills an element. "custom" = fixed text, or a value typed at print time.
const Map<String, String> kLabelSources = {
  'name': 'Name',
  'code': 'Code (barcode / QR data)',
  'codeText': 'Code text',
  'batch': 'Batch',
  'date': 'Date',
  'qty': 'Quantity',
  'custom': 'Custom text',
};

class LabelData {
  final String name;
  final String? code; // barcode / QR content (product barcode or SKU, asset URL…)
  final String? codeText; // readable code (e.g. asset code); defaults to code
  final String? batch;
  final String? date;
  final String? qty; // e.g. "12 pcs"
  final Map<String, String> custom; // element id → value typed at print time
  const LabelData({required this.name, this.code, this.codeText, this.batch, this.date, this.qty,
      this.custom = const {}});

  LabelData copyWith({String? name, String? code, String? codeText, String? batch, String? date, String? qty,
          Map<String, String>? custom}) =>
      LabelData(name: name ?? this.name, code: code ?? this.code, codeText: codeText ?? this.codeText,
          batch: batch ?? this.batch, date: date ?? this.date, qty: qty ?? this.qty, custom: custom ?? this.custom);

  String value(LabelElement e) {
    switch (e.source) {
      case 'name': return name;
      case 'code': return code ?? '';
      case 'codeText': return (codeText ?? '').isNotEmpty ? codeText! : (code ?? '');
      case 'batch': return batch ?? '';
      case 'date': return date ?? '';
      case 'qty': return qty ?? '';
      default: return custom[e.id] ?? e.text;
    }
  }
}

class LabelElement {
  String id;
  String kind; // text | barcode | qr | line
  String source;
  String prefix; // text only, e.g. "Batch: "
  String text; // custom: fixed text / default value
  bool askAtPrint; // custom: type the value when printing
  double x, y; // mm from the top-left corner
  bool center; // centre horizontally (x ignored)
  int font; // 1–5
  int scale; // 1–3
  int maxChars; // 0 = fit the width
  int maxLines;
  double lineGap; // mm
  double height; // barcode bar height / line thickness (mm)
  double width; // line length (mm)
  int narrow; // barcode module width in dots, 0 = auto
  bool human; // barcode: print the digits under it
  int cell; // QR module size in dots, 0 = auto

  LabelElement({
    required this.id,
    required this.kind,
    this.source = 'name',
    this.prefix = '',
    this.text = '',
    this.askAtPrint = false,
    this.x = 1,
    this.y = 1,
    this.center = false,
    this.font = 2,
    this.scale = 1,
    this.maxChars = 0,
    this.maxLines = 1,
    this.lineGap = 0.3,
    this.height = 8,
    this.width = 20,
    this.narrow = 0,
    this.human = true,
    this.cell = 0,
  });

  factory LabelElement.fromJson(Map<String, dynamic> m) => LabelElement(
        id: '${m['id'] ?? 'e${DateTime.now().microsecondsSinceEpoch}'}',
        kind: '${m['kind'] ?? 'text'}',
        source: '${m['source'] ?? 'name'}',
        prefix: '${m['prefix'] ?? ''}',
        text: '${m['text'] ?? ''}',
        askAtPrint: m['ask'] == true,
        x: (m['x'] as num?)?.toDouble() ?? 1,
        y: (m['y'] as num?)?.toDouble() ?? 1,
        center: m['center'] == true,
        font: (m['font'] as num?)?.toInt() ?? 2,
        scale: (m['scale'] as num?)?.toInt() ?? 1,
        maxChars: (m['maxChars'] as num?)?.toInt() ?? 0,
        maxLines: (m['maxLines'] as num?)?.toInt() ?? 1,
        lineGap: (m['lineGap'] as num?)?.toDouble() ?? 0.3,
        height: (m['height'] as num?)?.toDouble() ?? 8,
        width: (m['width'] as num?)?.toDouble() ?? 20,
        narrow: (m['narrow'] as num?)?.toInt() ?? 0,
        human: m['human'] != false,
        cell: (m['cell'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'kind': kind, 'source': source, 'prefix': prefix, 'text': text, 'ask': askAtPrint,
        'x': x, 'y': y, 'center': center, 'font': font, 'scale': scale, 'maxChars': maxChars,
        'maxLines': maxLines, 'lineGap': lineGap, 'height': height, 'width': width, 'narrow': narrow,
        'human': human, 'cell': cell,
      };

  LabelElement copy() => LabelElement.fromJson(toJson());

  String get title {
    switch (kind) {
      case 'barcode': return 'Barcode';
      case 'qr': return 'QR code';
      case 'line': return 'Line';
      default:
        return source == 'custom'
            ? (askAtPrint ? 'Text (typed at print)' : 'Text: ${text.isEmpty ? '…' : text}')
            : 'Text: ${kLabelSources[source] ?? source}';
    }
  }
}

class LabelTemplate {
  String id;
  String name;
  double widthMm, heightMm, gapMm;
  List<LabelElement> elements;
  bool builtIn;
  bool saved; // a stored row exists (built-ins: customised)

  LabelTemplate({required this.id, required this.name, required this.widthMm, required this.heightMm,
      this.gapMm = 3, required this.elements, this.builtIn = false, this.saved = false});

  factory LabelTemplate.fromJson(String id, String name, Map<String, dynamic> m, {bool builtIn = false}) =>
      LabelTemplate(
        id: id,
        name: name,
        widthMm: (m['w'] as num?)?.toDouble() ?? 38.1,
        heightMm: (m['h'] as num?)?.toDouble() ?? 25.4,
        gapMm: (m['gap'] as num?)?.toDouble() ?? 3,
        elements: [
          for (final e in (m['elements'] as List? ?? const []))
            LabelElement.fromJson(Map<String, dynamic>.from(e as Map))
        ],
        builtIn: builtIn,
        saved: true,
      );

  Map<String, dynamic> toJson() =>
      {'w': widthMm, 'h': heightMm, 'gap': gapMm, 'elements': [for (final e in elements) e.toJson()]};

  LabelTemplate copy({String? id, String? name}) => LabelTemplate(
      id: id ?? this.id, name: name ?? this.name, widthMm: widthMm, heightMm: heightMm, gapMm: gapMm,
      elements: [for (final e in elements) e.copy()], builtIn: id == null ? builtIn : false, saved: id == null ? saved : false);

  bool get hasCode => elements.any((e) => e.kind == 'barcode' || e.kind == 'qr');
  List<LabelElement> get askFields =>
      [for (final e in elements) if (e.kind == 'text' && e.source == 'custom' && e.askAtPrint) e];
}

// ── Built-in layouts ─────────────────────────────────────────────────────────
const kBuiltInIds = ['small_barcode', 'small_qr', 'large_barcode', 'large_qr'];

LabelTemplate builtInTemplate(String id) {
  switch (id) {
    case 'small_qr':
      return LabelTemplate(id: id, name: '1.5" × 1" · QR', widthMm: 38.1, heightMm: 25.4, builtIn: true, elements: [
        LabelElement(id: 'qr', kind: 'qr', source: 'code', x: 1, y: 4.5, cell: 0),
        LabelElement(id: 'name', kind: 'text', source: 'name', x: 16, y: 1, font: 2, maxChars: 14, maxLines: 3, lineGap: 0.3),
        LabelElement(id: 'ctext', kind: 'text', source: 'codeText', x: 16, y: 11.5, font: 1, maxChars: 20),
        LabelElement(id: 'batch', kind: 'text', source: 'batch', prefix: 'B: ', x: 16, y: 14.5, font: 1, maxChars: 20),
        LabelElement(id: 'date', kind: 'text', source: 'date', x: 16, y: 17.5, font: 1, maxChars: 20),
      ]);
    case 'large_barcode':
      return LabelTemplate(id: id, name: '2" × 2" · Barcode', widthMm: 50.8, heightMm: 50.8, builtIn: true, elements: [
        LabelElement(id: 'name', kind: 'text', source: 'name', x: 1.5, y: 1.5, font: 3, maxChars: 23, maxLines: 2, lineGap: 0.75),
        LabelElement(id: 'qty', kind: 'text', source: 'qty', prefix: 'Qty: ', x: 1.5, y: 9.5, font: 3, maxChars: 23),
        LabelElement(id: 'bc', kind: 'barcode', source: 'code', center: true, y: 15, height: 13.5),
        LabelElement(id: 'batch', kind: 'text', source: 'batch', prefix: 'Batch: ', x: 1.5, y: 39.5, font: 3, maxChars: 23),
        LabelElement(id: 'date', kind: 'text', source: 'date', x: 1.5, y: 44, font: 2, maxChars: 31),
      ]);
    case 'large_qr':
      return LabelTemplate(id: id, name: '2" × 2" · QR', widthMm: 50.8, heightMm: 50.8, builtIn: true, elements: [
        LabelElement(id: 'name', kind: 'text', source: 'name', x: 1.5, y: 1.5, font: 3, maxChars: 23, maxLines: 2, lineGap: 0.75),
        LabelElement(id: 'qty', kind: 'text', source: 'qty', prefix: 'Qty: ', x: 1.5, y: 9.5, font: 3, maxChars: 23),
        LabelElement(id: 'qr', kind: 'qr', source: 'code', center: true, y: 13.5, cell: 0),
        LabelElement(id: 'ctext', kind: 'text', source: 'codeText', center: true, y: 36.5, font: 2, maxChars: 31),
        LabelElement(id: 'batch', kind: 'text', source: 'batch', prefix: 'Batch: ', x: 1.5, y: 40, font: 3, maxChars: 23),
        LabelElement(id: 'date', kind: 'text', source: 'date', x: 1.5, y: 44.5, font: 2, maxChars: 31),
      ]);
    case 'small_barcode':
    default:
      return LabelTemplate(id: 'small_barcode', name: '1.5" × 1" · Barcode', widthMm: 38.1, heightMm: 25.4, builtIn: true, elements: [
        LabelElement(id: 'name', kind: 'text', source: 'name', x: 1, y: 0.75, font: 2, maxChars: 24, maxLines: 2, lineGap: 0.25),
        LabelElement(id: 'bc', kind: 'barcode', source: 'code', center: true, y: 6.75, height: 7.25),
        LabelElement(id: 'batch', kind: 'text', source: 'batch', prefix: 'B:', x: 1, y: 22.25, font: 1, maxChars: 20),
        LabelElement(id: 'date', kind: 'text', source: 'date', x: 24, y: 22.25, font: 1, maxChars: 12),
      ]);
  }
}

// ── Store (shared by the organisation) ───────────────────────────────────────
class LabelTemplateStore {
  /// Built-ins (customised where saved) first, then custom layouts by name.
  static Future<List<LabelTemplate>> load(String orgId) async {
    final byId = <String, LabelTemplate>{for (final id in kBuiltInIds) id: builtInTemplate(id)};
    final custom = <LabelTemplate>[];
    try {
      final rows = await Supabase.instance.client
          .from('label_templates').select('id, name, def').eq('org_id', orgId).order('name');
      for (final r in rows as List) {
        final id = '${r['id']}';
        final def = Map<String, dynamic>.from((r['def'] as Map?) ?? const {});
        if (kBuiltInIds.contains(id)) {
          byId[id] = LabelTemplate.fromJson(id, byId[id]!.name, def, builtIn: true);
        } else {
          custom.add(LabelTemplate.fromJson(id, '${r['name'] ?? 'Label'}', def));
        }
      }
    } catch (_) {/* not set up yet — built-ins only */}
    return [for (final id in kBuiltInIds) byId[id]!, ...custom];
  }

  static Future<void> save(String orgId, LabelTemplate t) async {
    await Supabase.instance.client.from('label_templates').upsert({
      'org_id': orgId, 'id': t.id, 'name': t.name, 'def': t.toJson(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'org_id,id');
    t.saved = true;
  }

  static Future<void> delete(String orgId, String id) async {
    await Supabase.instance.client.from('label_templates').delete().eq('org_id', orgId).eq('id', id);
  }
}

// ── Layout maths shared by printing and the on-screen preview ────────────────
String labelClean(String s) => s
    .replaceAll('—', '-').replaceAll('–', '-').replaceAll('·', '-')
    .replaceAll('"', "'")
    .replaceAll(RegExp(r'[^\x20-\x7E]'), '')
    .trim();

List<String> labelWrap(String text, int maxChars, int maxLines) {
  if (maxChars < 2) maxChars = 2;
  final words = labelClean(text).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
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
  if (maxLines < 1) maxLines = 1;
  if (lines.length > maxLines) {
    final kept = lines.take(maxLines).toList();
    final last = kept.last;
    kept[maxLines - 1] = last.length >= maxChars ? '${last.substring(0, maxChars - 2)}..' : '$last..';
    return kept;
  }
  return lines;
}

int _barcodeDots(String code, int narrow) => (11 * code.length + 35) * narrow;

int qrModules(String data) {
  final n = data.length;
  if (n <= 14) return 21;
  if (n <= 26) return 25;
  if (n <= 42) return 29;
  if (n <= 62) return 33;
  if (n <= 84) return 37;
  return 41;
}

/// Resolved, in dots — one entry per thing actually drawn.
class PlacedItem {
  final LabelElement el;
  final String kind; // text | barcode | qr | line
  final int x, y, w, h; // dots
  final String value;
  final int font, scale; // text
  final int narrow, cell; // barcode / qr
  PlacedItem(this.el, this.kind, this.x, this.y, this.w, this.h, this.value,
      {this.font = 2, this.scale = 1, this.narrow = 1, this.cell = 4});
}

List<PlacedItem> layoutLabel(LabelTemplate t, LabelData d) {
  final wDots = (t.widthMm * kDotsPerMm).round();
  final out = <PlacedItem>[];
  for (final e in t.elements) {
    final x0 = (e.x * kDotsPerMm).round();
    final y0 = (e.y * kDotsPerMm).round();
    switch (e.kind) {
      case 'line':
        final lw = (e.width * kDotsPerMm).round().clamp(1, wDots);
        final lh = (e.height * kDotsPerMm).round().clamp(1, 400);
        out.add(PlacedItem(e, 'line', e.center ? ((wDots - lw) / 2).round() : x0, y0, lw, lh, ''));
        break;
      case 'barcode':
        final code = labelClean(d.value(e));
        if (code.isEmpty) break;
        var narrow = e.narrow;
        if (narrow <= 0) {
          narrow = 1;
          for (final n in [3, 2]) {
            if (_barcodeDots(code, n) <= wDots - 16) { narrow = n; break; }
          }
        }
        final bw = _barcodeDots(code, narrow);
        final bh = (e.height * kDotsPerMm).round().clamp(8, 1000);
        out.add(PlacedItem(e, 'barcode', e.center ? math.max(0, ((wDots - bw) / 2).round()) : x0, y0, bw,
            bh + (e.human ? 22 : 0), code, narrow: narrow));
        break;
      case 'qr':
        final data = labelClean(d.value(e));
        if (data.isEmpty) break;
        final mods = qrModules(data);
        var cell = e.cell;
        if (cell <= 0) {
          final room = math.min(wDots, (t.heightMm * kDotsPerMm).round()) * (t.widthMm > 45 ? 0.45 : 0.5);
          cell = (room / mods).floor().clamp(2, 10);
        }
        final qw = mods * cell;
        out.add(PlacedItem(e, 'qr', e.center ? math.max(0, ((wDots - qw) / 2).round()) : x0, y0, qw, qw, data,
            cell: cell));
        break;
      default:
        final raw = d.value(e);
        if (raw.trim().isEmpty) break;
        final f = kTsplFonts[e.font] ?? kTsplFonts[2]!;
        final sc = e.scale.clamp(1, 4);
        final cw = f[0] * sc, ch = f[1] * sc;
        final avail = e.center ? wDots - 8 : wDots - x0 - 4;
        final fit = math.max(2, (avail / cw).floor());
        final maxChars = e.maxChars > 0 ? math.min(e.maxChars, fit) : fit;
        final lines = labelWrap('${e.prefix}$raw', maxChars, e.maxLines);
        var y = y0;
        for (final l in lines) {
          final lw = l.length * cw;
          out.add(PlacedItem(e, 'text', e.center ? math.max(0, ((wDots - lw) / 2).round()) : x0, y, lw, ch, l,
              font: e.font, scale: sc));
          y += ch + (e.lineGap * kDotsPerMm).round();
        }
    }
  }
  return out;
}

/// TSPL commands for [copies] of one label.
String buildTspl(LabelTemplate t, LabelData d, int copies,
    {int density = 8, int speed = 4, int offsetX = 0, int offsetY = 0}) {
  String mm(double v) => v.toStringAsFixed(1);
  final out = <String>[
    'SIZE ${mm(t.widthMm)} mm,${mm(t.heightMm)} mm',
    'GAP ${mm(t.gapMm)} mm,0 mm',
    'DIRECTION 1,0',
    'REFERENCE $offsetX,$offsetY',
    'SET TEAR ON',
    'DENSITY ${density.clamp(0, 15)}',
    'SPEED ${speed.clamp(2, 6)}',
    'CLS',
  ];
  for (final p in layoutLabel(t, d)) {
    switch (p.kind) {
      case 'line':
        out.add('BAR ${p.x},${p.y},${p.w},${p.h}');
        break;
      case 'barcode':
        out.add('BARCODE ${p.x},${p.y},"128",${p.h - (p.el.human ? 22 : 0)},${p.el.human ? 1 : 0},0,${p.narrow},${p.narrow},"${p.value}"');
        break;
      case 'qr':
        out.add('QRCODE ${p.x},${p.y},M,${p.cell},A,0,"${p.value}"');
        break;
      default:
        out.add('TEXT ${p.x},${p.y},"${p.font}",0,${p.scale},${p.scale},"${p.value}"');
    }
  }
  out.add('PRINT 1,${copies.clamp(1, 9999)}');
  return '${out.join('\r\n')}\r\n';
}

// ── On-screen preview (same layout maths as the printer) ─────────────────────
class LabelPreview extends StatelessWidget {
  final LabelTemplate template;
  final LabelData data;
  final double pxPerMm;
  final String? selectedId;
  final ValueChanged<String>? onSelect;
  /// Drag to move: called with the element and the new x / y in mm.
  final void Function(LabelElement el, double xMm, double yMm)? onMove;

  const LabelPreview({super.key, required this.template, required this.data, this.pxPerMm = 6,
      this.selectedId, this.onSelect, this.onMove});

  @override
  Widget build(BuildContext context) {
    final s = pxPerMm / kDotsPerMm; // px per dot
    final w = template.widthMm * pxPerMm;
    final h = template.heightMm * pxPerMm;
    final items = layoutLabel(template, data);
    final children = <Widget>[];
    // One hit box per element (covering all its lines), drawn on top.
    final boxes = <String, Rect>{};
    for (final p in items) {
      final r = Rect.fromLTWH(p.x * s, p.y * s, math.max(4.0, p.w * s), math.max(4.0, p.h * s));
      boxes[p.el.id] = boxes[p.el.id] == null ? r : boxes[p.el.id]!.expandToInclude(r);
      Widget child;
      switch (p.kind) {
        case 'line':
          child = Container(color: Colors.black);
          break;
        case 'barcode':
          child = Column(children: [
            Expanded(child: CustomPaint(painter: _BarsPainter(p.value), size: Size.infinite)),
            if (p.el.human)
              SizedBox(height: 22 * s, child: FittedBox(child: Text(p.value, style: const TextStyle(fontFamily: 'monospace')))),
          ]);
          break;
        case 'qr':
          child = CustomPaint(painter: _QrPainter(p.value), size: Size.infinite);
          break;
        default:
          child = FittedBox(
            fit: BoxFit.fill,
            child: Text(p.value, maxLines: 1, softWrap: false,
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600, color: Colors.black, height: 1)),
          );
      }
      children.add(Positioned(left: p.x * s, top: p.y * s, width: math.max(1.0, p.w * s), height: math.max(1.0, p.h * s), child: child));
    }
    boxes.forEach((id, r) {
      final sel = id == selectedId;
      LabelElement? el;
      for (final e in template.elements) {
        if (e.id == id) el = e;
      }
      children.add(Positioned(
        left: r.left - 2, top: r.top - 2, width: r.width + 4, height: r.height + 4,
        child: MouseRegion(
          cursor: onMove != null ? SystemMouseCursors.move : MouseCursor.defer,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onSelect == null ? null : () => onSelect!(id),
            onPanStart: onMove == null ? null : (_) => onSelect?.call(id),
            onPanUpdate: onMove == null || el == null
                ? null
                : (u) {
                    final e = el!;
                    double snap(double v) => (v * 4).round() / 4; // 0.25 mm
                    final nx = e.center ? e.x : snap((e.x + u.delta.dx / pxPerMm).clamp(0.0, template.widthMm - 1));
                    final ny = snap((e.y + u.delta.dy / pxPerMm).clamp(0.0, template.heightMm - 1));
                    onMove!(e, nx, ny);
                  },
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                    color: sel ? Colors.blue : (onSelect != null ? Colors.blue.withOpacity(0.15) : Colors.transparent),
                    width: sel ? 1.5 : 1),
              ),
            ),
          ),
        ),
      ));
    });
    return Container(
      width: w, height: h,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade400),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)],
      ),
      child: ClipRect(child: Stack(clipBehavior: Clip.hardEdge, children: children)),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final String v;
  _BarsPainter(this.v);
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()..color = Colors.black;
    final n = (11 * v.length + 35);
    final unit = s.width / n;
    var x = 0.0;
    var i = 0;
    final seed = v.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff);
    while (x < s.width) {
      final w = unit * (1 + ((seed >> (i % 24)) & 3));
      if (i.isEven) c.drawRect(Rect.fromLTWH(x, 0, w, s.height), p);
      x += w;
      i++;
    }
  }

  @override
  bool shouldRepaint(_BarsPainter o) => o.v != v;
}

class _QrPainter extends CustomPainter {
  final String v;
  _QrPainter(this.v);
  @override
  void paint(Canvas c, Size s) {
    final mods = qrModules(v);
    final u = s.width / mods;
    final p = Paint()..color = Colors.black;
    var seed = v.codeUnits.fold<int>(11, (a, b) => (a * 33 + b) & 0x7fffffff);
    void finder(int cx, int cy) {
      c.drawRect(Rect.fromLTWH(cx * u, cy * u, 7 * u, 7 * u), p);
      c.drawRect(Rect.fromLTWH((cx + 1) * u, (cy + 1) * u, 5 * u, 5 * u), Paint()..color = Colors.white);
      c.drawRect(Rect.fromLTWH((cx + 2) * u, (cy + 2) * u, 3 * u, 3 * u), p);
    }
    for (var y = 0; y < mods; y++) {
      for (var x = 0; x < mods; x++) {
        final inFinder = (x < 8 && y < 8) || (x >= mods - 8 && y < 8) || (x < 8 && y >= mods - 8);
        if (inFinder) continue;
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        if ((seed >> 16) & 1 == 1) c.drawRect(Rect.fromLTWH(x * u, y * u, u, u), p);
      }
    }
    finder(0, 0);
    finder(mods - 7, 0);
    finder(0, mods - 7);
  }

  @override
  bool shouldRepaint(_QrPainter o) => o.v != v;
}
