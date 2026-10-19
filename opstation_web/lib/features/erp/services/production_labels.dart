import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/printing/label_printer.dart';

/// Admin Settings → Manufacturing: "Ask to print product labels after
/// production" (org.ask_labels_after_production). ON unless switched off.
Future<bool> askLabelsAfterProduction(String? orgId) async {
  if (orgId == null) return false;
  try {
    final r = await Supabase.instance.client.from('app_config').select('value')
        .eq('org_id', orgId).eq('key', 'org.ask_labels_after_production').limit(1).maybeSingle();
    final v = r?['value'] as String?;
    return v == null || v == 'true';
  } catch (_) {
    return false;
  }
}

/// Opens the label dialog for a finished product: one label per unit by
/// default (copies editable; Cancel = no labels). Barcode, else SKU.
Future<void> printProductLabels(
  BuildContext context, {
  required String? productId,
  required String fallbackName,
  required double qty,
  required String batch,
  DateTime? date,
  String title = 'Print product labels?',
}) async {
  String name = fallbackName;
  String? code;
  if (productId != null) {
    try {
      final p = await Supabase.instance.client.from('products')
          .select('name, sku, barcode').eq('id', productId).maybeSingle();
      if (p != null) {
        name = '${p['name'] ?? fallbackName}';
        final bc = '${p['barcode'] ?? ''}'.trim();
        final sku = '${p['sku'] ?? ''}'.trim();
        code = bc.isNotEmpty ? bc : (sku.isNotEmpty ? sku : null);
      }
    } catch (_) {}
  }
  if (!context.mounted) return;
  await showLabelPrintDialog(
    context,
    title: title,
    items: [LabelData(
      name: name,
      code: code,
      batch: batch.isEmpty ? null : batch,
      date: DateFormat('dd/MM/yyyy').format(date ?? DateTime.now()),
    )],
    defaultCopies: qty > 0 ? qty.ceil() : 1,
  );
}
