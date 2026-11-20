/// What a salesperson's visit counts as, under the rules without "Skip":
///   verified (inside the geofence), money or not  → Visited
///   not verified (outside / no location) + money  → Outside geofence
///   not verified, no money                        → Not verified
/// Old visits recorded as "skipped" keep that label; no visit = Not visited.
///   no location check + money: [hasGps] false (the phone had no GPS) → No GPS;
///   [hasGps] true (the shop had no saved location) → No Location.
String visitOutcomeLabel(String? status, num? collected, {bool? hasGps}) {
  final s = status ?? '';
  final amt = collected ?? 0;
  switch (s) {
    case 'verified':
      return 'Visited';
    case 'outside':
      return amt > 0 ? 'Outside geofence' : 'Not verified';
    case 'noLocation':
    case 'no_location':
      if (amt <= 0) return 'Not verified';
      if (hasGps == null) return 'Outside geofence';
      return hasGps ? 'No Location' : 'No GPS';
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

/// Did the visit capture GPS? (null = not known from this row).
bool? visitHasGps(Map v) => v.containsKey('captured_lat') ? v['captured_lat'] != null && v['captured_lng'] != null : null;

/// Entered with "Ad-hoc collection" in the app (skip_reason = 'adhoc' on a
/// visit that isn't a skip).
bool visitIsAdhoc(Map v) => '${v['status'] ?? ''}' != 'skipped' && '${v['skip_reason'] ?? ''}' == 'adhoc';

/// A visit marked on the Free Route WITHOUT a customer (customer_id NULL,
/// skip_reason 'free', status 'verified' — the phone's GPS point was captured).
/// Reports list it by its place name; its GPS point counts in the trip distance.
bool visitIsFree(Map v) => '${v['skip_reason'] ?? ''}' == 'free';

/// Opens a GPS point in Google Maps.
String mapsLink(double lat, double lng) => 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';

/// " · Ad-hoc receipt" and, when the visit didn't count as Visited and the GPS
/// reading was rough (worse than 50 m), " · rough GPS (±90 m)". [outcome] is
/// the label from [visitOutcomeLabel].
String visitExtras(Map v, String outcome) {
  final acc = (v['accuracy_meters'] as num?)?.toDouble();
  final parts = <String>[
    if (visitIsAdhoc(v)) 'Ad-hoc receipt',
    if (outcome != 'Visited' && acc != null && acc > 50) 'rough GPS (±${acc.round()} m)',
  ];
  return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
}
