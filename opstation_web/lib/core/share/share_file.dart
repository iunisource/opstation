// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:typed_data';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

/// Share ONE file through the device's native share sheet with only the file
/// attached — no text, title, or URL. `Printing.sharePdf` adds those extra
/// fields, which makes WhatsApp (and others) show a blob link / text instead of
/// just the document. This calls `navigator.share({files:[file]})` directly so
/// the recipient gets only the PDF. Falls back to a plain named download where
/// the Web Share API with files isn't available (most desktop browsers).
Future<void> shareFileOnly(
  Uint8List bytes,
  String filename, {
  String mime = 'application/pdf',
}) async {
  final nav = html.window.navigator;
  try {
    final file = html.File([bytes], filename, {'type': mime});

    // Build a real JS array [file] and the payload {files:[file]} without
    // deep-converting the File object.
    final arrayCtor = js_util.getProperty(html.window, 'Array');
    final filesArray = js_util.callConstructor(arrayCtor, const []);
    js_util.callMethod(filesArray, 'push', [file]);
    final payload = js_util.newObject();
    js_util.setProperty(payload, 'files', filesArray);

    final canShare = js_util.hasProperty(nav, 'canShare') &&
        (js_util.callMethod(nav, 'canShare', [payload]) as bool? ?? false);
    if (canShare && js_util.hasProperty(nav, 'share')) {
      await js_util.promiseToFuture(js_util.callMethod(nav, 'share', [payload]));
      return; // shared just the file
    }
  } catch (e) {
    // User cancelled the share sheet (AbortError) → done, don't fall through to
    // a download. Any other error falls through to the download fallback.
    final s = e.toString().toLowerCase();
    if (s.contains('abort') || s.contains('cancel')) return;
  }

  // Fallback: download the file with the correct name.
  final url = html.Url.createObjectUrlFromBlob(html.Blob([bytes], mime));
  final a = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  html.document.body!.append(a);
  a.click();
  Future.delayed(const Duration(seconds: 5), () {
    a.remove();
    html.Url.revokeObjectUrl(url);
  });
}
