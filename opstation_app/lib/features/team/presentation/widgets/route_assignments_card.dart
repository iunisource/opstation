import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../audit/data/audit_repository.dart';
import '../../../../core/services/notification_service.dart';
import '../../../auth/models/user_role.dart';
import '../../../auth/providers/auth_controller.dart';
import '../../../salesperson/data/salesperson_repository.dart';
import '../../../salesperson/models/sales_route.dart';
import '../../models/team_user.dart';

/// Card showing a salesperson's currently-assigned routes, with an edit
/// button that opens a checklist modal. Rendered on [UserDetailScreen]
/// only when the target is a Salesperson.
class RouteAssignmentsCard extends ConsumerWidget {
  final TeamUser user;
  final bool canManage;

  const RouteAssignmentsCard({
    super.key,
    required this.user,
    required this.canManage,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (user.role != UserRole.salesperson) {
      return const SizedBox.shrink();
    }

    final repo = ref.watch(salespersonRepositoryProvider);
    return FutureBuilder<List<SalesRoute>>(
      future: repo.routesAssignedTo(user.id),
      builder: (context, snap) {
        final assigned = snap.data ?? const <SalesRoute>[];
        final loading = snap.connectionState == ConnectionState.waiting;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'ROUTE ASSIGNMENTS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: AppColors.textSecondaryLight,
                      ),
                    ),
                  ),
                  if (!loading)
                    Text(
                      '${assigned.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondaryLight,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (assigned.isEmpty)
                const Text(
                  'No routes assigned. This salesperson will see an empty home screen until an admin assigns routes.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondaryLight,
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in assigned) _RouteRow(route: r),
                  ],
                ),
              if (canManage) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _openEditor(context, ref, assigned),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Manage assignments'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    List<SalesRoute> currentlyAssigned,
  ) async {
    final repo = ref.read(salespersonRepositoryProvider);
    final allActive = await repo.allRoutes();
    if (!context.mounted) return;

    final initial = currentlyAssigned.map((r) => r.id).toSet();

    // A route assigned to another salesperson should NOT appear as an
    // option for this one. Filter: keep routes that are (a) currently
    // assigned to THIS user, or (b) assigned to nobody.
    final available = <SalesRoute>[];
    for (final r in allActive) {
      if (initial.contains(r.id)) {
        available.add(r);
        continue;
      }
      final assignees = await repo.usersAssignedTo(r.id);
      if (assignees.isEmpty) available.add(r);
    }

    if (!context.mounted) return;
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AssignmentEditor(
        user: user,
        allRoutes: available,
        initiallySelected: initial,
      ),
    );

    if (result != null && !const _SetEquality().equals(result, initial)) {
      final actor = ref.read(authControllerProvider).valueOrNull;
      await repo.setAssignmentsForUser(
        userId: user.id,
        routeIds: result,
        assignedBy: actor?.id ?? 'unknown',
      );
      // Log the assignment diff. `allActive` is the master list we built
      // earlier in this method; use it plus any currently-assigned routes
      // to resolve route names for the summary line.
      final routeNamesById = <String, String>{
        for (final r in allActive) r.id: r.name,
        for (final r in currentlyAssigned) r.id: r.name,
      };
      await ref.read(auditLoggerProvider).assignmentChanged(
            userId: user.id,
            userName: user.name,
            before: initial,
            after: result,
            routeNamesById: routeNamesById,
          );

      // FCM: notify the salesperson about newly added routes.
      // One push per save (combined message if multiple new routes).
      final newlyAdded = result.difference(initial);
      if (newlyAdded.isNotEmpty) {
        Future.microtask(() async {
          try {
            final notifService = ref.read(notificationServiceProvider);
            final names = newlyAdded
                .map((id) => routeNamesById[id] ?? 'a route')
                .toList();
            final body = names.length == 1
                ? '${names.first} has been assigned to you.'
                : '${names.length} new routes have been assigned: '
                  '${names.take(3).join(", ")}'
                  '${names.length > 3 ? "…" : ""}';
            await notifService.sendToUser(
              targetUserId: user.id,
              title: 'New Route Assigned',
              body: body,
            );
          } catch (_) {}
        });
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Assignments updated')),
        );
      }
      // Force this widget subtree to rebuild so the card reflects changes.
      ref.invalidate(salespersonRepositoryProvider);
    }
  }
}

class _RouteRow extends StatelessWidget {
  final SalesRoute route;
  const _RouteRow({required this.route});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: route.kind == RouteKind.recurring
                  ? AppColors.successLight
                  : AppColors.warningLight,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(
              route.kind == RouteKind.recurring
                  ? Icons.all_inclusive
                  : Icons.event_outlined,
              size: 18,
              color: route.kind == RouteKind.recurring
                  ? AppColors.successDark
                  : AppColors.warningDark,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  route.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${route.stops.length} stops · ${route.kind == RouteKind.recurring ? "Recurring" : "One-time"}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AssignmentEditor extends StatefulWidget {
  final TeamUser user;
  final List<SalesRoute> allRoutes;
  final Set<String> initiallySelected;

  const _AssignmentEditor({
    required this.user,
    required this.allRoutes,
    required this.initiallySelected,
  });

  @override
  State<_AssignmentEditor> createState() => _AssignmentEditorState();
}

class _AssignmentEditorState extends State<_AssignmentEditor> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set.of(widget.initiallySelected);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.75;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Assign routes to ${widget.user.name}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_selected.length} of ${widget.allRoutes.length} selected',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: widget.allRoutes.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No routes exist yet. Create routes first, then come back to assign.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final route in widget.allRoutes)
                            _RouteCheckbox(
                              route: route,
                              selected: _selected.contains(route.id),
                              onChanged: (v) {
                                setState(() {
                                  if (v) {
                                    _selected.add(route.id);
                                  } else {
                                    _selected.remove(route.id);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(_selected),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RouteCheckbox extends StatelessWidget {
  final SalesRoute route;
  final bool selected;
  final ValueChanged<bool> onChanged;

  const _RouteCheckbox({
    required this.route,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!selected),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primaryLight.withOpacity(0.5)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.borderLight,
          ),
        ),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: (v) => onChanged(v ?? false),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    route.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${route.stops.length} stops · ${route.kind == RouteKind.recurring ? "Recurring" : "One-time"}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondaryLight,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Used by the editor to avoid rewriting on no-op saves.
class _SetEquality {
  const _SetEquality();
  bool equals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
}
