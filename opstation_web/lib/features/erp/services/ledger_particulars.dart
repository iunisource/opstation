import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';

/// One product line of a voucher, for the ledger's Detailed view.
class LedgerItemRow {
  final String name;
  final double qty;
  final double rate;
  final double discount;
  final double amount;
  final bool free;
  const LedgerItemRow(this.name, this.qty, this.rate, this.discount, this.amount, this.free);
}

/// Particulars of one invoice-type voucher: its product lines plus header
/// extras (invoice discount, tax, freight, supplier bill no, POS payment).
class LedgerDetail {
  final List<LedgerItemRow> rows;
  final List<String> extras;
  const LedgerDetail(this.rows, this.extras);

  bool get isEmpty => rows.isEmpty && extras.isEmpty;

  /// One-line text for Print / Share / Excel.
  String get text {
    final parts = [
      for (final r in rows)
        r.free
            ? '${r.name} ${LedgerParticulars.qty(r.qty)} (free)'
            : '${r.name} ${LedgerParticulars.qty(r.qty)} × ${money(r.rate)}'
                '${r.discount >= 0.01 ? ' − disc ${money(r.discount)}' : ''} = ${money(r.amount)}',
      ...extras,
    ];
    return parts.join('  ·  ');
  }
}

/// "Detailed view" for the customer / supplier ledgers: the products,
/// quantities, rates and discounts of each invoice-type voucher.
///
/// Receipts, payments and journals are left out on purpose — their own
/// descriptions already carry the detail.
///
/// Loaded in batches per voucher type (never one query per row), and every
/// column is read defensively, so a missing column only leaves that detail out.
class LedgerParticulars {
  static String keyOf(Map<String, dynamic> e) =>
      '${_group(e['type'] as String? ?? '')}|${e['id'] ?? ''}';

  static String _group(String type) {
    switch (type) {
      case 'Sales Invoice':
        return 'SI';
      case 'Sale Return':
        return 'SRI';
      case 'POS Sale':
      case 'POS Return':
        return 'POS';
      case 'Purchase Invoice':
        return 'PI';
      case 'Purchase Return':
        return 'PRI';
      default:
        return '';
    }
  }

  static Future<Map<String, LedgerDetail>> load(List<Map<String, dynamic>> entries) async {
    final client = Supabase.instance.client;
    final ids = <String, Set<String>>{};
    for (final e in entries) {
      final g = _group(e['type'] as String? ?? '');
      final id = e['id'] as String?;
      if (g.isEmpty || id == null || id.isEmpty) continue;
      ids.putIfAbsent(g, () => <String>{}).add(id);
    }
    final out = <String, LedgerDetail>{};
    final jobs = <Future<void>>[];

    void items(String g, String headerTable, String itemTable, String fk) {
      final list = ids[g];
      if (list == null || list.isEmpty) return;
      jobs.add(() async {
        try {
          final headers = await _byIds(client, headerTable, 'id', list.toList());
          final lines = await _byIds(client, itemTable, fk, list.toList());
          final names = await _productNames(client, lines);
          final byDoc = <String, List<Map<String, dynamic>>>{};
          for (final l in lines) {
            final k = l[fk]?.toString();
            if (k != null) byDoc.putIfAbsent(k, () => []).add(l);
          }
          final hMap = {for (final h in headers) h['id'].toString(): h};
          for (final id in list) {
            final d = _detail(hMap[id], byDoc[id] ?? const [], names);
            if (!d.isEmpty) out['$g|$id'] = d;
          }
        } catch (_) {/* detail is optional */}
      }());
    }

    items('SI', 'sales_invoices', 'sales_invoice_items', 'invoice_id');
    items('SRI', 'sales_return_invoices', 'sales_return_invoice_items', 'invoice_id');
    items('POS', 'pos_transactions', 'pos_transaction_items', 'transaction_id');
    items('PI', 'purchase_invoices', 'purchase_invoice_items', 'invoice_id');
    items('PRI', 'purchase_return_invoices', 'purchase_return_invoice_items', 'voucher_id');

    await Future.wait(jobs);
    return out;
  }

