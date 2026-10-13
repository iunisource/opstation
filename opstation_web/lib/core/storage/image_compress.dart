// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// Shrinks a photo before upload: longest side ≤ [maxSide] px, JPEG at
/// [quality]. Keeps a workable quality (sharp on screen and in print) while
/// cutting a 3–8 MB phone photo to roughly 200–500 KB.
///
/// Transparent PNGs are flattened on white (JPEG has no transparency).
/// GIFs and anything that fails to decode are returned untouched, and if the
/// "compressed" result is not actually smaller, the original is kept.
/// Returns (bytes, mimeType, extension).
Future<(Uint8List, String, String)> compressImageBytes(
  Uint8List bytes, {
  String mime = 'image/jpeg',
  int maxSide = 1600,
  double quality = 0.82,
}) async {
  final m = mime.toLowerCase();
  if (m.contains('gif') || m.contains('svg') || bytes.isEmpty) {
    return (bytes, mime, m.contains('gif') ? 'gif' : (m.contains('svg') ? 'svg' : 'jpg'));
  }
  final url = html.Url.createObjectUrlFromBlob(html.Blob([bytes], mime));
  try {
    final img = html.ImageElement();
    final done = Completer<void>();
    img.onLoad.first.then((_) => done.complete());
    img.onError.first.then((_) => done.completeError('decode'));
    img.src = url;
    await done.future.timeout(const Duration(seconds: 20));
    final w = img.naturalWidth, h = img.naturalHeight;
    if (w == 0 || h == 0) return (bytes, mime, _ext(m));
    final longest = w > h ? w : h;
    final scale = longest > maxSide ? maxSide / longest : 1.0;
    final cw = (w * scale).round(), ch = (h * scale).round();
    final canvas = html.CanvasElement(width: cw, height: ch);
    final ctx = canvas.context2D;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, cw, ch);
    ctx.drawImageScaled(img, 0, 0, cw, ch);
    final blob = await canvas.toBlob('image/jpeg', quality);
    final reader = html.FileReader()..readAsArrayBuffer(blob);
    await reader.onLoadEnd.first;
    final r = reader.result;
    final out = r is Uint8List ? r : (r as ByteBuffer).asUint8List();
    if (out.isEmpty || out.length >= bytes.length) return (bytes, mime, _ext(m));
    return (out, 'image/jpeg', 'jpg');
  } catch (_) {
    return (bytes, mime, _ext(m));
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}

String _ext(String mime) {
  if (mime.contains('png')) return 'png';
  if (mime.contains('webp')) return 'webp';
  return 'jpg';
}
