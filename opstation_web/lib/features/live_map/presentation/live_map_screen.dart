import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/visit_outcome.dart';
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
  // Replay of the opened route run: the icon moves start → visits → end,
  // keeping the real timing (a long stop or gap takes longer to play).
  Timer? _playTimer;
  bool _playing = false;
  double _playT = 0; // 0 … 1
  double _speed = 1;
  static const _playSeconds = 30.0; // whole day at 1×

  /// (point, time) in time order; entries without a time are spaced evenly.
  List<(LatLng, DateTime)> _playPts(_FocusTrip t) {
    final out = <(LatLng, DateTime)>[];
    if (t.start != null && t.startedAt != null) out.add((t.start!, t.startedAt!));
    for (final v in t.visits) {
      if (v.point != null && v.at != null) out.add((v.point!, v.at!));
    }
    if (t.end != null && t.endedAt != null) out.add((t.end!, t.endedAt!));
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out;
  }

  /// Where the icon is and the clock time at progress [p].
  (LatLng, DateTime)? _playAt(List<(LatLng, DateTime)> pts, double p) {
    if (pts.isEmpty) return null;
    if (pts.length == 1) return pts.first;
    final t0 = pts.first.$2, t1 = pts.last.$2;
    final total = t1.difference(t0).inMilliseconds;
    if (total <= 0) return pts.last;
    final now = t0.add(Duration(milliseconds: (total * p).round()));
    for (var i = 1; i < pts.length; i++) {
      if (!pts[i].$2.isBefore(now)) {
        final a = pts[i - 1], b = pts[i];
        final seg = b.$2.difference(a.$2).inMilliseconds;
        final f = seg <= 0 ? 1.0 : now.difference(a.$2).inMilliseconds / seg;
        return (LatLng(a.$1.latitude + (b.$1.latitude - a.$1.latitude) * f,
            a.$1.longitude + (b.$1.longitude - a.$1.longitude) * f), now);
      }
    }
    return pts.last;
  }

  void _togglePlay() {
    if (_playing) {
      _playTimer?.cancel();
      setState(() => _playing = false);
      return;
    }
    if (_playT >= 1) _playT = 0;
    setState(() => _playing = true);
    _playTimer?.cancel();
    _playTimer = Timer.periodic(const Duration(milliseconds: 50), (tm) {
      if (!mounted || _focusTrip == null) { tm.cancel(); return; }
      setState(() {
        _playT = (_playT + 0.05 * _speed / _playSeconds).clamp(0.0, 1.0);
        if (_playT >= 1) { _playing = false; tm.cancel(); }
      });
    });
  }

  void _stopPlay() {
    _playTimer?.cancel();
    _playing = false;
    _playT = 0;
  }

  bool _loading = true;
  List<_UserLoc> _users = [];

  // The day on show. Today = live (realtime updates, freshness colours);
  // a past day = that day's last positions, route runs, tracks and visits.
  DateTime _day = _todayDate();
  static DateTime _todayDate() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }
  bool get _isToday => _day == _todayDate();
  String get _dayStartIso => _day.toUtc().toIso8601String();
  String get _dayEndIso => _day.add(const Duration(days: 1)).toUtc().toIso8601String();
  int _loadSeq = 0;

  // Visits that were outside the geofence / not verified / skipped on the day,
  // pinned where the salesperson actually was (works for shops with no saved
  // location too — the pin is the salesperson's own GPS).
  bool _showFlagged = true;
  List<_FlagVisit> _flagged = [];
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
      final rows = await Supabase.instance.client
          .from('trips')
          .select()
          .eq('org_id', orgId)
          .gte('started_at', _dayStartIso)
          .lt('started_at', _dayEndIso)
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
          .select('*, customers(shop_name, code)')
          .eq('trip_id', tripId)
          .order('timestamp', ascending: true));
      // Every visit keeps its number in visiting order (1, 2, 3 …), even when
      // it has no GPS point and so can't be drawn.
      final visitList = <_FocusVisit>[];
      num sales = 0;
      for (var i = 0; i < visits.length; i++) {
        final v = visits[i];
        sales += (v['amount'] as num?) ?? 0;
        final cust = v['customers'] as Map?;
        visitList.add(_FocusVisit(
          no: i + 1,
          point: _pt(v, 'captured_lat', 'captured_lng'),
          at: _ts(v['timestamp']),
          shop: '${cust?['shop_name'] ?? 'Shop'}',
          code: '${cust?['code'] ?? ''}',
          status: '${v['status'] ?? ''}',
          amount: (v['amount'] as num?) ?? 0,
          receipt: '${v['receipt_number'] ?? ''}',
          notes: '${v['notes'] ?? ''}',
          distance: (v['distance_meters'] as num?)?.toDouble(),
          place: '${v['location_name'] ?? ''}',
        ));
      }
      final stops = [for (final v in visitList) if (v.point != null) v.point!];
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
        visits: visitList,
        visitCount: visits.length,
        sales: sales,
        cutoff: '${t['close_reason'] ?? ''}' == 'cutoff',
      );
      if (!mounted || _focusRequested != tripId) return;
      setState(() {
        _stopPlay();
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
      _stopPlay();
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
              Text(t.endedAt == null ? 'Still running' : '${t.cutoff ? 'Cut-off ' : ''}${fmt.format(t.endedAt!)}$dur',
                  style: const TextStyle(fontSize: 12)),
            ]),
            Text('${t.visitCount} visit${t.visitCount == 1 ? '' : 's'} · Sales ${NumberFormat('#,##0').format(t.sales)}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          if (_playPts(t).length >= 2) _playControls(t),
          if (t.visits.any((v) => v.point == null))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'Not on the map (no GPS): ${t.visits.where((v) => v.point == null).map((v) => '#${v.no} ${v.shop}').join(', ')}',
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            ),
          if (t.cutoff)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Not ended by the salesperson — the system auto-closed it at the cut-off time, so there is no end location.',
                  style: TextStyle(fontSize: 11, color: AppTheme.warning)),
            )
          else if (missing.isNotEmpty)
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
    if (!_isToday) return; // a past day doesn't change
    _debounce = Timer(const Duration(milliseconds: 800), () {
      if (mounted && _isToday) _load();
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
    _playTimer?.cancel();
    _debounce?.cancel();
    _custSearchCtrl.dispose();
    if (_channel != null) Supabase.instance.client.removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final seq = ++_loadSeq;
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
      final names = {
        for (final u in allUsers as List) '${u['id']}': (u['name'] as String?) ?? '',
      };
      final tripEndsFut = _loadTripEnds(orgId, names);
      final flaggedFut = _loadFlagged([
        for (final u in users)
          if (u['role'] == 'salesperson') u['id'] as String
      ], names);
      // ignore: avoid_print
      print('LIVEMAP: ${users.length} drivers/salespeople in org');

      final List<_UserLoc> result = [];

      for (final u in users) {
        final userId = u['id'] as String;
        final role = u['role'] as String;
        final name = u['name'] as String;

        if (role == 'salesperson') {
          // Pull recent visits, filter null-GPS in Dart for safety.
          var vq = client
              .from('visits')
              .select('id, captured_lat, captured_lng, timestamp, status, amount, customer_id')
              .eq('user_id', userId);
          if (!_isToday) vq = vq.gte('timestamp', _dayStartIso).lt('timestamp', _dayEndIso);
          final raw = await vq.order('timestamp', ascending: false).limit(20);
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
          var dq = client
              .from('deliveries')
              .select('id')
              .eq('driver_id', userId);
          if (!_isToday) dq = dq.gte('created_at', _dayStartIso).lt('created_at', _dayEndIso);
          final dels = await dq.order('created_at', ascending: false).limit(20);
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
      await flaggedFut;
      if (!mounted || seq != _loadSeq) return; // a newer day was picked
      if (_showTracks) _loadTracks();

      // Routes for the selector (cheap; names only).
      List<Map<String, dynamic>> routes = _routes;
      try {
        final r = await client.from('sales_routes')
            .select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
        routes = (r as List).cast<Map<String, dynamic>>();
      } catch (_) {}

      if (!mounted || seq != _loadSeq) return;
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

      final dayStart = _dayStartIso;
      final dayEnd = _dayEndIso;

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
              .lt('timestamp', dayEnd)
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
              .gte('created_at', dayStart)
              .lt('created_at', dayEnd);
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
    if (!_isToday) return AppTheme.textSecondary;
    final mins = DateTime.now().difference(ts).inMinutes;
    if (mins < 30) return AppTheme.success;
    if (mins < 120) return AppTheme.warning;
    if (mins < 480) return Colors.orange;
    return AppTheme.textSecondary;
  }

  String _freshnessLabel(DateTime ts) {
    if (!_isToday) return DateFormat('h:mm a').format(ts);
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

  Widget _playControls(_FocusTrip t) {
    final at = _playAt(_playPts(t), _playT);
    // The next visit not reached yet.
    _FocusVisit? next;
    if (at != null) {
      for (final v in t.visits) {
        if (v.at != null && v.point != null && v.at!.isAfter(at.$2)) { next = v; break; }
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: _playing ? 'Pause' : 'Replay the day',
          icon: Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
              color: _userColor(t.userId), size: 30),
          onPressed: _togglePlay,
        ),
        PopupMenuButton<double>(
          tooltip: 'Speed',
          initialValue: _speed,
          onSelected: (v) => setState(() => _speed = v),
          itemBuilder: (_) => [
            for (final v in const [0.5, 1.0, 2.0, 4.0])
              PopupMenuItem(value: v, child: Text('${v == v.roundToDouble() ? v.toInt() : v}×')),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text('${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}×',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
            child: Slider(
              value: _playT,
              activeColor: _userColor(t.userId),
              onChanged: (v) => setState(() => _playT = v),
            ),
          ),
        ),
        SizedBox(
          width: 118,
          child: Text(
            at == null ? '' : '${DateFormat('h:mm a').format(at.$2)}${next == null ? '' : ' → #${next.no}'}',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
          ),
        ),
      ]),
    );
  }

  Widget _visitPin(String label, Color c) => Container(
        height: 24,
        constraints: const BoxConstraints(minWidth: 24),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 3)],
        ),
        // widthFactor 1 keeps the pin just as wide as its number.
        child: Center(widthFactor: 1, child: Text(label, maxLines: 1,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800))),
      );

  void _showVisitSheet(List<_FocusVisit> all, {_FocusVisit? first}) {
    // The tapped visit first, then any others at the same spot.
    final g = first == null ? all : [first, ...all.where((v) => v != first)];
    final fmt = DateFormat('h:mm a');
    final nf = NumberFormat('#,##0');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            if (g.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('${g.length} visits at this same spot',
                    style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
              ),
            for (final v in g) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 38, height: 38, alignment: Alignment.center,
                  decoration: BoxDecoration(color: _userColor(_focusTrip?.userId ?? '').withOpacity(0.14),
                      borderRadius: BorderRadius.circular(10)),
                  child: Text('${v.no}', style: TextStyle(fontWeight: FontWeight.w800,
                      color: _userColor(_focusTrip?.userId ?? ''))),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${v.shop}${v.place.isEmpty ? '' : ' (${v.place})'}',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  if (v.code.isNotEmpty) Text(v.code, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 14, runSpacing: 4, children: [
                    _kv('Visit', '#${v.no}${v.at == null ? '' : ' · ${fmt.format(v.at!)}'}'),
                    _kv('Result', visitOutcomeLabel(v.status, v.amount)),
                    _kv('Collected', 'Rs ${nf.format(v.amount)}'),
                    if (v.receipt.isNotEmpty) _kv('CR#', v.receipt),
                    if (v.distance != null && v.distance! > 0) _kv('From shop', '${v.distance!.round()} m'),
                  ]),
                  if (v.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(v.notes.trim(), style: const TextStyle(fontSize: 12.5)),
                  ],
                ])),
              ]),
              if (v != g.last) const Divider(height: 24),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      ]);

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

  // ── Day picker ──────────────────────────────────────────────────────────────
  void _setDay(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    if (day.isAfter(_todayDate()) || day == _day) return;
    setState(() {
      _day = day;
      _users = [];
      _tripEnds = [];
      _tracks = [];
      _flagged = [];
    });
    _load();
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2023),
      lastDate: _todayDate(),
      helpText: 'Show the map for',
    );
    if (d != null) _setDay(d);
  }

  String get _dayLabel {
    if (_isToday) return 'Today';
    if (_day == _todayDate().subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('EEE d MMM y').format(_day);
  }

  Widget _dayChip({bool dense = false}) {
    final canNext = _day.isBefore(_todayDate());
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Previous day',
        icon: const Icon(Icons.chevron_left, size: 20),
        onPressed: () => _setDay(_day.subtract(const Duration(days: 1))),
      ),
      InkWell(
        onTap: _pickDay,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: dense ? 4 : 6, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.calendar_today_outlined, size: 14, color: AppTheme.primary),
            const SizedBox(width: 6),
            Text(_dayLabel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Next day',
        icon: const Icon(Icons.chevron_right, size: 20),
        onPressed: canNext ? () => _setDay(_day.add(const Duration(days: 1))) : null,
      ),
      if (!_isToday)
        TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
          onPressed: () => _setDay(_todayDate()),
          child: const Text('Today', style: TextStyle(fontSize: 12)),
        ),
    ]);
  }

  // ── Flagged visits (outside geofence / not verified / skipped) ─────────────
  Future<void> _loadFlagged(List<String> spIds, Map<String, String> names) async {
    if (spIds.isEmpty) {
      if (mounted) setState(() => _flagged = []);
      return;
    }
    try {
      final client = Supabase.instance.client;
      final out = <_FlagVisit>[];
      for (var i = 0; i < spIds.length; i += 80) {
        final chunk = spIds.sublist(i, i + 80 > spIds.length ? spIds.length : i + 80);
        final rows = await client
            .from('visits')
            .select('id, trip_id, user_id, status, timestamp, captured_lat, captured_lng, distance_meters, amount, notes, customers(shop_name, code)')
            .inFilter('user_id', chunk)
            .inFilter('status', const ['outside', 'noLocation', 'no_location', 'skipped'])
            .gte('timestamp', _dayStartIso)
            .lt('timestamp', _dayEndIso)
            .order('timestamp', ascending: true);
        for (final v in (rows as List).cast<Map<String, dynamic>>()) {
          final cust = v['customers'] as Map?;
          final uid = '${v['user_id'] ?? ''}';
          out.add(_FlagVisit(
            tripId: '${v['trip_id'] ?? ''}',
            userId: uid,
            userName: names[uid] ?? 'Salesperson',
            shop: '${cust?['shop_name'] ?? 'Shop'}',
            code: '${cust?['code'] ?? ''}',
            status: '${v['status'] ?? ''}',
            at: _ts(v['timestamp']),
            point: _pt(v, 'captured_lat', 'captured_lng'),
            distance: (v['distance_meters'] as num?)?.toDouble(),
            amount: (v['amount'] as num?) ?? 0,
            notes: '${v['notes'] ?? ''}',
          ));
        }
      }
      if (mounted) setState(() => _flagged = out);
    } catch (_) {
      if (mounted) setState(() => _flagged = []);
    }
  }

  static Color _flagColor(_FlagVisit f) {
    final label = visitOutcomeLabel(f.status, f.amount);
    if (label == 'Outside geofence') return const Color(0xFFEA580C);
    if (label == 'Skipped') return const Color(0xFF64748B);
    return const Color(0xFFDC2626); // not verified
  }

  static IconData _flagIcon(_FlagVisit f) {
    final label = visitOutcomeLabel(f.status, f.amount);
    if (label == 'Outside geofence') return Icons.wrong_location;
    if (label == 'Skipped') return Icons.block;
    return Icons.gps_off;
  }

  Widget _flagPin(_FlagVisit f) => Container(
        decoration: BoxDecoration(
          color: _flagColor(f),
          shape: BoxShape.circle,
          // Ring in the salesperson's colour, so you can tell whose it is.
          border: Border.all(color: _userColor(f.userId), width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 3)],
        ),
        alignment: Alignment.center,
        child: Icon(_flagIcon(f), color: Colors.white, size: 13),
      );

  void _showFlagSheet(List<_FlagVisit> list, {String? title}) {
    final fmt = DateFormat('h:mm a');
    final nf = NumberFormat('#,##0');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              for (final f in list) ...[
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 30, height: 30, child: _flagPin(f)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(f.shop, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                    Text([f.userName, if (f.code.isNotEmpty) f.code].join(' · '),
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 14, runSpacing: 4, children: [
                      _kv('Result', visitOutcomeLabel(f.status, f.amount)),
                      if (f.at != null) _kv('Time', fmt.format(f.at!)),
                      _kv('Collected', 'Rs ${nf.format(f.amount)}'),
                      _kv('From shop', f.distance != null && f.distance! > 0
                          ? '${f.distance!.round()} m'
                          : 'Shop has no saved location'),
                      if (f.point == null) _kv('GPS', 'Not recorded'),
                    ]),
                    if (f.notes.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(f.notes.trim(), style: const TextStyle(fontSize: 12.5)),
                    ],
                    if (f.tripId.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      TextButton.icon(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                        icon: const Icon(Icons.timeline, size: 16),
                        label: const Text('Show this route run'),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _openTrip(f.tripId);
                        },
                      ),
                    ],
                  ])),
                ]),
                if (f != list.last) const Divider(height: 24),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Flagged visits close together share one tap target.
  List<List<_FlagVisit>> get _flagGroups {
    final groups = <List<_FlagVisit>>[];
    for (final f in _flagged) {
      if (f.point == null) continue;
      if (_focusTrip != null && f.tripId != _focusTrip!.tripId) continue;
      List<_FlagVisit>? hit;
      for (final g in groups) {
        final p = g.first.point!;
        if ((p.latitude - f.point!.latitude).abs() < 0.00012 && (p.longitude - f.point!.longitude).abs() < 0.00012) {
          hit = g;
          break;
        }
      }
      if (hit != null) {
        hit.add(f);
      } else {
        groups.add([f]);
      }
    }
    return groups;
  }

  // ── Panels (shared by desktop overlays and the mobile sheet) ───────────────
  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(t,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
      );

  Widget _usersList({required VoidCallback refresh, BuildContext? sheetCtx}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      _sectionTitle(_showTracks
          ? 'USERS · TRACKS ${_isToday ? 'TODAY' : 'THIS DAY'}'
          : (_isToday ? 'USERS ON MAP' : 'LAST POSITION THIS DAY')),
      const SizedBox(height: 6),
      if (_users.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Text('Nobody on the map for this day.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ),
      for (final u in _users)
        InkWell(
          onTap: () {
            if (sheetCtx != null) Navigator.of(sheetCtx).pop();
            _focusUser(u);
          },
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(children: [
              Icon(u.role == 'driver' ? Icons.local_shipping : Icons.person, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  color: _isToday ? _freshnessColor(u.timestamp) : _userColor(u.userId),
                  shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(u.userName, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
              if (!_isToday)
                Text(DateFormat('h:mm a').format(u.timestamp),
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
              if (_showTracks) ...[
                const SizedBox(width: 8),
                Container(width: 16, height: 3,
                    decoration: BoxDecoration(color: _userColor(u.userId), borderRadius: BorderRadius.circular(2))),
              ],
            ]),
          ),
        ),
    ]);
  }

  Widget _customerList({required VoidCallback refresh, BuildContext? sheetCtx, double listHeight = 240}) {
    if (!_hasListableCustomers) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      const Divider(height: 14),
      InkWell(
        onTap: () { _custListExpanded = !_custListExpanded; refresh(); },
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
              onChanged: (_) => refresh(),
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
                        onPressed: () { _custSearchCtrl.clear(); refresh(); },
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
              child: Text('No customers match.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            );
          }
          return SizedBox(
            height: listHeight,
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) {
                final c = list[i];
                final stopNo = _selectedRouteId != null ? _routeStops.indexOf(c) + 1 : i + 1;
                return InkWell(
                  onTap: () {
                    if (sheetCtx != null) Navigator.of(sheetCtx).pop();
                    _focusCust(c, stopNo: _selectedRouteId != null ? stopNo : null);
                  },
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
    ]);
  }

  /// Freshness / routes / visit legends.
  Widget _legendContent({BuildContext? sheetCtx}) {
    final noGps = _flagged.where((f) => f.point == null).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (_isToday) ...[
        const Text('FRESHNESS',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
        const SizedBox(height: 6),
        _legendDot(AppTheme.success, '< 30 min'),
        _legendDot(AppTheme.warning, '< 2 h'),
        _legendDot(Colors.orange, '< 8 h'),
        _legendDot(AppTheme.textSecondary, 'older'),
      ] else
        Text('Last position on ${DateFormat('d MMM').format(_day)}',
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
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
      if (_showFlagged && _flagged.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('VISITS TO CHECK · ${_flagged.length}',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
        const SizedBox(height: 6),
        _legendIcon(const Color(0xFFEA580C), Icons.wrong_location, 'Outside geofence'),
        _legendIcon(const Color(0xFFDC2626), Icons.gps_off, 'Not verified'),
        _legendIcon(const Color(0xFF64748B), Icons.block, 'Skipped'),
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Text('Ring colour = salesperson', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ),
        if (noGps.isNotEmpty)
          InkWell(
            onTap: () {
              if (sheetCtx != null) Navigator.of(sheetCtx).pop();
              _showFlagSheet(noGps, title: 'Visits with no GPS recorded');
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${noGps.length} with no GPS — see list',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary)),
            ),
          ),
      ],
    ]);
  }

  Widget _legendIcon(Color c, IconData icon, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 16, height: 16,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            child: Icon(icon, size: 10, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 11)),
        ]),
      );

  void _openMobilePanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void refresh() { if (mounted) setState(() {}); setSheet(() {}); }
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.92,
          expand: false,
          builder: (_, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 12),
              _usersList(refresh: refresh, sheetCtx: ctx),
              _customerList(refresh: refresh, sheetCtx: ctx, listHeight: 280),
              const Divider(height: 20),
              _legendContent(sheetCtx: ctx),
              if (_groupColors.isNotEmpty && (_showCustomers || _selectedRouteId != null)) ...[
                const Divider(height: 20),
                _groupsLegendCard(onChange: refresh, flat: true),
              ],
            ],
          ),
        );
      }),
    );
  }

  List<Widget> _mapChildren() => [
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
            // Visits to check: outside the geofence, not verified, skipped —
            // pinned at the salesperson's own GPS (shop location not needed).
            if (_showFlagged && _flagged.isNotEmpty)
              MarkerLayer(markers: [
                for (final g in _flagGroups)
                  Marker(
                    point: g.first.point!,
                    width: g.length > 1 ? 34 : 26, height: g.length > 1 ? 34 : 26, alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: () => _showFlagSheet(g, title: g.length > 1 ? '${g.length} visits at this spot' : null),
                      child: Tooltip(
                        message: '${g.first.userName} · ${g.first.shop} · ${visitOutcomeLabel(g.first.status, g.first.amount)}',
                        child: Stack(clipBehavior: Clip.none, children: [
                          Positioned.fill(child: _flagPin(g.first)),
                          if (g.length > 1)
                            Positioned(
                              right: -4, top: -4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                                child: Text('${g.length}', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
                              ),
                            ),
                        ]),
                      ),
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
            // The opened route run's visits, numbered in visiting order — drawn
            // last so no person or start / end pin covers a number. Tap = details.
            if (_focusTrip != null)
              MarkerLayer(markers: [
                // One pin per visit. Visits at the same spot fan out in a small
                // circle around it (fixed on screen), so every number shows.
                for (final g in _groupFocusVisits(_focusTrip!.visits))
                  for (var k = 0; k < g.length; k++)
                    Marker(
                      point: g[k].point!,
                      width: 120, height: 120, alignment: Alignment.center,
                      child: Center(
                        child: Transform.translate(
                          offset: g.length == 1
                              ? Offset.zero
                              : Offset((14.0 + 3 * g.length) * math.cos(-math.pi / 2 + 2 * math.pi * k / g.length),
                                  (14.0 + 3 * g.length) * math.sin(-math.pi / 2 + 2 * math.pi * k / g.length)),
                          child: GestureDetector(
                            onTap: () => _showVisitSheet(g, first: g[k]),
                            child: Tooltip(
                              message: '#${g[k].no} ${g[k].shop}',
                              child: _visitPin('${g[k].no}', _userColor(_focusTrip!.userId)),
                            ),
                          ),
                        ),
                      ),
                    ),
              ]),
            // The replaying salesperson (only while a replay is under way).
            if (_focusTrip != null && (_playing || _playT > 0))
              MarkerLayer(markers: [
                if (_playAt(_playPts(_focusTrip!), _playT) case final at?)
                  Marker(
                    point: at.$1,
                    width: 40, height: 40, alignment: Alignment.center,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: _userColor(_focusTrip!.userId), width: 3),
                        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
                      ),
                      child: Icon(Icons.directions_walk, color: _userColor(_focusTrip!.userId), size: 22),
                    ),
                  ),
              ]),
      ];

  Widget _fab({required String tag, required IconData icon, required String tip, required bool on, required bool busy, VoidCallback? onTap}) =>
      FloatingActionButton.small(
        heroTag: tag,
        onPressed: busy ? null : onTap,
        backgroundColor: on ? AppTheme.primary : Colors.white,
        foregroundColor: on ? Colors.white : AppTheme.primary,
        tooltip: tip,
        child: busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon),
      );

  List<Widget> _fabs({required bool mobile}) => [
        _fab(tag: 'customers_toggle', icon: Icons.storefront_outlined,
            tip: _showCustomers ? 'Hide customers' : 'Show customers',
            on: _showCustomers, busy: _customersLoading, onTap: _toggleCustomers),
        _fab(tag: 'tracks_toggle', icon: Icons.timeline,
            tip: _showTracks ? 'Hide tracks' : 'Show tracks',
            on: _showTracks, busy: _tracksLoading, onTap: _toggleTracks),
        _fab(tag: 'flagged_toggle', icon: Icons.wrong_location,
            tip: _showFlagged ? 'Hide visits to check' : 'Show visits outside geofence / not verified',
            on: _showFlagged, busy: false, onTap: () => setState(() => _showFlagged = !_showFlagged)),
        if (mobile)
          _fab(tag: 'panel', icon: Icons.people_alt_outlined, tip: 'People, customers & legend',
              on: false, busy: false, onTap: _openMobilePanel),
        _fab(tag: 'refresh', icon: Icons.refresh, tip: 'Refresh', on: false, busy: _loading, onTap: _load),
      ];

  Widget _routeSelector({double width = 190}) => Card(
        elevation: 4,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.alt_route, size: 18, color: AppTheme.primary),
            const SizedBox(width: 8),
            SizedBox(
              width: width,
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
      );

  Widget _statusText({bool compact = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_isToday ? Icons.location_on : Icons.history, color: AppTheme.primary, size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${_isToday ? 'Live Map' : 'Map'} · ${_users.length} on map'
            '${_flagged.isNotEmpty ? ' · ${_flagged.length} to check' : ''}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: compact ? 13 : 14)),
        ),
        if (_lastRefresh != null && _isToday && !compact) ...[
          const SizedBox(width: 12),
          Text('updated ${DateFormat('h:mm a').format(_lastRefresh!)}',
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ],
      ]);

  Widget _focusOrLoading({required double maxWidth}) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
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
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (context, box) {
        final mobile = box.maxWidth < 720;
        final map = FlutterMap(
          mapController: _mapController,
          options: const MapOptions(
            initialCenter: LatLng(31.5204, 74.3587), // Lahore
            initialZoom: 11,
            minZoom: 3,
            maxZoom: 18,
          ),
          children: _mapChildren(),
        );
        final empty = (_users.isEmpty && _flagged.isEmpty && !_loading)
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _isToday
                            ? 'No location data yet — drivers and salespeople appear here once they sync visits.'
                            : 'No activity recorded on ${DateFormat('d MMM y').format(_day)}.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              )
            : null;

        if (mobile) {
          return Stack(children: [
            map,
            if (empty != null) empty,
            // Header: status + day, route picker, then the map buttons.
            Positioned(
              top: 8, left: 8, right: 8,
              child: SafeArea(
                bottom: false,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Card(
                    elevation: 4,
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        _statusText(compact: true),
                        _dayChip(dense: true),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Flexible(child: _routeSelector(width: (box.maxWidth - 16 - 60).clamp(120.0, 260.0).toDouble())),
                  ]),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(spacing: 6, runSpacing: 6, children: _fabs(mobile: true)),
                  ),
                ]),
              ),
            ),
            if (_focusTrip != null || _focusLoading)
              Positioned(
                left: 8, right: 8, bottom: 8,
                child: SafeArea(top: false, child: _focusOrLoading(maxWidth: box.maxWidth - 16)),
              ),
          ]);
        }

        return Stack(children: [
          map,
          if (empty != null) empty,
          // Top-left: status + day, route selector, opened route run.
          Positioned(
            top: 16,
            left: 16,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: (box.maxWidth - 320).clamp(280.0, 520.0).toDouble()),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Card(
                  elevation: 4,
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      _statusText(),
                      _dayChip(),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                _routeSelector(),
                if (_focusTrip != null || _focusLoading) ...[
                  const SizedBox(height: 8),
                  _focusOrLoading(maxWidth: 380),
                ],
              ]),
            ),
          ),
          // Map buttons (top-right).
          Positioned(
            top: 16,
            right: 16,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final w in _fabs(mobile: false)) Padding(padding: const EdgeInsets.only(left: 8), child: w),
            ]),
          ),
          // Bottom-left: MAIN GROUPS above the legend.
          Positioned(
            left: 16,
            bottom: 16,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (_groupColors.isNotEmpty && (_showCustomers || _selectedRouteId != null)) ...[
                _groupsLegendCard(),
                const SizedBox(height: 10),
              ],
              Card(
                elevation: 4,
                child: Padding(padding: const EdgeInsets.all(12), child: _legendContent()),
              ),
            ]),
          ),
          // People + customer list (right).
          if (_users.isNotEmpty || _hasListableCustomers)
            Positioned(
              right: 16,
              top: 72,
              child: Card(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 260, maxHeight: (box.maxHeight - 180).clamp(200.0, 900.0).toDouble()),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      _usersList(refresh: () => setState(() {})),
                      _customerList(refresh: () => setState(() {})),
                    ]),
                  ),
                ),
              ),
            ),
          // Zoom controls.
          Positioned(
            right: 16,
            bottom: 16,
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: 'Zoom in',
                  onPressed: () {
                    final cam = _mapController.camera;
                    _mapController.move(cam.center, cam.zoom + 1);
                  },
                ),
                const SizedBox(width: 32, child: Divider(height: 1)),
                IconButton(
                  icon: const Icon(Icons.remove, size: 20),
                  tooltip: 'Zoom out',
                  onPressed: () {
                    final cam = _mapController.camera;
                    _mapController.move(cam.center, cam.zoom - 1);
                  },
                ),
              ]),
            ),
          ),
        ]);
      }),
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
  Widget _groupsLegendCard({VoidCallback? onChange, bool flat = false}) {
    final entries = _groupColors.entries.toList();
    if (flat) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Text('MAIN GROUPS',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6)),
          if (_selectedGroup != null) ...[
            const Spacer(),
            InkWell(
              onTap: () { setState(() => _selectedGroup = null); onChange?.call(); },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text('Clear', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.primary)),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 6),
        _groupLegendRow(null, AppTheme.textSecondary, 'All groups', onChange: onChange),
        for (final e in entries) _groupLegendRow(e.key, e.value, e.key, onChange: onChange),
      ]);
    }
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

  Widget _groupLegendRow(String? group, Color color, String label, {VoidCallback? onChange}) {
    final selected = _selectedGroup == group;
    return InkWell(
      onTap: () {
        setState(() {
          // Tapping the active group clears; "All groups" (group == null) always clears.
          _selectedGroup = (group == null || _selectedGroup == group) ? null : group;
        });
        onChange?.call();
      },
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
    final color = _isToday ? _freshnessColor(u.timestamp) : _userColor(u.userId);
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
  final List<_FocusVisit> visits;
  final int visitCount;
  final num sales;
  _FocusTrip({
    this.visits = const [],
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
    this.cutoff = false,
  });
  final bool cutoff; // auto-closed at the cut-off time (salesperson never pressed End)

  /// Start → visits in order → end.
  List<LatLng> get path => [if (start != null) start!, ...stops, if (end != null) end!];
}

/// One visit of the opened route run (Live Map), numbered in visiting order.
class _FocusVisit {
  final int no;
  final LatLng? point;
  final DateTime? at;
  final String shop, code, status, receipt, notes, place;
  final num amount;
  final double? distance;
  const _FocusVisit({required this.no, this.point, this.at, required this.shop, required this.code,
      required this.status, required this.amount, required this.receipt, required this.notes,
      this.distance, required this.place});
}

/// Visits at (almost) the same spot share one pin, so no number hides
/// under another.
List<List<_FocusVisit>> _groupFocusVisits(List<_FocusVisit> vs) {
  final groups = <List<_FocusVisit>>[];
  for (final v in vs) {
    if (v.point == null) continue;
    List<_FocusVisit>? hit;
    for (final g in groups) {
      final p = g.first.point!;
      if ((p.latitude - v.point!.latitude).abs() < 0.00012 && (p.longitude - v.point!.longitude).abs() < 0.00012) {
        hit = g;
        break;
      }
    }
    if (hit != null) {
      hit.add(v);
    } else {
      groups.add([v]);
    }
  }
  return groups;
}

/// A visit to check on the Live Map: outside the geofence, not verified or
/// skipped. [point] is where the salesperson's phone was (may be missing).
class _FlagVisit {
  final String tripId, userId, userName, shop, code, status, notes;
  final DateTime? at;
  final LatLng? point;
  final double? distance;
  final num amount;
  const _FlagVisit({required this.tripId, required this.userId, required this.userName,
      required this.shop, required this.code, required this.status, this.at, this.point,
      this.distance, required this.amount, required this.notes});
}
