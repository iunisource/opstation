import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/place_name.dart';
import '../../../core/utils/visit_outcome.dart' show awayLabel, visitIsAdhoc;
import 'time_in_market_pdf.dart';
import '../../reports/pdf/report_pdf_builder.dart' show TripReportContext;
import '../../team/services/trip_sessions.dart';
import '../../../core/format/time_format.dart';

/// Time in Market — how each salesperson's / driver's day was spent, worked
/// out from data already collected: route (or delivery) start and end, and
/// the time each visit / drop was marked. Shared by Operations → Time in
/// Market and the Team 360 "Time in Market" tab.

// ── Settings (Admin: the gear on the page) ───────────────────────────────────

class TimSettings {
  final int dayStart;   // minutes after midnight
  final int dayEnd;
  final int lateAfter;  // first stop after this = late start
  final int earlyBefore; // finished before this = early close
  final int gapMin;     // a gap longer than this is flagged
  const TimSettings(this.dayStart, this.dayEnd, this.lateAfter, this.earlyBefore, this.gapMin);
  static const defaults = TimSettings(9 * 60 + 30, 17 * 60 + 30, 10 * 60, 17 * 60, 45);

  static const keys = {
    'start': 'org.tim_day_start', 'end': 'org.tim_day_end', 'late': 'org.tim_late_after',
    'early': 'org.tim_early_before', 'gap': 'org.tim_gap_min',
  };

  static int? _hm(String? s) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch((s ?? '').trim());
    if (m == null) return null;
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) return null;
    return h * 60 + mi;
  }

  static String hm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  /// For showing a time of day in the org's clock format (Admin Settings →
  /// 24-hour time). [short] = whole-hour axis labels ("9 AM"). [hm] stays the
  /// edit format of the settings fields.
  static String clock(int minutes, {bool short = false}) {
    if (OrgTimeFormat.use24) return hm(minutes);
    final t = DateTime(2000, 1, 1, minutes ~/ 60, minutes % 60);
    return DateFormat(short && t.minute == 0 ? 'h a' : 'h:mm a').format(t);
  }

  static Future<TimSettings> load(String orgId) async {
    try {
      final rows = await Supabase.instance.client.from('app_config').select('key, value')
          .eq('org_id', orgId).inFilter('key', keys.values.toList());
      final m = {for (final r in rows as List) '${r['key']}': '${r['value'] ?? ''}'};
      final d = defaults;
      return TimSettings(
        _hm(m[keys['start']]) ?? d.dayStart,
        _hm(m[keys['end']]) ?? d.dayEnd,
        _hm(m[keys['late']]) ?? d.lateAfter,
        _hm(m[keys['early']]) ?? d.earlyBefore,
        int.tryParse(m[keys['gap']] ?? '') ?? d.gapMin,
      );
    } catch (_) {
      return defaults;
    }
  }

  Future<void> save(String orgId) async {
    final c = Supabase.instance.client;
    final vals = {
      keys['start']!: hm(dayStart), keys['end']!: hm(dayEnd), keys['late']!: hm(lateAfter),
      keys['early']!: hm(earlyBefore), keys['gap']!: '$gapMin',
    };
    for (final e in vals.entries) {
      // The setting row may have been saved with a branch — update whatever
      // row(s) exist for the org; insert only when there is none at all.
      final ex = await c.from('app_config').select('key').eq('org_id', orgId).eq('key', e.key).limit(1);
      if ((ex as List).isEmpty) {
        await c.from('app_config').insert({'org_id': orgId, 'key': e.key, 'value': e.value});
      } else {
        await c.from('app_config').update({'value': e.value}).eq('org_id', orgId).eq('key', e.key);
      }
    }
  }
}

// ── Model ────────────────────────────────────────────────────────────────────

class TimEvent {
  final DateTime at;
  final String place;
  final String kind; // visited | outside | not_verified | skipped | delivered | failed
  final int amount;
  final double? distance; // metres from the shop when marked (outside geofence)
  final bool adhoc; // entered with "Ad-hoc collection"
  final double? accuracy; // GPS accuracy in metres
  const TimEvent(this.at, this.place, this.kind, this.amount, [this.distance, this.adhoc = false, this.accuracy]);

  /// "Outside geofence · 85 m away · Ad-hoc receipt · rough GPS (±90 m)"
  String get kindText {
    final away = kind == 'outside' ? awayLabel(distance) : null;
    final parts = <String>[
      timKindLabel(kind),
      if (away != null) away,
      if (adhoc) 'Ad-hoc receipt',
      if (kind != 'visited' && kind != 'delivered' && (accuracy ?? 0) > 50) 'rough GPS (±${accuracy!.round()} m)',
    ];
    return parts.join(' · ');
  }
}

class TimGap {
  final DateTime from;
  final DateTime to;
  final bool beforeFirst; // start of the day → first stop
  const TimGap(this.from, this.to, this.beforeFirst);
  Duration get length => to.difference(from);
}

