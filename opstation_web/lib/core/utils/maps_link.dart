import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';

/// The Google Maps link for a spot: opens the map with a pin on it.
String mapsUrl(double lat, double lng) =>
    'https://www.google.com/maps/search/?api=1&query=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';

/// Opens the spot in Google Maps in a new tab.
Future<void> openInMaps(double lat, double lng) async {
  await launchUrl(Uri.parse(mapsUrl(lat, lng)), mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
}

/// Coordinates shown as a link: click to see the spot in Google Maps.
class CoordinatesLink extends StatelessWidget {
  const CoordinatesLink({super.key, required this.lat, required this.lng, this.text, this.fontSize = 12, this.opener});

  final double lat;
  final double lng;

  /// What to show; the coordinates to 5 decimals when not given.
  final String? text;
  final double fontSize;

  /// Replaces the real opener (for tests).
  final Future<void> Function(double lat, double lng)? opener;

  @override
  Widget build(BuildContext context) {
    final label = text ?? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    return Tooltip(
      message: 'Open in Google Maps',
      child: InkWell(
        onTap: () => (opener ?? openInMaps)(lat, lng),
        borderRadius: BorderRadius.circular(4),
        child: Text(
          label,
          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600, color: AppTheme.primary, decoration: TextDecoration.underline, decorationColor: AppTheme.primary),
        ),
      ),
    );
  }
}
