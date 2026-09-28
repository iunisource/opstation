// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../share/share_file.dart';

bool get _isMobileWeb {
  final ua = html.window.navigator.userAgent.toLowerCase();
  return ua.contains('android') ||
      ua.contains('iphone') ||
      ua.contains('ipad') ||
      ua.contains('mobile');
}

String _safeName(String fileName) {
  final base = fileName.toLowerCase().endsWith('.pdf')
      ? fileName.substring(0, fileName.length - 4)
      : fileName;
  final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '-').trim();
  return '${safe.isEmpty ? 'document' : safe}.pdf';
}

/// PRINT: show a PDF preview only — never downloads on its own; saving is the
/// user's choice from the preview (or the Share button).
///   • Desktop Chrome/Edge/Safari: the browser print preview.
///   • Desktop Firefox: opens the PDF in a new tab (Firefox's viewer, with its
///     own Print and Download buttons). Only if the browser blocks the new tab
///     do we fall back to downloading it.
///   • Mobile web: phones cannot show a print preview, so the file is handed to
///     the share sheet / saved (the only way to print from a phone browser).
Future<void> showPdf(Uint8List bytes, String fileName) async {
  final name = _safeName(fileName);
  if (_isMobileWeb) {
    await shareFileOnly(bytes, name);
    return;
  }
  final ua = html.window.navigator.userAgent.toLowerCase();
  if (!ua.contains('firefox')) {
    await Printing.layoutPdf(onLayout: (PdfPageFormat _) async => bytes, name: name);
    return;
  }
  // A named File (not a bare Blob) so Firefox's viewer offers the proper file
  // name when the user chooses Download / Save from the preview.
  final file = html.File([bytes], name, {'type': 'application/pdf'});
  final url = html.Url.createObjectUrlFromBlob(file);
  Object? win;
  try {
    win = js_util.callMethod(html.window, 'open', [url, '_blank']);
  } catch (_) {
    win = null;
  }
  if (win == null) {
    // New tab blocked — download so the user still gets the document.
    final a = html.AnchorElement(href: url)
      ..download = name
      ..style.display = 'none';
    html.document.body!.append(a);
    a.click();
    Future.delayed(const Duration(seconds: 5), () {
      a.remove();
      html.Url.revokeObjectUrl(url);
    });
  }
}

/// SHARE: hand the PDF to the device share sheet (WhatsApp, email…); on
/// desktop browsers without Web Share this saves it with the proper name.
Future<void> sharePdf(Uint8List bytes, String fileName) =>
    shareFileOnly(bytes, _safeName(fileName));

/// Report prints: preview with the name convention "Doc Name_d MMM yyyy",
/// e.g. "Trial Balance_28 Sep 2026.pdf". [date] defaults to today.
Future<void> outputPdf(Uint8List bytes, String docName, {DateTime? date}) =>
    showPdf(bytes,
        '${docName.trim()}_${DateFormat('d MMM yyyy').format(date ?? DateTime.now())}');
