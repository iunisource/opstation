// ignore_for_file: deprecated_member_use
import 'dart:math' as math;

import 'package:barcode/barcode.dart' as bc;
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
  String ecc; // QR error correction: '' = auto, L, M, Q, H

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
    this.ecc = '',
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
        ecc: '${m['ecc'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'kind': kind, 'source': source, 'prefix': prefix, 'text': text, 'ask': askAtPrint,
        'x': x, 'y': y, 'center': center, 'font': font, 'scale': scale, 'maxChars': maxChars,
        'maxLines': maxLines, 'lineGap': lineGap, 'height': height, 'width': width, 'narrow': narrow,
        'human': human, 'cell': cell, 'ecc': ecc,
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
        LabelElement(id: 'qr', kind: 'qr', source: 'code', x: 1, y: 1.5, cell: 0),
        LabelElement(id: 'name', kind: 'text', source: 'name', x: 19, y: 1, font: 2, maxChars: 13, maxLines: 3, lineGap: 0.3),
        LabelElement(id: 'ctext', kind: 'text', source: 'codeText', x: 19, y: 11.5, font: 1, maxChars: 18),
        LabelElement(id: 'batch', kind: 'text', source: 'batch', prefix: 'B: ', x: 19, y: 14.5, font: 1, maxChars: 18),
        LabelElement(id: 'date', kind: 'text', source: 'date', x: 19, y: 17.5, font: 1, maxChars: 18),
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

/// A real 1-D barcode as module runs: EAN-13 for 12/13-digit product codes
/// (what Opstation generates — reads best on phones and scanners), Code 128
/// for anything else. [runs] = (first module, width in modules) of each black
/// bar; [modules] = total width. Drawn the same way on screen and on the
/// printer, so the preview scans exactly like the label.
class BarRuns {
  final String symbology; // EAN13 | CODE128
  final int modules;
  final List<(int, int)> runs;
  const BarRuns(this.symbology, this.modules, this.runs);
}

final Map<String, BarRuns> _barCache = {};

BarRuns barRuns(String code) {
  final hit = _barCache[code];
  if (hit != null) return hit;
  if (_barCache.length > 300) _barCache.clear();
  BarRuns out = const BarRuns('CODE128', 0, []);
  final tries = <(String, bc.Barcode)>[
    if (RegExp(r'^\d{12,13}$').hasMatch(code)) ('EAN13', bc.Barcode.ean13()),
    ('CODE128', bc.Barcode.code128()),
  ];
  for (final (name, b) in tries) {
    try {
      const size = 2000.0;
      final bars = b.make(code, width: size, height: 10, drawText: false).whereType<bc.BarcodeBar>().toList();
      if (bars.isEmpty) continue;
      var unit = size;
      for (final x in bars) {
        if (x.width > 0.0001 && x.width < unit) unit = x.width;
      }
      final modules = (size / unit).round();
      final runs = <(int, int)>[];
      for (final x in bars) {
        if (!x.black) continue;
        runs.add(((x.left / unit).round(), math.max(1, (x.width / unit).round())));
      }
      out = BarRuns(name, modules, runs);
      break;
    } catch (_) {
      // e.g. a 13-digit code whose check digit isn't EAN — try Code 128.
    }
  }
  _barCache[code] = out;
  return out;
}

/// Barcode width in dots at [narrow] dots per module.
int _barcodeDots(String code, int narrow) => barRuns(code).modules * narrow;

/// Smallest bar width that prints and scans reliably at 203 dpi.
const int kMinBarModule = 2;

/// Byte-mode capacity per QR version 1–14 for each error-correction level.
const Map<String, List<int>> _qrCap = {
  'L': [17, 32, 53, 78, 106, 134, 154, 192, 230, 271, 321, 367, 425, 458],
  'M': [14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362],
  'Q': [11, 20, 32, 46, 60, 74, 86, 108, 130, 151, 177, 203, 241, 258],
  'H': [7, 14, 24, 34, 44, 58, 64, 84, 98, 119, 137, 155, 177, 194],
};

/// The real QR code for [data] as a square grid of dark (true) modules.
/// Labels draw QR codes from this grid themselves (on screen AND on the
/// printer, as solid bars), so what you see is exactly what prints and it
/// does not depend on the printer's own QR support.
final Map<String, List<List<bool>>> _qrCache = {};

