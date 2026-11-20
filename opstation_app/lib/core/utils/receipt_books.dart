import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_database.dart';
import 'receipt_slip_key.dart';

/// One physical CR book issued to this salesperson (SQL 411).
class ReceiptBook {
  final String id;
  final int start;
  final int end;
  final String? label;
  final Set<int> used;      // already on synced collections (plain numbers of this book)
  final Set<int> cancelled; // torn / spoiled
  final String? prefix;     // the book's letter, e.g. "B" (SQL 487); null = plain numbers
  const ReceiptBook(this.id, this.start, this.end, this.label, this.used, this.cancelled, [this.prefix]);

  bool contains(int n) => n >= start && n <= end;
  /// A slip key (see receipt_slip_key.dart) of this book?
  bool holds(int key) => slipPrefixOf(key) == (prefix ?? '') && contains(slipNumber(key));
  int keyOf(int n) => slipKey(prefix, n);
  String fmt(int n) => '${prefix ?? ''}$n';
  String get range => '${fmt(start)}–${fmt(end)}';

  Map<String, dynamic> toJson() => {
        'id': id, 'start': start, 'end': end, 'label': label, 'prefix': prefix,
        'used': used.toList(), 'cancelled': cancelled.toList(),
      };

  static ReceiptBook? fromJson(Map<String, dynamic> m) {
    final s = (m['start'] as num?)?.toInt(), e = (m['end'] as num?)?.toInt();
    if (s == null || e == null || m['id'] == null) return null;
    Set<int> ints(Object? l) => {
          for (final x in (l as List? ?? const [])) if (x is num) x.toInt(),
        };
    final pre = '${m['prefix'] ?? ''}'.trim().toUpperCase();
    return ReceiptBook('${m['id']}', s, e, m['label'] as String?, ints(m['used']), ints(m['cancelled']),
        pre.isEmpty ? null : pre);
  }
}

/// Slip keys of a CR#, reading the letters of this phone's books.
List<int> receiptSlipKeys(String raw) => slipKeys(raw, ReceiptBooks.letters);

/// The CR# text with the NEXT slip added — the "+" beside the CR# box:
/// "B1250" → "B1250, B1251", "101, 102" → "101, 102, 103". With receipt books on
/// it skips slips already used or cancelled and stays inside the book (null at
/// the book's end). Without books it is simply the number after the last one.
/// Null when no slip is typed yet. Slips that are not in sequence are typed by
/// hand as before ("101, 105").
String? receiptWithNextSlip(String raw, {Set<int> localUsed = const {}}) {
  final keys = receiptSlipKeys(raw);
  if (keys.isEmpty) return null;
  final last = keys.last;
  var n = slipNumber(last) + 1;
  final b = ReceiptBooks.on ? ReceiptBooks.bookOf(last) : null;
  if (b != null) {
    bool taken(int x) =>
        b.used.contains(x) || b.cancelled.contains(x) || localUsed.contains(b.keyOf(x)) || keys.contains(b.keyOf(x));
    while (n <= b.end && taken(n)) {
      n++;
    }
    if (n > b.end) return null;
  }
  final base = raw.trim().replaceAll(RegExp(r'[\s,&+]+$'), '');
  return '$base, ${slipPrefixOf(last)}$n';
}

/// Expand a CR# field into every slip it represents — "32282 83 84" →
/// 32282, 32283, 32284; "31457 & 31458" → both. Same rules as the web.
List<int> receiptSlips(String raw) {
  final toks = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).toList();
  final out = <int>[];
  int? prev;
  for (final t in toks) {
    if (t.length > 15) continue;
    final n = int.parse(t);
    if (prev == null || t.length >= prev.toString().length) {
      out.add(n);
      prev = n;
    } else {
      var p10 = 1;
      for (var i = 0; i < t.length; i++) {
        p10 *= 10;
      }
      prev = (prev - (prev % p10)) + n;
      out.add(prev);
    }
  }
  return out;
}

