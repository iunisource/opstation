import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// How a stored attendance day affects pay — the same rules payroll uses:
///   • approved leave (absent, reviewed "excused") → 1 day deducted
///   • unapproved absence → 2 days (the day itself + 1 extra). When attendance
///     review already placed the extra day on a later date, this day is 1 and
///     that later day is the "penalty day".
///   • penalty day → 1 day deducted, even if the employee was present / punched
///   • plain absent → 1 · half day → ½
class AttDeduction {
  final double days;
  final String short; // compact tag, e.g. "×2"
  final String text;  // full sentence for tooltips / notes
  final bool penaltyDay;
  const AttDeduction(this.days, this.short, this.text, {this.penaltyDay = false});

  String get daysLabel => days == days.roundToDouble() ? days.toInt().toString() : days.toString();
}

String _d(String? iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  return d == null ? '' : DateFormat('d MMM').format(d);
}

/// [hasPenaltyRow]: an extra (penalty) day was already placed elsewhere for
/// this unapproved absence.
AttDeduction? attDeduction(Map? rec, {bool hasPenaltyRow = false}) {
  if (rec == null) return null;
  final st = rec['status'] as String?;
  if (rec['is_penalty'] == true) {
    final src = _d(rec['penalty_source_date'] as String?);
    return AttDeduction(1, 'Penalty',
        'Penalty day${src.isEmpty ? '' : ' for the unapproved absence on $src'} — 1 day deducted, not paid even if present.',
        penaltyDay: true);
  }
  if (st == 'absent') {
    final rv = rec['review_status'] as String?;
    if (rv == 'unapproved') {
      return hasPenaltyRow
          ? const AttDeduction(1, 'Unapproved', 'Unapproved absence — 1 day here, the extra day is deducted on a later date.')
          : const AttDeduction(2, 'Unapproved ×2', 'Unapproved absence — 2 days deducted (the day + 1 extra).');
    }
    if (rv == 'excused') return const AttDeduction(1, 'Leave −1', 'Approved leave — 1 day deducted.');
    return const AttDeduction(1, 'Absent −1', 'Absent — 1 day deducted.');
  }
  if (st == 'half_day') return const AttDeduction(0.5, '−½', 'Half day — ½ day deducted.');
  return null;
}

/// Small red/orange tag shown next to a day's status.
Widget attDeductionChip(AttDeduction d) {
  final c = d.penaltyDay || d.days >= 2 ? Colors.red.shade700 : Colors.orange.shade800;
  return Tooltip(
    message: d.text,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withOpacity(0.35)),
      ),
      child: Text(d.short, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c)),
    ),
  );
}
