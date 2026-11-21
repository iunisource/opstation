import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// OpenStreetMap's public tile server: the map the app has always drawn.
const String osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// A second tile server for any tile the first one does not give. The public OpenStreetMap server
/// limits how much one place may take from it; when it refuses, the map used to stay a blur of
/// zoomed-in low-detail tiles. With this, the missing tiles come from here instead.
const String mapFallbackTileUrl = 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png';

/// The base map layer used by every map in the app.
///
/// [tileProvider] replaces the real network fetch (tests only).
TileLayer appTileLayer({String userAgent = 'com.opstation.web', TileProvider? tileProvider}) => TileLayer(
      urlTemplate: osmTileUrl,
      fallbackUrl: mapFallbackTileUrl,
      userAgentPackageName: userAgent,
      maxNativeZoom: 19,
      tileProvider: tileProvider,
    );

/// The credit the map data requires, bottom right. Small, never in the way of the map's gestures, and it
/// shortens itself on a narrow map instead of overflowing.
Widget mapAttribution() => const Align(
      alignment: Alignment.bottomRight,
      child: IgnorePointer(
        child: Padding(
          padding: EdgeInsets.all(3),
          child: DecoratedBox(
            decoration: BoxDecoration(color: Color(0xCCFFFFFF), borderRadius: BorderRadius.all(Radius.circular(3))),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              child: Text(
                'OpenStreetMap contributors, CARTO',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: Color(0xFF334155)),
              ),
            ),
          ),
        ),
      ),
    );
