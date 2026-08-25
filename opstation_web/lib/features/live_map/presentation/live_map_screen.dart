import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class LiveMapScreen extends ConsumerStatefulWidget {
  const LiveMapScreen({super.key});
  @override
  ConsumerState<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends ConsumerState<LiveMapScreen> {
  bool _loading = true;
  List<_UserLoc> _users = [];
  final _mapController = MapController();
  DateTime? _lastRefresh;
  bool _showTracks = false;
  bool _tracksLoading = false;
  List<_UserTrack> _tracks = [];
  RealtimeChannel? _channel;
  Timer? _debounce;

  // Customers on the map
  bool _showCustomers = false;
  bool _customersLoading = false;
  List<_Cust> _customers = [];

  // Route selection
  List<Map<String, dynamic>> _routes = [];
  String? _selectedRouteId;
  bool _routeLoading = false;
  List<_Cust> _routeStops = []; // selected route's customers, in stop order

  // Colour per customer main group (group_name)
  final Map<String, Color> _groupColors = {};
  bool _custListExpanded = false;
  static const _groupPalette = <Color>[
    Color(0xFF2F6FED), Color(0xFFEF4444), Color(0xFF16A34A), Color(0xFFF59E0B),
    Color(0xFF9333EA), Color(0xFF0891B2), Color(0xFFDB2777), Color(0xFF65A30D),
    Color(0xFF7C3AED), Color(0xFFEA580C), Color(0xFF0D9488), Color(0xFF334155),
  ];
  static const _noGroupColor = Color(0xFF94A3B8);

  Color _groupColor(String group) =>
      group.isEmpty ? _noGroupColor : (_groupColors[group] ?? _noGroupColor);

  void _rebuildGroupColors() {
    final groups = <String>{
      for (final c in _customers) if (c.group.isNotEmpty) c.group,
      for (final c in _routeStops) if (c.group.isNotEmpty) c.group,
    }.toList()..sort();
    _groupColors.clear();
    for (var i = 0; i < groups.length; i++) {
      _groupColors[groups[i]] = _groupPalette[i % _groupPalette.length];
    }
  }

  // Customers currently shown on the map: a selected route's stops (in order),
  // else every located customer when "show customers" is on.
  List<_Cust> get _shownCustomers =>
      _selectedRouteId != null ? _routeStops : (_showCustomers ? _customers : const []);

  // The list shown in the right-hand collapsible panel: a route's stops stay in
  // stop order; the "all customers" list is sorted by name.
  List<_Cust> get _panelCustomers {
    if (_selectedRouteId != null) return _routeStops;
    if (!_showCustomers) return const [];
    final l = List<_Cust>.from(_customers);
    l.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return l;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeToChanges();
  }

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      if (mounted) _load();
    });
  }

  void _subscribeToChanges() {
    _channel = Supabase.instance.client
        .channel('livemap_realtime')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'visits',
          callback: (_) => _scheduleReload(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'delivery_stops',
          callback: (_) => _scheduleReload(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_channel != null) Supabase.instance.client.removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);

    try {
      final client = Supabase.instance.client;
      // Fetch all org users; filter by role in Dart (avoids PostgREST .inFilter quirks).
      final allUsers = await client
          .from('users')
          .select('id, name, role')
          .eq('org_id', orgId);
      final users = (allUsers as List)
          .where((u) => u['role'] == 'salesperson' || u['role'] == 'driver')
          .toList();
      // ignore: avoid_print
      print('LIVEMAP: ${users.length} drivers/salespeople in org');

      final List<_UserLoc> result = [];

      for (final u in users) {
        final userId = u['id'] as String;
        final role = u['role'] as String;
        final name = u['name'] as String;

        if (role == 'salesperson') {
          // Pull recent visits, filter null-GPS in Dart for safety.
          final raw = await client
              .from('visits')
              .select('id, captured_lat, captured_lng, timestamp, status, amount, customer_id')
              .eq('user_id', userId)
              .order('timestamp', ascending: false)
              .limit(20);
          final withGps = (raw as List)
              .where((r) => r['captured_lat'] != null && r['captured_lng'] != null)
              .toList();
          // ignore: avoid_print
          print('LIVEMAP: $name (salesperson) - ${raw.length} recent visits, ${withGps.length} with GPS');
          if (withGps.isEmpty) continue;
          final visit = withGps.first as Map<String, dynamic>;
          String? cName;
          String? cCode;
          final cId = visit['customer_id'] as String?;
          if (cId != null) {
            final cs = await client
                .from('customers')
                .select('shop_name, code')
                .eq('id', cId)
                .limit(1);
            if (cs.isNotEmpty) {
              cName = cs.first['shop_name'] as String?;
              cCode = cs.first['code'] as String?;
            }
          }
          result.add(_UserLoc(
            userId: userId,
            userName: name,
            role: role,
            lat: (visit['captured_lat'] as num).toDouble(),
            lng: (visit['captured_lng'] as num).toDouble(),
            timestamp: DateTime.parse(visit['timestamp'] as String).toLocal(),
            status: visit['status'] as String?,
            amount: visit['amount'] as int?,
            customerName: cName,
            customerCode: cCode,
          ));
        } else if (role == 'driver') {
          final dels = await client
              .from('deliveries')
              .select('id')
              .eq('driver_id', userId)
              .order('created_at', ascending: false)
              .limit(20);
          // ignore: avoid_print
          print('LIVEMAP: $name (driver) - ${(dels as List).length} recent deliveries');
          if (dels.isEmpty) continue;
          final dIds = dels.map((d) => d['id'] as String).toList();
          final stops = await client
              .from('delivery_stops')
              .select()
              .inFilter('delivery_id', dIds)
              .not('captured_lat', 'is', null)
              .order('id', ascending: false)
              .limit(1);
          if (stops.isEmpty) continue;
          final s = stops.first;
          DateTime ts = DateTime.now();
          for (final col in ['completed_at', 'arrived_at', 'timestamp', 'created_at']) {
            if (s[col] != null) {
              ts = DateTime.parse(s[col] as String).toLocal();
              break;
            }
          }
          result.add(_UserLoc(
            userId: userId,
            userName: name,
            role: role,
            lat: (s['captured_lat'] as num).toDouble(),
            lng: (s['captured_lng'] as num).toDouble(),
            timestamp: ts,
            status: s['status'] as String?,
            amount: null,
            customerName: s['customer_name'] as String?,
            customerCode: s['customer_code'] as String?,
          ));
        }
      }

      // Routes for the selector (cheap; names only).
      List<Map<String, dynamic>> routes = _routes;
      try {
        final r = await client.from('sales_routes')
            .select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
        routes = (r as List).cast<Map<String, dynamic>>();
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _users = result;
        _routes = routes;
        _loading = false;
        _lastRefresh = DateTime.now();
      });

      if (result.length == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController.move(LatLng(result.first.lat, result.first.lng), 14);
        });
      } else if (result.length > 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final lats = result.map((u) => u.lat).toList()..sort();
          final lngs = result.map((u) => u.lng).toList()..sort();
          final bounds = LatLngBounds(
            LatLng(lats.first, lngs.first),
            LatLng(lats.last, lngs.last),
          );
          _mapController.fitCamera(CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.all(80),
          ));
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load: ${e.toString().split('\n').first}')),
      );
    }
  }

  static Color _userColor(String userId) {
    final hash = userId.hashCode.abs();
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.7, 0.45).toColor();
  }

  Future<void> _loadTracks() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _tracksLoading = true);

    try {
      final client = Supabase.instance.client;
      final allUsers = await client
          .from('users')
          .select('id, name, role')
          .eq('org_id', orgId);
      final users = (allUsers as List)
          .where((u) => u['role'] == 'salesperson' || u['role'] == 'driver')
          .toList();

      final now = DateTime.now();
      final dayStart =
          DateTime(now.year, now.month, now.day).toUtc().toIso8601String();

      final List<_UserTrack> tracks = [];

      for (final u in users) {
        final userId = u['id'] as String;
        final role = u['role'] as String;
        final name = u['name'] as String;

        List<LatLng> points = [];

        if (role == 'salesperson') {
          final raw = await client
              .from('visits')
              .select('captured_lat, captured_lng, timestamp')
              .eq('user_id', userId)
              .gte('timestamp', dayStart)
              .order('timestamp', ascending: true);
          points = (raw as List)
              .where((r) => r['captured_lat'] != null && r['captured_lng'] != null)
              .map((r) => LatLng(
                    (r['captured_lat'] as num).toDouble(),
                    (r['captured_lng'] as num).toDouble(),
                  ))
              .toList();
        } else if (role == 'driver') {
          final dels = await client
              .from('deliveries')
              .select('id')
              .eq('driver_id', userId)
              .gte('created_at', dayStart);
          final dIds = (dels as List).map((d) => d['id'] as String).toList();
          if (dIds.isNotEmpty) {
            final stops = await client
                .from('delivery_stops')
                .select()
                .inFilter('delivery_id', dIds);
            final filtered = (stops as List)
                .where((s) => s['captured_lat'] != null && s['captured_lng'] != null)
                .toList();
            filtered.sort((a, b) {
              String? aTs;
              String? bTs;
              for (final col in ['completed_at', 'arrived_at', 'timestamp', 'created_at']) {
                aTs ??= a[col] as String?;
                bTs ??= b[col] as String?;
              }
              if (aTs == null && bTs == null) return 0;
              if (aTs == null) return 1;
              if (bTs == null) return -1;
              return DateTime.parse(aTs).compareTo(DateTime.parse(bTs));
            });
            points = filtered.map((s) => LatLng(
                  (s['captured_lat'] as num).toDouble(),
                  (s['captured_lng'] as num).toDouble(),
                )).toList();
          }
        }

        if (points.length >= 2) {
          tracks.add(_UserTrack(
            userId: userId,
            userName: name,
            role: role,
            color: _userColor(userId),
            points: points,
          ));
        }
      }

      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _tracksLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _tracksLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tracks failed: ${e.toString().split('\n').first}')),
      );
    }
  }

  Future<void> _toggleTracks() async {
    final newState = !_showTracks;
    setState(() => _showTracks = newState);
    if (newState && _tracks.isEmpty) {
      await _loadTracks();
    }
  }

  // ── Customers ───────────────────────────────────────────────────────────────
  Future<void> _loadCustomers() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _customersLoading = true);
    try {
      final rows = await Supabase.instance.client.from('customers')
          .select('id, shop_name, code, group_name, latitude, longitude')
          .eq('org_id', orgId).eq('is_active', true).limit(20000);
      final list = <_Cust>[];
      for (final c in (rows as List)) {
        final lat = c['latitude'], lng = c['longitude'];
        if (lat == null || lng == null) continue;
        list.add(_Cust(
          id: c['id'] as String,
          name: (c['shop_name'] as String?) ?? '(no name)',
          code: (c['code'] as String?) ?? '',
          group: (c['group_name'] as String?)?.trim() ?? '',
          lat: (lat as num).toDouble(),
          lng: (lng as num).toDouble(),
        ));
      }
      if (mounted) setState(() { _customers = list; _customersLoading = false; _rebuildGroupColors(); });
    } catch (e) {
      if (mounted) setState(() => _customersLoading = false);
    }
  }

  Future<void> _toggleCustomers() async {
    final on = !_showCustomers;
    setState(() => _showCustomers = on);
    if (on && _customers.isEmpty) await _loadCustomers();
  }

  // ── Route selection ─────────────────────────────────────────────────────────
  Future<void> _selectRoute(String? routeId) async {
    setState(() { _selectedRouteId = routeId; _routeStops = []; });
    if (routeId == null) return;
    setState(() => _routeLoading = true);
    try {
      final client = Supabase.instance.client;
      final stops = await client.from('route_stops')
          .select('customer_id, position, customers(id, shop_name, code, group_name, latitude, longitude)')
          .eq('route_id', routeId).order('position');
      final list = <_Cust>[];
      for (final s in (stops as List)) {
        final c = s['customers'] as Map<String, dynamic>?;
        if (c == null) continue;
        final lat = c['latitude'], lng = c['longitude'];
        if (lat == null || lng == null) continue;
        list.add(_Cust(
          id: c['id'] as String,
          name: (c['shop_name'] as String?) ?? '(no name)',
          code: (c['code'] as String?) ?? '',
          group: (c['group_name'] as String?)?.trim() ?? '',
          lat: (lat as num).toDouble(),
          lng: (lng as num).toDouble(),
        ));
      }
      if (!mounted) return;
      setState(() { _routeStops = list; _routeLoading = false; _rebuildGroupColors(); });
      // Fit the map to the route.
      if (list.length == 1) {
        _mapController.move(LatLng(list.first.lat, list.first.lng), 14);
      } else if (list.length > 1) {
        final lats = list.map((c) => c.lat).toList()..sort();
        final lngs = list.map((c) => c.lng).toList()..sort();
        _mapController.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds(LatLng(lats.first, lngs.first), LatLng(lats.last, lngs.last)),
          padding: const EdgeInsets.all(80),
        ));
      }
    } catch (e) {
      if (mounted) setState(() => _routeLoading = false);
    }
  }

  Color _freshnessColor(DateTime ts) {
    final mins = DateTime.now().difference(ts).inMinutes;
    if (mins < 30) return AppTheme.success;
    if (mins < 120) return AppTheme.warning;
    if (mins < 480) return Colors.orange;
    return AppTheme.textSecondary;
  }

  String _freshnessLabel(DateTime ts) {
    final diff = DateTime.now().difference(ts);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }

  void _focusUser(_UserLoc u) {
    _mapController.move(LatLng(u.lat, u.lng), 15);
    _showDetails(u);
  }

  void _showDetails(_UserLoc u) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _DetailsSheet(
        user: u,
        freshness: _freshnessLabel(u.timestamp),
        freshnessColor: _freshnessColor(u.timestamp),
      ),
    );
  }

  Widget _customerDot(Color c) => Container(
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)],
        ),
      );

  Widget _routeStopPin(int n, Color c) => Container(
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 3)],
        ),
        alignment: Alignment.center,
        child: Text('$n', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
      );

  void _focusCust(_Cust c, {int? stopNo}) {
    _mapController.move(LatLng(c.lat, c.lng), 16);
    _showCustSheet(c, stopNo: stopNo);
  }

  void _showCustSheet(_Cust c, {int? stopNo}) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 40, height: 40, alignment: Alignment.center,
              decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: stopNo != null
                  ? Text('$stopNo', style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primary))
                  : const Icon(Icons.storefront, color: AppTheme.primary, size: 20)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (c.code.isNotEmpty) Text(c.code, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ])),
          ]),
          if (stopNo != null) ...[
            const SizedBox(height: 8),
            Text('Route stop #$stopNo', style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: _mapController,
          options: const MapOptions(
            initialCenter: LatLng(31.5204, 74.3587), // Lahore
            initialZoom: 11,
            minZoom: 3,
            maxZoom: 18,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.opstation.web',
              maxNativeZoom: 19,
            ),
            // Planned route path (selected route, stops in order).
            if (_routeStops.length >= 2)
              PolylineLayer(polylines: [
                Polyline(
                  points: [for (final c in _routeStops) LatLng(c.lat, c.lng)],
                  color: AppTheme.primary.withOpacity(0.7),
                  strokeWidth: 3,
                ),
              ]),
            // Salesperson travel lines (how/where they moved today).
            if (_showTracks)
              PolylineLayer(
                polylines: [
                  for (final t in _tracks)
                    Polyline(
                      points: t.points,
                      color: t.color,
                      strokeWidth: 4,
                    ),
                ],
              ),
            // Customer markers: a selected route shows its numbered stops;
            // otherwise the "show customers" toggle shows every located customer.
            if (_selectedRouteId != null)
              MarkerLayer(markers: [
                for (var i = 0; i < _routeStops.length; i++)
                  Marker(
                    point: LatLng(_routeStops[i].lat, _routeStops[i].lng),
                    width: 30, height: 30, alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: () => _showCustSheet(_routeStops[i], stopNo: i + 1),
                      child: _routeStopPin(i + 1, _groupColor(_routeStops[i].group)),
                    ),
                  ),
              ])
            else if (_showCustomers)
              MarkerLayer(markers: [
                for (final c in _customers)
                  Marker(
                    point: LatLng(c.lat, c.lng),
                    width: 18, height: 18, alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: () => _showCustSheet(c),
                      child: _customerDot(_groupColor(c.group)),
                    ),
                  ),
              ]),
            MarkerLayer(
              markers: [
                for (final u in _users)
                  Marker(
                    point: LatLng(u.lat, u.lng),
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: () => _showDetails(u),
                      child: _buildMarker(u),
                    ),
                  ),
              ],
            ),
          ],
        ),
        // Status card on the left
        Positioned(
          top: 16,
          left: 16,
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.location_on, color: AppTheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('Live Map · ${_users.length} on map',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                if (_lastRefresh != null) ...[
                  const SizedBox(width: 12),
                  Text('updated ${DateFormat('h:mm a').format(_lastRefresh!)}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ],
              ]),
            ),
          ),
        ),
        // Route selector
        Positioned(
          top: 64,
          left: 16,
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.alt_route, size: 18, color: AppTheme.primary),
                const SizedBox(width: 8),
                SizedBox(
                  width: 190,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      value: _selectedRouteId,
                      hint: const Text('Select a route', style: TextStyle(fontSize: 13)),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('No route', style: TextStyle(fontSize: 13))),
                        ..._routes.map((r) => DropdownMenuItem<String?>(
                            value: r['id'] as String,
                            child: Text(r['name'] as String? ?? '-', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis))),
                      ],
                      onChanged: _routeLoading ? null : _selectRoute,
                    ),
                  ),
                ),
                if (_routeLoading)
                  const Padding(padding: EdgeInsets.only(left: 6), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
                else if (_selectedRouteId != null)
                  Text('  ${_routeStops.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)),
              ]),
            ),
          ),
        ),
        // Action buttons on the right (separate Positioned so the middle stays clickable for pan/zoom)
        Positioned(
          top: 16,
          right: 16,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            FloatingActionButton.small(
              heroTag: 'customers_toggle',
              onPressed: _customersLoading ? null : _toggleCustomers,
              backgroundColor: _showCustomers ? AppTheme.primary : Colors.white,
              foregroundColor: _showCustomers ? Colors.white : AppTheme.primary,
              tooltip: _showCustomers ? 'Hide customers' : 'Show customers',
              child: _customersLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.storefront_outlined),
            ),
            const SizedBox(width: 8),
            FloatingActionButton.small(
              heroTag: 'tracks_toggle',
              onPressed: _toggleTracks,
              backgroundColor: _showTracks ? AppTheme.primary : Colors.white,
              foregroundColor: _showTracks ? Colors.white : AppTheme.primary,
              tooltip: _showTracks ? 'Hide tracks' : 'Show tracks',
              child: _tracksLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.timeline),
            ),
            const SizedBox(width: 8),
            FloatingActionButton.small(
              heroTag: 'refresh',
              onPressed: _loading ? null : _load,
              backgroundColor: Colors.white,
              foregroundColor: AppTheme.primary,
              tooltip: 'Refresh',
              child: _loading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ]),
        ),
        Positioned(
          left: 16,
          bottom: 16,
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                const Text('FRESHNESS',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
                const SizedBox(height: 6),
                _legendDot(AppTheme.success, '< 30 min'),
                _legendDot(AppTheme.warning, '< 2 h'),
                _legendDot(Colors.orange, '< 8 h'),
                _legendDot(AppTheme.textSecondary, 'older'),
              ]),
            ),
          ),
        ),
        // Always-visible clickable user legend (right side)
        if (_users.isNotEmpty)
          Positioned(
            right: 16,
            top: 80,
            child: Card(
              elevation: 4,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          _showTracks ? 'USERS · TRACKS TODAY' : 'USERS ON MAP',
                          style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary,
                              letterSpacing: 0.6),
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final u in _users)
                        InkWell(
                          onTap: () => _focusUser(u),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(
                                u.role == 'driver' ? Icons.local_shipping : Icons.person,
                                size: 14,
                                color: AppTheme.textSecondary,
                              ),
                              const SizedBox(width: 8),
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _freshnessColor(u.timestamp),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  u.userName,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                ),
                              ),
                              if (_showTracks) ...[
                                const SizedBox(width: 8),
                                Container(
                                  width: 16,
                                  height: 3,
                                  decoration: BoxDecoration(
                                    color: _userColor(u.userId),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ],
                            ]),
                          ),
                        ),
                      // ── Collapsible customer list ─────────────────────────
                      if (_panelCustomers.isNotEmpty) ...[
                        const Divider(height: 14),
                        InkWell(
                          onTap: () => setState(() => _custListExpanded = !_custListExpanded),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            child: Row(children: [
                              Icon(_custListExpanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: AppTheme.textSecondary),
                              const SizedBox(width: 4),
                              Text('${_selectedRouteId != null ? 'ROUTE STOPS' : 'CUSTOMERS'} · ${_panelCustomers.length}',
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
                            ]),
                          ),
                        ),
                        if (_custListExpanded)
                          SizedBox(
                            height: 240,
                            child: ListView.builder(
                                itemCount: _panelCustomers.length,
                                itemBuilder: (_, i) {
                                  final c = _panelCustomers[i];
                                  return InkWell(
                                    onTap: () => _focusCust(c, stopNo: _selectedRouteId != null ? i + 1 : null),
                                    borderRadius: BorderRadius.circular(6),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                                      child: Row(children: [
                                        SizedBox(width: 22, child: Text('${i + 1}.', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                                        Container(width: 9, height: 9, decoration: BoxDecoration(color: _groupColor(c.group), shape: BoxShape.circle)),
                                        const SizedBox(width: 8),
                                        Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                                      ]),
                                    ),
                                  );
                                },
                              ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        // Groups colour legend
        if (_groupColors.isNotEmpty && (_showCustomers || _selectedRouteId != null))
          Positioned(
            left: 16,
            top: 112,
            child: Card(
              elevation: 4,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220, maxHeight: 200),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    const Text('MAIN GROUPS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
                    const SizedBox(height: 6),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          for (final e in _groupColors.entries) _legendDot(e.value, e.key),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        // zoom_controls
        Positioned(
          right: 16,
          bottom: 16,
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: 'Zoom in',
                  onPressed: () {
                    final cam = _mapController.camera;
                    _mapController.move(cam.center, cam.zoom + 1);
                  },
                ),
                const SizedBox(
                  width: 32,
                  child: Divider(height: 1),
                ),
                IconButton(
                  icon: const Icon(Icons.remove, size: 20),
                  tooltip: 'Zoom out',
                  onPressed: () {
                    final cam = _mapController.camera;
                    _mapController.move(cam.center, cam.zoom - 1);
                  },
                ),
              ],
            ),
          ),
        ),
        if (_users.isEmpty && !_loading)
          const Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No location data yet — drivers and salespeople appear here once they sync visits.'),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _legendDot(Color c, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]),
    );
  }

  Widget _buildMarker(_UserLoc u) {
    final color = _freshnessColor(u.timestamp);
    final icon = u.role == 'driver' ? Icons.local_shipping : Icons.person;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: color, width: 3),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }
}

