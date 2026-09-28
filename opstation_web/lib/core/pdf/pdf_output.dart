// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../share/share_file.dart';

/// Show / save a generated PDF with a proper file name, the same way voucher
/// PDFs do:
///   • Mobile web: share / download the file directly (named).
///   • Firefox: its PDF.js viewer ignores the print-job name and saves the file
///     as "PDF.js viewer.pdf", so download it directly with the right name.
///   • Other desktop browsers: normal print preview.
/// File name convention: "Doc Name_d MMM yyyy.pdf", e.g.
/// "Trial Balance_28 Sep 2026.pdf". [date] defaults to today.
Future<void> outputPdf(Uint8List bytes, String docName, {DateTime? date}) async {
  final fileBase = '${docName.trim()}_${DateFormat('d MMM yyyy').format(date ?? DateTime.now())}';
  final safe = fileBase.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '-').trim();
  final name = '${safe.isEmpty ? 'document' : safe}.pdf';
  final ua = html.window.navigator.userAgent.toLowerCase();
  final mobile = ua.contains('android') ||
      ua.contains('iphone') ||
      ua.contains('ipad') ||
      ua.contains('mobile');
  if (mobile) {
    await shareFileOnly(bytes, name);
  } else if (ua.contains('firefox')) {
    final url = html.Url.createObjectUrlFromBlob(html.Blob([bytes], 'application/pdf'));
    final a = html.AnchorElement(href: url)
      ..download = name
      ..style.display = 'none';
    html.document.body!.append(a);
    a.click();
    Future.delayed(const Duration(seconds: 5), () {
      a.remove();
      html.Url.revokeObjectUrl(url);
    });
  } else {
    await Printing.layoutPdf(onLayout: (PdfPageFormat _) async => bytes, name: name);
  }
}