/// Admin Settings → "Receipt books". When ON, a collection's CR# must be an
/// unused slip from one of the salesperson's own open books. Kept on the phone
/// so it works offline; refreshed with the routes.
class ReceiptBooks {
  ReceiptBooks._();

  static const _key = 'cache.receipt_books';
  static bool on = false;
  static List<ReceiptBook> books = const [];
  static bool _loaded = false;

  static Future<void> ensureLoaded(AppDatabase db) async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await db.getConfig(_key);
      if (raw == null || raw.isEmpty) return;
      _apply(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {}
  }

  static Future<void> refresh(AppDatabase db, String orgId) async {
    try {
      final r = await Supabase.instance.client.rpc('receipt_books_mine', params: {'p_org': orgId});
      final m = Map<String, dynamic>.from(r as Map);
      _loaded = true;
      _apply(m);
      await db.setConfig(_key, jsonEncode({'on': on, 'books': [for (final b in books) b.toJson()]}));
    } catch (_) {
      // Not set up on the server yet / offline — keep the copy on the phone.
      await ensureLoaded(db);
    }
  }

  static void _apply(Map<String, dynamic> m) {
    on = m['on'] == true;
    final list = <ReceiptBook>[];
    for (final b in (m['books'] as List? ?? const [])) {
      final x = ReceiptBook.fromJson(Map<String, dynamic>.from(b as Map));
      if (x != null) list.add(x);
    }
    list.sort((a, b) {
      final p = (a.prefix ?? '').compareTo(b.prefix ?? '');
      return p != 0 ? p : a.start.compareTo(b.start);
    });
    books = list;
  }

  /// Letters of this phone's open books ("B", …).
  static Set<String> get letters => {for (final b in books) if (b.prefix != null) b.prefix!};

  /// The book holding a slip key (letter and number must both match).
  static ReceiptBook? bookOf(int key) {
    for (final b in books) {
      if (b.holds(key)) return b;
    }
    return null;
  }

  /// Why this CR# can't be used, or null when it's fine. [localUsed] = slip
  /// keys on this phone's collections not yet reflected by the server.
  static String? problem(String receipt, Set<int> localUsed) {
    if (!on) return null;
    final slips = receiptSlipKeys(receipt);
    if (slips.isEmpty) return 'Enter the receipt (CR#) number from your receipt book.';
    if (books.isEmpty) return 'No receipt book is issued to you. Ask your supervisor to issue one.';
    final seen = <int>{};
    for (final k in slips) {
      final label = slipLabel(k);
      if (!seen.add(k)) return 'CR# $label is entered twice.';
      final b = bookOf(k);
      if (b == null) {
        // Number of a lettered book typed without its letter.
        final n = slipNumber(k);
        final lettered = slipPrefixOf(k).isEmpty
            ? books.where((x) => x.prefix != null && x.contains(n)).toList()
            : const <ReceiptBook>[];
        if (lettered.isNotEmpty) {
          return 'Write the book letter with the number: ${lettered.first.fmt(n)}.';
        }
        return 'CR# $label is not from your receipt book (${books.map((b) => b.range).join(', ')}). '
            'Check the slip number.';
      }
      final n = slipNumber(k);
      if (b.cancelled.contains(n)) return 'CR# $label was cancelled. Use the next slip.';
      if (b.used.contains(n) || localUsed.contains(k)) return 'CR# $label is already used. Check the slip number.';
    }
    return null;
  }