class _Cust {
  final String id;
  final String name;
  final String code;
  final String group;
  final double lat;
  final double lng;
  _Cust({required this.id, required this.name, required this.code, required this.group, required this.lat, required this.lng});
}

class _UserLoc {
  final String userId;
  final String userName;
  final String role;
  final double lat;
  final double lng;
  final DateTime timestamp;
  final String? status;
  final int? amount;
  final String? customerName;
  final String? customerCode;

  _UserLoc({
    required this.userId,
    required this.userName,
    required this.role,
    required this.lat,
    required this.lng,
    required this.timestamp,
    this.status,
    this.amount,
    this.customerName,
    this.customerCode,
  });
}

class _DetailsSheet extends StatelessWidget {
  final _UserLoc user;
  final String freshness;
  final Color freshnessColor;
  const _DetailsSheet({required this.user, required this.freshness, required this.freshnessColor});

  @override
  Widget build(BuildContext context) {
    final cust = user.customerName == null
        ? null
        : (user.customerCode == null ? user.customerName! : '${user.customerCode} · ${user.customerName}');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(user.role == 'driver' ? Icons.local_shipping : Icons.person, color: AppTheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(user.userName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                Text(user.role.toUpperCase(),
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, letterSpacing: 0.6)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: freshnessColor.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
              child: Text(freshness, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: freshnessColor)),
            ),
          ]),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 14),
          if (cust != null) _kv(user.role == 'driver' ? 'Last stop' : 'Last visit', cust),
          if (cust != null) const SizedBox(height: 8),
          _kv('Time', DateFormat('h:mm a · d MMM y').format(user.timestamp)),
          const SizedBox(height: 8),
          _kv('Coordinates', '${user.lat.toStringAsFixed(5)}, ${user.lng.toStringAsFixed(5)}'),
          if (user.status != null) ...[
            const SizedBox(height: 8),
            _kv('Status', user.status!.toUpperCase()),
          ],
          if (user.amount != null && user.amount! > 0) ...[
            const SizedBox(height: 8),
            _kv('Amount collected', 'Rs ${user.amount}'),
          ],
          const SizedBox(height: 16),
        ]),
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
      Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
    ]);
  }
}


class _UserTrack {
  final String userId;
  final String userName;
  final String role;
  final Color color;
  final List<LatLng> points;

  _UserTrack({
    required this.userId,
    required this.userName,
    required this.role,
    required this.color,
    required this.points,
  });
}
