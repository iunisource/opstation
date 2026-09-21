// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// True when the text contains any Arabic-script codepoint (covers Urdu, which
/// uses the Arabic script).
bool hasArabicScript(String s) {
  for (final r in s.runes) {
    if ((r >= 0x0600 && r <= 0x06FF) || // Arabic
        (r >= 0x0750 && r <= 0x077F) || // Arabic Supplement
        (r >= 0x08A0 && r <= 0x08FF) || // Arabic Extended-A
        (r >= 0xFB50 && r <= 0xFDFF) || // Arabic Presentation Forms-A
        (r >= 0xFE70 && r <= 0xFEFF)) { // Arabic Presentation Forms-B
      return true;
    }
  }
  return false;
}

/// Render a right-to-left note (Urdu/Arabic) to a PNG using the BROWSER's text
/// engine, which does full contextual shaping (letter-joining) and bidi — things
/// the Dart pdf package cannot do on its own, so pw.Text renders Urdu as
/// disconnected/tofu. The result is embedded in the PDF as an image so parties
/// see properly joined script. Returns a ready pw.Image sized to [widthPt], or
/// null if canvas rendering isn't available (caller should fall back to text).
///
/// [align] is a canvas textAlign value: 'right', 'center' or 'left'.
Future<pw.Widget?> rtlNoteImage(
  String text,
  double widthPt, {
  double fontSizePt = 10,
  String colorHex = '#1f2937',
  String align = 'center',
  bool bold = true,
}) async {
  try {
    const scale = 3.0; // render at 3x for crisp print
    final widthPx = (widthPt * scale).round();
    final fontPx = fontSizePt * scale;
    final lineHeight = fontPx * 1.75;
    final padY = fontPx * 0.55;
    const fontStack =
        '"Noto Nastaliq Urdu","Jameel Noori Nastaleeq","Noto Naskh Arabic","Geeza Pro","Arial",sans-serif';
    final weight = bold ? 'bold ' : '';

    // Best-effort: make sure a web Arabic font is ready before drawing. Falls
    // back to the platform's own Arabic font (macOS/iOS/Android all ship one).
    try {
      final fonts = js_util.getProperty(html.document, 'fonts');
      if (fonts != null) {
        await js_util.promiseToFuture(
            js_util.callMethod(fonts, 'load', ['${weight}${fontPx}px "Noto Naskh Arabic"']));
        await js_util.promiseToFuture(js_util.getProperty(fonts, 'ready'));
      }
    } catch (_) {/* system font fallback still shapes correctly */}

    final canvas = html.CanvasElement(width: widthPx, height: 10);
    final ctx = canvas.context2D;
    final maxTextW = widthPx - fontPx; // small horizontal breathing room
    ctx.font = '$weight${fontPx}px $fontStack';

    // Word-wrap in logical order (canvas re-orders visually for RTL).
    final lines = <String>[];
    for (final para in text.split('\n')) {
      final words = para.trim().split(RegExp(r'\s+'));
      var cur = '';
      for (final w in words) {
        final trial = cur.isEmpty ? w : '$cur $w';
        final width = ctx.measureText(trial).width ?? 0;
        if (width > maxTextW && cur.isNotEmpty) {
          lines.add(cur);
          cur = w;
        } else {
          cur = trial;
        }
      }
      lines.add(cur);
    }
    if (lines.isEmpty) return null;

    // Resizing the canvas resets the context, so set height then re-apply state.
    canvas.height = (padY * 2 + lines.length * lineHeight).ceil();
    ctx.font = '$weight${fontPx}px $fontStack';
    js_util.setProperty(ctx, 'direction', 'rtl');
    ctx.textAlign = align;
    ctx.textBaseline = 'middle';
    ctx.fillStyle = colorHex;
    final x = align == 'right'
        ? widthPx - fontPx * 0.3
        : (align == 'left' ? fontPx * 0.3 : widthPx / 2);
    for (var i = 0; i < lines.length; i++) {
      ctx.fillText(lines[i], x, padY + lineHeight * (i + 0.5));
    }

    final dataUrl = canvas.toDataUrl('image/png');
    final bytes = base64Decode(dataUrl.split(',').last);
    final hPt = (canvas.height ?? 0) / scale;
    return pw.Image(pw.MemoryImage(bytes), width: widthPt, height: hPt);
  } catch (_) {
    return null; // fall back to plain pw.Text
  }
}
