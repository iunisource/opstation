import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import '../../../core/services/retailer_invoice_pdf.dart';
import '../retailer_auth_controller.dart';
import 'retailer_shell.dart';

/// The retailer's own account ledger.
///
/// Reuses the exact netting the staff/web ledger uses: retailer_my_ledger()
/// returns the raw source rows (invoices, POS, returns, receipts/payments,
/// journals) and the same _build() math runs here so the running balance never
/// drifts between web and app. Debit = owed by the customer; Credit =
/// paid/returned.
///
/// Sales-Invoice rows are hyperlinked — tapping one opens the actual invoice
/// PDF (retailer_invoice_detail -> native PDF), matching the web portal.
class RetailerLedgerScreen extends ConsumerStatefulWidget {
  const RetailerLedgerScreen({super.key});

  @override
  ConsumerState<RetailerLedgerScreen> createState() =>
      _RetailerLedgerScreenState();
}

class _RetailerLedgerScreenState extends ConsumerState<RetailerLedgerScreen> {
  bool _loading = true;
  bool _allowed = true;
  String? _openingId;
  List<Map<String, dynamic>> _entries = [];
  double _debit = 0, _credit = 0, _balance = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _dateStr(Map m, List<String> keys) {
    for (final k in keys) {
      final val = m[k];
      if (val == null) continue;
      final s = val.toString();
      if (s.isNotEmpty && s != 'null' && DateTime.tryParse(s) != null) return s;
    }
    return '';
  }

