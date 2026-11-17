// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:supabase_flutter/supabase_flutter.dart';

/// Area name for a GPS point ("Johar Town, Lahore").
///
/// 1. This page's memory.
/// 2. The shared list of names already found (table place_names, SQL 488) —
///    once anyone in the organisation got a name for a spot (~10 m), every
///    later report uses it at once.
/// 3. OpenStreetMap's free lookup — ONE request at a time, about one per
///    second (its limit; firing many at once made most of them fail, which is
///    why reports showed coordinates). A name found is saved to the shared
///    list. A failed lookup is tried again later, not remembered as "none".
///
/// Returns null when no name could be found (in time) — callers show the GPS.
/// [until]: give up waiting after this moment (prints use a time budget).

final Map<String, String> _names = {};
final Map<String, DateTime> _failedAt = {}; // retry after a minute
final Map<String, Future<String?>> _pending = {};

String _key(double lat, double lng) => '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';

Future<String?> placeName(double lat, double lng, {DateTime? until}) {
  final key = _key(lat, lng);
  final hit = _names[key];
  if (hit != null) return Future.value(hit);
  final f = _failedAt[key];
  if (f != null && DateTime.now().difference(f) < const Duration(minutes: 1)) return Future.value(null);
  final running = _pending[key];
  if (running != null) return _withDeadline(running, until);
  final job = _resolve(key, lat, lng).whenComplete(() => _pending.remove(key));
  _pending[key] = job;
  return _withDeadline(job, until);
}

Future<String?> _withDeadline(Future<String?> f, DateTime? until) {
  if (until == null) return f;
  final left = until.difference(DateTime.now());
  if (left <= Duration.zero) return Future.value(null);
  return f.timeout(left, onTimeout: () => null); // the lookup carries on and is saved
}

Future<String?> _resolve(String key, double lat, double lng) async {
  // 2. shared list (several keys asked together)
  final saved = await _Batch.get(key);
  if (saved != null && saved.isNotEmpty) {
    _names[key] = saved;
    return saved;
  }
  // 3. OpenStreetMap, queued; one retry
  for (var attempt = 0; attempt < 2; attempt++) {
    final n = await _Osm.lookup(lat, lng);
    if (n != null) {
      _names[key] = n;
      _failedAt.remove(key);
      _save(key, lat, lng, n);
      return n;
    }
    await Future.delayed(const Duration(seconds: 2));
  }
  _failedAt[key] = DateTime.now();
  return null;
}

void _save(String key, double lat, double lng, String name) {
  Supabase.instance.client.from('place_names').upsert(
    {'key': key, 'lat': double.parse(lat.toStringAsFixed(4)), 'lng': double.parse(lng.toStringAsFixed(4)), 'name': name},
    onConflict: 'key',
    ignoreDuplicates: true,
  ).then((_) {}, onError: (_) {}); // table not there yet → just not shared
}

/// Collects the keys asked for within ~60 ms and reads them in one request.
class _Batch {
  static final Map<String, Completer<String?>> _waiting = {};
  static Timer? _timer;
  static bool _tableMissing = false;

  static Future<String?> get(String key) {
    if (_tableMissing) return Future.value(null);
    final c = _waiting.putIfAbsent(key, () => Completer<String?>());
    _timer ??= Timer(const Duration(milliseconds: 60), _flush);
    return c.future;
  }

  static Future<void> _flush() async {
    _timer = null;
    final batch = Map<String, Completer<String?>>.from(_waiting);
    _waiting.clear();
    final found = <String, String>{};
    try {
      final keys = batch.keys.toList();
      for (var i = 0; i < keys.length; i += 150) {
        final rows = await Supabase.instance.client.from('place_names').select('key, name')
            .inFilter('key', keys.sublist(i, i + 150 > keys.length ? keys.length : i + 150));
        for (final r in rows as List) {
          found['${r['key']}'] = '${r['name'] ?? ''}';
        }
      }
    } catch (e) {
      if ('$e'.contains('place_names')) _tableMissing = true;
    }
    batch.forEach((k, c) {
      if (!c.isCompleted) c.complete(found[k]);
    });
  }
}

/// OpenStreetMap reverse lookup, one at a time, ≥ 1.1 s apart.
class _Osm {
  static Future<void> _chain = Future.value();
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<String?> lookup(double lat, double lng) {
    final done = Completer<String?>();
    _chain = _chain.then((_) async {
      final wait = const Duration(milliseconds: 1100) - DateTime.now().difference(_last);
      if (wait > Duration.zero) await Future.delayed(wait);
      _last = DateTime.now();
      done.complete(await _fetch(lat, lng));
    });
    return done.future;
  }

  static Future<String?> _fetch(double lat, double lng) async {
    try {
      final url = 'https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=16&addressdetails=1'
          '&accept-language=en&lat=$lat&lon=$lng';
      final res = await html.HttpRequest.request(url, requestHeaders: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      final m = jsonDecode(res.responseText ?? '{}') as Map<String, dynamic>;
      final a = Map<String, dynamic>.from((m['address'] as Map?) ?? const {});
      String? pick(List<String> keys) {
        for (final k in keys) {
          final v = '${a[k] ?? ''}'.trim();
          if (v.isNotEmpty) return v;
        }
        return null;
      }
      final area = pick(['neighbourhood', 'suburb', 'quarter', 'residential', 'village', 'road']);
      final city = pick(['city', 'town', 'county', 'state_district']);
      final parts = <String>[
        if (area != null) area,
        if (city != null && city != area) city,
      ];
      return parts.isEmpty ? null : parts.join(', ');
    } catch (_) {
      return null;
    }
  }
}

/// Start / end place for a trip row (start_lat … end_lng), as
/// "Area, City\n31.47680, 74.24280" — or null when unknown.
Future<(String?, String?)> tripPlaceNames(Map<String, dynamic> trip, {DateTime? until}) async {
  final deadline = until ?? DateTime.now().add(const Duration(seconds: 10));
  Future<String?> one(String la, String lo) async {
    final lat = (trip[la] as num?)?.toDouble(), lng = (trip[lo] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    final n = await placeName(lat, lng, until: deadline);
    if (n == null) return null;
    return '$n\n${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
  }
  final r = await Future.wait([one('start_lat', 'start_lng'), one('end_lat', 'end_lng')]);
  return (r[0], r[1]);
}