class TimDay {
  final String userId;
  final String name;
  final String role; // salesperson | driver
  final DateTime date; // local date
  final List<String> routes;
  final DateTime? start; // route / delivery started
  final DateTime? end;   // null = still open
  final bool open;
  final List<TimEvent> events;
  final int totalStops; // planned shops / drops (0 = unknown)
  // Where the route started / ended (GPS of the first trip's start and the
  // last trip's end) — null when not recorded (e.g. deliveries).
  final (double, double)? startAt;
  final (double, double)? endAt;
  // Raw trips of the day + their visits, for the distance (salespeople only).
  final List<Map<String, dynamic>> trips;
  final Map<String, List<Map<String, dynamic>>> visitsByTrip;
  /// Road distance of the day in km, same as the Trip Summary (abandoned trips
  /// left out). null until [timLoadDistances] has run, or for drivers.
  double? km;
  TimDay(this.userId, this.name, this.role, this.date, this.routes, this.start, this.end, this.open,
      this.events, this.totalStops,
      {this.startAt, this.endAt, this.trips = const [], this.visitsByTrip = const {}});

  late final List<TimEvent> sorted = [...events]..sort((a, b) => a.at.compareTo(b.at));
  DateTime? get first => sorted.isEmpty ? null : sorted.first.at;
  DateTime? get last => sorted.isEmpty ? null : sorted.last.at;
  Duration get inMarket => (first == null || last == null) ? Duration.zero : last!.difference(first!);
  Duration? get routeOpen => (start == null) ? null : ((end ?? (open ? null : last)) ?? DateTime.now()).difference(start!);
  int get visits => sorted.length;
  double get perHour {
    final h = inMarket.inMinutes / 60.0;
    return h <= 0.25 ? visits.toDouble() : visits / h;
  }
  int get collected => sorted.fold(0, (s, e) => s + e.amount);

  List<TimGap> gaps(TimSettings s) {
    final out = <TimGap>[];
    if (start != null && first != null && first!.difference(start!).inMinutes > s.gapMin) {
      out.add(TimGap(start!, first!, true));
    }
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].at.difference(sorted[i - 1].at).inMinutes > s.gapMin) {
        out.add(TimGap(sorted[i - 1].at, sorted[i].at, false));
      }
    }
    return out;
  }

  Duration lostToGaps(TimSettings s) =>
      gaps(s).fold(Duration.zero, (a, g) => a + g.length);

  Duration? longestGap(TimSettings s) {
    Duration? best;
    for (var i = 1; i < sorted.length; i++) {
      final d = sorted[i].at.difference(sorted[i - 1].at);
      if (best == null || d > best) best = d;
    }
    return best;
  }

  static int _min(DateTime d) => d.hour * 60 + d.minute;
  bool lateStart(TimSettings s) => first != null && _min(first!) > s.lateAfter;
  bool earlyClose(TimSettings s) {
    if (open) return false;
    final e = end ?? last;
    if (e == null) return false;
    // Only for a past or today's finished day.
    return _min(e) < s.earlyBefore;
  }
  int longGapCount(TimSettings s) => gaps(s).where((g) => !g.beforeFirst).length;

  /// Gaps between consecutive stops that are NOT long gaps — the usual time
  /// one stop takes (time at the shop + getting to the next one).
  List<Duration> stopIntervals(TimSettings s) => [
        for (var i = 1; i < sorted.length; i++)
          if (sorted[i].at.difference(sorted[i - 1].at).inMinutes <= s.gapMin)
            sorted[i].at.difference(sorted[i - 1].at),
      ];

  Duration? avgPerStop(TimSettings s) => timAvg(stopIntervals(s));
}

Duration? timAvg(List<Duration> l) =>
    l.isEmpty ? null : Duration(seconds: l.fold<int>(0, (a, d) => a + d.inSeconds) ~/ l.length);

/// Average time per stop across many days (long gaps left out).
Duration? timAvgPerStop(Iterable<TimDay> days, TimSettings s) =>
    timAvg([for (final d in days) ...d.stopIntervals(s)]);

