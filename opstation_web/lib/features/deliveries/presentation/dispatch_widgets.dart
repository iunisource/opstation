import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

String _alnum(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Whether a driver card matches what was typed in the dispatch search: the driver's name, or the
/// registration number of his vehicle ("lea 555", "LEA555" and "lea-555" all find LEA 555).
bool driverMatches(String query, {required String name, String? regNo}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (name.toLowerCase().contains(q)) return true;
  final reg = (regNo ?? '').trim();
  if (reg.isEmpty) return false;
  if (reg.toLowerCase().contains(q)) return true;
  final qa = _alnum(q);
  return qa.isNotEmpty && _alnum(reg).contains(qa);
}

/// When the dashboard last got its data ("Updated 6:23:45 PM"). It turns amber when that was a while ago
/// (the dashboard refreshes by itself every 45 seconds, so an old time means the refreshing is not getting
/// through), so nobody trusts a stale picture without knowing.
class LastUpdatedLabel extends StatelessWidget {
  const LastUpdatedLabel({super.key, required this.at, required this.format, this.now, this.staleAfter = const Duration(minutes: 3)});

  final DateTime? at;
  final String Function(DateTime) format;
  final DateTime Function()? now;
  final Duration staleAfter;

  @override
  Widget build(BuildContext context) {
    final t = at;
    if (t == null) return const SizedBox.shrink();
    final stale = (now ?? DateTime.now)().difference(t) > staleAfter;
    final color = stale ? const Color(0xFFB45309) : AppTheme.textSecondary;
    return Tooltip(
      message: stale ? 'The dashboard has not refreshed for a while. Press refresh.' : 'The last time the dashboard got its data',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(stale ? Icons.warning_amber_rounded : Icons.schedule, size: 14, color: color),
        const SizedBox(width: 4),
        Text('Updated ${format(t)}', style: TextStyle(fontSize: 12, fontWeight: stale ? FontWeight.w700 : FontWeight.w500, color: color)),
      ]),
    );
  }
}

/// The registration number of the driver's vehicle, on his card.
class RegNoPill extends StatelessWidget {
  const RegNoPill(this.regNo, {super.key});

  final String regNo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
      child: Text(regNo, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF334155), letterSpacing: 0.3)),
    );
  }
}
