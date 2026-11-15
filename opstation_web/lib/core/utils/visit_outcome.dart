/// What a salesperson's visit counts as, under the rules without "Skip":
///   verified (inside the geofence), money or not  → Visited
///   not verified (outside / no location) + money  → Outside geofence
///   not verified, no money                        → Not verified
/// Old visits recorded as "skipped" keep that label; no visit = Not visited.
String visitOutcomeLabel(String? status, num? collected) {
  final s = status ?? '';
  final amt = collected ?? 0;
  switch (s) {
    case 'verified':
      return 'Visited';
    case 'outside':
    case 'noLocation':
    case 'no_location':
      return amt > 0 ? 'Outside geofence' : 'Not verified';
    case 'skipped':
      return 'Skipped';
    case 'pending':
    case 'not_visited':
    case '':
      return 'Not visited';
    default:
      return s;
  }
}

/// "85 m away" / "1.2 km away" — how far from the shop a visit was marked
/// (visits.distance_meters). Null when unknown or zero.
String? awayLabel(num? meters) {
  if (meters == null || meters <= 0) return null;
  if (meters < 1000) return '${meters.round()} m away';
  return '${(meters / 1000).toStringAsFixed(meters < 10000 ? 1 : 0)} km away';
}
