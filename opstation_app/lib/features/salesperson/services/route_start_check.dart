import '../models/customer.dart';

/// A route's customers on a salesperson's phone. A route lists its customers from the phone's own copy
/// of them, and a stop whose customer is not on the phone is hidden — so a phone that had not got all
/// of a route's customers used to start the route with fewer (even none), frozen for the whole trip.
/// These rules decide when to refresh from the server, when a route must not be started, and which
/// customers a running trip is missing.
class RouteStartCheck {
  RouteStartCheck._();

  /// [visible] customers are shown for the route; [expected] stops are recorded for it on this phone.
  /// Refresh from the server when nothing is shown or fewer are shown than the route has stops.
  static bool needsRefresh({required int visible, required int expected}) => visible == 0 || expected > visible;

  /// The reason a route cannot be started (after a refresh), or null when it can. A route with some of
  /// its customers shown starts with those.
  static String? blockMessage({required int visible, required int expected}) {
    if (visible > 0) return null;
    return expected == 0
        ? 'This route has no customers assigned yet. Please ask your manager, or check your internet connection and try again.'
        : 'The $expected customer${expected == 1 ? '' : 's'} of this route could not be loaded on your phone. '
            'Check your internet connection and try again; if it keeps happening, tell your manager (the customers may not be available to your account).';
  }

  /// The customers of the route that a running trip does not have yet, in the route's order.
  static List<Customer> missingStops({required Set<String> snapshotIds, required List<Customer> routeStops}) =>
      [for (final c in routeStops) if (!snapshotIds.contains(c.id)) c];
}

/// What repairing a running trip's customers did: [added] customers joined the trip; [stillMissing] are
/// stops of the route whose customers could not be loaded.
class RouteHealResult {
  const RouteHealResult(this.added, this.stillMissing);

  final int added;
  final int stillMissing;
}
