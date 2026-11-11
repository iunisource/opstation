import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../fleet/vehicle_profile.dart';

/// Logistics → Dispatch Dashboard.
///  • Every driver on a map (truck icon) at their latest delivery location.
///  • Each driver's progress (done / total, failed, cash) — tap for details.
///  • While this screen is open, a popup appears whenever a delivery is marked.
class DispatchDashboardScreen extends ConsumerStatefulWidget {
  const DispatchDashboardScreen({super.key});
  @override
  ConsumerState<DispatchDashboardScreen> createState() => _DispatchDashboardScreenState();
}

class _Driver {
  final String id;
  final String name;
  final Color color;
  final List<Map<String, dynamic>> jobs = [];
  final List<Map<String, dynamic>> stops = [];
  LatLng? pos;
  Map<String, dynamic>? lastStop;
  _Driver(this.id, this.name, this.color);

  int get total => stops.length;
  int get done => stops.where((s) => _isOk(s['status'])).length;
  int get failed => stops.where((s) => _isFail(s['status'])).length;
  int get pending => total - done - failed;
  num get cash => stops.fold<num>(0, (a, s) => a + ((s['cash_received'] as num?) ?? 0));
  bool get started => jobs.any((j) => j['status'] == 'in_progress' || j['started_at'] != null) || done + failed > 0;
  bool get finished => total > 0 && pending == 0;
}

bool _isOk(dynamic s) => const {'delivered', 'completed', 'picked_up', 'done'}.contains('$s');
bool _isFail(dynamic s) => const {'failed', 'cancelled', 'returned', 'skipped'}.contains('$s');
bool _isDone(dynamic s) => _isOk(s) || _isFail(s);

class _Toast {
  final String id;
  final String driver;
  final Map<String, dynamic> stop;
  final Color color;
  _Toast(this.id, this.driver, this.stop, this.color);
}

class _DispatchDashboardScreenState extends ConsumerState<DispatchDashboardScreen> {
  static const _palette = [
    Color(0xFF2563EB), Color(0xFF059669), Color(0xFFD97706), Color(0xFF7C3AED),
    Color(0xFFDB2777), Color(0xFF0891B2), Color(0xFF65A30D), Color(0xFFDC2626),
  ];

  final _map = MapController();
  DateTime _day = DateTime.now();
  bool _loading = true;
  String? _error;
  List<_Driver> _drivers = [];
  int _unassigned = 0;
  Map<String, LatLng> _custLoc = {};
  // Driver → their Fleet vehicle (SQL 463), for the vehicle icon on the card.
  Map<String, Map<String, dynamic>> _vehOf = {};
  String? _selId;
  final Map<String, String> _lastStatus = {};
  bool _primed = false;
  final List<_Toast> _toasts = [];
  RealtimeChannel? _channel;
  Timer? _poll;
  Timer? _debounce;
  bool _fitted = false;

