import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_database.dart';

/// One physical CR book issued to this salesperson (SQL 411).
class ReceiptBook {
  final String id;
  final int start;
  final int end;
  final String? label;
  final Set<int> used;      // already on synced collections
  final Set<int> cancelled; // torn / spoiled
  const ReceiptBook(this.id, this.start, this.end, this.label, this.used, this.cancelled);

  bool contains(int n) => n >= start && n <= end;
  String get range => '$start–$end';

  Map<String, dynamic> toJson() => {
        'id': id, 'start': start, 'end': end, 'label': label,
        'used': used.toList(), 'cancelled': cancelled.toList(),
      };

  static ReceiptBook? fromJson(Map<String, dynamic> m) {
    final s = (m['start'] as num?)?.toInt(), e = (m['end'] as num?)?.toInt();
    if (s == null || e == null || m['id'] == null) return null;
    Set<int> ints(Object? l) => {
          for (final x in (l as List? ?? const [])) if (x is num) x.toInt(),
        };
    return ReceiptBook('${m['id']}', s, e, m['label'] as String?, ints(m['used']), ints(m['cancelled']));
  }
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
    list.sort((a, b) => a.start.compareTo(b.start));
    books = list;
  }

  static ReceiptBook? bookOf(int n) {
    for (final b in books) {
      if (b.contains(n)) return b;
    }
    return null;
  }

  /// Why this CR# can't be used, or null when it's fine. [localUsed] = slips
  /// on this phone's collections not yet reflected by the server.
  static String? problem(String receipt, Set<int> localUsed) {
    if (!on) return null;
    final slips = receiptSlips(receipt);
    if (slips.isEmpty) return 'Enter the receipt (CR#) number from your receipt book.';
    if (books.isEmpty) return 'No receipt book is issued to you. Ask your supervisor to issue one.';
    final seen = <int>{};
    for (final n in slips) {
      if (!seen.add(n)) return 'CR# $n is entered twice.';
      final b = bookOf(n);
      if (b == null) {
        return 'CR# $n is not from your receipt book (${books.map((b) => b.range).join(', ')}). '
            'Check the slip number.';
      }
      if (b.cancelled.contains(n)) return 'CR# $n was cancelled. Use the next slip.';
      if (b.used.contains(n) || localUsed.contains(n)) return 'CR# $n is already used. Check the slip number.';
    }
    return null;
  }

  /// The lowest slip not yet used or cancelled (oldest book first).
  static int? next(Set<int> localUsed) {
    if (!on) return null;
    for (final b in books) {
      for (var n = b.start; n <= b.end; n++) {
        if (!b.used.contains(n) && !b.cancelled.contains(n) && !localUsed.contains(n)) return n;
      }
    }
    return null;
  }

  /// Slips left across open books.
  static int left(Set<int> localUsed) {
    var n = 0;
    for (final b in books) {
      for (var s = b.start; s <= b.end; s++) {
        if (!b.used.contains(s) && !b.cancelled.contains(s) && !localUsed.contains(s)) n++;
      }
    }
    return n;
  }

  /// Mark a torn / spoiled slip as cancelled (needs internet).
  static Future<void> cancelSlip(AppDatabase db, String orgId, int serial, String reason) async {
    final b = bookOf(serial);
    if (b == null) throw ArgumentError('CR# $serial is not from your receipt book.');
    await Supabase.instance.client.rpc('receipt_slip_cancel', params: {
      'p_book': b.id, 'p_serial': serial, 'p_reason': reason,
    });
    b.cancelled.add(serial);
    await refresh(db, orgId);
  }
}
