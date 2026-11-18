import 'package:supabase_flutter/supabase_flutter.dart';

/// The ONE place that decides what counts as an inventory integrity issue.
/// The Inventory Integrity screen and the Inventory menu badge both read from
/// here, so the number on the menu can never disagree with the page again.
class InventoryIntegrityData {
  InventoryIntegrityData._();

  /// PRODUCTS tab: stock-data problems that are real (timing windows that are
  /// fully explained by in-transit transfers, saved purchase returns or
  /// confirmed sales returns awaiting their invoice are not counted).
  static Future<List<Map<String, dynamic>>> products(SupabaseClient client, String orgId) async {
    final res = await client.rpc('rpc_inventory_integrity', params: {'p_org': orgId});
    var rows = List<Map<String, dynamic>>.from(res as List);

    try {
      final expected = <String, double>{};
      // (a) in-transit stock transfers (dispatched, not yet received)
      final trs = await client.from('stock_transfers').select('id').eq('org_id', orgId).eq('status', 'in_transit');
      final ids = (trs as List).map((e) => e['id'] as String).toList();
      if (ids.isNotEmpty) {
        final items = await client.from('stock_transfer_items').select('product_id, quantity').inFilter('transfer_id', ids);
        for (final r in (items as List)) {
          final pid = r['product_id'] as String?;
          if (pid == null) continue;
          expected[pid] = (expected[pid] ?? 0) + ((r['quantity'] as num?)?.toDouble() ?? 0);
        }
      }
      // (b) purchase returns saved but not yet invoiced (layer consumed at PRI)
      try {
        final pr = await client.rpc('rpc_pending_purchase_return_qty', params: {'p_org': orgId});
        for (final r in (pr as List)) {
          final pid = r['product_id'] as String?;
          if (pid == null) continue;
          expected[pid] = (expected[pid] ?? 0) + ((r['qty'] as num?)?.toDouble() ?? 0);
        }
      } catch (_) {/* helper RPC unavailable */}
      // (c) sales returns confirmed (SRN) but whose Return Invoice (SRI) is not
      //     issued yet: stock came back IN at the SRN, the cost layer is only
      //     created when the SRI is issued. Stock runs AHEAD of layers.
      try {
        final srns = await client
            .from('sales_returns')
            .select('id')
            .eq('org_id', orgId)
            .eq('status', 'saved')
            .or('is_voided.is.null,is_voided.eq.false');
        final srnIds = (srns as List).map((e) => e['id'] as String).toList();
        for (var i = 0; i < srnIds.length; i += 200) {
          final items = await client
              .from('sales_return_items')
              .select('product_id, quantity')
              .inFilter('return_id', srnIds.sublist(i, (i + 200).clamp(0, srnIds.length)));
          for (final r in (items as List)) {
            final pid = r['product_id'] as String?;
            if (pid == null) continue;
            expected[pid] = (expected[pid] ?? 0) - ((r['quantity'] as num?)?.toDouble() ?? 0);
          }
        }
      } catch (_) {/* ignore */}

      if (expected.isNotEmpty) {
        rows = rows.where((r) {
          if (r['issue'] != 'STOCK <> LAYERS') return true;
          if (((r['neg_layers'] as num?)?.toInt() ?? 0) != 0) return true;
          final pid = r['product_id'] as String?;
          final it = pid != null ? (expected[pid] ?? 0) : 0;
          if (it == 0) return true;
          final stock = (r['stock_qty'] as num?)?.toDouble() ?? 0;
          final layer = (r['layer_qty'] as num?)?.toDouble() ?? 0;
          return (stock + it - layer).abs() > 0.001;
        }).toList();
      }
    } catch (_) {/* if the lookup fails, use the raw list */}
    return rows;
  }

  static String _d(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// DOCUMENTS tab: documents where the General Ledger and the inventory cost
  /// ledger disagree, after hiding anything already marked reviewed and any
  /// gap that is exactly the Purchase Price Variance the invoice booked.
  static Future<List<Map<String, dynamic>>> documents(
      SupabaseClient client, String orgId, DateTime from, DateTime to) async {
    final res = await client.rpc('rpc_inventory_gl_reconciliation_active', params: {
      'p_org_id': orgId,
      'p_from': _d(from),
      'p_to': _d(to),
      'p_branch_id': null,
    });
    final rows = List<Map<String, dynamic>>.from(res as List);
    return _dropExplainedByPpv(client, orgId, rows);
  }

  /// Default range of the Documents tab: 1 January this year to today.
  static Future<List<Map<String, dynamic>>> documentsThisYear(SupabaseClient client, String orgId) {
    final now = DateTime.now();
    return documents(client, orgId, DateTime(now.year, 1, 1), now);
  }

  /// A Purchase Invoice whose price differs from the received cost posts the
  /// difference on units ALREADY SOLD/USED to Purchase Price Variance (an
  /// expense), not to inventory. That is correct, so a row whose gap is exactly
  /// the PPV the invoice booked is not a real divergence.
  static Future<List<Map<String, dynamic>>> _dropExplainedByPpv(
      SupabaseClient client, String orgId, List<Map<String, dynamic>> rows) async {
    final piNos = rows
        .map((r) => '${r['voucher_no'] ?? ''}')
        .where((v) => v.startsWith('PI-') || v.startsWith('PRI-'))
        .toSet()
        .toList();
    if (piNos.isEmpty) return rows;
    try {
      final byRef = await client
          .from('journal_entries')
          .select('id, reference_number, entry_number')
          .eq('org_id', orgId)
          .eq('status', 'posted')
          .inFilter('reference_number', piNos);
      final byNo = await client
          .from('journal_entries')
          .select('id, reference_number, entry_number')
          .eq('org_id', orgId)
          .eq('status', 'posted')
          .inFilter('entry_number', [for (final v in piNos) 'PINV-$v']);
      final entryToVoucher = <String, String>{};
      for (final e in [...(byRef as List), ...(byNo as List)]) {
        final ref = '${e['reference_number'] ?? ''}';
        final no = '${e['entry_number'] ?? ''}';
        final v = piNos.contains(ref) ? ref : (no.startsWith('PINV-') ? no.substring(5) : ref);
        if (piNos.contains(v)) entryToVoucher[e['id'] as String] = v;
      }
      if (entryToVoucher.isEmpty) return rows;
      final lines = await client
          .from('journal_lines')
          .select('entry_id, debit, credit, account_name, description')
          .inFilter('entry_id', entryToVoucher.keys.toList());
      final ppv = <String, double>{};
      for (final l in (lines as List)) {
        final name = '${l['account_name'] ?? ''} ${l['description'] ?? ''}'.toLowerCase();
        if (!name.contains('price variance')) continue;
        final v = entryToVoucher[l['entry_id']];
        if (v == null) continue;
        final amt = ((l['debit'] as num?)?.toDouble() ?? 0) - ((l['credit'] as num?)?.toDouble() ?? 0);
        ppv[v] = (ppv[v] ?? 0) + amt;
      }
      return rows.where((r) {
        final v = '${r['voucher_no'] ?? ''}';
        final p = ppv[v];
        if (p == null || p == 0) return true;
        final diff = ((r['difference'] as num?)?.toDouble() ?? 0).abs();
        return (diff - p.abs()).abs() > 0.05;
      }).toList();
    } catch (_) {
      return rows;
    }
  }
}