  SupabaseClient get _db => Supabase.instance.client;
  bool get _isToday {
    final n = DateTime.now();
    return _day.year == n.year && _day.month == n.month && _day.day == n.day;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _poll = Timer.periodic(const Duration(seconds: 45), (_) { if (_isToday) _load(quiet: true); });
    _channel = _db
        .channel('dispatch_dashboard_${DateTime.now().millisecondsSinceEpoch}')
        .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'delivery_stops', callback: (_) => _soon())
        .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'deliveries', callback: (_) => _soon())
        .subscribe();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _debounce?.cancel();
    if (_channel != null) _db.removeChannel(_channel!);
    super.dispose();
  }

  void _soon() {
    if (!_isToday) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1200), () { if (mounted) _load(quiet: true); });
  }

  // ── data ──────────────────────────────────────────────────────────────────
  Future<void> _load({bool quiet = false}) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final s = DateTime(_day.year, _day.month, _day.day).toUtc().toIso8601String();
      final e = DateTime(_day.year, _day.month, _day.day).add(const Duration(days: 1)).toUtc().toIso8601String();
      final users = await _db.from('users').select('id, name').eq('org_id', orgId).eq('role', 'driver').order('name');
      try {
        final vs = await _db.from('fleet_vehicles').select('id, reg_no, driver_ids').eq('org_id', orgId).eq('is_active', true);
        final m = <String, Map<String, dynamic>>{};
        for (final v in vs as List) {
          for (final d in (v['driver_ids'] as List? ?? const [])) {
            m['$d'] ??= Map<String, dynamic>.from(v as Map);
          }
        }
        _vehOf = m;
      } catch (_) {}
      var q = _db.from('deliveries').select().eq('org_id', orgId);
      q = _isToday
          ? q.or('status.in.(pending,assigned,in_progress),created_at.gte.$s,completed_at.gte.$s')
          : q.or('and(created_at.gte.$s,created_at.lt.$e),and(completed_at.gte.$s,completed_at.lt.$e)');
      final jobs = List<Map<String, dynamic>>.from(await q.order('created_at'));
      final jobIds = [for (final j in jobs) j['id'] as String];
      final stops = <Map<String, dynamic>>[];
      for (var i = 0; i < jobIds.length; i += 150) {
        final part = jobIds.sublist(i, i + 150 > jobIds.length ? jobIds.length : i + 150);
        stops.addAll(List<Map<String, dynamic>>.from(await _db.from('delivery_stops').select().inFilter('delivery_id', part)));
      }
      // Shop locations for stops that haven't been reached yet.
      final need = {for (final st in stops) if (st['customer_id'] != null && !_custLoc.containsKey(st['customer_id'])) st['customer_id'] as String}.toList();
      for (var i = 0; i < need.length; i += 150) {
        final part = need.sublist(i, i + 150 > need.length ? need.length : i + 150);
        final rows = await _db.from('customers').select('id, latitude, longitude').inFilter('id', part);
        for (final r in rows as List) {
          final la = (r['latitude'] as num?)?.toDouble(), lo = (r['longitude'] as num?)?.toDouble();
          if (la != null && lo != null && la != 0 && lo != 0) _custLoc[r['id'] as String] = LatLng(la, lo);
        }
      }

      // Build drivers.
      final byId = <String, _Driver>{};
      var ci = 0;
      for (final u in users as List) {
        byId[u['id'] as String] = _Driver(u['id'] as String, (u['name'] as String?) ?? 'Driver', _palette[ci++ % _palette.length]);
      }
      final jobDriver = <String, String?>{};
      var unassigned = 0;
      for (final j in jobs) {
        final did = j['driver_id'] as String?;
        jobDriver[j['id'] as String] = did;
        if (did == null) { unassigned++; continue; }
        final d = byId.putIfAbsent(did, () => _Driver(did, (j['driver_name'] as String?) ?? 'Driver', _palette[ci++ % _palette.length]));
        d.jobs.add(j);
      }
      for (final st in stops) {
        final did = jobDriver[st['delivery_id']];
        if (did == null) continue;
        byId[did]?.stops.add(st);
      }
      for (final d in byId.values) {
        d.stops.sort((a, b) => ((a['sequence'] as num?) ?? 0).compareTo((b['sequence'] as num?) ?? 0));
        Map<String, dynamic>? last;
        for (final st in d.stops) {
          if (st['captured_lat'] == null || st['captured_lng'] == null) continue;
          final t = DateTime.tryParse('${st['delivered_at'] ?? ''}');
          final lt = last == null ? null : DateTime.tryParse('${last['delivered_at'] ?? ''}');
          if (last == null || (t != null && (lt == null || t.isAfter(lt)))) last = st;
        }
        if (last != null) {
          d.lastStop = last;
          d.pos = LatLng((last['captured_lat'] as num).toDouble(), (last['captured_lng'] as num).toDouble());
        }
      }

      // Popups for deliveries marked since the last check.
      final names = {for (final d in byId.values) for (final st in d.stops) st['id'] as String: d};
      if (_primed && _isToday) {
        for (final st in stops) {
          final id = st['id'] as String;
          final was = _lastStatus[id];
          if (_isDone(st['status']) && !_isDone(was)) {
            final d = names[id];
            if (d != null) _pushToast(_Toast(id, d.name, st, d.color));
          }
        }
      }
      _lastStatus
        ..clear()
        ..addAll({for (final st in stops) st['id'] as String: '${st['status']}'});
      _primed = true;

      final list = byId.values.toList()
        ..sort((a, b) {
          int rank(_Driver d) => d.total == 0 ? 2 : (d.finished ? 1 : 0);
          final r = rank(a).compareTo(rank(b));
          return r != 0 ? r : a.name.compareTo(b.name);
        });
      if (!mounted) return;
      setState(() {
        _drivers = list;
        _unassigned = unassigned;
        _loading = false;
      });
      if (!_fitted) { _fitted = true; _fitAll(); }
    } catch (err) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load the dashboard. Pull to refresh.'; });
    }
  }

  void _pushToast(_Toast t) {
    if (_toasts.any((x) => x.id == t.id)) return;
    _toasts.insert(0, t);
    if (_toasts.length > 4) _toasts.removeLast();
    Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      setState(() => _toasts.removeWhere((x) => x.id == t.id));
    });
  }

  void _fitAll({_Driver? only}) {
    final pts = <LatLng>[
      for (final d in (only == null ? _drivers : [only])) ...[
        if (d.pos != null) d.pos!,
        for (final st in d.stops)
          if (_stopPoint(st) != null) _stopPoint(st)!,
      ],
    ];
    if (pts.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (pts.length == 1) {
          _map.move(pts.first, 14);
          return;
        }
        final lats = pts.map((p) => p.latitude).toList()..sort();
        final lngs = pts.map((p) => p.longitude).toList()..sort();
        _map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds(LatLng(lats.first, lngs.first), LatLng(lats.last, lngs.last)),
          padding: const EdgeInsets.all(60),
        ));
      } catch (_) {}
    });
  }

  LatLng? _stopPoint(Map<String, dynamic> st) {
    if (st['captured_lat'] != null && st['captured_lng'] != null) {
      return LatLng((st['captured_lat'] as num).toDouble(), (st['captured_lng'] as num).toDouble());
    }
    return _custLoc[st['customer_id']];
  }

  // ── helpers ───────────────────────────────────────────────────────────────
  static String _money(num? v) => 'Rs ${NumberFormat('#,##0').format(v ?? 0)}';
  static String _time(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : DateFormat('h:mm a').format(d.toLocal());
  }

  static String _stopLabel(Map<String, dynamic> st) {
    final n = '${st['customer_name'] ?? ''}'.trim();
    return n.isEmpty ? (st['item_description'] as String? ?? 'Stop') : n;
  }

  static (String, Color) _stopStatus(Map<String, dynamic> st) {
    final s = '${st['status'] ?? ''}';
    final pickup = st['stop_type'] == 'pickup';
    if (_isOk(s)) return (pickup ? 'Picked up' : 'Delivered', const Color(0xFF059669));
    if (_isFail(s)) return (s == 'cancelled' ? 'Cancelled' : 'Failed', const Color(0xFFDC2626));
    return ('Pending', const Color(0xFF94A3B8));
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 980;
    final all = _drivers.where((d) => d.total > 0).toList();
    final total = all.fold<int>(0, (a, d) => a + d.total);
    final done = all.fold<int>(0, (a, d) => a + d.done);
    final failed = all.fold<int>(0, (a, d) => a + d.failed);
    final cash = all.fold<num>(0, (a, d) => a + d.cash);
    final onRoad = all.where((d) => d.started && !d.finished).length;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 16, wide ? 24 : 12, 10),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('Dispatch Dashboard', style: TextStyle(fontSize: wide ? 24 : 20, fontWeight: FontWeight.w800)),
        const SizedBox(width: 4),
        _chip('$onRoad', 'on the road', AppTheme.primary),
        _chip('$done / $total', 'delivered', const Color(0xFF059669)),
        if (failed > 0) _chip('$failed', 'failed', const Color(0xFFDC2626)),
        _chip(_money(cash), 'collected', const Color(0xFF7C3AED)),
        if (_unassigned > 0) _chip('$_unassigned', 'jobs not assigned', const Color(0xFFD97706)),
        OutlinedButton.icon(
          onPressed: () async {
            final p = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2024), lastDate: DateTime.now());
            if (p == null) return;
            setState(() { _day = p; _primed = false; _fitted = false; _selId = null; _toasts.clear(); });
            _load();
          },
          icon: const Icon(Icons.calendar_today_outlined, size: 15),
          label: Text(_isToday ? 'Today' : DateFormat('d MMM yyyy').format(_day), style: const TextStyle(fontSize: 12)),
        ),
        IconButton(tooltip: 'Refresh', onPressed: () => _load(), icon: const Icon(Icons.refresh)),
        if (_isToday)
          const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.circle, size: 8, color: Color(0xFF10B981)),
            SizedBox(width: 5),
            Text('Live', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF059669))),
          ]),
      ]),
    );

    Widget body;
    if (_loading && _drivers.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null && _drivers.isEmpty) {
      body = Center(child: Text(_error!, style: const TextStyle(color: AppTheme.textSecondary)));
    } else if (wide) {
      body = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 380, child: _driverList()),
        Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(0, 0, 16, 16), child: _mapCard())),
      ]);
    } else {
      body = ListView(padding: const EdgeInsets.only(bottom: 16), children: [
        SizedBox(height: 320, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _mapCard())),
        const SizedBox(height: 10),
        ..._driverCards(),
      ]);
    }

    return Container(
      color: AppTheme.background,
      child: Stack(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [header, Expanded(child: body)]),
        Positioned(
          top: 12,
          right: 12,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [for (final t in _toasts) _toastCard(t)]),
        ),
      ]),
    );
  }

  Widget _chip(String v, String l, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: c.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: c.withOpacity(0.25))),
        child: RichText(
          text: TextSpan(style: TextStyle(fontSize: 12, color: c), children: [
            TextSpan(text: v, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            TextSpan(text: '  $l'),
          ]),
        ),
      );

  Widget _driverList() {
    final cards = _driverCards();
    if (cards.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No deliveries for this day.', style: TextStyle(color: AppTheme.textSecondary)),
      );
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 12, 16), children: cards);
  }

  List<Widget> _driverCards() => [
        for (final d in _drivers)
          if (d.total > 0 || d.jobs.isNotEmpty) _driverCard(d),
      ];

  Widget _driverCard(_Driver d) {
    final sel = _selId == d.id;
    final pct = d.total == 0 ? 0.0 : (d.done + d.failed) / d.total;
    final state = d.finished ? 'All stops done' : d.started ? 'On the road' : 'Not started';
    final last = d.lastStop;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            setState(() => _selId = sel ? null : d.id);
            _fitAll(only: sel ? null : d);
            if (!sel) _showDetails(d);
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sel ? d.color : AppTheme.border, width: sel ? 1.6 : 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _truck(d.color, 30),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
                  Text(state, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600,
                      color: d.finished ? const Color(0xFF059669) : d.started ? AppTheme.primary : AppTheme.textSecondary)),
                ])),
                if (_vehOf[d.id] != null) ...[
                  Tooltip(
                    message: 'Vehicle ${_vehOf[d.id]!['reg_no'] ?? ''}',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => showVehicleProfile(context, _vehOf[d.id]!['id'] as String, readOnly: true),
                      child: Container(
                        width: 30, height: 30,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: const Icon(Icons.directions_car_rounded, size: 17, color: AppTheme.primary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Text('${d.done + d.failed}/${d.total}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Row(children: [
                  if (d.done > 0) Expanded(flex: d.done, child: Container(height: 6, color: const Color(0xFF10B981))),
                  if (d.failed > 0) Expanded(flex: d.failed, child: Container(height: 6, color: const Color(0xFFEF4444))),
                  if (d.pending > 0) Expanded(flex: d.pending, child: Container(height: 6, color: const Color(0xFFE2E8F0))),
                  if (d.total == 0) Expanded(child: Container(height: 6, color: const Color(0xFFE2E8F0))),
                ]),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 12, runSpacing: 4, children: [
                Text('${d.done} delivered', style: const TextStyle(fontSize: 11.5, color: Color(0xFF059669))),
                if (d.failed > 0) Text('${d.failed} failed', style: const TextStyle(fontSize: 11.5, color: Color(0xFFDC2626))),
                Text('${d.pending} left', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                if (d.cash > 0) Text('${_money(d.cash)} cash', style: const TextStyle(fontSize: 11.5, color: Color(0xFF7C3AED))),
                Text('${(pct * 100).round()}%', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
              ]),
              if (last != null) ...[
                const SizedBox(height: 6),
                Text('Last: ${_stopLabel(last)} · ${_time(last['delivered_at'])}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _truck(Color c, double size, {bool ring = false}) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [BoxShadow(color: c.withOpacity(ring ? 0.55 : 0.30), blurRadius: ring ? 14 : 6, spreadRadius: ring ? 3 : 0)],
        ),
        child: Icon(Icons.local_shipping_rounded, color: Colors.white, size: size * 0.55),
      );

  Widget _mapCard() {
    final sel = _selId == null ? null : _drivers.where((d) => d.id == _selId).firstOrNull;
    final showStopsFor = sel == null ? _drivers : [sel];
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(14)),
        child: Stack(children: [
          FlutterMap(
            mapController: _map,
            options: const MapOptions(initialCenter: LatLng(31.5204, 74.3587), initialZoom: 11, minZoom: 3, maxZoom: 18),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.opstation.web', maxNativeZoom: 19),
              if (sel != null)
                PolylineLayer(polylines: [
                  Polyline(points: [for (final st in sel.stops) if (_stopPoint(st) != null) _stopPoint(st)!], color: sel.color.withOpacity(0.5), strokeWidth: 3),
                ]),
              MarkerLayer(markers: [
                for (final d in showStopsFor)
                  for (final st in d.stops)
                    if (_stopPoint(st) != null)
                      Marker(
                        point: _stopPoint(st)!,
                        width: 22, height: 22, alignment: Alignment.center,
                        child: Tooltip(
                          message: '${_stopLabel(st)} · ${_stopStatus(st).$1}${st['delivered_at'] != null ? ' · ${_time(st['delivered_at'])}' : ''}',
                          child: GestureDetector(
                            onTap: () => _showDetails(d),
                            child: Container(
                              decoration: BoxDecoration(color: _stopStatus(st).$2, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                              alignment: Alignment.center,
                              child: Text('${st['sequence'] ?? ''}', style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w800)),
                            ),
                          ),
                        ),
                      ),
                for (final d in _drivers)
                  if (d.pos != null)
                    Marker(
                      point: d.pos!,
                      width: 140, height: 62, alignment: Alignment.topCenter,
                      child: GestureDetector(
                        onTap: () { setState(() => _selId = d.id); _showDetails(d); },
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: d.color.withOpacity(0.5))),
                            child: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: d.color)),
                          ),
                          const SizedBox(height: 2),
                          _truck(d.color, 34, ring: _selId == d.id),
                        ]),
                      ),
                    ),
              ]),
            ],
          ),
          Positioned(
            left: 10, bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.92), borderRadius: BorderRadius.circular(8)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.circle, size: 9, color: Color(0xFF059669)), SizedBox(width: 4), Text('Delivered', style: TextStyle(fontSize: 11)),
                SizedBox(width: 10),
                Icon(Icons.circle, size: 9, color: Color(0xFFDC2626)), SizedBox(width: 4), Text('Failed', style: TextStyle(fontSize: 11)),
                SizedBox(width: 10),
                Icon(Icons.circle, size: 9, color: Color(0xFF94A3B8)), SizedBox(width: 4), Text('Pending', style: TextStyle(fontSize: 11)),
              ]),
            ),
          ),
          if (sel != null)
            Positioned(
              right: 10, top: 10,
              child: ActionChip(
                avatar: const Icon(Icons.close, size: 14),
                label: Text('Showing ${sel.name} · show all', style: const TextStyle(fontSize: 11.5)),
                onPressed: () { setState(() => _selId = null); _fitAll(); },
              ),
            ),
        ]),
      ),
    );
  }

  Widget _toastCard(_Toast t) {
    final st = t.stop;
    final (label, color) = _stopStatus(st);
    final ok = _isOk(st['status']);
    final amt = (st['cash_received'] as num?) ?? (st['amount'] as num?);
    return Container(
      width: 340,
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        elevation: 10,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border(left: BorderSide(color: color, width: 4))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded, color: color, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${t.driver} · $label', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(_stopLabel(st), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
              Text(
                [
                  if (st['delivered_at'] != null) _time(st['delivered_at']),
                  if (ok && amt != null && amt > 0) _money(amt),
                  if (!ok && (st['failure_reason'] ?? '') != '') '${st['failure_reason']}',
                ].join(' · '),
                style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: () {
                    final d = _drivers.where((x) => x.stops.any((s) => s['id'] == st['id'])).firstOrNull;
                    setState(() => _toasts.removeWhere((x) => x.id == t.id));
                    if (d != null) { setState(() => _selId = d.id); _fitAll(only: d); _showDetails(d); }
                  },
                  child: const Text('View', style: TextStyle(fontSize: 12)),
                ),
              ),
            ])),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => setState(() => _toasts.removeWhere((x) => x.id == t.id)),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _showDetails(_Driver d) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 8, 8),
              child: Row(children: [
                _truck(d.color, 36),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  Text('${d.done} delivered · ${d.failed} failed · ${d.pending} left${d.cash > 0 ? ' · ${_money(d.cash)} cash' : ''}',
                      style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                ])),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
              ]),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(18, 8, 18, 16), children: [
                for (final j in d.jobs) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: Row(children: [
                      Expanded(child: Text(
                        'Job · ${_time(j['created_at'])}${(j['notes'] ?? '') != '' ? ' · ${j['notes']}' : ''}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary),
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                      TextButton(
                        onPressed: () { Navigator.pop(ctx); context.go('/deliveries/${j['id']}'); },
                        child: const Text('Open job', style: TextStyle(fontSize: 12)),
                      ),
                    ]),
                  ),
                  for (final st in d.stops.where((s) => s['delivery_id'] == j['id'])) _stopRow(st),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _stopRow(Map<String, dynamic> st) {
    final (label, color) = _stopStatus(st);
    final pickup = st['stop_type'] == 'pickup';
    final amt = (st['cash_received'] as num?) ?? (st['amount'] as num?);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22, height: 22, alignment: Alignment.center,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Text('${st['sequence'] ?? ''}', style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_stopLabel(st)}${pickup ? '  ·  Pickup' : ''}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          Text(
            [
              if ((st['customer_code'] ?? '') != '') '${st['customer_code']}',
              if ((st['so_invoice_number'] ?? '') != '') '${st['so_invoice_number']}',
              if (amt != null && amt > 0) _money(amt),
              if ((st['payment_type'] ?? '') != '') '${st['payment_type']}',
            ].join(' · '),
            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
          ),
          if ((st['failure_reason'] ?? '') != '')
            Text('Reason: ${st['failure_reason']}', style: const TextStyle(fontSize: 11.5, color: Color(0xFFDC2626))),
          if ((st['driver_note'] ?? '') != '')
            Text('Note: ${st['driver_note']}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(999)),
            child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
          ),
          if (st['delivered_at'] != null)
            Padding(padding: const EdgeInsets.only(top: 3), child: Text(_time(st['delivered_at']), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        ]),
      ]),
    );
  }
}