  /// The slip to suggest next, written as on the slip: "B1251" for a lettered
  /// book, "1251" otherwise. It always MOVES FORWARD: the first free slip after
  /// the last one used ([lastKey] = the latest slip on this phone's collections;
  /// without one, after the highest slip used in the first open book).
  /// A skipped slip is not suggested again and again — it stays unused (the
  /// Skipped Receipts report shows it) and can still be typed or cancelled.
  /// Only when nothing is free after it does it fall back to a skipped slip.
  static String? next(Set<int> localUsed, {int? lastKey}) {
    if (!on) return null;
    bool free(ReceiptBook b, int n) =>
        !b.used.contains(n) && !b.cancelled.contains(n) && !localUsed.contains(b.keyOf(n));
    int? firstFree(ReceiptBook b, int from) {
      for (var n = from < b.start ? b.start : from; n <= b.end; n++) {
        if (free(b, n)) return n;
      }
      return null;
    }

    // 1) Keep going in the book the rep is writing in right now.
    if (lastKey != null) {
      final cur = bookOf(lastKey);
      if (cur != null) {
        final n = firstFree(cur, slipNumber(lastKey) + 1);
        if (n != null) return cur.fmt(n);
      }
    }
    // 2) Otherwise the first open book, after the highest slip already used.
    for (final b in books) {
      var hi = b.start - 1;
      for (final u in b.used) {
        if (b.contains(u) && u > hi) hi = u;
      }
      for (final k in localUsed) {
        if (b.holds(k) && slipNumber(k) > hi) hi = slipNumber(k);
      }
      final n = firstFree(b, hi + 1) ?? firstFree(b, b.start);
      if (n != null) return b.fmt(n);
    }
    return null;
  }

  /// Slips left across open books.
  static int left(Set<int> localUsed) {
    var n = 0;
    for (final b in books) {
      for (var s = b.start; s <= b.end; s++) {
        if (!b.used.contains(s) && !b.cancelled.contains(s) && !localUsed.contains(b.keyOf(s))) n++;
      }
    }
    return n;
  }

  /// Mark a torn / spoiled slip as cancelled (needs internet). [key] = slip key.
  static Future<void> cancelSlip(AppDatabase db, String orgId, int key, String reason) async {
    final b = bookOf(key);
    if (b == null) throw ArgumentError('CR# ${slipLabel(key)} is not from your receipt book.');
    final serial = slipNumber(key);
    await Supabase.instance.client.rpc('receipt_slip_cancel', params: {
      'p_book': b.id, 'p_serial': serial, 'p_reason': reason,
    });
    b.cancelled.add(serial);
    await refresh(db, orgId);
  }
}

/// Next CR# when receipt books are OFF: continues the series of the latest
/// receipt entered, keeping its letters and style — "B-1234" → "B-1235",
/// "B1234" → "B1235", "1234" → "1235". [receipts] = (when, CR#) of today's
/// collections. null when nothing has been entered yet.
String? nextReceiptAfter(Iterable<(DateTime, String)> receipts) {
  final list = [...receipts]..sort((a, b) => a.$1.compareTo(b.$1));
  if (list.isEmpty) return null;
  // Slips as (letters, separator, number), with "& 51" short endings expanded.
  List<(String, String, int)> parse(String raw) {
    final out = <(String, String, int)>[];
    int? prev;
    var prevL = '', prevSep = '';
    for (final m in RegExp(r'(?:([A-Za-z]{1,3})([ \-]?))?(\d+)').allMatches(raw)) {
      final t = m.group(3)!;
      if (t.length > 15) continue;
      var l = (m.group(1) ?? '').toUpperCase(), sep = m.group(2) ?? '';
      if (m.group(1) == null) { l = prevL; sep = prevSep; }
      final int n;
      if (prev == null || t.length >= prev.toString().length) {
        n = int.parse(t);
      } else {
        var p10 = 1;
        for (var i = 0; i < t.length; i++) {
          p10 *= 10;
        }
        n = (prev - (prev % p10)) + int.parse(t);
      }
      out.add((l, sep, n));
      prev = n; prevL = l; prevSep = sep;
    }
    return out;
  }
  final last = parse(list.last.$2);
  if (last.isEmpty) return null;
  final series = last.last.$1; // letters of the latest slip
  var sep = last.last.$2;
  int? hi;
  for (final r in list) {
    for (final (l, s, n) in parse(r.$2)) {
      if (l != series) continue;
      if (hi == null || n > hi) { hi = n; sep = s; }
    }
  }
  return hi == null ? null : '$series$sep${hi + 1}';
}