String timDur(Duration? d) {
  if (d == null) return '—';
  final m = d.inMinutes;
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

String timClock(DateTime? t) => t == null ? '—' : DateFormat(orgTime('HH:mm')).format(t);

// ── Loading ──────────────────────────────────────────────────────────────────

Future<List<Map<String, dynamic>>> _paged(dynamic Function(int f, int t) q) async {
  final out = <Map<String, dynamic>>[];
  for (int f = 0;; f += 1000) {
    final page = List<Map<String, dynamic>>.from(await q(f, f + 999) as List);
    out.addAll(page);
    if (page.length < 1000 || f > 100000) break;
  }
  return out;
}

/// Days for salespeople (routes + visits) and drivers (deliveries + drops)
/// between [from] and [to] (local dates, inclusive). [userId] limits to one.
Future<List<TimDay>> loadTimDays(String orgId, DateTime from, DateTime to, {String? userId}) async {
  final c = Supabase.instance.client;
  final start = DateTime(from.year, from.month, from.day);
  final endEx = DateTime(to.year, to.month, to.day).add(const Duration(days: 1));
  final s = start.toUtc().toIso8601String(), e = endEx.toUtc().toIso8601String();
  DateTime local(Object? v) => DateTime.parse('$v').toLocal();
  DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

  final users = await _paged((f, t) {
    var q = c.from('users').select('id, name, role').eq('org_id', orgId).inFilter('role', ['salesperson', 'driver']);
    if (userId != null) q = q.eq('id', userId);
    return q.range(f, t);
  });
  final byUser = {for (final u in users) '${u['id']}': u};
  if (byUser.isEmpty) return [];

  // key user|yyyy-mm-dd → accumulating day
  final days = <String, _Acc>{};
  _Acc acc(String uid, DateTime d) {
    final u = byUser[uid]!;
    return days.putIfAbsent('$uid|${DateFormat('yyyy-MM-dd').format(d)}',
        () => _Acc(uid, '${u['name'] ?? ''}', '${u['role'] ?? ''}', d));
  }

  final visitsByTrip = <String, List<Map<String, dynamic>>>{};
  // Salespeople: trips + visits.
  final sales = [for (final u in users) if (u['role'] == 'salesperson') '${u['id']}'];
  if (sales.isNotEmpty) {
    final trips = <Map<String, dynamic>>[];
    for (var k = 0; k < sales.length; k += 100) {
      final chunk = sales.sublist(k, (k + 100).clamp(0, sales.length));
      trips.addAll(await _paged((f, t) => c.from('trips')
          .select('id, org_id, user_id, route_id, route_name, started_at, ended_at, start_lat, start_lng, end_lat, end_lng')
          .eq('org_id', orgId).inFilter('user_id', chunk)
          .gte('started_at', s).lt('started_at', e).range(f, t)));
    }
    final tripById = {for (final t in trips) '${t['id']}': t};
    final ids = tripById.keys.toList();
    final visits = <Map<String, dynamic>>[];
    for (var k = 0; k < ids.length; k += 150) {
      final chunk = ids.sublist(k, (k + 150).clamp(0, ids.length));
      visits.addAll(await _paged((f, t) => c.from('visits')
          .select('trip_id, timestamp, status, amount, customer_id, distance_meters, captured_lat, captured_lng, accuracy_meters, skip_reason, customers(shop_name)')
          .inFilter('trip_id', chunk).range(f, t)));
    }
    final stopsByRoute = <String, int>{};
    final routeIds = {for (final t in trips) if (t['route_id'] != null && t['route_id'] != 'offroute') '${t['route_id']}'}.toList();
    for (var k = 0; k < routeIds.length; k += 150) {
      final chunk = routeIds.sublist(k, (k + 150).clamp(0, routeIds.length));
      for (final r in await _paged((f, t) => c.from('route_stops').select('route_id').inFilter('route_id', chunk).range(f, t))) {
        stopsByRoute['${r['route_id']}'] = (stopsByRoute['${r['route_id']}'] ?? 0) + 1;
      }
    }
    for (final t in trips) {
      final uid = '${t['user_id']}';
      if (!byUser.containsKey(uid) || t['started_at'] == null) continue;
      final st = local(t['started_at']);
      final a = acc(uid, dayOf(st));
      a.trips.add(t); // for the day's distance (worked out when printing)
      final off = t['route_id'] == 'offroute';
      if (!off) {
        a.routes.add('${t['route_name'] ?? 'Route'}');
        (double, double)? pt(String la, String lo) {
          final x = (t[la] as num?)?.toDouble(), y = (t[lo] as num?)?.toDouble();
          return (x == null || y == null || (x == 0 && y == 0)) ? null : (x, y);
        }
        if (a.start == null || st.isBefore(a.start!)) {
          a.start = st;
          a.startAt = pt('start_lat', 'start_lng') ?? a.startAt;
        }
        if (t['ended_at'] == null) {
          a.open = true;
        } else {
          final en = local(t['ended_at']);
          if (a.end == null || en.isAfter(a.end!)) {
            a.end = en;
            a.endAt = pt('end_lat', 'end_lng') ?? a.endAt;
          }
        }
        a.stops += stopsByRoute['${t['route_id']}'] ?? 0;
      }
    }
    for (final v in visits) {
      (visitsByTrip['${v['trip_id']}'] ??= []).add(v);
    }
    for (final v in visits) {
      final t = tripById['${v['trip_id']}'];
      if (t == null || v['timestamp'] == null) continue;
      final at = local(v['timestamp']);
      final uid = '${t['user_id']}';
      if (!byUser.containsKey(uid)) continue;
      final status = '${v['status'] ?? ''}';
      final amt = (v['amount'] as num?)?.toInt() ?? 0;
      final noLoc = status == 'noLocation' || status == 'no_location';
      final kind = status == 'verified'
          ? 'visited'
          : status == 'skipped'
              ? 'skipped'
              : (amt > 0
                  ? (noLoc ? (v['captured_lat'] == null ? 'no_gps' : 'no_location') : 'outside')
                  : 'not_verified');
      acc(uid, dayOf(at)).events.add(TimEvent(at, '${(v['customers'] as Map?)?['shop_name'] ?? 'Shop'}', kind, amt,
          (v['distance_meters'] as num?)?.toDouble(), visitIsAdhoc(v), (v['accuracy_meters'] as num?)?.toDouble()));
    }
  }

  // Drivers: deliveries + drops.
  final drivers = [for (final u in users) if (u['role'] == 'driver') '${u['id']}'];
  if (drivers.isNotEmpty) {
    final dels = <Map<String, dynamic>>[];
    final since = start.subtract(const Duration(days: 7)).toUtc().toIso8601String();
    for (var k = 0; k < drivers.length; k += 100) {
      final chunk = drivers.sublist(k, (k + 100).clamp(0, drivers.length));
      dels.addAll(await _paged((f, t) => c.from('deliveries')
          .select('id, driver_id, started_at, completed_at, status, created_at')
          .eq('org_id', orgId).inFilter('driver_id', chunk)
          .gte('created_at', since).lt('created_at', e).range(f, t)));
    }
    final delById = {for (final d in dels) '${d['id']}': d};
    final ids = delById.keys.toList();
    final stops = <Map<String, dynamic>>[];
    for (var k = 0; k < ids.length; k += 150) {
      final chunk = ids.sublist(k, (k + 150).clamp(0, ids.length));
      stops.addAll(await _paged((f, t) => c.from('delivery_stops')
          .select('delivery_id, customer_name, status, delivered_at, verification, amount, cash_received, distance_meters')
          .inFilter('delivery_id', chunk).range(f, t)));
    }
    final stopCount = <String, int>{};
    for (final st in stops) {
      stopCount['${st['delivery_id']}'] = (stopCount['${st['delivery_id']}'] ?? 0) + 1;
    }
    for (final d in dels) {
      final uid = '${d['driver_id']}';
      if (!byUser.containsKey(uid) || d['started_at'] == null) continue;
      final st = local(d['started_at']);
      if (st.isBefore(start) || !st.isBefore(endEx)) continue;
      final a = acc(uid, dayOf(st));
      a.routes.add('Delivery');
      if (a.start == null || st.isBefore(a.start!)) a.start = st;
      if (d['completed_at'] == null && d['status'] != 'completed') {
        a.open = true;
      } else if (d['completed_at'] != null) {
        final en = local(d['completed_at']);
        if (a.end == null || en.isAfter(a.end!)) a.end = en;
      }
      a.stops += stopCount['${d['id']}'] ?? 0;
    }
    for (final st in stops) {
      final d = delById['${st['delivery_id']}'];
      if (d == null || st['delivered_at'] == null) continue;
      final at = local(st['delivered_at']);
      if (at.isBefore(start) || !at.isBefore(endEx)) continue;
      final uid = '${d['driver_id']}';
      if (!byUser.containsKey(uid)) continue;
      final failed = st['status'] == 'failed';
      final ver = '${st['verification'] ?? ''}';
      final kind = failed ? 'failed' : (ver == 'verified' ? 'delivered' : 'outside');
      final amt = (st['cash_received'] as num?)?.toInt() ?? 0;
      acc(uid, dayOf(at)).events.add(TimEvent(at, '${st['customer_name'] ?? 'Drop'}', kind, amt,
          (st['distance_meters'] as num?)?.toDouble()));
    }
  }

  final out = [
    for (final a in days.values)
      TimDay(a.uid, a.name, a.role, a.date, a.routes.toSet().toList(), a.start, a.end,
          a.open && DateUtils.isSameDay(a.date, DateTime.now()), a.events, a.stops,
          startAt: a.startAt, endAt: a.endAt,
          trips: a.trips, visitsByTrip: visitsByTrip),
  ]..sort((x, y) {
      final d = y.date.compareTo(x.date);
      return d != 0 ? d : x.name.toLowerCase().compareTo(y.name.toLowerCase());
    });
  return out;
}

class _Acc {
  final String uid, name, role;
  final DateTime date;
  final List<String> routes = [];
  DateTime? start, end;
  (double, double)? startAt, endAt;
  bool open = false;
  int stops = 0;
  final List<TimEvent> events = [];
  final List<Map<String, dynamic>> trips = [];
  _Acc(this.uid, this.name, this.role, this.date);
}

// ── Widgets ──────────────────────────────────────────────────────────────────

Color timKindColor(String k) => switch (k) {
      'visited' || 'delivered' => AppTheme.success,
      'outside' => Colors.amber.shade700,
      'no_location' => AppTheme.danger,
      'no_gps' => AppTheme.danger,
      'failed' => AppTheme.danger,
      _ => const Color(0xFF94A3B8),
    };

String timKindLabel(String k) => switch (k) {
      'visited' => 'Visited',
      'delivered' => 'Delivered',
      'outside' => 'Outside geofence',
      'no_location' => 'No Location',
      'no_gps' => 'No GPS',
      'failed' => 'Failed',
      'skipped' => 'Skipped',
      _ => 'Not verified',
    };

/// Flags shown next to a day.
List<(String, Color)> timFlags(TimDay d, TimSettings s) {
  final out = <(String, Color)>[];
  if (d.events.isEmpty) out.add(('No stops marked', AppTheme.danger));
  if (d.lateStart(s)) out.add(('Late start', AppTheme.danger));
  final g = d.longGapCount(s);
  if (g > 0) out.add(('$g long gap${g == 1 ? '' : 's'}', Colors.amber.shade800));
  if (d.earlyClose(s)) out.add(('Early close', AppTheme.danger));
  if (d.open) out.add(('Still out', AppTheme.primary));
  if (out.isEmpty) out.add(('On track', AppTheme.success));
  return out;
}

Widget timTag(String t, Color c) => Container(
      margin: const EdgeInsets.only(right: 4, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
      child: Text(t, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
    );

/// The day as a bar from 07:00 to 21:00 (stretched when needed).
class TimTimeline extends StatelessWidget {
  final TimDay day;
  final TimSettings s;
  const TimTimeline({super.key, required this.day, required this.s});

  @override
  Widget build(BuildContext context) {
    int m(DateTime t) => t.hour * 60 + t.minute;
    var lo = 7 * 60, hi = 21 * 60;
    for (final t in [day.start, day.end, day.first, day.last]) {
      if (t == null) continue;
      if (m(t) < lo) lo = (m(t) ~/ 60) * 60;
      if (m(t) > hi) hi = ((m(t) ~/ 60) + 1) * 60;
    }
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      double x(int mins) => ((mins - lo) / (hi - lo)).clamp(0.0, 1.0) * w;
      final kids = <Widget>[
        Positioned(left: 0, right: 0, top: 22, child: Container(height: 6,
            decoration: BoxDecoration(color: const Color(0xFFEEF2F7), borderRadius: BorderRadius.circular(4)))),
        Positioned(left: x(s.dayStart), top: 19, child: Container(width: x(s.dayEnd) - x(s.dayStart), height: 12,
            decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08),
                border: Border.all(color: AppTheme.primary.withOpacity(0.35)), borderRadius: BorderRadius.circular(4)))),
      ];
      if (day.start != null) {
        final en = day.end ?? (day.open ? DateTime.now() : day.last) ?? day.start!;
        kids.add(Positioned(left: x(m(day.start!)), top: 22, child: Container(
            width: (x(m(en)) - x(m(day.start!))).clamp(2.0, w), height: 6,
            decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.35), borderRadius: BorderRadius.circular(4)))));
      }
      for (final g in day.gaps(s)) {
        kids.add(Positioned(left: x(m(g.from)), top: 17, child: Tooltip(
          message: '${timClock(g.from)}–${timClock(g.to)} · ${timDur(g.length)}',
          child: Container(width: (x(m(g.to)) - x(m(g.from))).clamp(3.0, w), height: 16,
              decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.16),
                  border: Border.all(color: AppTheme.danger.withOpacity(0.5)), borderRadius: BorderRadius.circular(4))),
        )));
      }
      for (final ev in day.sorted) {
        kids.add(Positioned(left: x(m(ev.at)) - 6, top: 19, child: Tooltip(
          message: '${timClock(ev.at)} · ${ev.place} · ${ev.kindText}${ev.amount > 0 ? ' · Rs ${money(ev.amount)}' : ''}',
          child: Container(width: 12, height: 12, decoration: BoxDecoration(
              color: timKindColor(ev.kind), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2))),
        )));
      }
      for (final (t, l) in [(day.start, 'Start'), (day.end, 'End')]) {
        if (t == null) continue;
        kids.add(Positioned(left: (x(m(t)) - 14).clamp(0.0, w - 28), top: 0,
            child: Text(l, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary))));
      }
      final ticks = <Widget>[];
      // Fewer hour labels on a narrow (phone) screen so they don't overlap.
      final perHour = w / ((hi - lo) / 60);
      final step = perHour < 22 ? 180 : (perHour < 40 || (hi - lo) > 12 * 60) ? 120 : 60;
      for (var h = lo; h <= hi; h += step) {
        ticks.add(Positioned(left: (x(h) - 14).clamp(0.0, w - 30), top: 0,
            child: Text(TimSettings.clock(h, short: true), style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary))));
      }
      return Column(children: [
        SizedBox(height: 40, child: Stack(clipBehavior: Clip.none, children: kids)),
        SizedBox(height: 14, child: Stack(children: ticks)),
      ]);
    });
  }
}

