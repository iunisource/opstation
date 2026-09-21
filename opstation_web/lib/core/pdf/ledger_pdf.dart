// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../share/share_file.dart';

/// One posted ledger line, pre-formatted by the caller (so this builder stays
/// decoupled from the app's money/date formatting).
class LedgerLine {
  final String date, voucher, description, type, debit, credit, balance;
  const LedgerLine(this.date, this.voucher, this.description, this.type,
      this.debit, this.credit, this.balance);
}

/// A pending-cheque (PDC) memo line, customer ledger only.
class LedgerPdc {
  final String voucher, chequeDate, details, amount;
  const LedgerPdc(this.voucher, this.chequeDate, this.details, this.amount);
}

/// Every field needed to render a party ledger. Both the Share button and the
/// Print / Save-as-PDF button build one of these and hand it to the SAME
/// generator, so the two outputs are byte-for-byte identical — the parties see
/// the exact same document however it reaches them.
class LedgerDoc {
  final String docTitle; // 'Customer Ledger' / 'Supplier Ledger'
  final String orgName;
  final String partyName;
  final String partyCode;
  final String branchName;
  final String period;
  final String genTime;
  final List<LedgerLine> lines;
  final String totalDebit;
  final String totalCredit;
  final String netBalanceLabel; // e.g. 'Balance Receivable: Rs. 12,000'
  final String netBalanceValue; // signed money for the stat card, e.g. 'Rs. 12,000'
  final bool netIsDanger; // red when they owe (receivable) / we owe (payable)
  final String fileBase;
  final List<LedgerPdc> pdc;
  final String? pdcTotal;
  final String? footerMessage; // optional custom note printed at the very end

  const LedgerDoc({
    required this.docTitle,
    required this.orgName,
    required this.partyName,
    required this.partyCode,
    required this.branchName,
    required this.period,
    required this.genTime,
    required this.lines,
    required this.totalDebit,
    required this.totalCredit,
    required this.netBalanceLabel,
    required this.netBalanceValue,
    required this.netIsDanger,
    required this.fileBase,
    this.pdc = const [],
    this.pdcTotal,
    this.footerMessage,
  });
}

const _accent = PdfColor.fromInt(0xFF1976D2); // debit blue
const _green = PdfColor.fromInt(0xFF2E7D32); // credit green
const _danger = PdfColor.fromInt(0xFFC62828);

