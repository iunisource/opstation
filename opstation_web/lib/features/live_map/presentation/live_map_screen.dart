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
  /// Opens with this trip (route run) highlighted: start, visits in order, end.
  /// Push-notification deep link: /live-map?trip=<trip id>.
  final String? tripId;
  const LiveMapScreen({super.key, this.tripId});
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

  // Today's route runs (trips): where each salesperson started / ended.
  List<_TripEnds> _tripEnds = [];
  // A single trip opened from a notification (or tapped on the map).
  _FocusTrip? _focusTrip;
  bool _focusLoading = false;
  String? _focusRequested;

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
  // When set, only customers in this main group are drawn on the map and listed
  // in the right panel. Toggled by clicking a group in the MAIN GROUPS legend.
  String? _selectedGroup;
  // Search inside the collapsible customer list (right panel).
  final TextEditingController _custSearchCtrl = TextEditingController();
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

  bool _matchesGroup(_Cust c) =>
      _selectedGroup == null || c.group == _selectedGroup;

  // Whether the right panel has a list to show at all (before the search box
  // narrows it) — so an empty search result never hides the search field.
  bool get _hasListableCustomers =>
      _selectedRouteId != null ? _routeStops.isNotEmpty : (_showCustomers && _customers.isNotEmpty);

  // Customers currently shown on the map: a selected route's stops (in order),
  // else every located customer when "show customers" is on. A selected main
  // group narrows either set to that group.
  List<_Cust> get _shownCustomers {
    final base =
        _selectedRouteId != null ? _routeStops : (_showCustomers ? _customers : const <_Cust>[]);
    if (_selectedGroup == null) return base;
    return base.where(_matchesGroup).toList();
  }

  // The list shown in the right-hand collapsible panel: a route's stops stay in
  // stop order; the "all customers" list is sorted by name. Narrowed by the
  // selected group and the search box.
  List<_Cust> get _panelCustomers {
    List<_Cust> l;
    if (_selectedRouteId != null) {
      l = List<_Cust>.from(_routeStops);
    } else if (_showCustomers) {
      l = List<_Cust>.from(_customers)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else {
      return const [];
    }
    if (_selectedGroup != null) l = l.where(_matchesGroup).toList();
    final q = _custSearchCtrl.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      l = l
          .where((c) =>
              c.name.toLowerCase().contains(q) ||
              c.code.toLowerCase().contains(q))
          .toList();
    }
    return l;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeToChanges();
    if ((widget.tripId ?? '').isNotEmpty) _openTrip(widget.tripId!);
  }

  @override
  void didUpdateWidget(covariant LiveMapScreen old) {
    super.didUpdateWidget(old);
    final id = widget.tripId;
    if (id != old.tripId && (id ?? '').isNotEmpty) _openTrip(id!);
  }

  static double? _num(dynamic v) =>
      v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));

  static LatLng? _pt(Map t, String lat, String lng) {
    final a = _num(t[lat]), b = _num(t[lng]);
    if (a == null || b == null || (a == 0 && b == 0)) return null;
    return LatLng(a, b);
  }

  static DateTime? _ts(dynamic v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

  /// Today's trips for the org → start / end flags on the map.
  Future<void> _loadTripEnds(String orgId, Map<String, String> names) async {
    try {
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day).toUtc().toIso8601String();
      final rows = await Supabase.instance.client
          .from('trips')
          .select()
          .eq('org_id', orgId)
          .gte('started_at', dayStart)
          .order('started_at', ascending: true);
      final list = <_TripEnds>[];
      for (final t in (rows as List).cast<Map<String, dynamic>>()) {
        final uid = '${t['user_id'] ?? ''}';
        list.add(_TripEnds(
          tripId: '${t['id']}',
          userId: uid,
          userName: names[uid] ?? (t['user_name'] as String?) ?? 'Salesperson',
          routeName: (t['route_name'] as String?) ?? '',
          start: _pt(t, 'start_lat', 'start_lng'),
          end: _pt(t, 'end_lat', 'end_lng'),
          startedAt: _ts(t['started_at']),
          endedAt: _ts(t['ended_at']),
        ));
      }
      if (mounted) setState(() => _tripEnds = list);
    } catch (_) {}
  }

  /// Loads one trip with its visits and fits the map to it.
  Future<void> _openTrip(String tripId) async {
    _focusRequested = tripId;
    setState(() => _focusLoading = true);
    try {
      final client = Supabase.instance.client;
      final t = await client.from('trips').select().eq('id', tripId).maybeSingle();
      if (t == null || _focusRequested != tripId) {
        if (mounted) setState(() => _focusLoading = false);
        return;
      }
      String name = (t['user_name'] as String?) ?? 'Salesperson';
      try {
        final u = await client.from('users').select('name').eq('id', '${t['user_id']}').maybeSingle();
        if (u != null && (u['name'] as String?)?.isNotEmpty == true) name = u['name'] as String;
      } catch (_) {}
      String route = (t['route_name'] as String?) ?? '';
      if (route.isEmpty && t['route_id'] != null) {
        try {
          final r = await client.from('sales_routes').select('name').eq('id', '${t['route_id']}').maybeSingle();
          route = (r?['name'] as String?) ?? '';
        } catch (_) {}
      }
      final visits = List<Map<String, dynamic>>.from(await client
          .from('visits')
          .select('captured_lat, captured_lng, timestamp, amount, customer_id')
          .eq('trip_id', tripId)
          .order('timestamp', ascending: true));
      final stops = <LatLng>[];
      num sales = 0;
      for (final v in visits) {
        sales += (v['amount'] as num?) ?? 0;
        final p = _pt(v, 'captured_lat', 'captured_lng');
        if (p != null) stops.add(p);
      }
      final ft = _FocusTrip(
        tripId: tripId,
        userId: '${t['user_id'] ?? ''}',
        userName: name,
        routeName: route,
        start: _pt(t, 'start_lat', 'start_lng'),
        end: _pt(t, 'end_lat', 'end_lng'),
        startedAt: _ts(t['started_at']),
        endedAt: _ts(t['ended_at']),
        stops: stops,
        visitCount: visits.length,
        sales: sales,
      );
      if (!mounted || _focusRequested != tripId) return;
      setState(() {
        _focusTrip = ft;
        _focusLoading = false;
      });
      final pts = ft.path;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || pts.isEmpty) return;
        if (pts.length == 1) {
          _mapController.move(pts.first, 15);
        } else {
          final lats = pts.map((p) => p.latitude).toList()..sort();
          final lngs = pts.map((p) => p.longitude).toList()..sort();
          _mapController.fitCamera(CameraFit.bounds(
            bounds: LatLngBounds(LatLng(lats.first, lngs.first), LatLng(lats.last, lngs.last)),
            padding: const EdgeInsets.all(90),
          ));
        }
      });
    } catch (e) {
      if (mounted) setState(() => _focusLoading = false);
    }
  }

  void _closeTrip() {
    setState(() {
      _focusTrip = null;
      _focusRequested = null;
    });
  }

  Widget _endPin({required bool start, bool big = false}) {
    final c = start ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    return Container(
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
      ),
      alignment: Alignment.center,
      child: Icon(start ? Icons.play_arrow_rounded : Icons.flag_rounded,
          color: Colors.white, size: big ? 18 : 14),
    );
  }

  void _showEndSheet(_TripEnds t, {required bool start}) {
    final fmt = DateFormat('h:mm a');
    final when = start ? t.startedAt : t.endedAt;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SizedBox(width: 36, height: 36, child: _endPin(start: start, big: true)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${start ? 'Route started' : 'Route ended'} · ${t.userName}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              Text(
                  [if (t.routeName.isNotEmpty) t.routeName, if (when != null) fmt.format(when)].join(' · '),
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            ])),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.timeline, size: 16),
              label: const Text('Show this route run'),
              onPressed: () {
                Navigator.of(sheetCtx).pop();
                _openTrip(t.tripId);
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _focusCard(_FocusTrip t) {
    final fmt = DateFormat('h:mm a');
    String dur = '';
    if (t.startedAt != null && t.endedAt != null) {
      final m = t.endedAt!.difference(t.startedAt!).inMinutes;
      dur = ' (${m ~/ 60}h ${m % 60}m)';
    }
    final missing = [
      if (t.start == null) 'start',
      if (t.endedAt != null && t.end == null) 'end',
    ];
    return Card(
      elevation: 5,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: _userColor(t.userId), shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${t.userName}${t.routeName.isEmpty ? '' : ' · ${t.routeName}'}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Close',
              onPressed: _closeTrip,
            ),
          ]),
          Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 16, height: 16, child: _endPin(start: true)),
              const SizedBox(width: 4),
              Text(t.startedAt == null ? 'Start' : fmt.format(t.startedAt!), style: const TextStyle(fontSize: 12)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 16, height: 16, child: _endPin(start: false)),
              const SizedBox(width: 4),
              Text(t.endedAt == null ? 'Still running' : '${fmt.format(t.endedAt!)}$dur',
                  style: const TextStyle(fontSize: 12)),
            ]),
            Text('${t.visitCount} visit${t.visitCount == 1 ? '' : 's'} · Sales ${NumberFormat('#,##0').format(t.sales)}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('No GPS was recorded for the ${missing.join(' and ')} location of this route.',
                  style: const TextStyle(fontSize: 11, color: AppTheme.warning)),
            ),
        ]),
      ),
    );
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
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'trips',
          callback: (_) => _scheduleReload(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _custSearchCtrl.dispose();
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
          .eq('org_id', orgId).or('role.is.null,role.neq.retailer');
      final users = (allUsers as List)
          .where((u) => u['role'] == 'salesperson' || u['role'] == 'driver')
          .toList();
      final tripEndsFut = _loadTripEnds(orgId, {
        for (final u in allUsers as List) '${u['id']}': (u['name'] as String?) ?? '',
      });
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

      await tripEndsFut;
      if (_showTracks) _loadTracks();

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

      if (_focusTrip != null || _focusRequested != null) {
        // A route run is open — keep the map on it.
      } else if (result.length == 1) {
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
          .eq('org_id', orgId).or('role.is.null,role.neq.retailer');
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
          // Begin the line where the route was started and finish it where it
          // was ended (today's first start / last end for this salesperson).
          final mine = _tripEnds.where((t) => t.userId == userId).toList();
          if (mine.isNotEmpty) {
            final s0 = mine.first.start;
            final eN = mine.last.end;
            if (s0 != null) points.insert(0, s0);
            if (eN != null) points.add(eN);
          }
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
    setState(() {
      _showCustomers = on;
      if (!on) {
        _selectedGroup = null;
        _custSearchCtrl.clear();
      }
    });
    if (on && _customers.isEmpty) await _loadCustomers();
  }

  // ── Route selection ─────────────────────────────────────────────────────────
  Future<void> _selectRoute(String? routeId) async {
    // Clear any group filter so a new route's stops aren't hidden by a stale
    // selection from the previous view.
    setState(() { _selectedRouteId = routeId; _routeStops = []; _selectedGroup = null; });
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
            // The route run opened from a notification: start → visits → end.
            if (_focusTrip != null && _focusTrip!.path.length >= 2)
              PolylineLayer(polylines: [
                Polyline(
                  points: _focusTrip!.path,
                  color: _userColor(_focusTrip!.userId),
                  strokeWidth: 4.5,
                ),
              ]),
            if (_focusTrip != null)
              MarkerLayer(markers: [
                for (var i = 0; i < _focusTrip!.stops.length; i++)
                  Marker(
                    point: _focusTrip!.stops[i],
                    width: 24, height: 24, alignment: Alignment.center,
                    child: _routeStopPin(i + 1, _userColor(_focusTrip!.userId)),
                  ),
              ]),
            // Where each route run started (green) and ended (red) today.
            MarkerLayer(markers: [
              for (final t in _focusTrip != null
                  ? _tripEnds.where((x) => x.tripId == _focusTrip!.tripId)
                  : _tripEnds) ...[
                if (t.start != null)
                  Marker(
                    point: t.start!,
                    width: 28, height: 28, alignment: Alignment.center,
                    child: Tooltip(
                      message: 'Route started · ${t.userName}',
                      child: GestureDetector(onTap: () => _showEndSheet(t, start: true), child: _endPin(start: true)),
                    ),
                  ),
                if (t.end != null)
                  Marker(
                    point: t.end!,
                    width: 28, height: 28, alignment: Alignment.center,
                    child: Tooltip(
                      message: 'Route ended · ${t.userName}',
                      child: GestureDetector(onTap: () => _showEndSheet(t, start: false), child: _endPin(start: false)),
                    ),
                  ),
              ],
              // Opened trip from another day (not in today's list): its own ends.
              if (_focusTrip != null && !_tripEnds.any((x) => x.tripId == _focusTrip!.tripId)) ...[
                if (_focusTrip!.start != null)
                  Marker(point: _focusTrip!.start!, width: 30, height: 30, alignment: Alignment.center,
                      child: _endPin(start: true, big: true)),
                if (_focusTrip!.end != null)
                  Marker(point: _focusTrip!.end!, width: 30, height: 30, alignment: Alignment.center,
                      child: _endPin(start: false, big: true)),
              ],
            ]),
            // Customer markers: a selected route shows its numbered stops;
            // otherwise the "show customers" toggle shows every located customer.
            if (_selectedRouteId != null)
              MarkerLayer(markers: [
                for (var i = 0; i < _routeStops.length; i++)
                  if (_matchesGroup(_routeStops[i]))
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
                for (final c in _shownCustomers)
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
        // Opened route run (from a Route started / ended notification).
        if (_focusTrip != null || _focusLoading)
          Positioned(
            top: 118,
            left: 16,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: (MediaQuery.of(context).size.width - 32).clamp(200.0, 380.0).toDouble()),
              child: _focusTrip == null
                  ? const Card(
                      elevation: 4,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 10),
                          Text('Loading route…', style: TextStyle(fontSize: 12.5)),
                        ]),
                      ),
                    )
                  : _focusCard(_focusTrip!),
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
        // Bottom-left stack: MAIN GROUPS (clickable filter) above FRESHNESS.
        // Kept in one Column so the two cards never overlap the route selector.
        Positioned(
          left: 16,
          bottom: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_groupColors.isNotEmpty && (_showCustomers || _selectedRouteId != null)) ...[
                _groupsLegendCard(),
                const SizedBox(height: 10),
              ],
              Card(
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
                    if (_tripEnds.isNotEmpty || _focusTrip != null) ...[
                      const SizedBox(height: 8),
                      const Text('ROUTES',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
                      const SizedBox(height: 6),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(width: 14, height: 14, child: _endPin(start: true)),
                        const SizedBox(width: 8),
                        const Text('Started', style: TextStyle(fontSize: 11)),
                      ]),
                      const SizedBox(height: 4),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(width: 14, height: 14, child: _endPin(start: false)),
                        const SizedBox(width: 8),
                        const Text('Ended', style: TextStyle(fontSize: 11)),
                      ]),
                    ],
                  ]),
                ),
              ),
            ],
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
                      if (_hasListableCustomers) ...[
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
                        if (_custListExpanded) ...[
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: SizedBox(
                              height: 34,
                              child: TextField(
                                controller: _custSearchCtrl,
                                onChanged: (_) => setState(() {}),
                                style: const TextStyle(fontSize: 12),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: 'Search name or code...',
                                  hintStyle: const TextStyle(fontSize: 12),
                                  prefixIcon: const Icon(Icons.search, size: 16),
                                  prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                                  suffixIcon: _custSearchCtrl.text.isEmpty
                                      ? null
                                      : IconButton(
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                                          icon: const Icon(Icons.clear, size: 14),
                                          onPressed: () => setState(() => _custSearchCtrl.clear()),
                                        ),
                                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Builder(builder: (_) {
                            final list = _panelCustomers;
                            if (list.isEmpty) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Text('No customers match.',
                                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                              );
                            }
                            return SizedBox(
                              height: 240,
                              child: ListView.builder(
                                  itemCount: list.length,
                                  itemBuilder: (_, i) {
                                    final c = list[i];
                                    // In route mode the label is the true stop
                                    // position (unaffected by search/group filter).
                                    final stopNo = _selectedRouteId != null
                                        ? _routeStops.indexOf(c) + 1
                                        : i + 1;
                                    return InkWell(
                                      onTap: () => _focusCust(c, stopNo: _selectedRouteId != null ? stopNo : null),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                                        child: Row(children: [
                                          SizedBox(width: 22, child: Text('$stopNo.', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                                          Container(width: 9, height: 9, decoration: BoxDecoration(color: _groupColor(c.group), shape: BoxShape.circle)),
                                          const SizedBox(width: 8),
                                          Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                                        ]),
                                      ),
                                    );
                                  },
                                ),
                            );
                          }),
                        ],
                      ],
                    ],
                  ),
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

  /// Clickable MAIN GROUPS legend. Tapping a group filters the map (and the
  /// customer list) to only that group; tapping the selected group again — or
  /// the "All groups" row — clears the filter.
  Widget _groupsLegendCard() {
    final entries = _groupColors.entries.toList();
    return Card(
      elevation: 4,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220, maxHeight: 240),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Text('MAIN GROUPS',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
              if (_selectedGroup != null) ...[
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _selectedGroup = null),
                  borderRadius: BorderRadius.circular(4),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text('Clear',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 6),
            Flexible(
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  _groupLegendRow(null, AppTheme.textSecondary, 'All groups'),
                  for (final e in entries) _groupLegendRow(e.key, e.value, e.key),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _groupLegendRow(String? group, Color color, String label) {
    final selected = _selectedGroup == group;
    return InkWell(
      onTap: () => setState(() {
        // Tapping the active group clears; "All groups" (group == null) always clears.
        _selectedGroup = (group == null || _selectedGroup == group) ? null : group;
      }),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary.withOpacity(0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          group == null
              ? Icon(Icons.done_all, size: 11, color: color)
              : Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected ? AppTheme.primary : AppTheme.textPrimary)),
          ),
          if (selected) ...[
            const SizedBox(width: 6),
            const Icon(Icons.check, size: 12, color: AppTheme.primary),
          ],
        ]),
      ),
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


class _TripEnds {
  final String tripId, userId, userName, routeName;
  final LatLng? start, end;
  final DateTime? startedAt, endedAt;
  _TripEnds({
    required this.tripId,
    required this.userId,
    required this.userName,
    required this.routeName,
    this.start,
    this.end,
    this.startedAt,
    this.endedAt,
  });
}

class _FocusTrip {
  final String tripId, userId, userName, routeName;
  final LatLng? start, end;
  final DateTime? startedAt, endedAt;
  final List<LatLng> stops;
  final int visitCount;
  final num sales;
  _FocusTrip({
    required this.tripId,
    required this.userId,
    required this.userName,
    required this.routeName,
    this.start,
    this.end,
    this.startedAt,
    this.endedAt,
    required this.stops,
    required this.visitCount,
    required this.sales,
  });

  /// Start → visits in order → end.
  List<LatLng> get path => [if (start != null) start!, ...stops, if (end != null) end!];
}
