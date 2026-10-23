import 'package:flutter/material.dart';
import '../../../core/database/app_database.dart';

/// Customer filter shared by Competitor Spotting and Placement Audit: narrow the
/// shop list by Main Group (customer category) and Group. The choice is kept
/// while the app is open, so both survey screens show the same selection.
class SurveyCustomerFilter {
  SurveyCustomerFilter._();

  static final Set<String> mainGroups = {};
  static final Set<String> groups = {};

  static const String blank = '(Not set)';

  static int get count => mainGroups.length + groups.length;

  static String _v(String? s) {
    final t = (s ?? '').trim();
    return t.isEmpty ? blank : t;
  }

  static bool matches(CustomersData c) =>
      (mainGroups.isEmpty || mainGroups.contains(_v(c.category))) &&
      (groups.isEmpty || groups.contains(_v(c.groupName)));

  /// Opens the filter sheet. Returns true when the selection changed.
  static Future<bool> open(BuildContext context, List<CustomersData> customers) async {
    List<MapEntry<String, int>> counted(String? Function(CustomersData) pick) {
      final m = <String, int>{};
      for (final c in customers) {
        final k = _v(pick(c));
        m[k] = (m[k] ?? 0) + 1;
      }
      final l = m.entries.toList()
        ..sort((a, b) {
          if (a.key == blank) return 1;
          if (b.key == blank) return -1;
          return a.key.toLowerCase().compareTo(b.key.toLowerCase());
        });
      return l;
    }

    final mains = counted((c) => c.category);
    final grps = counted((c) => c.groupName);
    final selMain = {...mainGroups};
    final selGrp = {...groups};

    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        Widget section(String title, List<MapEntry<String, int>> items, Set<String> sel) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                  if (sel.isNotEmpty)
                    TextButton(onPressed: () => setLocal(sel.clear), child: const Text('Clear')),
                ]),
                const SizedBox(height: 4),
                if (items.isEmpty)
                  const Text('None on this phone yet.', style: TextStyle(color: Colors.grey))
                else
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final e in items)
                      FilterChip(
                        label: Text('${e.key} (${e.value})'),
                        selected: sel.contains(e.key),
                        onSelected: (v) => setLocal(() => v ? sel.add(e.key) : sel.remove(e.key)),
                      ),
                  ]),
              ],
            );
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Filter shops', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      section('Main Group', mains, selMain),
                      const SizedBox(height: 18),
                      section('Group', grps, selGrp),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setLocal(() { selMain.clear(); selGrp.clear(); }),
                      child: const Text('Clear all'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Apply'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        );
      }),
    );
    if (applied != true) return false;
    final changed = selMain.length != mainGroups.length || !selMain.containsAll(mainGroups) ||
        selGrp.length != groups.length || !selGrp.containsAll(groups);
    mainGroups
      ..clear()
      ..addAll(selMain);
    groups
      ..clear()
      ..addAll(selGrp);
    return changed;
  }

  /// App-bar button with a count badge.
  static Widget button({required VoidCallback onPressed}) => IconButton(
        tooltip: 'Filter by Main Group / Group',
        onPressed: onPressed,
        icon: Badge(
          isLabelVisible: count > 0,
          label: Text('$count'),
          child: const Icon(Icons.filter_list),
        ),
      );
}