/// True when the text contains any Arabic-script codepoint (covers Urdu, which
/// uses the Arabic script). Used to switch the footer note to RTL so the words
/// read in the correct order.
bool _hasArabicScript(String s) {
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
/// disconnected, isolated letters. The result is embedded in the PDF as an image
/// so the parties see properly joined script. Returns a ready pw.Image sized to
/// [widthPt], or null if canvas rendering isn't available.
Future<pw.Widget?> _rtlNoteImage(String text, double widthPt,
    {double fontSizePt = 10}) async {
  try {
    const scale = 3.0; // render at 3x for crisp print
    final widthPx = (widthPt * scale).round();
    final fontPx = fontSizePt * scale;
    final lineHeight = fontPx * 1.75;
    final padY = fontPx * 0.6;
    const fontStack =
        '"Noto Nastaliq Urdu","Jameel Noori Nastaleeq","Noto Naskh Arabic","Geeza Pro","Arial",sans-serif';

    // Best-effort: make sure a web Arabic font is ready before drawing. Falls
    // back to the platform's own Arabic font (macOS/iOS/Android all ship one).
    try {
      final fonts = js_util.getProperty(html.document, 'fonts');
      if (fonts != null) {
        await js_util.promiseToFuture(
            js_util.callMethod(fonts, 'load', ['bold ${fontPx}px "Noto Naskh Arabic"']));
        await js_util.promiseToFuture(js_util.getProperty(fonts, 'ready'));
      }
    } catch (_) {/* system font fallback still shapes correctly */}

    final canvas = html.CanvasElement(width: widthPx, height: 10);
    final ctx = canvas.context2D;
    final maxTextW = widthPx - fontPx; // small horizontal breathing room
    ctx.font = 'bold ${fontPx}px $fontStack';

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
    ctx.font = 'bold ${fontPx}px $fontStack';
    js_util.setProperty(ctx, 'direction', 'rtl');
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#1f2937';
    for (var i = 0; i < lines.length; i++) {
      ctx.fillText(lines[i], widthPx / 2, padY + lineHeight * (i + 0.5));
    }

    final dataUrl = canvas.toDataUrl('image/png');
    final bytes = base64Decode(dataUrl.split(',').last);
    final hPt = (canvas.height ?? 0) / scale;
    return pw.Image(pw.MemoryImage(bytes), width: widthPt, height: hPt);
  } catch (_) {
    return null; // fall back to plain pw.Text
  }
}

/// Load a Unicode-capable theme so the ledger renders non-Latin text correctly:
/// Noto Sans as the base (covers dashes / bullets / symbols that default
/// Helvetica shows as tofu boxes) with Noto Naskh Arabic as a fallback for
/// Urdu / Arabic footer notes and descriptions. Falls back to the default font
/// if the web fonts can't be fetched — text still prints, just Latin-only.
Future<pw.ThemeData?> _loadLedgerTheme() async {
  try {
    final base = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final fallback = <pw.Font>[];
    try {
      fallback.add(await PdfGoogleFonts.notoNaskhArabicRegular());
      fallback.add(await PdfGoogleFonts.notoNaskhArabicBold());
    } catch (_) {/* Arabic script fallback unavailable — Latin still works */}
    return pw.ThemeData.withFont(
        base: base, bold: bold, fontFallback: fallback.isEmpty ? null : fallback);
  } catch (_) {
    return null; // never let a font fetch break ledger generation
  }
}

/// Build the ledger PDF bytes from a [LedgerDoc]. This is the single source of
/// truth for the ledger's appearance — both Share and Print call it, so what a
/// party receives via WhatsApp is identical to the printed / saved PDF.
Future<Uint8List> buildLedgerPdfBytes(LedgerDoc d) async {
  final theme = await _loadLedgerTheme();
  final doc = pw.Document(
      title: d.fileBase, creator: 'Opstation ERP', theme: theme);

  // Pre-render a right-to-left footer note (Urdu/Arabic) to an image so the
  // script is properly joined. Latin notes keep using plain text.
  final footerNote = (d.footerMessage ?? '').trim();
  pw.Widget? footerImg;
  if (footerNote.isNotEmpty && _hasArabicScript(footerNote)) {
    footerImg = await _rtlNoteImage(footerNote, 511);
  }

  final hStyle = pw.TextStyle(
      fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700);
  pw.Widget hc(String t, {pw.TextAlign a = pw.TextAlign.left}) => pw.Padding(
      padding: const pw.EdgeInsets.all(4),
      child: pw.Text(t, style: hStyle, textAlign: a));
  pw.Widget c(String t,
          {pw.TextAlign a = pw.TextAlign.left,
          bool bold = false,
          PdfColor? color}) =>
      pw.Padding(
          padding: const pw.EdgeInsets.all(4),
          child: pw.Text(t,
              textAlign: a,
              style: pw.TextStyle(
                  fontSize: 8.5,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                  color: color)));

  final netColor = d.netIsDanger ? _danger : _green;

  // A bordered stat card (Total Debit / Total Credit / Net Balance) matching the
  // print header cards.
  pw.Widget stat(String label, String value, PdfColor valueColor) => pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.only(right: 8),
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(label.toUpperCase(),
                style: pw.TextStyle(
                    fontSize: 7,
                    color: PdfColors.grey600,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 0.5)),
            pw.SizedBox(height: 3),
            pw.Text(value,
                style: pw.TextStyle(
                    fontSize: 12, fontWeight: pw.FontWeight.bold, color: valueColor)),
          ]),
        ),
      );

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    build: (ctx) => [
      // ── Header ─────────────────────────────────────────────────────────
      pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              if (d.orgName.trim().isNotEmpty) ...[
                pw.Text(d.orgName,
                    style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 2),
                pw.Text(d.docTitle,
                    style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
              ] else
                pw.Text(d.docTitle,
                    style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            ]),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text(d.partyName + (d.partyCode.isNotEmpty ? '  (${d.partyCode})' : ''),
                  style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.Text(d.branchName,
                  style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
              if (d.period.isNotEmpty)
                pw.Text(d.period,
                    style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
              pw.Text('Generated: ' + d.genTime,
                  style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey)),
            ]),
          ]),
      pw.SizedBox(height: 6),
      pw.Container(height: 1.5, color: PdfColors.black),
      pw.SizedBox(height: 10),

      // ── Stat cards ─────────────────────────────────────────────────────
      pw.Row(children: [
        stat('Total Debit', 'Rs. ' + d.totalDebit, _accent),
        stat('Total Credit', 'Rs. ' + d.totalCredit, _green),
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(4)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('NET BALANCE',
                  style: pw.TextStyle(
                      fontSize: 7,
                      color: PdfColors.grey600,
                      fontWeight: pw.FontWeight.bold,
                      letterSpacing: 0.5)),
              pw.SizedBox(height: 3),
              pw.Text(d.netBalanceValue,
                  style: pw.TextStyle(
                      fontSize: 12, fontWeight: pw.FontWeight.bold, color: netColor)),
            ]),
          ),
        ),
      ]),
      pw.SizedBox(height: 12),

      // ── Ledger table ───────────────────────────────────────────────────
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
        columnWidths: const {
          0: pw.FixedColumnWidth(46),
          1: pw.FixedColumnWidth(66),
          2: pw.FlexColumnWidth(3),
          3: pw.FixedColumnWidth(52),
          4: pw.FixedColumnWidth(58),
          5: pw.FixedColumnWidth(58),
          6: pw.FixedColumnWidth(64),
        },
        children: [
          pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                hc('Date'),
                hc('Voucher'),
                hc('Description'),
                hc('Type'),
                hc('Debit', a: pw.TextAlign.right),
                hc('Credit', a: pw.TextAlign.right),
                hc('Balance', a: pw.TextAlign.right),
              ]),
          for (final l in d.lines)
            pw.TableRow(children: [
              c(l.date),
              c(l.voucher),
              c(l.description),
              c(l.type),
              c(l.debit, a: pw.TextAlign.right),
              c(l.credit, a: pw.TextAlign.right),
              c(l.balance, a: pw.TextAlign.right, bold: true),
            ]),
          pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey100),
              children: [
                c('${d.lines.length} entries', bold: true),
                c(''),
                c(''),
                c('Total', bold: true, a: pw.TextAlign.right),
                c(d.totalDebit, a: pw.TextAlign.right, bold: true),
                c(d.totalCredit, a: pw.TextAlign.right, bold: true),
                c(''),
              ]),
        ],
      ),
      pw.SizedBox(height: 10),

      // ── Net balance chip (party-facing summary) ────────────────────────
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: pw.BoxDecoration(
              color: PdfColors.grey100, borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Text(d.netBalanceLabel,
              style: pw.TextStyle(
                  fontSize: 11, fontWeight: pw.FontWeight.bold, color: netColor)),
        ),
      ]),

      // ── Pending cheques (PDC) memo ─────────────────────────────────────
      if (d.pdc.isNotEmpty) ...[
        pw.SizedBox(height: 14),
        pw.Text('Pending Cheques (PDC) — memo only, not included in the balance',
            style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.orange800)),
        pw.SizedBox(height: 4),
        pw.Table(border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5), children: [
          pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColors.grey200), children: [
            hc('Voucher'),
            hc('Cheque Date'),
            hc('Details'),
            hc('Amount', a: pw.TextAlign.right),
          ]),
          for (final p in d.pdc)
            pw.TableRow(children: [
              c(p.voucher),
              c(p.chequeDate),
              c(p.details),
              c(p.amount, a: pw.TextAlign.right),
            ]),
        ]),
        if (d.pdcTotal != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
              pw.Text('PDC Total: ' + d.pdcTotal!,
                  style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            ]),
          ),
      ],

      // ── Custom footer message (boxed, centered note) ───────────────────
      if (footerNote.isNotEmpty) ...[
        pw.SizedBox(height: 18),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: pw.BoxDecoration(
            color: PdfColors.grey100,
            border: pw.Border.all(color: PdfColors.grey400, width: 0.7),
            borderRadius: pw.BorderRadius.circular(5),
          ),
          // Urdu/Arabic notes render as a browser-shaped image; Latin notes
          // stay as selectable text.
          child: footerImg ??
              pw.Text(
                footerNote,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 9.5,
                  color: PdfColors.grey900,
                  fontWeight: pw.FontWeight.bold,
                  lineSpacing: 2,
                ),
              ),
        ),
      ],
    ],
  ));

  return doc.save();
}