List<List<bool>> qrMatrix(String data, [String ecc = 'M']) {
  final key = '$ecc|$data';
  final hit = _qrCache[key];
  if (hit != null) return hit;
  if (_qrCache.length > 300) _qrCache.clear();
  List<List<bool>> grid = const [];
  try {
    final level = const {
          'L': bc.BarcodeQRCorrectionLevel.low,
          'M': bc.BarcodeQRCorrectionLevel.medium,
          'Q': bc.BarcodeQRCorrectionLevel.quartile,
          'H': bc.BarcodeQRCorrectionLevel.high,
        }[ecc] ??
        bc.BarcodeQRCorrectionLevel.medium;
    const size = 1000.0;
    final bars = bc.Barcode.qrCode(errorCorrectLevel: level)
        .make(data, width: size, height: size, drawText: false)
        .whereType<bc.BarcodeBar>()
        .toList();
    if (bars.isNotEmpty) {
      var unit = size;
      for (final b in bars) {
        if (b.width > 0 && b.width < unit) unit = b.width;
        if (b.height > 0 && b.height < unit) unit = b.height;
      }
      final n = (size / unit).round();
      if (n >= 21 && n <= 177) {
        grid = List.generate(n, (_) => List<bool>.filled(n, false));
        for (final b in bars) {
          if (!b.black) continue;
          final x0 = (b.left / unit).round(), y0 = (b.top / unit).round();
          final w = math.max(1, (b.width / unit).round()), h = math.max(1, (b.height / unit).round());
          for (var y = y0; y < y0 + h && y < n; y++) {
            for (var x = x0; x < x0 + w && x < n; x++) {
              grid[y][x] = true;
            }
          }
        }
      }
    }
  } catch (_) {
    grid = const [];
  }
  _qrCache[key] = grid;
  return grid;
}

/// Modules per side of the QR drawn for [data].
int qrModules(String data, [String ecc = 'M']) {
  final m = qrMatrix(data, ecc);
  if (m.isNotEmpty) return m.length;
  final caps = _qrCap[ecc] ?? _qrCap['M']!;
  final n = data.length;
  for (var v = 0; v < caps.length; v++) {
    if (n <= caps[v]) return 17 + 4 * (v + 1);
  }
  return 17 + 4 * 15;
}

/// A QR module smaller than 3 printer dots (0.375 mm) often won't scan.
const int kMinQrCell = 3;

