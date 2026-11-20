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
