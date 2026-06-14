import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:open_location_code/open_location_code.dart' as olc;

import '../../../core/services/device_gps_service.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/customers_controller.dart';

/// Four-tab location wizard:
///   • GPS       — capture from device
///   • Map       — pin a point on Google Maps (with search bar)
///   • Plus Code — decode a Google Plus Code (e.g. "8V9W+M4 Lahore")
///   • Manual    — raw lat / lng
class LocationWizardScreen extends ConsumerStatefulWidget {
  final String customerId;
  const LocationWizardScreen({super.key, required this.customerId});

  @override
  ConsumerState<LocationWizardScreen> createState() =>
      _LocationWizardScreenState();
}

class _LocationWizardScreenState extends ConsumerState<LocationWizardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  double? _lat;
  double? _lng;
  double? _accuracy;
  String _source = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrateFromCustomer());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _hydrateFromCustomer() {
    final state = ref.read(customersControllerProvider).valueOrNull;
    if (state == null) return;
    final match = state.all.where((c) => c.id == widget.customerId).toList();
    if (match.isEmpty) return;
    final c = match.first;
    if (c.hasLocation) {
      setState(() {
        _lat = c.latitude;
        _lng = c.longitude;
        _source = 'Current saved location';
      });
    }
  }

  void _setCoords({
    required double lat,
    required double lng,
    double? accuracy,
    required String source,
  }) {
    setState(() {
      _lat = lat;
      _lng = lng;
      _accuracy = accuracy;
      _source = source;
    });
  }

  Future<void> _save() async {
    if (_lat == null || _lng == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(customersControllerProvider.notifier)
          .setLocation(widget.customerId, _lat!, _lng!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location saved')),
      );
      if (mounted) context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Let the layout NOT resize for the keyboard; the inner Plus Code
      // and Manual tabs each have their own SingleChildScrollView with
      // viewInsets padding, so content scrolls behind the keyboard
      // instead of forcing the fixed SaveFooter to overlap the tab body
      // (which caused a RenderFlex overflow banner).
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Set location',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.gps_fixed), text: 'GPS'),
            Tab(icon: Icon(Icons.map_outlined), text: 'Map'),
            Tab(icon: Icon(Icons.link_outlined), text: 'Maps link'),
            Tab(icon: Icon(Icons.edit_outlined), text: 'Manual'),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _GpsTab(onCoords: _setCoords),
                _MapTab(
                  initialLat: _lat,
                  initialLng: _lng,
                  onCoords: _setCoords,
                ),
                _MapsLinkTab(onCoords: _setCoords),
                _ManualTab(
                  initialLat: _lat,
                  initialLng: _lng,
                  onCoords: _setCoords,
                ),
              ],
            ),
          ),
          _SaveFooter(
            lat: _lat,
            lng: _lng,
            accuracy: _accuracy,
            source: _source,
            saving: _saving,
            onSave: _save,
          ),
        ],
      ),
    );
  }
}

// ---- GPS tab -----------------------------------------------------------

class _GpsTab extends ConsumerStatefulWidget {
  final void Function({
    required double lat,
    required double lng,
    double? accuracy,
    required String source,
  }) onCoords;

  const _GpsTab({required this.onCoords});

  @override
  ConsumerState<_GpsTab> createState() => _GpsTabState();
}

class _GpsTabState extends ConsumerState<_GpsTab> {
  DeviceFix? _fix;
  bool _loading = false;
  bool _stale = false;
  String? _error;

