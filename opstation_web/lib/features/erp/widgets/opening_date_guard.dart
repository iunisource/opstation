import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';

/// Guard for documents dated BEFORE the org's opening balance date.
///
/// The opening balance (Opening Journal) stands in for everything that happened
/// before it — customer balances, stock, cash. A sale or receipt dated earlier
/// than that is very likely already inside those opening figures, so posting it
/// would count it twice (or, if it was left out of the opening, needs care).
/// Opstation itself accepts any date, so we warn and ask before posting.

final Map<String, DateTime?> _cache = {};

/// The org's opening balance date (earliest posted opening journal), or null if
/// the org has no opening journal. Cached per org for the session.
Future<DateTime?> orgOpeningDate(String orgId) async {
  if (_cache.containsKey(orgId)) return _cache[orgId];
  DateTime? d;
  try {
    final rows = await Supabase.instance.client
        .from('journal_entries')
        .select('entry_date')
        .eq('org_id', orgId)
        .inFilter('reference_type', ['opening_jv', 'opening_balance'])
        .neq('status', 'draft')
        .order('entry_date', ascending: true)
        .limit(1);
    final list = rows as List;
    if (list.isNotEmpty) d = DateTime.tryParse('${list.first['entry_date']}');
  } catch (_) {}
  _cache[orgId] = d;
  return d;
}

/// Returns true when it's fine to go ahead: the date is on/after the opening
/// date, there is no opening date, or the user confirmed after the warning.
/// [doc] is a short label like "sales invoice" or "receipt".
Future<bool> confirmPreOpeningDate(BuildContext context,
    {required String? orgId, required DateTime date, required String doc}) async {
  if (orgId == null) return true;
  final open = await orgOpeningDate(orgId);
  if (open == null) return true;
  final day = DateTime(date.year, date.month, date.day);
  final openDay = DateTime(open.year, open.month, open.day);
  if (!day.isBefore(openDay)) return true;
  if (!context.mounted) return false;
  final f = DateFormat('d MMM yyyy');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.history_toggle_off, color: Color(0xFFB45309), size: 32),
      title: const Text('Dated before your opening balance', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('This $doc is dated ${f.format(day)}, which is before your opening balance date (${f.format(openDay)}).',
              style: const TextStyle(fontSize: 13.5, height: 1.45)),
          const SizedBox(height: 10),
          const Text(
            'Your opening balances already stand in for everything before that date — customer balances, '
            'stock and cash. If this was part of them, posting it now counts it twice.',
            style: TextStyle(fontSize: 13, height: 1.45, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7E6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFF5C26B)),
            ),
            child: const Text(
              'Usually the right fix is to change the date to the opening date or later, '
              'or to add it to the opening balance instead.',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF7C4A03), height: 1.4),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Go back')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB45309), foregroundColor: Colors.white),
          onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
          child: const Text('Post anyway'),
        ),
      ],
    ),
  );
  return ok == true;
}