/// Expanded view of one day: timeline, the day in order, and a summary.
class TimDayDetail extends StatefulWidget {
  final TimDay day;
  final TimSettings s;
  const TimDayDetail({super.key, required this.day, required this.s});
  @override
  State<TimDayDetail> createState() => _TimDayDetailState();
}

class _TimDayDetailState extends State<TimDayDetail> {
  // Where the route started / ended — GPS at once, the area name when found.
  late (String?, String?) _at = (timGps(widget.day.startAt), timGps(widget.day.endAt));

  @override
  void initState() {
    super.initState();
    _lookUp();
  }

  @override
  void didUpdateWidget(TimDayDetail old) {
    super.didUpdateWidget(old);
    if (!identical(old.day, widget.day)) {
      _at = (timGps(widget.day.startAt), timGps(widget.day.endAt));
      _lookUp();
    }
  }

  void _lookUp() {
    final d = widget.day;
    if (d.startAt == null && d.endAt == null) return;
    timPlaces(d).then((p) {
      if (mounted && identical(widget.day, d)) setState(() => _at = p);
    });
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final s = widget.s;
    String withPlace(String t, String? p) => p == null ? t : '$t · $p';
    final gaps = day.gaps(s);
    final lines = <Widget>[];
    if (day.start != null) {
      lines.add(_line(timClock(day.start), withPlace(day.role == 'driver' ? 'Delivery started' : 'Route started', _at.$1)));
    }
    var gi = 0;
    for (final ev in day.sorted) {
      while (gi < gaps.length && !gaps[gi].to.isAfter(ev.at)) {
        final g = gaps[gi++];
        lines.add(_line(timClock(g.from),
            g.beforeFirst ? '${timDur(g.length)} before the first stop' : '${timDur(g.length)} gap — nothing marked until ${timClock(g.to)}',
            gap: true));
      }
      lines.add(_line(timClock(ev.at),
          '${ev.place} · ${ev.kindText}${ev.amount > 0 ? ' · Rs ${money(ev.amount)}' : ''}',
          dot: timKindColor(ev.kind)));
    }
    if (day.end != null && !day.open) {
      lines.add(_line(timClock(day.end), withPlace(day.role == 'driver' ? 'Delivery completed' : 'Route ended', _at.$2)));
    } else if (day.open) {
      lines.add(_line('', 'Still out', color: AppTheme.primary));
    }

    final summary = <(String, String, Color?)>[
      ('Time in market (first → last stop)', timDur(day.inMarket), null),
      if (day.routeOpen != null) ('Route open (start → end)', timDur(day.routeOpen), null),
      ('Time in gaps over ${s.gapMin} min', timDur(day.lostToGaps(s)), gaps.isEmpty ? null : AppTheme.danger),
      ('Stops · per hour in market', '${day.visits} · ${day.perHour.toStringAsFixed(1)}', null),
      ('Average time per stop (incl. travel from last stop)', timDur(day.avgPerStop(s)), null),
      if (day.totalStops > 0) ('Planned stops not marked', '${(day.totalStops - day.visits).clamp(0, 100000)} of ${day.totalStops}', null),
      if (day.collected > 0) ('Collected', 'Rs ${money(day.collected)}', null),
    ];
    final wide = MediaQuery.of(context).size.width >= 900;
    final left = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('The day, in order', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
      const SizedBox(height: 6),
      Container(
        decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(10)),
        child: Column(children: lines),
      ),
    ]);
    final right = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Summary', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
      const SizedBox(height: 6),
      Container(
        decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(10)),
        child: Column(children: [
          for (final (l, v, c) in summary)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
              child: Row(children: [
                Expanded(child: Text(l, style: const TextStyle(fontSize: 12.5))),
                Text(v, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: c)),
              ]),
            ),
        ]),
      ),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 14, runSpacing: 4, children: [
        for (final k in day.role == 'driver'
            ? const ['delivered', 'outside', 'failed']
            : const ['visited', 'outside', 'no_gps', 'no_location', 'not_verified'])
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: timKindColor(k), shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(timKindLabel(k), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 14, height: 10, color: AppTheme.danger.withOpacity(0.25)),
          const SizedBox(width: 4),
          Text('Gap over ${s.gapMin} min', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 14, height: 10, color: AppTheme.primary.withOpacity(0.15)),
          const SizedBox(width: 4),
          Text('Day ${TimSettings.clock(s.dayStart)}–${TimSettings.clock(s.dayEnd)}',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        ]),
      ]),
      const SizedBox(height: 8),
      TimTimeline(day: day, s: s),
      if (day.startAt != null || day.endAt != null)
        FutureBuilder<(String?, String?)>(
          future: timPlaces(day),
          builder: (context, snap) {
            final p = snap.data ?? (timGps(day.startAt), timGps(day.endAt));
            Widget one(String label, String text) => Text.rich(
                  TextSpan(style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary), children: [
                    TextSpan(text: '$label  ', style: const TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(text: text),
                  ]),
                );
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 18, runSpacing: 4, children: [
                if (p.$1 != null) one('Started at', p.$1!),
                if (p.$2 != null) one('Ended at', p.$2!),
              ]),
            );
          },
        ),
      const SizedBox(height: 14),
      if (wide)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 6, child: left),
          const SizedBox(width: 16),
          Expanded(flex: 5, child: right),
        ])
      else ...[left, const SizedBox(height: 14), right],
    ]);
  }

  Widget _line(String t, String text, {bool gap = false, Color? dot, Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: gap ? AppTheme.danger.withOpacity(0.06) : null,
          border: const Border(bottom: BorderSide(color: AppTheme.border)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 46, child: Text(t, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          if (dot != null) ...[
            Padding(padding: const EdgeInsets.only(top: 4, right: 6),
                child: Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle))),
          ],
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5,
              fontWeight: gap ? FontWeight.w700 : FontWeight.w400, color: gap ? AppTheme.danger : color))),
        ]),
      );
}