/// Build the ledger PDF and hand it to the device's native share sheet
/// (WhatsApp, email, files, …) with ONLY the file attached.
Future<void> shareLedgerPdf(LedgerDoc d) async {
  final bytes = await buildLedgerPdfBytes(d);
  await shareFileOnly(bytes, d.fileBase + '.pdf');
}

/// Print / Save-as-PDF the ledger. Uses the SAME bytes as [shareLedgerPdf], so
/// the printed and shared documents are identical. Mobile downloads/shares the
/// file; Firefox downloads directly (its PDF.js viewer ignores the job name);
/// other desktop browsers open the native print preview.
Future<void> printLedgerPdf(LedgerDoc d) async {
  final bytes = await buildLedgerPdfBytes(d);
  final fileName = d.fileBase + '.pdf';
  final ua = html.window.navigator.userAgent.toLowerCase();
  final isMobile = ua.contains('android') ||
      ua.contains('iphone') ||
      ua.contains('ipad') ||
      ua.contains('mobile');
  if (isMobile) {
    await shareFileOnly(bytes, fileName);
  } else if (ua.contains('firefox')) {
    final blob = html.Blob([bytes], 'application/pdf');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final a = html.AnchorElement(href: url)
      ..download = fileName
      ..style.display = 'none';
    html.document.body!.append(a);
    a.click();
    Future.delayed(const Duration(seconds: 5), () {
      a.remove();
      html.Url.revokeObjectUrl(url);
    });
  } else {
    await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => bytes, name: fileName);
  }
}
