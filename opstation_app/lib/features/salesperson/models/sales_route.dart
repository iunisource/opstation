import 'customer.dart';

enum RouteKind { oneTime, recurring }

/// A route template — a named, ordered list of customers assigned to a user.
class SalesRoute {
  final String id;
  final String name;
  final List<Customer> stops;
  final RouteKind kind;
  final bool isActive;

  const SalesRoute({
    required this.id,
    required this.name,
    required this.stops,
    required this.kind,
    this.isActive = true,
  });

  bool get isOneTime => kind == RouteKind.oneTime;
  bool get isRecurring => kind == RouteKind.recurring;
}