/// A list of day rows (tap to expand). Used by the page and the 360 tab.
class TimDayList extends StatefulWidget {
  final List<TimDay> days;
  final TimSettings s;
  final bool showName; // page: name + route; 360: date + route
  final String? orgName; // for the print header
  final bool expandAll; // open every day (e.g. a single day in a pop-up)
  const TimDayList({super.key, required this.days, required this.s, this.showName = true, this.orgName, this.expandAll = false});
  @override
  State<TimDayList> createState() => _TimDayListState();
}

class _TimDayListState extends State<TimDayList> {
  final Set<String> _open = {};

  String _key(TimDay d) => '${d.userId}|${d.date.toIso8601String()}';

  @override
  void initState() {
    super.initState();
    if (widget.expandAll) _open.addAll(widget.days.map(_key));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final mobile = MediaQuery.of(context).size.width < 700;
    return Column(children: [
      for (final d in widget.days)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _open.contains(_key(d)) ? _open.remove(_key(d)) : _open.add(_key(d))),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.showName ? d.name : DateFormat('EEE, d MMM yyyy').format(d.date),
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                      Text([
                        if (widget.showName && d.role == 'driver') 'Driver',
                        if (d.routes.isNotEmpty) d.routes.join(', '),
                      ].join(' · '), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 6),
                      Wrap(spacing: 14, runSpacing: 4, children: [
                        _kv('Start', timClock(d.start)),
                        _kv('First stop', timClock(d.first), bad: d.lateStart(s)),
                        _kv('Last stop', timClock(d.last)),
                        _kv('End', d.open ? 'out' : timClock(d.end), bad: d.earlyClose(s)),
                        _kv('In market', timDur(d.inMarket)),
                        _kv('Stops', d.totalStops > 0 ? '${d.visits} / ${d.totalStops}' : '${d.visits}'),
                        if (!mobile) _kv('Per hour', d.perHour.toStringAsFixed(1)),
                        _kv('Per stop', timDur(d.avgPerStop(s))),
                        _kv('Longest gap', timDur(d.longestGap(s)),
                            bad: (d.longestGap(s)?.inMinutes ?? 0) > s.gapMin),
                      ]),
                      const SizedBox(height: 6),
                      Wrap(children: [for (final (t, c) in timFlags(d, s)) timTag(t, c)]),
                    ]),
                  ),
                  Icon(_open.contains(_key(d)) ? Icons.expand_less : Icons.expand_more, color: AppTheme.textSecondary),
                ]),
              ),
            ),
            if (_open.contains(_key(d)))
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: () => printTimDays([d], s,
                          orgName: widget.orgName,
                          detail: true,
                          rangeLabel: DateFormat('EEE, d MMM yyyy').format(d.date),
                          fileName: 'Time in Market - ${d.name} - ${DateFormat('d MMM yyyy').format(d.date)}'),
                      icon: const Icon(Icons.print_outlined, size: 16),
                      label: const Text('Print this day'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TimDayDetail(day: d, s: s),
                ]),
              ),
          ]),
        ),
    ]);
  }

  Widget _kv(String k, String v, {bool bad = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        Text(v, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: bad ? AppTheme.danger : null)),
      ]);
}

