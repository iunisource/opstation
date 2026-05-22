/// Google Maps API configuration.
///
/// The key is injected at build time via --dart-define so it never
/// appears in source code or git history:
///
///   flutter run  --dart-define=GOOGLE_MAPS_API_KEY=AIza...
///   flutter build apk --dart-define=GOOGLE_MAPS_API_KEY=AIza...
///
/// If the key is absent the app falls back to Haversine straight-line
/// distances for trip reports — no crash, just less accurate numbers.
class MapsConfig {
  static const String apiKey = String.fromEnvironment(
    'GOOGLE_MAPS_API_KEY',
    defaultValue: '',
  );

  /// True when a real key has been injected at build time.
  static bool get hasKey => apiKey.isNotEmpty;
}
