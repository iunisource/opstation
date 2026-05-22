import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/order.dart';

class OrderService {
  final SupabaseClient _client;
  OrderService(this._client);

  Future<Order> create({
    required String id,
    required String orgId,
    required String customerId,
    String? customerName,
    String? customerCode,
    required String salespersonId,
    required String salespersonName,
    required String notes,
    required List<String> photoPaths,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = {
      'id': id,
      'org_id': orgId,
      'customer_id': customerId,
      'customer_name': customerName,
      'customer_code': customerCode,
      'salesperson_id': salespersonId,
      'salesperson_name': salespersonName,
      'notes': notes,
      'photo_paths_json': jsonEncode(photoPaths),
      'status': 'in_review',
      'created_at': now,
      'updated_at': now,
    };
    final row = await _client.from('orders').insert(payload).select().single();
    return Order.fromRow(Map<String, dynamic>.from(row));
  }

  Future<List<Order>> bySalesperson(String salespersonId) async {
    final rows = await _client
        .from('orders')
        .select()
        .eq('salesperson_id', salespersonId)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => Order.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
  }
}

final orderServiceProvider = Provider<OrderService>((ref) {
  return OrderService(Supabase.instance.client);
});
