import 'dart:convert';

enum OrderStatus {
  inReview, approved, declined, dispatched, onHold, cancelled, delivered,
}

extension OrderStatusX on OrderStatus {
  String get key {
    switch (this) {
      case OrderStatus.inReview: return 'in_review';
      case OrderStatus.approved: return 'approved';
      case OrderStatus.declined: return 'declined';
      case OrderStatus.dispatched: return 'dispatched';
      case OrderStatus.onHold: return 'on_hold';
      case OrderStatus.cancelled: return 'cancelled';
      case OrderStatus.delivered: return 'delivered';
    }
  }

  String get label {
    switch (this) {
      case OrderStatus.inReview: return 'In review';
      case OrderStatus.approved: return 'Approved';
      case OrderStatus.declined: return 'Declined';
      case OrderStatus.dispatched: return 'Dispatched';
      case OrderStatus.onHold: return 'On hold';
      case OrderStatus.cancelled: return 'Cancelled';
      case OrderStatus.delivered: return 'Delivered';
    }
  }

  static OrderStatus? fromKey(String? k) {
    if (k == null) return null;
    for (final s in OrderStatus.values) {
      if (s.key == k) return s;
    }
    return null;
  }
}

class Order {
  final String id;
  final String orgId;
  final String customerId;
  final String? customerName;
  final String? customerCode;
  final String? salespersonId;
  final String? salespersonName;
  final String? notes;
  final List<String> photoPaths;
  final OrderStatus status;
  final String? statusNote;
  final String? driverId;
  final String? driverName;
  final String? deliveryId;
  final DateTime createdAt;
  final DateTime updatedAt;

  Order({
    required this.id,
    required this.orgId,
    required this.customerId,
    this.customerName,
    this.customerCode,
    this.salespersonId,
    this.salespersonName,
    this.notes,
    this.photoPaths = const [],
    required this.status,
    this.statusNote,
    this.driverId,
    this.driverName,
    this.deliveryId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Order.fromRow(Map<String, dynamic> r) {
    final pj = r['photo_paths_json'] as String?;
    final paths = (pj != null && pj.isNotEmpty)
        ? List<String>.from(jsonDecode(pj) as List)
        : const <String>[];
    return Order(
      id: r['id'] as String,
      orgId: r['org_id'] as String,
      customerId: r['customer_id'] as String,
      customerName: r['customer_name'] as String?,
      customerCode: r['customer_code'] as String?,
      salespersonId: r['salesperson_id'] as String?,
      salespersonName: r['salesperson_name'] as String?,
      notes: r['notes'] as String?,
      photoPaths: paths,
      status: OrderStatusX.fromKey(r['status'] as String?) ?? OrderStatus.inReview,
      statusNote: r['status_note'] as String?,
      driverId: r['driver_id'] as String?,
      driverName: r['driver_name'] as String?,
      deliveryId: r['delivery_id'] as String?,
      createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
      updatedAt: DateTime.parse(r['updated_at'] as String).toLocal(),
    );
  }
}
