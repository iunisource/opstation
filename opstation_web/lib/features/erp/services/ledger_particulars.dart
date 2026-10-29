import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';

/// "Detailed view" for the customer / supplier ledgers: the particulars of
/// each voucher (products, quantities, rates, discounts, payment mode,
/// cheque, the other side of a journal…) as one short line of text.
///
/// Everything is loaded in batches per voucher type, never one query per row.
/// Every column is read defensively, so a missing column only leaves that
/// detail out instead of breaking the ledger.
class LedgerParticulars {
  /// Key used to look up the particulars of a ledger entry.
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
      case 'Receipt (CRV)':
        return 'CRV';
      case 'Payment (CPV)':
        return 'CPV';
      case 'Journal (JV)':
      case 'Opening Balance':
      case 'Job-work Fee':
        return 'JV';
      default:
        return ''; // settlement lines (Paid at POS, cash refund) have no own particulars
    }
  }

  /// Loads particulars for [entries]. [partyId] is the customer / supplier, so
  /// a journal shows only the OTHER side of the entry.
  static Future<Map<String, String>> load(
      List<Map<String, dynamic>> entries, String partyId) async {
    final client = Supabase.instance.client;
    final ids = <String, Set<String>>{};
    for (final e in entries) {
      final g = _group(e['type'] as String? ?? '');
      final id = e['id'] as String?;
      if (g.isEmpty || id == null || id.isEmpty) continue;
      ids.putIfAbsent(g, () => <String>{}).add(id);
    }
    final out = <String, String>{};
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
            final txt = _docText(hMap[id], byDoc[id] ?? const [], names);
            if (txt.isNotEmpty) out['$g|$id'] = txt;
          }
        } catch (_) {/* detail is optional */}
      }());
    }

    items('SI', 'sales_invoices', 'sales_invoice_items', 'invoice_id');
    items('SRI', 'sales_return_invoices', 'sales_return_invoice_items', 'invoice_id');
    items('POS', 'pos_transactions', 'pos_transaction_items', 'transaction_id');
    items('PI', 'purchase_invoices', 'purchase_invoice_items', 'invoice_id');
    items('PRI', 'purchase_return_invoices', 'purchase_return_invoice_items', 'voucher_id');

    for (final g in const ['CRV', 'CPV']) {
      final list = ids[g];
      if (list == null || list.isEmpty) continue;
      jobs.add(() async {
        try {
          final table = g == 'CRV' ? 'crv_vouchers' : 'cpv_vouchers';
          final lineTable = g == 'CRV' ? 'crv_voucher_lines' : 'cpv_voucher_lines';
          final headers = await _byIds(client, table, 'id', list.toList());
          final lines = await _byIds(client, lineTable, 'voucher_id', list.toList());
          final accIds = <String>{
            for (final h in headers)
              for (final k in const ['account_id', 'cash_account_id', 'bank_account_id', 'payment_account_id', 'deposit_account_id'])
                if ((h[k] ?? '').toString().isNotEmpty) h[k].toString(),
          };
          final accNames = await _accountNames(client, accIds.toList());
          final otherLines = <String, int>{};
          for (final l in lines) {
            final vid = l['voucher_id']?.toString();
            if (vid != null && l['account_id']?.toString() != partyId) {
              otherLines[vid] = (otherLines[vid] ?? 0) + 1;
            }
          }
          for (final h in headers) {
            final id = h['id'].toString();
            final txt = _payText(h, accNames, otherLines[id] ?? 0);
            if (txt.isNotEmpty) out['$g|$id'] = txt;
          }
        } catch (_) {}
      }());
    }

    final jv = ids['JV'];
    if (jv != null && jv.isNotEmpty) {
      jobs.add(() async {
        try {
          final lines = await _byIds(client, 'journal_lines', 'entry_id', jv.toList());
          final accNames = await _accountNames(client, [
            for (final l in lines)
              if ((l['account_id'] ?? '').toString().isNotEmpty) l['account_id'].toString()
          ]);
          final byEntry = <String, List<Map<String, dynamic>>>{};
          for (final l in lines) {
            final k = l['entry_id']?.toString();
            if (k != null) byEntry.putIfAbsent(k, () => []).add(l);
          }
          for (final id in jv) {
            final parts = <String>[];
            for (final l in byEntry[id] ?? const <Map<String, dynamic>>[]) {
              if (l['party_id']?.toString() == partyId) continue; // this party's own line
              final dr = _num(l['debit']);
              final cr = _num(l['credit']);
              if (dr == 0 && cr == 0) continue;
              final acc = accNames[l['account_id']?.toString()] ??
                  (l['description']?.toString().trim().isNotEmpty == true ? l['description'].toString().trim() : 'Account');
              parts.add('${dr > 0 ? 'Dr' : 'Cr'} $acc ${money(dr > 0 ? dr : cr)}');
            }
            if (parts.isNotEmpty) out['JV|$id'] = _cap(parts, 8);
          }
        } catch (_) {}
      }());
    }

    await Future.wait(jobs);
    return out;
  }

  // ── Formatting ────────────────────────────────────────────────────────────

  static String _docText(Map<String, dynamic>? h, List<Map<String, dynamic>> lines,
      Map<String, String> names) {
    final parts = <String>[];
    for (final l in lines) {
      final q = _firstNonZero(l, const ['qty_delivered', 'quantity', 'qty', 'qty_received', 'qty_returned']);
      final p = _firstNonZero(l, const ['unit_price', 'price', 'rate', 'unit_cost']);
      final stored = l['line_total'] ?? l['total'] ?? l['amount'];
      final t = stored is num ? stored.toDouble() : q * p;
      final name = names[l['product_id']?.toString()] ??
          (l['product_name'] ?? l['description'] ?? 'Item').toString();
      final foc = l['is_foc'] == true;
      var s = '$name ${_qty(q)}';
      if (foc) {
        s += ' (free)';
      } else if (p > 0) {
        s += ' × ${money(p)}';
        final gross = q * p;
        if ((gross - t).abs() >= 0.01 && t > 0) s += ' − disc ${money(gross - t)}';
        s += ' = ${money(t)}';
      }
      parts.add(s);
    }
    var text = _cap(parts, 12);
    if (h != null) {
      final extras = <String>[];
      final disc = _firstNonZero(h, const ['discount_total', 'discount_amount', 'discount', 'invoice_discount']);
      if (disc > 0) extras.add('Discount ${money(disc)}');
      final tax = _firstNonZero(h, const ['tax_total', 'tax_amount', 'sales_tax', 'gst_amount']);
      if (tax > 0) extras.add('Tax ${money(tax)}');
      final frt = _firstNonZero(h, const ['freight', 'freight_charges', 'delivery_charges', 'shipping']);
      if (frt > 0) extras.add('Freight ${money(frt)}');
      final bill = _firstText(h, const ['supplier_invoice_number', 'supplier_invoice_no', 'supplier_bill_no', 'bill_no', 'bill_number', 'reference_no']);
      if (bill.isNotEmpty) extras.add('Bill $bill');
      final pm = _firstText(h, const ['payment_method']);
      if (pm.isNotEmpty) extras.add(pm);
      if (extras.isNotEmpty) text = text.isEmpty ? extras.join(' · ') : '$text  ·  ${extras.join(' · ')}';
    }
    return text;
  }

  static String _payText(Map<String, dynamic> h, Map<String, String> accNames, int otherLines) {
    final parts = <String>[];
    final mode = _firstText(h, const ['payment_mode', 'payment_method', 'mode', 'payment_type', 'instrument_type']);
    if (mode.isNotEmpty) parts.add(_titleCase(mode));
    for (final k in const ['account_id', 'cash_account_id', 'bank_account_id', 'payment_account_id', 'deposit_account_id']) {
      final n = accNames[(h[k] ?? '').toString()];
      if (n != null) {
        parts.add(n);
        break;
      }
    }
    final chq = _firstText(h, const ['cheque_number', 'cheque_no', 'instrument_no', 'instrument_number', 'transaction_ref', 'reference_number', 'reference_no']);
    if (chq.isNotEmpty) parts.add('Chq/Ref $chq');
    final bank = _firstText(h, const ['bank_name', 'drawee_bank', 'cheque_bank', 'bank']);
    if (bank.isNotEmpty) parts.add(bank);
    final cd = _firstText(h, const ['cheque_date', 'instrument_date']);
    if (cd.length >= 10) parts.add('dated ${cd.substring(0, 10)}');
    final narr = _firstText(h, const ['narration', 'description', 'remarks', 'notes', 'memo']);
    if (narr.isNotEmpty) parts.add(narr);
    if (otherLines > 0) parts.add('+$otherLines other line${otherLines == 1 ? '' : 's'} on this voucher');
    return parts.join(' · ');
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

  static Future<Map<String, String>> _accountNames(SupabaseClient client, List<String> ids) async {
    final out = <String, String>{};
    final uniq = ids.toSet().toList();
    if (uniq.isEmpty) return out;
    try {
      for (var i = 0; i < uniq.length; i += 100) {
        final chunk = uniq.sublist(i, i + 100 > uniq.length ? uniq.length : i + 100);
        final rows = await client.from('chart_of_accounts').select('id, name').inFilter('id', chunk);
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

  static String _qty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  static String _titleCase(String s) {
    final t = s.replaceAll('_', ' ').trim();
    return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
  }

  static String _cap(List<String> parts, int max) {
    if (parts.length <= max) return parts.join('  ·  ');
    return '${parts.take(max).join('  ·  ')}  ·  +${parts.length - max} more';
  }
}