/// Team 360 tab: one person's days (salespeople and drivers only).
class TimPersonTab extends StatefulWidget {
  final String orgId;
  final String userId;
  const TimPersonTab({super.key, required this.orgId, required this.userId});
  @override
  State<TimPersonTab> createState() => _TimPersonTabState();
}

class _TimPersonTabState extends State<TimPersonTab> {
  int _daysBack = 7; // 7 | 30
  bool _loading = true;
  String? _error;
  TimSettings _s = TimSettings.defaults;
  List<TimDay> _days = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final now = DateTime.now();
      final s = await TimSettings.load(widget.orgId);
      final d = await loadTimDays(widget.orgId, now.subtract(Duration(days: _daysBack - 1)), now, userId: widget.userId);
      if (!mounted) return;
      setState(() { _s = s; _days = d; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load. Please try again.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final withStops = _days.where((d) => d.visits > 0).toList();
    final avg = withStops.isEmpty
        ? Duration.zero
        : Duration(minutes: withStops.fold<int>(0, (a, d) => a + d.inMarket.inMinutes) ~/ withStops.length);
    final late = _days.where((d) => d.lateStart(_s)).length;
    final early = _days.where((d) => d.earlyClose(_s)).length;
    final gaps = _days.fold<int>(0, (a, d) => a + d.longGapCount(_s));
    return ListView(
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 12 : 24),
      children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final n in const [7, 30])
            ChoiceChip(
              label: Text('Last $n days'),
              selected: _daysBack == n,
              onSelected: (_) { setState(() => _daysBack = n); _load(); },
            ),
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, size: 20)),
        ]),
        const SizedBox(height: 10),
        if (_loading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Text(_error!, style: const TextStyle(color: AppTheme.danger))
        else if (_days.isEmpty)
          const Padding(padding: EdgeInsets.all(30),
              child: Center(child: Text('No routes or deliveries in this period.', style: TextStyle(color: AppTheme.textSecondary))))
        else ...[
          Wrap(spacing: 10, runSpacing: 10, children: [
            _kpi('${_days.length}', 'days out'),
            _kpi(timDur(avg), 'average time in market'),
            _kpi(timDur(timAvgPerStop(_days, _s)), 'average time per stop'),
            _kpi('$late', 'late starts', bad: late > 0),
            _kpi('$gaps', 'long gaps', bad: gaps > 0),
            _kpi('$early', 'closed early', bad: early > 0),
          ]),
          const SizedBox(height: 12),
          TimDayList(days: _days, s: _s, showName: false),
        ],
      ],
    );
  }

  Widget _kpi(String v, String l, {bool bad = false}) => Container(
        width: 160,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(v, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: bad ? AppTheme.danger : null)),
          Text(l, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        ]),
      );
}