/// Resolved, in dots — one entry per thing actually drawn.
class PlacedItem {
  final LabelElement el;
  final String kind; // text | barcode | qr | line
  final int x, y, w, h; // dots
  final String value;
  final int font, scale; // text
  final int narrow, cell; // barcode / qr
  final String ecc; // qr
  PlacedItem(this.el, this.kind, this.x, this.y, this.w, this.h, this.value,
      {this.font = 2, this.scale = 1, this.narrow = 1, this.cell = 4, this.ecc = 'M'});
  bool get qrTooSmall => kind == 'qr' && cell < kMinQrCell;
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
          // Widest bars that fit with a quiet zone of 10 modules each side.
          narrow = 1;
          final mods = barRuns(code).modules;
          for (final n in [3, 2]) {
            if ((mods + 20) * n <= wDots) { narrow = n; break; }
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
        // Room for the square: from its top to the bottom edge, and the width
        // it may use (half the label beside text, or the full label centred).
        final hDots = (t.heightMm * kDotsPerMm).round();
        final roomH = hDots - y0 - 4;
        final roomW = e.center ? wDots - 8 : (t.widthMm > 45 ? wDots - x0 - 8 : ((wDots * 0.5) - x0).round());
        final room = math.max(20, math.min(roomH, roomW));
        var ecc = 'MLQH'.contains(e.ecc) && e.ecc.isNotEmpty ? e.ecc : '';
        var cell = e.cell;
        if (ecc.isEmpty) {
          // Auto: prefer M; fall back to L (smaller symbol, bigger dots) when M
          // would make the dots too small to scan.
          ecc = 'M';
          final mCell = (room / qrModules(data, 'M')).floor();
          final lCell = (room / qrModules(data, 'L')).floor();
          final mFits = cell > 0 ? qrModules(data, 'M') * cell <= room : mCell >= kMinQrCell + 1;
          if (!mFits && (cell > 0 || lCell > mCell)) ecc = 'L';
        }
        final mods = qrModules(data, ecc);
        if (cell <= 0) cell = (room / mods).floor().clamp(2, 10);
        final qw = mods * cell;
        out.add(PlacedItem(e, 'qr', e.center ? math.max(0, ((wDots - qw) / 2).round()) : x0, y0, qw, qw, data,
            cell: cell, ecc: ecc));
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

/// Problems that would make a printed label hard to scan.
List<String> labelWarnings(LabelTemplate t, LabelData d) => [
      for (final p in layoutLabel(t, d))
        if (p.kind == 'barcode' && p.narrow < kMinBarModule)
          'The barcode is too long for this label width and its bars are very thin — it may not scan. '
              'Use a wider label or a QR template.',
      for (final p in layoutLabel(t, d))
        if (p.qrTooSmall)
          'The QR code is too dense for its space (dots of ${p.cell}) and may not scan. '
              'Give it more room (move it up/left or use a bigger label), set "QR size" to 3 or more, '
              'or set error correction to L.',
    ];

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
        // Draw the bars ourselves (EAN-13 / Code 128), exactly as previewed.
        final br = barRuns(p.value);
        final bh = p.h - (p.el.human ? 22 : 0);
        if (br.runs.isEmpty) {
          out.add('BARCODE ${p.x},${p.y},"128",$bh,${p.el.human ? 1 : 0},0,${p.narrow},${p.narrow},"${p.value}"');
          break;
        }
        for (final (start, w) in br.runs) {
          out.add('BAR ${p.x + start * p.narrow},${p.y},${w * p.narrow},$bh');
        }
        if (p.el.human) {
          // Font 2 is 12 dots per character — centred under the bars.
          final tx = p.x + ((p.w - 12 * p.value.length) / 2).round();
          out.add('TEXT ${math.max(0, tx)},${p.y + bh + 2},"2",0,1,1,"${p.value}"');
        }
        break;
      case 'qr':
        final m = qrMatrix(p.value, p.ecc);
        if (m.isEmpty) {
          out.add('QRCODE ${p.x},${p.y},${p.ecc},${p.cell},A,0,"${p.value}"');
          break;
        }
        // Draw the QR ourselves: one solid bar per run of dark modules.
        for (var r = 0; r < m.length; r++) {
          final row = m[r];
          var c = 0;
          while (c < row.length) {
            if (!row[c]) { c++; continue; }
            final start = c;
            while (c < row.length && row[c]) { c++; }
            out.add('BAR ${p.x + start * p.cell},${p.y + r * p.cell},${(c - start) * p.cell},${p.cell}');
          }
        }
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
  /// Drag the corner handle of the selected item: its new box size in mm.
  final void Function(LabelElement el, double wMm, double hMm)? onResize;
  /// Drag the label's own corner: new label size in mm.
  final void Function(double wMm, double hMm)? onResizeLabel;

  const LabelPreview({super.key, required this.template, required this.data, this.pxPerMm = 6,
      this.selectedId, this.onSelect, this.onMove, this.onResize, this.onResizeLabel});

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
          child = CustomPaint(painter: _QrPainter(p.value, p.ecc), size: Size.infinite);
          if (p.qrTooSmall) {
            child = Container(
              foregroundDecoration: BoxDecoration(border: Border.all(color: Colors.red, width: 2)),
              child: child,
            );
          }
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
    // Resize handle on the selected item (bottom-right corner).
    final selBox = selectedId == null ? null : boxes[selectedId];
    if (onResize != null && selBox != null) {
      LabelElement? selEl;
      for (final e in template.elements) {
        if (e.id == selectedId) selEl = e;
      }
      if (selEl != null) {
        final el = selEl;
        children.add(Positioned(
          left: math.min(selBox.right - 6, w - 12), top: math.min(selBox.bottom - 6, h - 12), width: 12, height: 12,
          child: _DragHandle(
            pxPerMm: pxPerMm, startW: selBox.width / pxPerMm, startH: selBox.height / pxPerMm,
            color: Colors.blue, tooltip: 'Drag to resize',
            onDrag: (nw, nh) => onResize!(el, nw, nh),
          ),
        ));
      }
    }
    // Label size handle (bottom-right corner of the label).
    if (onResizeLabel != null) {
      children.add(Positioned(
        right: 0, bottom: 0, width: 14, height: 14,
        child: _DragHandle(
          pxPerMm: pxPerMm, startW: template.widthMm, startH: template.heightMm,
          color: Colors.grey.shade600, tooltip: 'Drag to change the label size',
          onDrag: (nw, nh) => onResizeLabel!(nw, nh),
        ),
      ));
    }
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

/// Small square handle that reports a new width / height (mm) while dragged.
class _DragHandle extends StatefulWidget {
  final double pxPerMm, startW, startH;
  final Color color;
  final String tooltip;
  final void Function(double wMm, double hMm) onDrag;
  const _DragHandle({required this.pxPerMm, required this.startW, required this.startH,
      required this.color, required this.tooltip, required this.onDrag});
  @override
  State<_DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<_DragHandle> {
  double _w0 = 0, _h0 = 0;
  Offset _acc = Offset.zero;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              _w0 = widget.startW;
              _h0 = widget.startH;
              _acc = Offset.zero;
            },
            onPanUpdate: (u) {
              _acc += u.delta;
              widget.onDrag(math.max(1.0, _w0 + _acc.dx / widget.pxPerMm), math.max(1.0, _h0 + _acc.dy / widget.pxPerMm));
            },
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: widget.color, width: 2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      );
}

class _BarsPainter extends CustomPainter {
  final String v;
  _BarsPainter(this.v);
  @override
  void paint(Canvas c, Size s) {
    // The real barcode (same bars the printer gets) — scannable on screen too.
    final p = Paint()..color = Colors.black;
    final br = barRuns(v);
    if (br.modules == 0) return;
    final unit = s.width / br.modules;
    for (final (start, w) in br.runs) {
      c.drawRect(Rect.fromLTWH(start * unit, 0, w * unit, s.height), p);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter o) => o.v != v;
}

class _QrPainter extends CustomPainter {
  final String v;
  final String ecc;
  _QrPainter(this.v, this.ecc);
  @override
  void paint(Canvas c, Size s) {
    final m = qrMatrix(v, ecc);
    if (m.isEmpty) return;
    final u = s.width / m.length;
    final p = Paint()..color = Colors.black;
    for (var y = 0; y < m.length; y++) {
      for (var x = 0; x < m.length; x++) {
        if (m[y][x]) c.drawRect(Rect.fromLTWH(x * u, y * u, u + 0.3, u + 0.3), p);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter o) => o.v != v || o.ecc != ecc;
}
