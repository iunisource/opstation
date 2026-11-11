import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/utils/geo_utils.dart';
import '../models/customer.dart';

/// Smart route guide (Admin Settings → Smart route guide, SQL 459).
///
/// Holds one brief per stop (from `route_guide_briefs`), which shops' briefs
/// were already opened today, and which stop(s) the salesperson is standing
/// at right now — only the nearest stop with a brief, inside the geofence.
/// Stops within [_tieMeters] of the nearest one count as equally near.
class RouteGuideState {
  final bool on;
  final String lang; // en | ur | both
  final Map<String, Map<String, dynamic>> briefs;
  final Set<String> seen;
  final Set<String> near;
  const RouteGuideState({
    this.on = false,
    this.lang = 'en',
    this.briefs = const {},
    this.seen = const {},
    this.near = const {},
  });

  RouteGuideState copyWith({
    bool? on,
    String? lang,
    Map<String, Map<String, dynamic>>? briefs,
    Set<String>? seen,
    Set<String>? near,
  }) =>
      RouteGuideState(
        on: on ?? this.on,
        lang: lang ?? this.lang,
        briefs: briefs ?? this.briefs,
        seen: seen ?? this.seen,
        near: near ?? this.near,
      );

  Map<String, dynamic>? briefFor(String id) => on ? briefs[id] : null;
  int countFor(String id) => routeGuideSectionCount(briefFor(id));
}

/// How many sections a brief has (money parts count as one).
int routeGuideSectionCount(Map<String, dynamic>? b) {
  if (b == null) return 0;
  bool has(String k) {
    final v = b[k];
    if (v == null) return false;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  var n = 0;
  if (has('missing')) n++;
  if (has('notes')) n++;
  if (has('balance') || has('credit') || has('last_payment')) n++;
  for (final k in const ['order_due', 'not_bought', 'competitors', 'offers', 'visits']) {
    if (has(k)) n++;
  }
  return n;
}

class RouteGuideController extends Notifier<RouteGuideState> {
  static const _tieMeters = 10.0;
  static const _cacheKey = 'cache.route_guide';
  static const _seenKey = 'route_guide_seen';

  StreamSubscription<Position>? _sub;
  String _signature = '';
  List<Customer> _stops = const [];
  double _radius = 100;
  Position? _last;

  AppDatabase get _db => ref.read(appDatabaseProvider);

  @override
  RouteGuideState build() {
    ref.onDispose(() => _sub?.cancel());
    return const RouteGuideState();
  }

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  /// Called by the route screen on every build. Cheap when nothing changed.
  Future<void> ensure(String? orgId, List<Customer> stops, double radius) async {
    final sig = [
      orgId ?? '',
      radius.toStringAsFixed(0),
      for (final c in stops) '${c.id}@${c.latitude ?? ''},${c.longitude ?? ''}',
    ].join('|');
    if (sig == _signature) return;
    final idsChanged = _stops.map((c) => c.id).join(',') != stops.map((c) => c.id).join(',');
    _signature = sig;
    _stops = stops;
    _radius = radius;

    try {
      final on = (await _db.getConfig('org.route_guide'))?.trim() == 'true';
      final lang = (await _db.getConfig('org.route_guide_lang'))?.trim() ?? '';
      if (!on || orgId == null || orgId.isEmpty || stops.isEmpty) {
        _sub?.cancel();
        _sub = null;
        _last = null;
        if (state.on || state.briefs.isNotEmpty) state = const RouteGuideState();
        return;
      }
      state = state.copyWith(on: true, lang: lang.isEmpty ? 'en' : lang, seen: await _loadSeen());
      if (idsChanged || state.briefs.isEmpty) await _loadBriefs(orgId, stops);
      _recompute();
      await _startTracking();
    } catch (_) {
      // The guide is a helper — never get in the way of the route.
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _last = null;
    _signature = '';
    _stops = const [];
  }

  Future<void> _loadBriefs(String orgId, List<Customer> stops) async {
    final ids = [for (final c in stops) c.id];
    try {
      final rows = await Supabase.instance.client
          .rpc('route_guide_briefs', params: {'p_org': orgId, 'p_customers': ids})
          .timeout(const Duration(seconds: 20));
      final map = <String, Map<String, dynamic>>{};
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final b = m['brief'];
        if (b is Map) map['${m['customer_id']}'] = Map<String, dynamic>.from(b);
      }
      state = state.copyWith(briefs: map);
      try {
        await _db.setConfig(_cacheKey, jsonEncode({'org': orgId, 'd': _today(), 'b': map}));
      } catch (_) {}
    } catch (_) {
      // Offline: use today's saved copy if there is one.
      try {
        final raw = await _db.getConfig(_cacheKey);
        if (raw == null || raw.isEmpty) return;
        final j = jsonDecode(raw) as Map;
        if (j['org'] != orgId || j['d'] != _today()) return;
        final map = <String, Map<String, dynamic>>{};
        (j['b'] as Map).forEach((k, v) {
          if (v is Map) map['$k'] = Map<String, dynamic>.from(v);
        });
        state = state.copyWith(briefs: map);
      } catch (_) {}
    }
  }

  Future<Set<String>> _loadSeen() async {
    try {
      final raw = await _db.getConfig(_seenKey);
      if (raw == null || raw.isEmpty) return {};
      final j = jsonDecode(raw) as Map;
      if (j['d'] != _today()) return {};
      return {for (final x in (j['ids'] as List? ?? const [])) '$x'};
    } catch (_) {
      return {};
    }
  }

  /// The brief was opened — that shop stops pulsing for the rest of the day.
  Future<void> markSeen(String customerId) async {
    if (state.seen.contains(customerId)) return;
    final seen = {...state.seen, customerId};
    state = state.copyWith(seen: seen);
    _recompute();
    try {
      await _db.setConfig(_seenKey, jsonEncode({'d': _today(), 'ids': seen.toList()}));
    } catch (_) {}
  }

  Future<void> _startTracking() async {
    if (_sub != null) return;
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      if (!await Geolocator.isLocationServiceEnabled()) return;
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 8),
      ).listen((p) {
        _last = p;
        _recompute();
      }, onError: (_) {});
    } catch (_) {}
  }

  void _recompute() {
    final p = _last;
    if (p == null || !state.on) {
      if (state.near.isNotEmpty) state = state.copyWith(near: const {});
      return;
    }
    final dist = <String, double>{};
    for (final c in _stops) {
      if (c.latitude == null || c.longitude == null) continue;
      if (state.seen.contains(c.id) || state.countFor(c.id) == 0) continue;
      final d = GeoUtils.distanceMeters(p.latitude, p.longitude, c.latitude!, c.longitude!);
      if (d <= _radius) dist[c.id] = d;
    }
    var near = <String>{};
    if (dist.isNotEmpty) {
      final best = dist.values.reduce((a, b) => a < b ? a : b);
      near = {for (final e in dist.entries) if (e.value <= best + _tieMeters) e.key};
    }
    if (near.length != state.near.length || !near.containsAll(state.near)) {
      state = state.copyWith(near: near);
    }
  }
}

final routeGuideProvider =
    NotifierProvider<RouteGuideController, RouteGuideState>(RouteGuideController.new);
