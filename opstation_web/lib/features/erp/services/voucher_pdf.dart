// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Shared PDF generator for ERP vouchers (SO, DO, SI, PO, GRN, PI, etc.)
class VoucherPdf {
  static const _accent = PdfColor.fromInt(0xFF2563EB);
  static const _muted = PdfColor.fromInt(0xFF64748B);
  static const _border = PdfColor.fromInt(0xFFE2E8F0);
  static const _bg = PdfColor.fromInt(0xFFF8FAFC);

  static bool _isPurchaseType(String voucherTypeLabel) =>
      voucherTypeLabel.toLowerCase().contains('purchase') ||
      voucherTypeLabel.toLowerCase().contains('grn');

  /// Reads the org-level "show company name" flag from app_config for the
  /// relevant document family. RLS scopes app_config to the current org, so no
  /// org id is needed. Defaults to SHOWING the name when the flag is unset, so
  /// existing prints are unchanged until the toggle is turned off.
  static Future<bool> _showOrgName(bool isPurchase) async {
    final key =
        isPurchase ? 'org.show_org_name_purchase' : 'org.show_org_name_sales';
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('value')
          .eq('key', key);
      for (final r in rows as List) {
        if ((r['value'] as String?) == 'false') return false; // explicitly off
      }
      return true; // unset or 'true' => show
    } catch (_) {
      return true; // never let a config read break printing
    }
  }

  /// Builds the download/title base: Party_Date_DocType
  /// e.g. "Ali ES_1 Aug 2026_Sales Invoice". Falls back to the voucher number
  /// when no party is on the document (e.g. stock transfers use branches).
  static String _fileBase(String type, String number, String? date,
      {String? party}) {
    final p = (party ?? '').trim();
    final d = (date ?? '').trim();
    final t = type.trim();
    final base = p.isNotEmpty
        ? [p, if (d.isNotEmpty) d, t].join('_')
        : [t, number.trim(), if (d.isNotEmpty) d].join('_');
    // keep filename-safe but readable characters (spaces and commas allowed)
    final clean = base.replaceAll(RegExp(r'[^A-Za-z0-9 _,\-\.]'), '').trim();
    return clean.isEmpty ? number : clean;
  }

  static bool get _isMobileWeb {
    final ua = html.window.navigator.userAgent.toLowerCase();
    return ua.contains('android') ||
        ua.contains('iphone') ||
        ua.contains('ipad') ||
        ua.contains('mobile');
  }

  /// One output path for every voucher PDF:
  ///   • Desktop: browser print preview (Print or Save-as-PDF, named [fileBase]).
  ///   • Mobile: the print preview cannot open, so DOWNLOAD the PDF directly —
  ///     sharePdf triggers the browser download / share sheet with the filename.
  static Future<void> _output(Uint8List bytes, String fileBase) async {
    if (_isMobileWeb) {
      await Printing.sharePdf(bytes: bytes, filename: '$fileBase.pdf');
    } else {
      await Printing.layoutPdf(
          onLayout: (PdfPageFormat format) async => bytes,
          name: '$fileBase.pdf');
    }
  }

  static Future<void> printVoucher({
    required String voucherNumber,
    required String voucherTypeLabel,
    required String orgName,
    String? branchName,
    String? date,
    String? customerOrSupplier,
    String? customerCode,
    String? customerAddress,
    String? customerContact,
    String? customerPhone,
    String? salespersonName,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    List<VoucherLine>? focLines, // free-of-cost lines, rendered in their own block
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? preparedBy,
    String? createdAt,
    String? approvedBy,
    String? approvedAt,
    String? approvedSignatureUrl,
    String? stampUrl,
    // Middle sign-off column. Defaults to a blank "Checked By" box; callers can
    // relabel it (e.g. 'Supervised By' for GRN) and supply a name/signature/stamp
    // so it prints like the Approved By column.
    String? checkedByLabel,
    String? checkedByName,
    String? checkedByAt,
    String? checkedBySignatureUrl,
    String? checkedByStampUrl,
    String? footerNote,
    Map<String, String>? relatedRefs, // e.g. {'SO #': 'SO-2026-0001', 'DO #': 'DO-...'}
    String? watermark, // optional diagonal page watermark, e.g. 'VOIDED'
  }) async {
    final isPurchase = _isPurchaseType(voucherTypeLabel);
    // Quotations keep their own per-print "Show company name" control, so the
    // org-level voucher toggle does not apply to them.
    final isQuotation = voucherTypeLabel.toLowerCase().contains('quotation');
    final effectiveOrg =
        (isQuotation || await _showOrgName(isPurchase)) ? orgName : '';
    final fileBase = _fileBase(voucherTypeLabel, voucherNumber, date,
        party: customerOrSupplier);
    final doc = await _buildDoc(
      voucherNumber: voucherNumber, voucherTypeLabel: voucherTypeLabel,
      orgName: effectiveOrg, branchName: branchName, date: date,
      customerOrSupplier: customerOrSupplier, customerCode: customerCode,
      customerAddress: customerAddress, customerContact: customerContact, customerPhone: customerPhone,
      salespersonName: salespersonName,
      status: status, remarks: remarks, lines: lines, focLines: focLines,
      subtotal: subtotal, discountTotal: discountTotal, grandTotal: grandTotal,
      preparedBy: preparedBy, createdAt: createdAt,
      approvedBy: approvedBy, approvedAt: approvedAt,
      approvedSignatureUrl: approvedSignatureUrl, stampUrl: stampUrl,
      checkedByLabel: checkedByLabel, checkedByName: checkedByName, checkedByAt: checkedByAt,
      checkedBySignatureUrl: checkedBySignatureUrl, checkedByStampUrl: checkedByStampUrl,
      footerNote: footerNote, relatedRefs: relatedRefs,
      watermark: watermark, docTitle: fileBase,
    );
    await _output(await doc.save(), fileBase);
  }

  /// Stock transfer voucher (internal branch-to-branch; no pricing). Includes an
  /// audit trail: generated / dispatched / approved with who + when.
  static Future<void> printStockTransfer({
    required String voucherNumber,
    required String orgName,
    required String fromBranch,
    required String toBranch,
    String? date,
    String? notes,
    String? status,
    required List<Map<String, dynamic>> items,
    String? generatedBy, String? generatedAt,
    String? dispatchedBy, String? dispatchedAt,
    String? approvedBy, String? approvedAt,
  }) async {
    final fileBase = _fileBase('Stock Transfer', voucherNumber, date,
        party: '$fromBranch to $toBranch');
    final doc = pw.Document(title: fileBase, author: orgName);

    pw.Widget kv(String k, String v) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(k, style: const pw.TextStyle(fontSize: 8, color: _muted)),
          pw.SizedBox(height: 2),
          pw.Text(v, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ]);

    pw.Widget auditLine(String label, String? who, String? when) {
      if (who == null || who.isEmpty) return pw.SizedBox();
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4),
        child: pw.Row(children: [
          pw.SizedBox(width: 110, child: pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: _muted))),
          pw.Expanded(child: pw.Text('$who${when != null && when.isNotEmpty ? '    |    $when' : ''}', style: const pw.TextStyle(fontSize: 10))),
        ]),
      );
    }

    final totalQty = items.fold<double>(0, (s, it) => s + ((it['qty'] as num?)?.toDouble() ?? 0));

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            if (orgName.isNotEmpty) pw.Text(orgName, style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 2),
            pw.Text('STOCK TRANSFER', style: pw.TextStyle(fontSize: 11, color: _accent, fontWeight: pw.FontWeight.bold, letterSpacing: 1)),
          ]),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text(voucherNumber, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            if (date != null) pw.Text(date, style: const pw.TextStyle(fontSize: 10, color: _muted)),
            if (status != null && status.isNotEmpty) pw.Text(status.toUpperCase(), style: const pw.TextStyle(fontSize: 9, color: _muted)),
          ]),
        ]),
        pw.SizedBox(height: 8),
        pw.Divider(color: _border),
        pw.SizedBox(height: 8),
        pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(color: _bg, borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Row(children: [
            pw.Expanded(child: kv('From Branch', fromBranch)),
            pw.SizedBox(width: 20),
            pw.Text('->', style: const pw.TextStyle(fontSize: 14, color: _muted)),
            pw.SizedBox(width: 20),
            pw.Expanded(child: kv('To Branch', toBranch)),
          ]),
        ),
        pw.SizedBox(height: 14),
        pw.Table(
          border: pw.TableBorder.all(color: _border, width: 0.5),
          columnWidths: {0: const pw.FlexColumnWidth(5), 1: const pw.FlexColumnWidth(2), 2: const pw.FlexColumnWidth(2)},
          children: [
            pw.TableRow(decoration: const pw.BoxDecoration(color: _bg), children: [
              _stCell('Product', header: true),
              _stCell('UOM', header: true),
              _stCell('Quantity', header: true, align: pw.TextAlign.right),
            ]),
            ...items.map((it) {
              final sku = (it['sku'] as String?) ?? '';
              return pw.TableRow(children: [
                _stCell('${it['product'] ?? ''}${sku.isNotEmpty ? '  ($sku)' : ''}'),
                _stCell('${it['uom'] ?? ''}'),
                _stCell(_stNum((it['qty'] as num?)?.toDouble() ?? 0), align: pw.TextAlign.right),
              ]);
            }),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Total quantity: ${_stNum(totalQty)}', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold))),
        if (notes != null && notes.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          pw.Text('Notes', style: const pw.TextStyle(fontSize: 9, color: _muted)),
          pw.Text(notes, style: const pw.TextStyle(fontSize: 10)),
        ],
        pw.SizedBox(height: 18),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _border, width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('AUDIT TRAIL', style: pw.TextStyle(fontSize: 9, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.5)),
            pw.SizedBox(height: 6),
            auditLine('Generated by', generatedBy, generatedAt),
            auditLine('Dispatched by', dispatchedBy, dispatchedAt),
            auditLine('Approved by', approvedBy, approvedAt),
          ]),
        ),
      ]),
    ));

    await _output(await doc.save(), fileBase);
  }

  static pw.Widget _stCell(String s, {bool header = false, pw.TextAlign align = pw.TextAlign.left}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: pw.Text(s, textAlign: align, style: pw.TextStyle(fontSize: header ? 9 : 10, fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal, color: header ? _muted : PdfColors.black)),
      );

  static String _stNum(double v) => _n4(v);

  /// Up to 4 decimals, trailing zeros trimmed, with thousands separators —
  /// used for quantities, unit prices and totals so fractional values are not
  /// rounded away on the printed voucher.
  static final NumberFormat _num4 = NumberFormat('#,##0.####');
  static String _n4(num? v) => _num4.format((v ?? 0).toDouble());

  static Future<Uint8List> generateBytes({
    required String voucherNumber,
    required String voucherTypeLabel,
    required String orgName,
    String? branchName,
    String? date,
    String? customerOrSupplier,
    String? customerCode,
    String? customerAddress,
    String? customerContact,
    String? customerPhone,
    String? salespersonName,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    List<VoucherLine>? focLines, // free-of-cost lines, rendered in their own block
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? preparedBy,
    String? createdAt,
    String? approvedBy,
    String? approvedAt,
    String? approvedSignatureUrl,
    String? stampUrl,
    // Middle sign-off column. Defaults to a blank "Checked By" box; callers can
    // relabel it (e.g. 'Supervised By' for GRN) and supply a name/signature/stamp
    // so it prints like the Approved By column.
    String? checkedByLabel,
    String? checkedByName,
    String? checkedByAt,
    String? checkedBySignatureUrl,
    String? checkedByStampUrl,
    String? footerNote,
    Map<String, String>? relatedRefs,
    String? watermark, // optional diagonal page watermark, e.g. 'VOIDED'
  }) async {
    final isPurchase = _isPurchaseType(voucherTypeLabel);
    final isQuotation = voucherTypeLabel.toLowerCase().contains('quotation');
    final effectiveOrg =
        (isQuotation || await _showOrgName(isPurchase)) ? orgName : '';
    final fileBase = _fileBase(voucherTypeLabel, voucherNumber, date,
        party: customerOrSupplier);
    final doc = await _buildDoc(
      voucherNumber: voucherNumber, voucherTypeLabel: voucherTypeLabel,
      orgName: effectiveOrg, branchName: branchName, date: date,
      customerOrSupplier: customerOrSupplier, customerCode: customerCode,
      customerAddress: customerAddress, customerContact: customerContact, customerPhone: customerPhone,
      salespersonName: salespersonName,
      status: status, remarks: remarks, lines: lines, focLines: focLines,
      subtotal: subtotal, discountTotal: discountTotal, grandTotal: grandTotal,
      preparedBy: preparedBy, createdAt: createdAt,
      approvedBy: approvedBy, approvedAt: approvedAt,
      approvedSignatureUrl: approvedSignatureUrl, stampUrl: stampUrl,
      checkedByLabel: checkedByLabel, checkedByName: checkedByName, checkedByAt: checkedByAt,
      checkedBySignatureUrl: checkedBySignatureUrl, checkedByStampUrl: checkedByStampUrl,
      footerNote: footerNote, relatedRefs: relatedRefs,
      watermark: watermark, docTitle: fileBase,
    );
    return doc.save();
  }

  static Future<pw.Document> _buildDoc({
    required String voucherNumber,
    required String voucherTypeLabel,
    required String orgName,
    String? branchName,
    String? date,
    String? customerOrSupplier,
    String? customerCode,
    String? customerAddress,
    String? customerContact,
    String? customerPhone,
    String? salespersonName,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    List<VoucherLine>? focLines, // free-of-cost lines, rendered in their own block
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? preparedBy,
    String? createdAt,
    String? approvedBy,
    String? approvedAt,
    String? approvedSignatureUrl,
    String? stampUrl,
    // Middle sign-off column. Defaults to a blank "Checked By" box; callers can
    // relabel it (e.g. 'Supervised By' for GRN) and supply a name/signature/stamp
    // so it prints like the Approved By column.
    String? checkedByLabel,
    String? checkedByName,
    String? checkedByAt,
    String? checkedBySignatureUrl,
    String? checkedByStampUrl,
    String? footerNote,
    Map<String, String>? relatedRefs,
    String? watermark, // optional diagonal page watermark, e.g. 'VOIDED'
    String? docTitle,
  }) async {
    final doc = pw.Document(
      title: docTitle,
      author: preparedBy,
      creator: 'Opstation ERP',
    );
    final showTotals = subtotal != null || discountTotal != null || grandTotal != null;
    final hasMoney = lines.any((l) => l.unitPrice != null || l.lineTotal != null);
    final isPurchase = _isPurchaseType(voucherTypeLabel);
    final showOrg = orgName.trim().isNotEmpty;

    // Approver for the "Approved By" signature column. Prefer structured params;
    // otherwise lift them out of a "Approved by <name> on <time>" footer note.
    String? apName = approvedBy;
    String? apTime = approvedAt;
    String? residualFooter = footerNote;
    // Lift an "Approved by <name> on <time>" line out of the footer note (it can
    // sit anywhere — e.g. appended after custom terms) into the Approved By
    // signature column, leaving the remaining note lines as the footer.
    if (apName == null && footerNote != null && footerNote.contains('Approved by ')) {
      final kept = <String>[];
      for (final ln in footerNote.split('\n')) {
        final m = RegExp(r'^Approved by (.+?) on (.+)$').firstMatch(ln.trim());
        if (m != null && apName == null) {
          apName = m.group(1);
          apTime = m.group(2);
        } else {
          kept.add(ln);
        }
      }
      final rest = kept.join('\n').trim();
      residualFooter = rest.isEmpty ? null : rest;
    }

    // Fetch the reviewer signature + org stamp (if any) for the Approved By box.
    pw.ImageProvider? sigImg;
    pw.ImageProvider? stampImg;
    if (approvedSignatureUrl != null && approvedSignatureUrl.isNotEmpty) {
      try { sigImg = await networkImage(approvedSignatureUrl); } catch (_) {}
    }
    if (stampUrl != null && stampUrl.isNotEmpty) {
      try { stampImg = await networkImage(stampUrl); } catch (_) {}
    }

    // Signature + stamp for the middle (Checked By / Supervised By) column.
    pw.ImageProvider? checkedSigImg;
    pw.ImageProvider? checkedStampImg;
    if (checkedBySignatureUrl != null && checkedBySignatureUrl.isNotEmpty) {
      try { checkedSigImg = await networkImage(checkedBySignatureUrl); } catch (_) {}
    }
    if (checkedByStampUrl != null && checkedByStampUrl.isNotEmpty) {
      try { checkedStampImg = await networkImage(checkedByStampUrl); } catch (_) {}
    }

    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        buildBackground: (watermark == null || watermark.isEmpty)
            ? null
            : (ctx) => pw.FullPage(
                  ignoreMargins: true,
                  child: pw.Center(
                    child: pw.Transform.rotate(
                      angle: 0.6,
                      child: pw.Opacity(
                        opacity: 0.12,
                        child: pw.Column(
                          mainAxisSize: pw.MainAxisSize.min,
                          children: [
                            pw.Text(
                              watermark,
                              style: pw.TextStyle(
                                fontSize: 130,
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColors.red,
                              ),
                            ),
                            pw.Text(
                              'This document is no longer valid',
                              style: pw.TextStyle(
                                fontSize: 22,
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColors.red,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
      ),
      header: (ctx) => ctx.pageNumber == 1
          ? pw.SizedBox.shrink()
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                pw.Text(orgName, style: pw.TextStyle(fontSize: 9, color: _muted)),
                pw.Text('$voucherTypeLabel  $voucherNumber',
                    style: pw.TextStyle(fontSize: 9, color: _muted, fontWeight: pw.FontWeight.bold)),
              ]),
            ),
      footer: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: pw.TextStyle(fontSize: 9, color: _muted)),
          pw.Text('Generated ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())}',
              style: pw.TextStyle(fontSize: 9, color: _muted)),
        ]),
      ),
      build: (ctx) => [
        // ── Header band ────────────────────────────────────────────────
        pw.Container(
          padding: const pw.EdgeInsets.all(16),
          decoration: pw.BoxDecoration(color: _bg, borderRadius: pw.BorderRadius.circular(8)),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                // Company name only. Branch is shown once, in the meta grid below.
                if (showOrg)
                  pw.Text(orgName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              ]),
            ),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              // When the company name is hidden the left header is blank, so
              // enlarge the doc-type title to anchor the header.
              pw.Text(voucherTypeLabel.toUpperCase(),
                  style: pw.TextStyle(
                      fontSize: showOrg ? 11 : 28,
                      color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 1.2)),
              pw.SizedBox(height: 4),
              pw.Text(voucherNumber, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _accent)),
              if (status != null) ...[
                pw.SizedBox(height: 4),
                pw.Text(status, style: pw.TextStyle(fontSize: 10, color: _muted)),
              ],
            ]),
          ]),
        ),

        pw.SizedBox(height: 14),

        // ── Meta grid ──────────────────────────────────────────────────
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Row(children: [
            if (date != null) _metaCell('Date', date),
            if (customerOrSupplier != null)
              _metaCell(isPurchase ? 'Supplier' : 'Customer', customerOrSupplier,
                  sub: (customerCode != null && customerCode.isNotEmpty)
                      ? 'Code: $customerCode'
                      : null),
            if (branchName != null) _metaCell('Branch', branchName),
            if (salespersonName != null) _metaCell('Salesperson', salespersonName),
          ]),
        ),

        // ── Related references (SO # in DO, SO+DO in SI) ────────────────
        if (relatedRefs != null && relatedRefs.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Row(children: [
              for (final e in relatedRefs.entries) _metaCell(e.key, e.value),
            ]),
          ),
        ],

        // ── Customer details (address / contact / phone) ────────────────
        if (customerAddress != null || customerContact != null || customerPhone != null) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(isPurchase ? 'SUPPLIER DETAILS' : 'BILL TO',
                  style: pw.TextStyle(fontSize: 8, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8)),
              pw.SizedBox(height: 4),
              if (customerAddress != null && customerAddress.isNotEmpty)
                pw.Text(customerAddress, style: pw.TextStyle(fontSize: 11)),
              if ((customerContact != null && customerContact.isNotEmpty) ||
                  (customerPhone != null && customerPhone.isNotEmpty)) ...[
                pw.SizedBox(height: 3),
                pw.Row(children: [
                  if (customerContact != null && customerContact.isNotEmpty)
                    pw.Text('Attn: $customerContact', style: pw.TextStyle(fontSize: 10, color: _muted)),
                  if (customerContact != null && customerContact.isNotEmpty &&
                      customerPhone != null && customerPhone.isNotEmpty)
                    pw.Text('  ·  ', style: pw.TextStyle(fontSize: 10, color: _muted)),
                  if (customerPhone != null && customerPhone.isNotEmpty)
                    pw.Text('Ph: $customerPhone', style: pw.TextStyle(fontSize: 10, color: _muted)),
                ]),
              ],
            ]),
          ),
        ],

        if (remarks != null && remarks.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('REMARKS', style: pw.TextStyle(fontSize: 8, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8)),
              pw.SizedBox(height: 4),
              pw.Text(remarks, style: pw.TextStyle(fontSize: 11)),
            ]),
          ),
        ],

        pw.SizedBox(height: 14),

        // ── Line items ─────────────────────────────────────────────────
        _itemsTable(lines, hasMoney),

        // ── Free of Cost items (qty only, no value) ────────────────────
        if (focLines != null && focLines.isNotEmpty) ...[
          pw.SizedBox(height: 14),
          pw.Row(children: [
            pw.Text('Free of Cost Items', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
            pw.SizedBox(width: 6),
            pw.Text('(no invoice value)', style: pw.TextStyle(fontSize: 9, color: _muted)),
          ]),
          pw.SizedBox(height: 4),
          _itemsTable(focLines, false),
        ],

        // ── Total quantity (all lines, paid + FOC) ─────────────────────
        pw.SizedBox(height: 6),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Total Quantity: ' + _stNum(lines.fold<double>(0, (s, l) => s + l.qty) + (focLines?.fold<double>(0, (s, l) => s + l.qty) ?? 0)),
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
        ),

        // ── Totals ─────────────────────────────────────────────────────
        if (showTotals) ...[
          pw.SizedBox(height: 12),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Container(
              width: 220,
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
              child: pw.Column(children: [
                if (subtotal != null) _totalRow('Subtotal', _n4(subtotal)),
                if (discountTotal != null && discountTotal > 0)
                  _totalRow('Discount', '- ${_n4(discountTotal)}', color: PdfColors.orange),
                if (grandTotal != null) ...[
                  pw.Divider(color: _border, height: 8),
                  _totalRow('Grand Total', _n4(grandTotal), bold: true),
                ],
              ]),
            ),
          ),
        ],

        // ── Signature blocks ───────────────────────────────────────────
        pw.SizedBox(height: 36),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          _signatureBlock('Prepared By', preparedBy, sub: createdAt),
          _signatureBlock(checkedByLabel ?? 'Checked By', checkedByName, sub: checkedByAt, signature: checkedSigImg, stamp: checkedStampImg),
          _signatureBlock('Approved By', apName, sub: apTime, signature: sigImg, stamp: stampImg),
        ]),

        // ── Terms & Conditions / Additional Information ────────────────
        if (residualFooter != null && residualFooter.isNotEmpty) ...[
          pw.SizedBox(height: 18),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: _bg,
              border: pw.Border.all(color: _border),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Row(children: [
                pw.Container(width: 3, height: 11,
                    decoration: pw.BoxDecoration(color: _accent, borderRadius: pw.BorderRadius.circular(2))),
                pw.SizedBox(width: 6),
                pw.Text('TERMS & CONDITIONS / ADDITIONAL INFORMATION',
                    style: pw.TextStyle(fontSize: 8, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8)),
              ]),
              pw.SizedBox(height: 7),
              for (final ln in residualFooter.split('\n'))
                if (ln.trim().isNotEmpty)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 3),
                    child: pw.Text(ln.trim(),
                        style: pw.TextStyle(fontSize: 9.5, color: PdfColors.grey800, lineSpacing: 1.2)),
                  ),
            ]),
          ),
        ],
      ],
    ));

    return doc;
  }

  /// A sign-off column: underlined label, the signer's name, and an optional
  /// small timestamp under the name.
  static pw.Widget _signatureBlock(String label, String? name, {String? sub, pw.ImageProvider? signature, pw.ImageProvider? stamp}) {
    return pw.Expanded(
      child: pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          // Signature + stamp sit just above the sign-off line. The fixed height
          // keeps all three columns' lines aligned, signed or not.
          pw.Container(
            height: 34,
            alignment: pw.Alignment.center,
            child: (signature == null && stamp == null)
                ? pw.SizedBox()
                : pw.Stack(alignment: pw.Alignment.center, children: [
                    if (stamp != null) pw.Opacity(opacity: 0.9, child: pw.Image(stamp, height: 34)),
                    if (signature != null) pw.Image(signature, height: 26),
                  ]),
          ),
          pw.Container(
            width: double.infinity,
            decoration: pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _muted))),
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Column(children: [
              pw.Text(label,
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline)),
              pw.SizedBox(height: 4),
              pw.Text(name ?? ' ', style: pw.TextStyle(fontSize: 11, color: _muted)),
              if (sub != null && sub.trim().isNotEmpty) ...[
                pw.SizedBox(height: 2),
                pw.Text(sub, style: pw.TextStyle(fontSize: 8, color: _muted)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  static pw.Widget _metaCell(String label, String value, {String? sub}) {
    return pw.Expanded(
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(label.toUpperCase(),
            style: pw.TextStyle(fontSize: 8, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8)),
        pw.SizedBox(height: 3),
        pw.Text(value, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        if (sub != null && sub.isNotEmpty) ...[
          pw.SizedBox(height: 2),
          pw.Text(sub, style: pw.TextStyle(fontSize: 9, color: _muted)),
        ],
      ]),
    );
  }

  static pw.Widget _totalRow(String label, String value, {bool bold = false, PdfColor? color}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(label,
            style: pw.TextStyle(fontSize: bold ? 12 : 10, color: color ?? _muted,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        pw.Text(value,
            style: pw.TextStyle(fontSize: bold ? 14 : 11, color: color,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      ]),
    );
  }

  static pw.Widget _itemsTable(List<VoucherLine> lines, bool hasMoney) {
    final headers = hasMoney
        ? ['#', 'Product', 'UOM', 'Qty', 'Unit Price', 'Discount', 'Disc. Price', 'Line Total']
        : ['#', 'Product', 'UOM', 'Qty'];
    final flex = hasMoney ? [1, 5, 1, 2, 2, 2, 2, 2] : [1, 8, 1, 2];

    return pw.Table(
      border: pw.TableBorder.all(color: _border, width: 0.5),
      columnWidths: {
        for (var i = 0; i < flex.length; i++) i: pw.FlexColumnWidth(flex[i].toDouble()),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _bg),
          children: headers.map((h) => pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: pw.Text(h, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _muted)),
          )).toList(),
        ),
        ...lines.asMap().entries.map((entry) {
          final i = entry.key; final l = entry.value;
          final cells = hasMoney
              ? [
                  '${i + 1}',
                  l.product + (l.sku != null ? '\n${l.sku}' : ''),
                  l.uom ?? '-',
                  _n4(l.qty),
                  l.unitPrice != null ? _n4(l.unitPrice) : '-',
                  l.discountPct != null ? '${_n4(l.discountPct)}%' : '-',
                  l.unitPrice != null ? _n4(l.unitPrice! * (1 - (l.discountPct ?? 0) / 100)) : '-',
                  l.lineTotal != null ? _n4(l.lineTotal) : '-',
                ]
              : [
                  '${i + 1}',
                  l.product + (l.sku != null ? '\n${l.sku}' : ''),
                  l.uom ?? '-',
                  _n4(l.qty),
                ];
          return pw.TableRow(
            children: cells.map((c) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: pw.Text(c, style: const pw.TextStyle(fontSize: 10)),
            )).toList(),
          );
        }),
      ],
    );
  }
}

class VoucherLine {
  final String product;
  final String? sku;
  final String? uom;
  final double qty;
  final double? unitPrice;
  final double? discountPct;
  final double? lineTotal;

  VoucherLine({
    required this.product,
    this.sku,
    this.uom,
    required this.qty,
    this.unitPrice,
    this.discountPct,
    this.lineTotal,
  });
}
