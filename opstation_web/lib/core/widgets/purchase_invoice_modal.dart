import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import '../utils/app_link.dart';

/// A Purchase Invoice (header, items, totals) in a modal — like the ledgers.
Future<void> showPurchaseInvoiceModal(BuildContext context, {required String invoiceId}) async {
  final db = Supabase.instance.client;
  Map<String, dynamic>? v;
  List<Map<String, dynamic>> lines = [];
  final refs = <String, String>{};
  String? err;
  try {
    v = await db.from('purchase_invoices').select('*, suppliers(name)').eq('id', invoiceId).maybeSingle();
    if (v != null) {
      lines = List<Map<String, dynamic>>.from(
          await db.from('purchase_invoice_items').select('*, products(name, sku)').eq('invoice_id', invoiceId));
      try {
        final poId = v['po_id'] as String?;
        if (poId != null && poId.isNotEmpty) {
          final r = await db.from('purchase_orders').select('voucher_number').eq('id', poId).maybeSingle();
          if ((r?['voucher_number'] ?? '') != '') refs['PO'] = '${r!['voucher_number']}';
        }
        final grnId = v['grn_id'] as String?;
        if (grnId != null && grnId.isNotEmpty) {
          final r = await db.from('purchase_grns').select('voucher_number').eq('id', grnId).maybeSingle();
          if ((r?['voucher_number'] ?? '') != '') refs['GRN'] = '${r!['voucher_number']}';
        }
      } catch (_) {}
    }
  } catch (e) {
    err = '$e';
  }
  if (!context.mounted) return;
  if (v == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(err == null ? 'This invoice was not found.' : 'Could not open the invoice.')));
    return;
  }
  final h = v;
  final money = NumberFormat('#,##0.##');
  double n(dynamic x) => (x as num?)?.toDouble() ?? double.tryParse('$x') ?? 0;
  double qtyOf(Map l) => n(l['qty'] ?? l['quantity'] ?? l['qty_received']);
  double rateOf(Map l) => n(l['unit_price'] ?? l['price'] ?? l['unit_cost'] ?? l['rate']);
  double amtOf(Map l) {
    final a = l['line_total'] ?? l['amount'] ?? l['total'];
    return a != null ? n(a) : qtyOf(l) * rateOf(l);
  }
  final total = n(h['grand_total'] ?? h['total'] ?? h['total_amount']);
  final sub = lines.fold<double>(0, (s, l) => s + qtyOf(l) * rateOf(l));
  final date = DateTime.tryParse('${h['voucher_date'] ?? h['created_at'] ?? ''}');
  final status = '${h['is_voided'] == true ? 'void' : (h['status'] ?? '')}';
  final note = '${h['notes'] ?? h['remarks'] ?? h['note'] ?? ''}'.trim();
  const th = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary);
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 780, maxHeight: MediaQuery.of(ctx).size.height * 0.88),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Purchase Invoice', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              if (status.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: (status == 'void' ? AppTheme.danger : AppTheme.primary).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(status.toUpperCase(),
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: status == 'void' ? AppTheme.danger : AppTheme.primary)),
                ),
              const Spacer(),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 18, runSpacing: 4, children: [
              Text('${h['voucher_number'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
              if (date != null) Text(DateFormat('d MMM yyyy').format(date), style: const TextStyle(color: AppTheme.textSecondary)),
              if ((h['suppliers'] is Map) && '${h['suppliers']['name'] ?? ''}'.isNotEmpty)
                Text('${h['suppliers']['name']}', style: const TextStyle(color: AppTheme.textSecondary)),
              for (final e in refs.entries) Text('${e.key}: ${e.value}', style: const TextStyle(color: AppTheme.textSecondary)),
              if ((h['supplier_invoice_no'] ?? h['bill_no'] ?? '') != '')
                Text('Supplier bill: ${h['supplier_invoice_no'] ?? h['bill_no']}', style: const TextStyle(color: AppTheme.textSecondary)),
            ]),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(note, style: const TextStyle(fontSize: 12.5)),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              color: AppTheme.background,
              child: const Row(children: [
                Expanded(flex: 6, child: Text('Product', style: th)),
                Expanded(flex: 2, child: Text('Qty', textAlign: TextAlign.right, style: th)),
                Expanded(flex: 2, child: Text('Rate', textAlign: TextAlign.right, style: th)),
                Expanded(flex: 3, child: Text('Amount', textAlign: TextAlign.right, style: th)),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(children: [
                  for (final l in lines)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(flex: 6, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${(l['products'] is Map ? l['products']['name'] : null) ?? l['description'] ?? '-'}',
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                          if (l['products'] is Map && '${l['products']['sku'] ?? ''}'.isNotEmpty)
                            Text('${l['products']['sku']}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ])),
                        Expanded(flex: 2, child: Text(money.format(qtyOf(l)), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5))),
                        Expanded(flex: 2, child: Text(money.format(rateOf(l)), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5))),
                        Expanded(flex: 3, child: Text(money.format(amtOf(l)), textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700))),
                      ]),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if ((sub - total).abs() > 0.01)
                  Text('Subtotal Rs ${money.format(sub)}', style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                Text('Total Rs ${money.format(total)}',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppTheme.primary)),
              ]),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 15),
                label: const Text('Open Purchase Invoice'),
                onPressed: () {
                  Navigator.pop(ctx);
                  openAppLink(context, '/erp/purchase-invoices?focus=$invoiceId');
                },
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}
