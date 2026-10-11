// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:intl/intl.dart';

/// Shared print for Cash Payment / Cash Receipt vouchers, in the same design as
/// the Journal Voucher print (blue title, meta row, blue-header striped grid,
/// totals band, signature footprints) plus the amount in words.
class CashVoucherLine {
  final String account;
  final String description;
  final double amount;
  const CashVoucherLine(this.account, this.description, this.amount);
}

class CashVoucherFootprint {
  final String label;
  final String who;
  final String when;
  final bool done;
  const CashVoucherFootprint(this.label, this.who, {this.when = '', this.done = true});
}

String _esc(String? v) => (v ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// "Rupees Twelve Thousand Five Hundred Only" (lakh / crore grouping).
String amountInWordsPkr(double amount) {
  const ones = [
    '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve',
    'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'
  ];
  const tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
  String two(int n) => n < 20 ? ones[n] : '${tens[n ~/ 10]}${n % 10 > 0 ? ' ${ones[n % 10]}' : ''}';
  String three(int n) {
    final h = n ~/ 100, r = n % 100;
    return [if (h > 0) '${ones[h]} Hundred', if (r > 0) two(r)].join(' ');
  }

  final neg = amount < 0;
  final a = amount.abs();
  var rupees = a.floor();
  final paisa = ((a - rupees) * 100).round();
  if (rupees == 0 && paisa == 0) return 'Rupees Zero Only';
  final parts = <String>[];
  final crore = rupees ~/ 10000000;
  rupees %= 10000000;
  final lakh = rupees ~/ 100000;
  rupees %= 100000;
  final thousand = rupees ~/ 1000;
  rupees %= 1000;
  if (crore > 0) parts.add('${crore >= 100 ? three(crore) : two(crore)} Crore');
  if (lakh > 0) parts.add('${two(lakh)} Lakh');
  if (thousand > 0) parts.add('${two(thousand)} Thousand');
  if (rupees > 0) parts.add(three(rupees));
  var s = 'Rupees ${parts.isEmpty ? 'Zero' : parts.join(' ')}';
  if (paisa > 0) s += ' and ${two(paisa)} Paisa';
  return '${neg ? 'Minus ' : ''}$s Only';
}

void openCashVoucherPrint({
  required String title,
  required String voucherNo,
  required DateTime date,
  required String cashLabel, // e.g. "Paid from" / "Received in"
  required String cashAccount,
  required String status,
  required String partyHeader, // e.g. "Paid to (Account / Party)"
  required List<CashVoucherLine> lines,
  required List<CashVoucherFootprint> footprints,
  String orgName = '',
  String branchName = '',
}) {
  final money = NumberFormat('#,##0.00');
  final total = lines.fold<double>(0, (s, l) => s + l.amount);
  final rows = lines.asMap().entries.map((e) => '<tr><td>${e.key + 1}</td><td>${_esc(e.value.account)}</td>'
      '<td>${_esc(e.value.description)}</td><td class="num">${money.format(e.value.amount)}</td></tr>').join();
  final fps = footprints
      .map((f) => '<div class="fp${f.done ? '' : ' pending'}"><div class="sig-space"></div><div class="line"></div>'
          '<b>${_esc(f.who.isEmpty ? ' ' : f.who)}</b><span>${_esc(f.label)}${f.when.isEmpty ? '' : ' · ${_esc(f.when)}'}</span></div>')
      .join();
  final st = status.toUpperCase();
  final stColor = st == 'POSTED' ? '#2f855a' : (st == 'VOID' || st == 'VOIDED' ? '#c53030' : '#b7791f');
  final htmlStr = '''<!DOCTYPE html><html><head><meta charset="UTF-8"><title>${_esc(title)} ${_esc(voucherNo)}</title><style>@page{margin:0}
    body{font-family:-apple-system,Segoe UI,Arial,sans-serif;padding:16px;color:#2d3748}
    .org{text-align:center;font-size:10px;font-weight:700;letter-spacing:1.5px;color:#4a5568;text-transform:uppercase}
    h2{text-align:center;color:#1a56db;margin:1px 0 4px;font-size:17px;letter-spacing:.4px}
    table.grid{width:100%;border-collapse:collapse;margin-top:8px;font-size:11px;line-height:1.3}
    table.grid th,table.grid td{padding:4px 7px;text-align:left;vertical-align:top}
    table.grid thead th{background:#1a56db;color:#fff;font-weight:600;border:none;-webkit-print-color-adjust:exact;print-color-adjust:exact}
    table.grid tbody td{border-bottom:1px solid #e2e8f0}
    table.grid tbody tr:nth-child(even) td{background:#f8fafc;-webkit-print-color-adjust:exact;print-color-adjust:exact}
    table.grid tfoot td{border-top:2px solid #1a56db;background:#f0f4ff;-webkit-print-color-adjust:exact;print-color-adjust:exact}
    .total{font-weight:700}.num{text-align:right}
    .meta td{border:none;font-size:10px;padding:0 12px 1px 0}
    .words{margin-top:5px;font-size:10.5px;color:#2d3748}
    .words b{color:#1a56db}
    .fps{margin-top:22px;display:flex;gap:14px}
    .fp{flex:1;position:relative;font-size:10px;line-height:1.35}
    .fp .line{border-top:1px solid #718096;margin-bottom:4px}
    .fp b{display:block;font-size:11px;color:#1a202c;min-height:14px}
    .fp span{color:#718096}
    .fp.pending b{color:#a0aec0}
    .fp .sig-space{height:28px}
    @media print{.no-print{display:none}@page{margin:0}body{padding:10mm 14mm}}
  </style></head><body>
  <div class="no-print" style="margin-bottom:16px"><button onclick="window.print()">Print</button></div>
  ${orgName.isEmpty ? '' : '<div class="org">${_esc(orgName)}</div>'}
  <h2>${_esc(title)}</h2>
  <table class="meta" style="border:none;margin-bottom:5px"><tr>
    <td><b>Voucher#:</b> ${_esc(voucherNo)}</td>
    <td><b>Date:</b> ${DateFormat('dd MMM yyyy').format(date)}</td>
    ${branchName.isEmpty ? '' : '<td><b>Branch:</b> ${_esc(branchName)}</td>'}
    <td><b>Status:</b> <span style="color:$stColor;font-weight:700">$st</span></td>
  </tr><tr><td colspan="4"><b>${_esc(cashLabel)}:</b> ${_esc(cashAccount)}</td></tr></table>
  <table class="grid"><thead><tr><th style="width:22px">#</th><th>${_esc(partyHeader)}</th><th>Description</th><th class="num" style="width:110px">Amount (Rs.)</th></tr></thead><tbody>
  $rows
  </tbody><tfoot><tr><td colspan="3" class="total num">Total:</td><td class="total num">${money.format(total)}</td></tr></tfoot></table>
  <div class="words"><b>Amount in words:</b> ${_esc(amountInWordsPkr(total))}</div>
  <div class="fps">$fps</div>
  </body></html>''';
  final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
  html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
}