/// Time in Market for one person and a date range, in a pop-up (used by
/// Reimbursement Approvals to check the days of a claim).
Future<void> showTimeInMarketDialog(
  BuildContext context, {
  required String orgId,
  required String userId,
  required String name,
  required DateTime from,
  required DateTime to,
  String? orgName,
}) {
  final single = DateUtils.isSameDay(from, to);
  final label = single
      ? DateFormat('EEE, d MMM yyyy').format(from)
      : '${DateFormat('d MMM').format(from)} – ${DateFormat('d MMM yyyy').format(to)}';
  final load = () async {
    final s = await TimSettings.load(orgId);
    final days = await loadTimDays(orgId, from, to, userId: userId);
    return (s, days);
  }();
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 980, maxHeight: MediaQuery.of(ctx).size.height * 0.92),
        child: FutureBuilder<(TimSettings, List<TimDay>)>(
          future: load,
          builder: (ctx, snap) {
            final data = snap.data;
            return Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Time in Market · $name', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      Text(label, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                    ]),
                  ),
                  if (data != null && data.$2.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => printTimDays(data.$2, data.$1,
                          orgName: orgName, rangeLabel: label, detail: single,
                          fileName: 'Time in Market - $name - $label'),
                      icon: const Icon(Icons.print_outlined, size: 16),
                      label: const Text('Print'),
                    ),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ]),
                const SizedBox(height: 10),
                Flexible(
                  child: snap.connectionState != ConnectionState.done
                      ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                      : snap.hasError || data == null
                          ? const Padding(
                              padding: EdgeInsets.all(30),
                              child: Text('Could not load Time in Market. Please try again.',
                                  style: TextStyle(color: AppTheme.danger)))
                          : data.$2.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.all(30),
                                  child: Text('No route or delivery found on these days.',
                                      style: TextStyle(color: AppTheme.textSecondary)))
                              : SingleChildScrollView(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: TimDayList(
                                      days: data.$2, s: data.$1, showName: false,
                                      orgName: orgName, expandAll: data.$2.length == 1),
                                ),
                ),
              ]),
            );
          },
        ),
      ),
    ),
  );
}