  Future<void> _capture() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await ref.read(deviceGpsServiceProvider).getFixResult();
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _loading = false;
        _stale = false;
        _error = _messageFor(res.outcome);
      });
      return;
    }
    final fix = res.fix!;
    setState(() {
      _loading = false;
      _stale = res.isStale;
      _fix = fix;
    });
    widget.onCoords(
      lat: fix.lat,
      lng: fix.lng,
      accuracy: fix.accuracy,
      source: res.isStale ? 'Device GPS (last known)' : 'Device GPS',
    );
  }

  String _messageFor(GpsOutcome outcome) {
    switch (outcome) {
      case GpsOutcome.serviceDisabled:
        return 'Location is turned off on this phone. Switch on GPS / Location '
            'in your phone settings, then tap Capture again.';
      case GpsOutcome.permissionDenied:
        return 'Location permission was denied. Tap Capture again and allow it '
            'when prompted.';
      case GpsOutcome.permissionBlocked:
        return 'Location permission is blocked for Opstation. Enable it in '
            'Settings → Apps → Opstation → Permissions, then retry.';
      case GpsOutcome.timeout:
        return "Couldn't get a GPS fix here — the signal is weak. Step toward "
            'open sky (a doorway or outside) and tap Capture again, or use the '
            'Map / Manual tab.';
      case GpsOutcome.error:
      case GpsOutcome.success:
        return 'Location unavailable. Try again, or use the Map / Manual tab.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Capture from device GPS',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            "Stand next to the shop and tap Capture. The device's current GPS position will be stored as this customer's location.",
            style: TextStyle(
              color: AppColors.textSecondaryLight,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _loading ? null : _capture,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.my_location, size: 22),
              label: Text(_loading ? 'Capturing location...' : 'Capture my current location'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 56),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      color: AppColors.dangerDark, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: AppColors.dangerDark,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_fix != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.successLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.gps_fixed,
                          color: AppColors.successDark, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'GPS captured',
                        style: TextStyle(
                          color: AppColors.successDark,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Lat ${_fix!.lat.toStringAsFixed(6)}, Lng ${_fix!.lng.toStringAsFixed(6)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  _AccuracyMeter(
                    accuracyMeters: _fix!.accuracy,
                    stale: _stale,
                  ),
                  if (_stale) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Last known position (a live fix timed out here). If the '
                      'pin looks off, move toward open sky and capture again.',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.dangerDark,
                      ),
                    ),
                  ] else if (_fix!.accuracy > 50) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Accuracy is low here. For a tighter pin, move toward open '
                      'sky and capture again.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFFB45309),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---- GPS accuracy health meter ----------------------------------------

/// A 4-segment signal-strength-style meter that grades a captured fix's
/// accuracy so a surveyor can tell at a glance whether the pin is trustworthy
/// or worth re-capturing. Bands (radius in metres):
///   <=10  Excellent (4)   <=25 Good (3)   <=50 Fair (2)   >50 Poor (1)
/// A stale (last-known) fix is shown greyed at one bar regardless of radius.
class _AccuracyMeter extends StatelessWidget {
  final double accuracyMeters;
  final bool stale;
  const _AccuracyMeter({required this.accuracyMeters, this.stale = false});

  int get _band {
    if (accuracyMeters <= 10) return 4;
    if (accuracyMeters <= 25) return 3;
    if (accuracyMeters <= 50) return 2;
    return 1;
  }

  String get _label {
    if (stale) return 'Last known';
    switch (_band) {
      case 4:
        return 'Excellent';
      case 3:
        return 'Good';
      case 2:
        return 'Fair';
      default:
        return 'Poor';
    }
  }

  Color get _color {
    if (stale) return const Color(0xFF6B7280); // grey
    switch (_band) {
      case 4:
        return const Color(0xFF16A34A); // green
      case 3:
        return const Color(0xFF22C55E); // light green
      case 2:
        return const Color(0xFFF59E0B); // amber
      default:
        return const Color(0xFFDC2626); // red
    }
  }

  @override
  Widget build(BuildContext context) {
    final filled = stale ? 1 : _band;
    return Row(
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            margin: const EdgeInsets.only(right: 4),
            width: 20,
            height: 8,
            decoration: BoxDecoration(
              color: i < filled ? _color : const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '$_label  ·  ±${accuracyMeters.round()}m',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _color,
            ),
          ),
        ),
      ],
    );
  }
}

// ---- Map tab (with search) --------------------------------------------