  static double _amt(Map m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is num) return v.toDouble();
      if (v is String) {
        final p = double.tryParse(v);
        if (p != null) return p;
      }
    }
    return 0;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_ledger');
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (m['visible'] == false) {
        if (mounted) {
          setState(() {
            _allowed = false;
            _loading = false;
          });
        }
        return;
      }
      final entries = _build(m);
      double d = 0, c = 0, bal = 0;
      for (final e in entries) {
        d += e['debit'] as double;
        c += e['credit'] as double;
        bal += (e['debit'] as double) - (e['credit'] as double);
        e['balance'] = bal;
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _debit = d;
        _credit = c;
        _balance = bal;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) _snack(T.of(context).somethingWentWrong);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  // Same sourcing/netting as the staff ledger, over the raw rows the RPC
  // returns. Sales-Invoice rows additionally carry their invoice_id so the row
  // can open its PDF.
  List<Map<String, dynamic>> _build(Map<String, dynamic> m) {
    final out = <Map<String, dynamic>>[];
    List asList(String k) => (m[k] as List?) ?? const [];

    for (final raw in asList('sales_invoices')) {
      final si = Map<String, dynamic>.from(raw as Map);
      if (si['is_voided'] == true) continue;
      final total = _amt(si, const ['total', 'total_amount', 'grand_total', 'net_amount']);
      if (total <= 0) continue;
      out.add({
        'date': _dateStr(si, const ['voucher_date', 'invoice_date', 'si_date', 'date', 'posted_at', 'created_at']),
        'voucher': (si['invoice_number'] ?? si['voucher_number'] ?? si['si_number'] ?? '').toString(),
        'description': (si['remarks'] as String?)?.trim() ?? '',
        'debit': total,
        'credit': 0.0,
        'type': 'Sales Invoice',
        'invoice_id': si['id'],
      });
    }

    final pos = [for (final t in asList('pos_transactions')) Map<String, dynamic>.from(t as Map)];
    final posById = {for (final t in pos) if (t['id'] is String) t['id'] as String: t};
    for (final t in pos) {
      final ttype = (t['transaction_type'] as String?) ?? 'sale';
      final raw = _amt(t, const ['total']);
      if (ttype == 'expense' || raw == 0) continue;
      final vno = (t['transaction_number'] as String?)?.isNotEmpty == true
          ? t['transaction_number'] as String
          : 'POS';
      final amt = raw.abs();
      final isReturn = ttype == 'return' || raw < 0;
      final dateStr = (t['transacted_at'] ?? t['created_at'] ?? '').toString();
      if (isReturn) {
        out.add({'date': dateStr, 'voucher': vno, 'description': '', 'debit': 0.0, 'credit': amt, 'type': 'POS Return'});
        double cashRefund = amt;
        Map<String, dynamic>? orig;
        for (final f in const ['reference_transaction_id', 'original_transaction_id', 'parent_transaction_id', 'ref_transaction_id', 'reference_id']) {
          final rid = t[f];
          if (rid is String && posById[rid] != null) {
            orig = posById[rid];
            break;
          }
        }
        if (orig != null) {
          final ot = _amt(orig, const ['total']);
          final op = orig['amount_paid'] == null ? ot : _amt(orig, const ['amount_paid']);
          cashRefund = (amt - (ot - op)).clamp(0.0, amt).toDouble();
        }
        if (cashRefund > 0) {
          out.add({'date': dateStr, 'voucher': vno, 'description': 'Cash refund', 'debit': cashRefund, 'credit': 0.0, 'type': 'POS Refund (Cash)'});
        }
      } else {
        out.add({'date': dateStr, 'voucher': vno, 'description': '', 'debit': amt, 'credit': 0.0, 'type': 'POS Sale'});
        final paid = (t['amount_paid'] == null ? amt : _amt(t, const ['amount_paid'])).clamp(0.0, amt).toDouble();
        if (paid > 0) {
          out.add({'date': dateStr, 'voucher': vno, 'description': 'Paid at POS', 'debit': 0.0, 'credit': paid, 'type': 'POS Payment'});
        }
      }
    }

    for (final raw in asList('sales_return_invoices')) {
      final sr = Map<String, dynamic>.from(raw as Map);
      if (sr['is_voided'] == true) continue;
      final total = _amt(sr, const ['total', 'total_amount', 'grand_total', 'amount', 'net_amount', 'return_total', 'refund_amount', 'value', 'subtotal']);
      if (total <= 0) continue;
      out.add({
        'date': _dateStr(sr, const ['return_date', 'invoice_date', 'voucher_date', 'sri_date', 'srn_date', 'date', 'posted_at', 'created_at']),
        'voucher': (sr['invoice_number'] ?? sr['return_number'] ?? sr['srn_number'] ?? sr['sri_number'] ?? sr['voucher_number'] ?? sr['return_no'] ?? '').toString(),
        'description': (sr['remarks'] as String?)?.trim() ?? '',
        'debit': 0.0,
        'credit': total,
        'type': 'Sale Return',
      });
    }

    for (final raw in asList('crv')) {
      final r = Map<String, dynamic>.from(raw as Map);
      out.add({
        'date': (r['date'] ?? '').toString(),
        'voucher': (r['voucher'] ?? '').toString(),
        'description': (r['description'] as String?)?.trim() ?? '',
        'debit': 0.0,
        'credit': _amt(r, const ['amount']),
        'type': 'Receipt (CRV)',
      });
    }
    for (final raw in asList('cpv')) {
      final r = Map<String, dynamic>.from(raw as Map);
      out.add({
        'date': (r['date'] ?? '').toString(),
        'voucher': (r['voucher'] ?? '').toString(),
        'description': (r['description'] as String?)?.trim() ?? '',
        'debit': _amt(r, const ['amount']),
        'credit': 0.0,
        'type': 'Payment (CPV)',
      });
    }
    for (final raw in asList('jv')) {
      final r = Map<String, dynamic>.from(raw as Map);
      final ref = (r['reference_type'] as String?) ?? 'jv';
      final opening = ref == 'opening_jv' || ref == 'opening_balance';
      out.add({
        'date': (r['date'] ?? '').toString(),
        'voucher': (r['voucher'] ?? '').toString(),
        'description': (r['description'] as String?)?.trim() ?? '',
        'debit': _amt(r, const ['debit']),
        'credit': _amt(r, const ['credit']),
        'type': opening ? 'Opening Balance' : 'Journal (JV)',
      });
    }

    int seq(Map e) => (e['type'] == 'POS Payment' || e['type'] == 'POS Refund (Cash)') ? 1 : 0;
    out.sort((a, b) {
      final d = (a['date'] as String).compareTo(b['date'] as String);
      return d != 0 ? d : seq(a).compareTo(seq(b));
    });
    return out;
  }

  String _fmtDate(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? '-' : DateFormat('d MMM yyyy').format(d.toLocal());
  }

  Future<void> _openInvoice(Map<String, dynamic> e) async {
    final id = e['invoice_id'];
    if (id == null) return;
    setState(() => _openingId = id.toString());
    try {
      final res = await Supabase.instance.client
          .rpc('retailer_invoice_detail', params: {'p_invoice_id': id});
      final m = Map<String, dynamic>.from(res as Map);
      final header = Map<String, dynamic>.from(m['invoice'] as Map);
      final lines = (m['lines'] as List?) ?? [];
      final orgName = m['org_name'] as String? ?? 'Opstation';

      final pdfLines = lines.map((x) {
        final l = Map<String, dynamic>.from(x as Map);
        return RetailerPdfLine(
          product: l['product'] as String? ?? '-',
          sku: l['sku'] as String?,
          uom: l['uom'] as String?,
          qty: (l['qty'] as num?)?.toDouble() ?? 0,
          unitPrice: (l['unit_price'] as num?)?.toDouble(),
          discountPct: (l['discount'] as num?)?.toDouble(),
          lineTotal: (l['line_total'] as num?)?.toDouble(),
        );
      }).toList();

      final dateStr = header['voucher_date'] != null
          ? DateFormat('d MMM yyyy').format(DateTime.parse('${header['voucher_date']}'))
          : null;

      await RetailerInvoicePdf.open(
        voucherNumber: header['voucher_number'] as String? ?? (e['voucher']?.toString() ?? '-'),
        orgName: orgName,
        date: dateStr,
        customerName: ref.read(retailerAuthControllerProvider).valueOrNull?.name,
        lines: pdfLines,
        subtotal: (header['subtotal'] as num?)?.toDouble(),
        discountTotal: (header['discount_total'] as num?)?.toDouble(),
        grandTotal: (header['grand_total'] as num?)?.toDouble(),
      );
    } catch (_) {
      _snack(T.of(context).couldNotOpen);
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (!_allowed) {
      return _empty(t.ledgerUnavailable, Icons.account_balance_wallet_outlined);
    }
    if (_entries.isEmpty) {
      return _empty(t.ledgerEmpty, Icons.account_balance_wallet_outlined);
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Wrap(spacing: 10, runSpacing: 8, children: [
          _stat(t.totalDebit, _debit, AppColors.primary),
          _stat(t.totalCredit, _credit, AppColors.success),
          _stat(t.balance, _balance, _balance >= 0 ? AppColors.danger : AppColors.success),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _entries.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) {
              final e = _entries[i];
              final debit = e['debit'] as double;
              final credit = e['credit'] as double;
              final canOpen = e['type'] == 'Sales Invoice' && e['invoice_id'] != null;
              final opening = _openingId != null && _openingId == e['invoice_id']?.toString();
              return Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: canOpen && !opening ? () => _openInvoice(e) : null,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Flexible(
                              child: Text(
                                [
                                  if ((e['voucher'] as String).isNotEmpty) e['voucher'],
                                  e['type'],
                                ].join('  •  '),
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                            ),
                            if (canOpen) ...[
                              const SizedBox(width: 6),
                              opening
                                  ? const SizedBox(
                                      width: 12, height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2))
                                  : Icon(Icons.picture_as_pdf_outlined, size: 15, color: AppColors.primary),
                            ],
                          ]),
                          const SizedBox(height: 2),
                          Text(
                            [
                              _fmtDate(e['date'] as String),
                              if ((e['description'] as String).isNotEmpty) e['description'],
                            ].join('  •  '),
                            style: TextStyle(fontSize: 11, color: AppColors.textSecondaryLight),
                          ),
                        ]),
                      ),
                      const SizedBox(width: 10),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(
                          debit > 0 ? 'Dr ${_money(debit)}' : 'Cr ${_money(credit)}',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: debit > 0 ? AppColors.primary : AppColors.success),
                        ),
                        const SizedBox(height: 2),
                        Text('${t.balanceShort} ${_money(e['balance'] as double)}',
                            style: TextStyle(fontSize: 11, color: AppColors.textSecondaryLight)),
                      ]),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }

  // Compact money — reuses the retailer rs() but drops the "Rs. " prefix for the
  // tight ledger rows (the column headers already say Dr/Cr/Bal).
  String _money(num v) {
    final s = rs(v);
    return s.replaceFirst('Rs. ', '');
  }

  Widget _stat(String label, double v, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppColors.borderLight),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label.toUpperCase(),
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.textSecondaryLight, letterSpacing: 0.4)),
          const SizedBox(height: 2),
          Text(rs(v), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c)),
        ]),
      );

  Widget _empty(String msg, IconData icon) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 44, color: AppColors.textSecondaryLight.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(msg, style: TextStyle(color: AppColors.textSecondaryLight)),
        ]),
      );
}