/// "31.47680, 74.24280" (null when unknown).
String? timGps((double, double)? p) => p == null ? null : '${p.$1.toStringAsFixed(5)}, ${p.$2.toStringAsFixed(5)}';

/// Start / end place of a day: "Johar Town, Lahore (31.47680, 74.24280)", or
/// the GPS alone when the area name can't be looked up.
Future<(String?, String?)> timPlaces(TimDay d) async {
  Future<String?> one((double, double)? p) async {
    if (p == null) return null;
    String? n;
    try {
      n = await placeName(p.$1, p.$2);
    } catch (_) {}
    return n == null ? timGps(p) : '$n (${timGps(p)})';
  }
  return (await one(d.startAt), await one(d.endAt));
}

/// Works out each salesperson day's distance the same way the Combined Trip
/// Summary does: quick restarts merged, abandoned trips (no visits) left out,
/// road distance per trip (saved per trip on the server, straight lines if not
/// available). A few trips at a time. Never throws.
Future<void> timLoadDistances(List<TimDay> days) async {
  final jobs = <(TimDay, Map<String, dynamic>)>[];
  for (final d in days) {
    if (d.km != null || d.role == 'driver' || d.trips.isEmpty) continue;
    d.km = 0;
    final sessions = TripSessions.collapse(d.trips, (id) => (d.visitsByTrip[id] ?? const []).length);
    for (final t in sessions) {
      if (t['_abandoned'] == true) continue;
      jobs.add((d, t));
    }
  }
  for (var i = 0; i < jobs.length; i += 6) {
    final part = jobs.sublist(i, i + 6 > jobs.length ? jobs.length : i + 6);
    await Future.wait([
      for (final (d, t) in part)
        () async {
          try {
            final ctx = await TripReportContext.buildRoad(
              trip: t,
              visits: d.visitsByTrip['${t['id']}'] ?? const <Map<String, dynamic>>[],
              customersById: const {},
            );
            d.km = (d.km ?? 0) + ctx.totalDistanceKm;
          } catch (_) {}
        }(),
    ]);
  }
}