class _MapTab extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;
  final void Function({
    required double lat,
    required double lng,
    double? accuracy,
    required String source,
  }) onCoords;

  const _MapTab({
    this.initialLat,
    this.initialLng,
    required this.onCoords,
  });

  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> {
  late LatLng _center;
  GoogleMapController? _controller;
  final _searchCtrl = TextEditingController();
  String? _searchHint;

  @override
  void initState() {
    super.initState();
    _center = LatLng(
      widget.initialLat ?? 31.5204,
      widget.initialLng ?? 74.3587,
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onCameraIdle() async {
    if (_controller == null) return;
    final visible = await _controller!.getVisibleRegion();
    final latlng = LatLng(
      (visible.northeast.latitude + visible.southwest.latitude) / 2,
      (visible.northeast.longitude + visible.southwest.longitude) / 2,
    );
    setState(() => _center = latlng);
    widget.onCoords(
      lat: latlng.latitude,
      lng: latlng.longitude,
      accuracy: null,
      source: 'Map pin',
    );
  }

  Future<void> _onSearch() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;

    // Accept raw "lat,lng" input.
    final coordMatch = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$').firstMatch(q);
    if (coordMatch != null) {
      final lat = double.parse(coordMatch.group(1)!);
      final lng = double.parse(coordMatch.group(2)!);
      await _controller?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(lat, lng), 17),
      );
      setState(() => _searchHint = null);
      return;
    }

    // Accept Plus Code too.
    try {
      final trimmed = q.replaceAll(' ', '');
      final pc = olc.PlusCode.unverified(trimmed);
      if (pc.isValid) {
        final decoded = pc.decode();
        final lat = decoded.center.latitude;
        final lng = decoded.center.longitude;
        await _controller?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(lat, lng), 17),
        );
        setState(() => _searchHint = null);
        return;
      }
    } catch (_) {
      // not a plus code, fall through
    }

    // Named place search using Google Places API
    try {
      const apiKey = String.fromEnvironment(
        'GOOGLE_MAPS_API_KEY',
        defaultValue: '',
      );
      if (apiKey.isEmpty) {
        setState(() {
          _searchHint = 'No API key. Try: "31.47,74.29" or a Plus code.';
        });
        return;
      }
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?address=\${Uri.encodeComponent(q)}&key=\$apiKey',
      );
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty) {
          final location = data['results'][0]['geometry']['location'];
          final lat = (location['lat'] as num).toDouble();
          final lng = (location['lng'] as num).toDouble();
          await _controller?.animateCamera(
            CameraUpdate.newLatLngZoom(LatLng(lat, lng), 17),
          );
          setState(() => _searchHint = null);
          return;
        }
      }
      setState(() {
        _searchHint = 'No results found for "\$q". Try a more specific location.';
      });
    } catch (_) {
      setState(() {
        _searchHint = 'Search failed. Try coordinates: "31.47,74.29"';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GoogleMap(
            initialCameraPosition: CameraPosition(target: _center, zoom: 16),
            onMapCreated: (c) => _controller = c,
            onCameraIdle: _onCameraIdle,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: true,
          ),
        ),
        // Centered pin overlay
        const IgnorePointer(
          child: Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: 32),
              child: Icon(Icons.place, size: 48, color: AppColors.primary),
            ),
          ),
        ),
        // Search bar
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Column(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.borderLight),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Icon(Icons.search, size: 20),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _onSearch(),
                        decoration: const InputDecoration(
                          hintText: 'Search: coords, plus code...',
                          border: InputBorder.none,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward, size: 20),
                      tooltip: 'Search',
                      onPressed: _onSearch,
                    ),
                  ],
                ),
              ),
              if (_searchHint != null) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.borderLight),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 14, color: AppColors.textSecondaryLight),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _searchHint!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondaryLight,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        // Note about API key
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.9),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Row(
              children: const [
                Icon(Icons.info_outline,
                    size: 14, color: AppColors.textSecondaryLight),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "If tiles don't load: add your Google Maps API key in the manifest.",
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondaryLight,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---- Maps Link tab ----------------------------------------------------

class _MapsLinkTab extends StatefulWidget {
  final void Function({
    required double lat,
    required double lng,
    double? accuracy,
    required String source,
  }) onCoords;

  const _MapsLinkTab({required this.onCoords});

  @override
  State<_MapsLinkTab> createState() => _MapsLinkTabState();
}

class _MapsLinkTabState extends State<_MapsLinkTab> {
  final _urlCtrl = TextEditingController();
  String? _error;
  double? _parsedLat;
  double? _parsedLng;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _extract() {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() { _error = 'Paste a Google Maps link first.'; _parsedLat = null; _parsedLng = null; });
      return;
    }

    double? lat, lng;

    // Pattern 1: @lat,lng,zoom  (most common desktop/app share links)
    final atMatch = RegExp(r'@(-?\d+\.?\d*),(-?\d+\.?\d*)').firstMatch(url);
    if (atMatch != null) {
      lat = double.tryParse(atMatch.group(1)!);
      lng = double.tryParse(atMatch.group(2)!);
    }

    // Pattern 2: !3dlat!4dlng  (place detail links)
    if (lat == null) {
      final dMatch = RegExp(r'!3d(-?\d+\.?\d*)!4d(-?\d+\.?\d*)').firstMatch(url);
      if (dMatch != null) {
        lat = double.tryParse(dMatch.group(1)!);
        lng = double.tryParse(dMatch.group(2)!);
      }
    }

    // Pattern 3: q=lat,lng or ll=lat,lng
    if (lat == null) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        for (final key in ['q', 'll']) {
          final val = uri.queryParameters[key];
          if (val != null) {
            final parts = val.split(',');
            if (parts.length == 2) {
              lat = double.tryParse(parts[0]);
              lng = double.tryParse(parts[1]);
              if (lat != null && lng != null) break;
            }
          }
        }
      }
    }

    if (lat == null || lng == null || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      setState(() {
        _error = 'Could not extract coordinates. Open the location in Google Maps, tap Share → Copy link, and paste the full URL here.';
        _parsedLat = null;
        _parsedLng = null;
      });
      return;
    }

    setState(() { _error = null; _parsedLat = lat; _parsedLng = lng; });
    widget.onCoords(lat: lat!, lng: lng!, accuracy: null, source: 'Google Maps link');
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + keyboard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Paste a Google Maps link',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text(
            'Open the location in Google Maps → tap Share → Copy link. Paste the copied URL below.',
            style: TextStyle(color: AppColors.textSecondaryLight, fontSize: 13),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _urlCtrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Google Maps URL',
              hintText: 'https://maps.app.goo.gl/... or https://www.google.com/maps/...',
              prefixIcon: Icon(Icons.link_outlined),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _extract,
            icon: const Icon(Icons.location_on_outlined),
            label: const Text('Extract coordinates'),
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.dangerLight,
                  borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                const Icon(Icons.error_outline, color: AppColors.dangerDark, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!,
                    style: const TextStyle(color: AppColors.dangerDark, fontSize: 13))),
              ]),
            ),
          if (_parsedLat != null && _parsedLng != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.successLight,
                  borderRadius: BorderRadius.circular(10)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Coordinates extracted',
                    style: TextStyle(color: AppColors.successDark, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'Lat ${_parsedLat!.toStringAsFixed(6)}, Lng ${_parsedLng!.toStringAsFixed(6)}',
                  style: const TextStyle(fontSize: 13),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(10)),
            child: const Text(
              'Tip: Short links (maps.app.goo.gl) work only if they contain coordinates. If extraction fails, open the link in a browser first, then copy the full URL from the address bar.',
              style: TextStyle(color: AppColors.primaryDark, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Manual tab --------------------------------------------------------

class _ManualTab extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;
  final void Function({
    required double lat,
    required double lng,
    double? accuracy,
    required String source,
  }) onCoords;

  const _ManualTab({
    this.initialLat,
    this.initialLng,
    required this.onCoords,
  });

  @override
  State<_ManualTab> createState() => _ManualTabState();
}

class _ManualTabState extends State<_ManualTab> {
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initialLat != null) _latCtrl.text = widget.initialLat.toString();
    if (widget.initialLng != null) _lngCtrl.text = widget.initialLng.toString();
  }

  @override
  void dispose() {
    _latCtrl.dispose();
    _lngCtrl.dispose();
    super.dispose();
  }

  void _apply() {
    final lat = double.tryParse(_latCtrl.text.trim());
    final lng = double.tryParse(_lngCtrl.text.trim());
    if (lat == null || lng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter valid numeric coordinates.')),
      );
      return;
    }
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Coordinates out of range.')),
      );
      return;
    }
    widget.onCoords(lat: lat, lng: lng, accuracy: null, source: 'Manual entry');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Coordinates applied. Tap Save to store.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter coordinates manually',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Use this when you already know the coordinates (e.g. from a previous survey or GPS app).',
            style: TextStyle(
              color: AppColors.textSecondaryLight,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _latCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Latitude',
              hintText: '31.470200',
              prefixIcon: Icon(Icons.arrow_upward),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _lngCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Longitude',
              hintText: '74.290500',
              prefixIcon: Icon(Icons.arrow_forward),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _apply,
            icon: const Icon(Icons.check),
            label: const Text('Apply coordinates'),
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
        ],
      ),
    );
  }
}

// ---- Save footer -------------------------------------------------------

class _SaveFooter extends StatelessWidget {
  final double? lat;
  final double? lng;
  final double? accuracy;
  final String source;
  final bool saving;
  final VoidCallback onSave;

  const _SaveFooter({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.source,
    required this.saving,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final ready = lat != null && lng != null;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: const Border(top: BorderSide(color: AppColors.borderLight)),
        ),
        child: Column(
          children: [
            if (ready)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: AppColors.primaryDark,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Lat ${lat!.toStringAsFixed(6)}, Lng ${lng!.toStringAsFixed(6)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    if (accuracy != null)
                      Text(
                        'Accuracy: ±${accuracy!.round()}m',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondaryLight,
                        ),
                      ),
                  ],
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Pick a location using any of the tabs above.',
                  style: TextStyle(
                    color: AppColors.textSecondaryLight,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: (ready && !saving) ? onSave : null,
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text(saving ? 'Saving...' : 'Save location'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
