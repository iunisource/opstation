import 'package:flutter/material.dart';

/// What the Fleet page's counters filter the list by. Several can be on at once: a vehicle is shown when it
/// matches ANY of them (service due + overdue = everything that needs a service).
enum FleetFilter { due, overdue, repairs }

String fleetFilterLabel(FleetFilter f) {
  switch (f) {
    case FleetFilter.due:
      return 'Service due';
    case FleetFilter.overdue:
      return 'Overdue';
    case FleetFilter.repairs:
      return 'Repairs ongoing';
  }
}

/// The vehicles to show (and to print): those matching the search text AND, when any counter is on, matching
/// at least one of the counters. [states] holds each vehicle's service state ('ok' | 'due' | 'overdue') by
/// id; [openTasks] its number of ongoing repairs; [searchText] is what the search looks in.
List<Map<String, dynamic>> filterVehicles(
  List<Map<String, dynamic>> vehicles, {
  String search = '',
  Set<FleetFilter> filters = const {},
  required Map<dynamic, String> states,
  required Map<String, int> openTasks,
  required String Function(Map<String, dynamic> v) searchText,
}) {
  final q = search.trim().toLowerCase();
  bool matchesFilters(Map<String, dynamic> v) {
    if (filters.isEmpty) return true;
    final id = '${v['id']}';
    final st = states[v['id']] ?? states[id] ?? 'ok';
    if (filters.contains(FleetFilter.due) && st == 'due') return true;
    if (filters.contains(FleetFilter.overdue) && st == 'overdue') return true;
    if (filters.contains(FleetFilter.repairs) && (openTasks[id] ?? 0) > 0) return true;
    return false;
  }

  return [
    for (final v in vehicles)
      if ((q.isEmpty || searchText(v).toLowerCase().contains(q)) && matchesFilters(v)) v,
  ];
}

/// "Service due, Overdue" / "Search: "hilux"" — what is narrowing the list, for the line under the title and
/// for the printout. Empty when nothing is.
String describeFleetFilter(Set<FleetFilter> filters, String search) {
  final parts = <String>[
    if (filters.isNotEmpty) [for (final f in FleetFilter.values) if (filters.contains(f)) fleetFilterLabel(f)].join(', '),
    if (search.trim().isNotEmpty) 'Search: "${search.trim()}"',
  ];
  return parts.join(' · ');
}

/// A counter at the top of the Fleet page that can be pressed to filter the list.
class FleetCountChip extends StatelessWidget {
  const FleetCountChip({super.key, required this.value, required this.label, required this.color, this.selected = false, this.onTap});

  final String value;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '$value $label',
      onTap: onTap, // a screen reader can press it too
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withOpacity(selected ? 0.2 : 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: selected ? color : color.withOpacity(0.25), width: selected ? 1.6 : 1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (selected) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.check, size: 14, color: color)),
                Text.rich(TextSpan(style: TextStyle(fontSize: 12, color: color), children: [
                  TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  TextSpan(text: '  $label'),
                ])),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
