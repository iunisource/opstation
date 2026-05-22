import 'package:supabase_flutter/supabase_flutter.dart';
import '../../orders/models/order.dart';

class DispatchOrderService {
  final SupabaseClient _client;
  DispatchOrderService(this._client);

  Future<List<Order>> listOrdersForDispatch({
    required String orgId,
    String? status,
    String? driverId,
    DateTime? from,
    DateTime? to,
  }) async {
    var query = _client.from('orders').select('*').eq('org_id', orgId);
    if (status != null) {
      query = query.eq('status', status);
    } else {
      query = query.inFilter('status', ['approved', 'dispatched', 'on_hold']);
    }
    if (driverId != null) query = query.eq('driver_id', driverId);
    if (from != null) query = query.gte('created_at', from.toIso8601String());
    if (to != null) query = query.lte('created_at', to.toIso8601String());
    final rows = await query.order('created_at', ascending: false);
    return (rows as List)
        .map((r) => Order.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  Future<List<Map<String, dynamic>>> listDrivers(String orgId) async {
    final rows = await _client
        .from('users')
        .select('id, name, role')
        .eq('org_id', orgId)
        .eq('role', 'driver')
        .eq('is_active', true)
        .order('name');
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Assigns one or more orders to a single driver as one multi-stop delivery.
  /// Optional override maps (orderId → value) override what's currently on
  /// the order and are also persisted onto the order row.
  Future<void> assignOrdersToDriver({
    required List<Order> orders,
    required String driverId,
    required String driverName,
    required String currentUserId,
    required String currentUserName,
    required String orgId,
    Map<String, String?>? driverNoteOverrides,
    Map<String, String?>? soInvoiceOverrides,
  }) async {
    if (orders.isEmpty) return;
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch;
    final hex = ts.toRadixString(16);
    final deliveryId = 'delivery_${ts}_$hex';

    await _client.from('deliveries').insert({
      'id': deliveryId,
      'driver_id': driverId,
      'driver_name': driverName,
      'driver_role': 'driver',
      'created_by': currentUserId,
      'created_by_name': currentUserName,
      'created_by_role': 'dispatchManager',
      'created_at': now.toIso8601String(),
      'status': 'assigned',
      'org_id': orgId,
      'order_id': orders.length == 1 ? orders.first.id : null,
    });

    final stopRows = <Map<String, dynamic>>[];
    for (var i = 0; i < orders.length; i++) {
      final o = orders[i];
      final dn = (driverNoteOverrides != null &&
              driverNoteOverrides.containsKey(o.id))
          ? driverNoteOverrides[o.id]
          : o.driverNote;
      final so = (soInvoiceOverrides != null &&
              soInvoiceOverrides.containsKey(o.id))
          ? soInvoiceOverrides[o.id]
          : o.soInvoiceNumber;
      stopRows.add({
        'id': 'stop_${ts}_${i}_$hex',
        'delivery_id': deliveryId,
        'customer_id': o.customerId,
        'customer_name': o.customerName ?? '',
        'customer_code': o.customerCode ?? '',
        'sequence': i + 1,
        'item_description': '',
        'amount': o.amount,
        'payment_type': o.paymentType,
        'status': 'pending',
        'verification': 'none',
        'photo_paths_json': '[]',
        'order_id': o.id,
        'driver_note':
            (dn == null || dn.trim().isEmpty) ? null : dn.trim(),
        'so_invoice_number':
            (so == null || so.trim().isEmpty) ? null : so.trim(),
      });
    }
    await _client.from('delivery_stops').insert(stopRows);

    for (final o in orders) {
      final payload = <String, dynamic>{
        'status': 'dispatched',
        'dispatched_at': now.toIso8601String(),
        'dispatched_by': currentUserId,
        'driver_id': driverId,
        'driver_name': driverName,
        'delivery_id': deliveryId,
        'updated_at': now.toIso8601String(),
      };
      if (driverNoteOverrides != null &&
          driverNoteOverrides.containsKey(o.id)) {
        final v = driverNoteOverrides[o.id];
        payload['driver_note'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (soInvoiceOverrides != null &&
          soInvoiceOverrides.containsKey(o.id)) {
        final v = soInvoiceOverrides[o.id];
        payload['so_invoice_number'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      await _client.from('orders').update(payload).eq('id', o.id);
    }

    // Fire-and-forget FCM notification to the driver. Don't fail the
    // assignment if the edge function errors.
    try {
      final firstName = orders.first.customerName ?? 'a stop';
      final body = orders.length == 1
          ? 'New delivery for $firstName'
          : '${orders.length} stops assigned';
      // ignore: avoid_print
      print('FCM: invoking send-notification for driver $driverId');
      await _client.functions.invoke('send-notification', body: {
        'userId': driverId,
        'title': 'New delivery assigned',
        'body': body,
        'data': {
          'type': 'delivery_assigned',
          'delivery_id': deliveryId,
        },
      });
    } catch (e, st) {
      // notification failures shouldn't break dispatch, but log them
      // so we can see what's happening during debugging.
      // ignore: avoid_print
      print('FCM notify failed: $e\n$st');
    }
  }

  Future<void> updateStatus({
    required String orderId,
    required String newStatus,
    required String note,
  }) async {
    await _client.from('orders').update({
      'status': newStatus,
      'status_note': note,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', orderId);
  }

  /// Fetch all orders attached to a given delivery via `orders.delivery_id`.
  Future<List<Order>> listOrdersInDelivery(String deliveryId) async {
    final rows = await _client
        .from('orders')
        .select('*')
        .eq('delivery_id', deliveryId)
        .order('created_at');
    return (rows as List)
        .map((row) => Order.fromRow(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  /// Update an existing delivery's per-order driver_note and so_invoice_number,
  /// and optionally reassign the driver. Does NOT change order status. Writes
  /// to both `orders` and the matching `delivery_stops` rows so the driver
  /// app sees the changes on next sync.
  Future<void> updateExistingDelivery({
    required String deliveryId,
    required List<Order> orders,
    String? newDriverId,
    String? newDriverName,
    Map<String, String?>? driverNoteOverrides,
    Map<String, String?>? soInvoiceOverrides,
  }) async {
    final now = DateTime.now().toIso8601String();
    final driverChanged = newDriverId != null && newDriverName != null;

    if (driverChanged) {
      await _client.from('deliveries').update({
        'driver_id': newDriverId,
        'driver_name': newDriverName,
      }).eq('id', deliveryId);
    }

    for (final o in orders) {
      final payload = <String, dynamic>{'updated_at': now};
      if (driverNoteOverrides != null &&
          driverNoteOverrides.containsKey(o.id)) {
        final v = driverNoteOverrides[o.id];
        payload['driver_note'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (soInvoiceOverrides != null &&
          soInvoiceOverrides.containsKey(o.id)) {
        final v = soInvoiceOverrides[o.id];
        payload['so_invoice_number'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (driverChanged) {
        payload['driver_id'] = newDriverId;
        payload['driver_name'] = newDriverName;
      }
      if (payload.length > 1) {
        await _client.from('orders').update(payload).eq('id', o.id);
      }

      // Mirror note/SO onto the delivery_stop. lock_delivered_stops trigger
      // blocks updates on already-delivered stops, which is exactly what
      // we want — those rows are immutable.
      final stopPayload = <String, dynamic>{};
      if (driverNoteOverrides != null &&
          driverNoteOverrides.containsKey(o.id)) {
        final v = driverNoteOverrides[o.id];
        stopPayload['driver_note'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (soInvoiceOverrides != null &&
          soInvoiceOverrides.containsKey(o.id)) {
        final v = soInvoiceOverrides[o.id];
        stopPayload['so_invoice_number'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (stopPayload.isNotEmpty) {
        try {
          await _client
              .from('delivery_stops')
              .update(stopPayload)
              .eq('delivery_id', deliveryId)
              .eq('order_id', o.id);
        } catch (_) {
          // Stop may be locked (already delivered). Skip silently — the
          // order-level update still went through above.
        }
      }
    }

    if (driverChanged) {
      try {
        final body = orders.length == 1
            ? 'Delivery for ${orders.first.customerName ?? "a stop"}'
            : '${orders.length} stops assigned';
        await _client.functions.invoke('send-notification', body: {
          'userId': newDriverId,
          'title': 'Delivery reassigned to you',
          'body': body,
          'data': {
            'type': 'delivery_assigned',
            'delivery_id': deliveryId,
          },
        });
      } catch (e, st) {
        // ignore: avoid_print
        print('FCM reassign notify failed: $e\n$st');
      }
    }
  }

  /// Manually mark a delivery as fully delivered. For third-party drivers
  /// who don't run the mobile app — the dispatch manager confirms delivery
  /// verbally / via paperwork and flips the records.
  ///
  /// Flips each non-delivered `delivery_stops.status` to 'delivered'. The
  /// `delivery_stop_to_order_sync` trigger cascades that to `orders.status`
  /// automatically. Then marks the delivery itself completed.
  Future<void> markDeliveryAsDelivered({
    required String deliveryId,
  }) async {
    final now = DateTime.now().toIso8601String();

    await _client
        .from('delivery_stops')
        .update({'status': 'delivered', 'delivered_at': now})
        .eq('delivery_id', deliveryId)
        .neq('status', 'delivered');

    await _client.from('deliveries').update({
      'status': 'completed',
      'completed_at': now,
    }).eq('id', deliveryId);
  }
}