  static LedgerDetail _detail(Map<String, dynamic>? h, List<Map<String, dynamic>> lines,
      Map<String, String> names) {
    final rows = <LedgerItemRow>[];
    for (final l in lines) {
      final q = _firstNonZero(l, const ['qty_delivered', 'quantity', 'qty', 'qty_received', 'qty_returned']);
      final p = _firstNonZero(l, const ['unit_price', 'price', 'rate', 'unit_cost']);
      final stored = l['line_total'] ?? l['total'] ?? l['amount'];
      final t = stored is num ? stored.toDouble() : q * p;
      final name = names[l['product_id']?.toString()] ??
          (l['product_name'] ?? l['description'] ?? 'Item').toString();
      final foc = l['is_foc'] == true;
      final disc = (q * p - t) >= 0.01 && t > 0 ? q * p - t : 0.0;
      rows.add(LedgerItemRow(name, q, p, disc, foc ? 0 : t, foc));
    }
    final extras = <String>[];
    if (h != null) {
      final disc = _firstNonZero(h, const ['discount_total', 'discount_amount', 'invoice_discount']);
      if (disc > 0) extras.add('Discount ${money(disc)}');
      final tax = _firstNonZero(h, const ['tax_total', 'tax_amount', 'sales_tax', 'gst_amount']);
      if (tax > 0) extras.add('Tax ${money(tax)}');
      final frt = _firstNonZero(h, const ['freight', 'freight_charges', 'delivery_charges', 'shipping']);
      if (frt > 0) extras.add('Freight ${money(frt)}');
      final bill = _firstText(h, const ['supplier_invoice_number', 'supplier_invoice_no', 'supplier_bill_no', 'bill_no', 'bill_number', 'reference_no']);
      if (bill.isNotEmpty) extras.add('Bill $bill');
      final pm = _firstText(h, const ['payment_method']);
      if (pm.isNotEmpty) extras.add(pm);
    }
    return LedgerDetail(rows, extras);
  }

  /// The small product grid shown under the description.
  static Widget table(LedgerDetail d) {
    const head = TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
    const cell = TextStyle(fontSize: 10.5, color: AppTheme.textPrimary);
    final showDisc = d.rows.any((r) => r.discount >= 0.01);
    Widget c(String s, TextStyle st, {bool right = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Text(s, style: st, textAlign: right ? TextAlign.right : TextAlign.left),
        );
    final children = <Widget>[];
    if (d.rows.isNotEmpty) {
      children.add(ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Table(
          border: TableBorder.all(color: AppTheme.border, width: 0.6),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: {
            0: const FlexColumnWidth(4),
            1: const FlexColumnWidth(1.1),
            2: const FlexColumnWidth(1.5),
            if (showDisc) 3: const FlexColumnWidth(1.4),
            (showDisc ? 4 : 3): const FlexColumnWidth(1.7),
          },
          children: [
            TableRow(
              decoration: const BoxDecoration(color: AppTheme.background),
              children: [
                c('Product', head),
                c('Qty', head, right: true),
                c('Rate', head, right: true),
                if (showDisc) c('Disc', head, right: true),
                c('Amount', head, right: true),
              ],
            ),
            for (final r in d.rows)
              TableRow(children: [
                c(r.free ? '${r.name} (free)' : r.name, cell),
                c(qty(r.qty), cell, right: true),
                c(r.free ? '—' : money(r.rate), cell, right: true),
                if (showDisc) c(r.discount >= 0.01 ? money(r.discount) : '—', cell, right: true),
                c(r.free ? '—' : money(r.amount), cell, right: true),
              ]),
          ],
        ),
      ));
    }
    if (d.extras.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(d.extras.join('  ·  '),
            style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> _byIds(
      SupabaseClient client, String table, String col, List<String> ids) async {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
      final rows = await client.from(table).select('*').inFilter(col, chunk);
      for (final r in rows as List) {
        out.add(Map<String, dynamic>.from(r as Map));
      }
    }
    return out;
  }

  static Future<Map<String, String>> _productNames(
      SupabaseClient client, List<Map<String, dynamic>> lines) async {
    final ids = <String>{
      for (final l in lines)
        if ((l['product_id'] ?? '').toString().isNotEmpty) l['product_id'].toString()
    }.toList();
    final out = <String, String>{};
    if (ids.isEmpty) return out;
    try {
      for (var i = 0; i < ids.length; i += 100) {
        final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
        final rows = await client.from('products').select('id, name').inFilter('id', chunk);
        for (final r in rows as List) {
          out[r['id'].toString()] = (r['name'] ?? '').toString();
        }
      }
    } catch (_) {}
    return out;
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }

  static double _firstNonZero(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = _num(m[k]);
      if (v != 0) return v;
    }
    return 0;
  }

  static String _firstText(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  static String qty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}
