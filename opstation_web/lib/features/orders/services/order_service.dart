import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/order.dart';

class OrderService {
  final SupabaseClient _client;
  OrderService(this._client);

  Future<List<Order>> listByOrg({
    required String orgId,
    DateTime? fromInclusive,
    DateTime? toExclusive,
    OrderStatus? status,
    String? salespersonId,
  }) async {
    var q = _client.from('orders').select().eq('org_id', orgId);
    if (fromInclusive != null) {
      q = q.gte('created_at', fromInclusive.toIso8601String());
    }
    if (toExclusive != null) {
      q = q.lt('created_at', toExclusive.toIso8601String());
    }
    if (status != null) {
      q = q.eq('status', status.key);
    }
    if (salespersonId != null) {
      q = q.eq('salesperson_id', salespersonId);
    }
    final rows = await q.order('created_at', ascending: false);
    return (rows as List)
        .map((r) => Order.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  /// Updates status + status_note. Auto-sets approved_at/by when moving
  /// to approved, since that's the accountant's signal.
  Future<void> updateStatus({
    required String orderId,
    required OrderStatus newStatus,
    String? statusNote,
    required String actorUserId,
    String? driverNote,
    String? soInvoiceNumber,
    bool includeDriverFields = false,
    String? paymentType,
    int? amount,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final payload = <String, dynamic>{
      'status': newStatus.key,
      'status_note': statusNote,
      'updated_at': nowIso,
    };
    if (newStatus == OrderStatus.approved) {
      payload['approved_at'] = nowIso;
      payload['approved_by'] = actorUserId;
      if (paymentType != null) {
        payload['payment_type'] = paymentType;
      }
      if (amount != null) {
        payload['amount'] = amount;
      }
    }
    if (includeDriverFields) {
      payload['driver_note'] =
          (driverNote == null || driverNote.trim().isEmpty)
              ? null
              : driverNote.trim();
      payload['so_invoice_number'] =
          (soInvoiceNumber == null || soInvoiceNumber.trim().isEmpty)
              ? null
              : soInvoiceNumber.trim();
    }
    await _client.from('orders').update(payload).eq('id', orderId);
  }

  Future<List<Map<String, dynamic>>> listSalespeople(String orgId) async {
    final rows = await _client
        .from('users')
        .select('id, name, role')
        .eq('org_id', orgId);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .where((u) => u['role'] == 'salesperson')
        .toList()
      ..sort((a, b) =>
          ((a['name'] as String?) ?? '').toLowerCase().compareTo(
              ((b['name'] as String?) ?? '').toLowerCase()));
  }
}

final orderServiceProvider = Provider<OrderService>((ref) {
  return OrderService(Supabase.instance.client);
});
