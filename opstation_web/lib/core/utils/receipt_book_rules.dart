import 'receipt_slip_key.dart';

/// Rules of the Receipt Books report that are kept apart so they can be tested.

/// Slips written out of order. The slips are lined up by the time they were
/// written; a slip lower than one already used earlier is out of order.
///
/// Only the HOLDER's own entries decide the order. A stray entry by someone else
/// has its own flag ("Used by someone else"); counting it here made every slip
/// written after it look out of order (one early entry of slip 130 flagged
/// 101–129). [used] rows: {serial, user_id, at, ...}.
List<int> outOfOrderSerials(List<Map<String, dynamic>> used, String holderId) {
  final own = holderId.isEmpty
      ? [...used]
      : [
          for (final u in used)
            if ('${u['user_id'] ?? ''}' == holderId) u
        ];
  own.sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
  final out = <int>{};
  var maxSoFar = -1;
  for (final u in own) {
    final n = (u['serial'] as num).toInt();
    if (n < maxSoFar) out.add(n);
    if (n > maxSoFar) maxSoFar = n;
  }
  return out.toList()..sort();
}

/// The slips of a book that are neither used nor cancelled — the ones a "mark
/// the unused slips as returned blank" close accounts for.
List<int> unaccountedSlips(int start, int end, Set<int> used, Set<int> cancelled) =>
    [for (var n = start; n <= end; n++) if (!used.contains(n) && !cancelled.contains(n)) n];

/// One issued receipt book, as the missing-receipts check needs it.
class BookSlips {
  const BookSlips({required this.start, required this.end, required this.accounted, this.prefix});
  final int start;
  final int end;
  final String? prefix; // the book's letter, or null
  /// Numbers accounted for: used on a collection (by anyone), cancelled, or cleared.
  final Set<int> accounted;

  bool holds(int key) {
    final n = slipNumber(key);
    return n >= start && n <= end && slipPrefixOf(key) == (prefix ?? '');
  }

  String label(int n) => '${prefix ?? ''}$n';
}

/// Receipt numbers in a text, digits only (letters ignored), with short endings
/// expanded ("101 02 03" -> 101, 102, 103). The original, book-less reading.
List<int> legacyReceiptNumbers(String raw) {
  final toks = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).toList();
  final out = <int>[];
  int? prevFull;
  for (final t in toks) {
    final n = int.tryParse(t);
    if (n == null) continue;
    final prevLen = prevFull?.toString().length ?? 0;
    if (prevFull == null || t.length >= prevLen) {
      out.add(n);
      prevFull = n;
    } else {
      var p10 = 1;
      for (var i = 0; i < t.length; i++) {
        p10 *= 10;
      }
      final expanded = (prevFull - (prevFull % p10)) + n;
      out.add(expanded);
      prevFull = expanded;
    }
  }
  return out;
}

List<String> _plainGaps(List<int> nums) {
  final sorted = [...nums]..sort();
  final out = <String>[];
  for (var i = 1; i < sorted.length; i++) {
    final gap = sorted[i] - sorted[i - 1];
    if (gap > 1 && gap <= 20) {
      for (var n = sorted[i - 1] + 1; n < sorted[i]; n++) {
        out.add('$n');
      }
    }
  }
  return out;
}

/// Receipt slips that look missing from [rawEntries] (the CR# texts one person
/// entered in a trip or a period).
///
/// The receipt-books flow is either ON or OFF:
///  * ON  ([flowOn] true): checked against the person's [books] only. A slip between
///    the lowest and highest entered number of a book is missing only if it is not
///    accounted for there — used on a collection (by anyone), cancelled or cleared.
///    Numbers that belong to no book are not guessed at: the Receipt Books screen
///    lists them as "from no book".
///  * OFF: the old check — a gap of up to 20 in the sorted number sequence, bigger
///    jumps being a new book. [books] is ignored.
List<String> missingSlipLabels(Iterable<String> rawEntries, {required bool flowOn, List<BookSlips> books = const []}) {
  if (!flowOn) {
    return _plainGaps([for (final r in rawEntries) ...legacyReceiptNumbers(r)]);
  }
  if (books.isEmpty) return const [];
  final letters = {
    for (final b in books)
      if (b.prefix != null && b.prefix!.isNotEmpty) b.prefix!.toUpperCase()
  };
  final byBook = <BookSlips, Set<int>>{};
  for (final raw in rawEntries) {
    for (final k in slipKeys(raw, letters)) {
      for (final b in books) {
        if (b.holds(k)) {
          (byBook[b] ??= <int>{}).add(slipNumber(k));
          break;
        }
      }
    }
  }
  final out = <String>[];
  for (final e in byBook.entries) {
    final ns = e.value.toList()..sort();
    if (ns.length < 2) continue;
    for (var n = ns.first + 1; n < ns.last; n++) {
      if (!e.key.accounted.contains(n)) out.add(e.key.label(n));
    }
  }
  return out;
}
