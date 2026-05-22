import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audit/data/audit_repository.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/sales_route.dart';

/// Filter state for the admin routes list.
class RouteListFilters {
  final String query;
  final bool includeInactive;
  final RouteKind? kindFilter;

  const RouteListFilters({
    this.query = '',
    this.includeInactive = false,
    this.kindFilter,
  });

  RouteListFilters copyWith({
    String? query,
    bool? includeInactive,
    RouteKind? kindFilter,
    bool clearKind = false,
  }) {
    return RouteListFilters(
      query: query ?? this.query,
      includeInactive: includeInactive ?? this.includeInactive,
      kindFilter: clearKind ? null : (kindFilter ?? this.kindFilter),
    );
  }
}

class RouteListState {
  final List<SalesRoute> all;
  final RouteListFilters filters;

  const RouteListState({
    this.all = const [],
    this.filters = const RouteListFilters(),
  });

  RouteListState copyWith({
    List<SalesRoute>? all,
    RouteListFilters? filters,
  }) {
    return RouteListState(
      all: all ?? this.all,
      filters: filters ?? this.filters,
    );
  }

  List<SalesRoute> get filtered {
    final q = filters.query.trim().toLowerCase();
    return all.where((r) {
      if (!filters.includeInactive && !r.isActive) return false;
      if (filters.kindFilter != null && r.kind != filters.kindFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      return r.name.toLowerCase().contains(q);
    }).toList();
  }
}

class RoutesController extends AsyncNotifier<RouteListState> {
  SalespersonRepository get _repo => ref.read(salespersonRepositoryProvider);

  @override
  Future<RouteListState> build() async {
    final all = await _repo.allRoutesIncludingInactive();
    return RouteListState(all: all);
  }

  Future<void> refresh() async {
    final all = await _repo.allRoutesIncludingInactive();
    final current = state.valueOrNull;
    state = AsyncData((current ?? const RouteListState()).copyWith(all: all));
  }

  void updateFilters(RouteListFilters filters) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(filters: filters));
  }

  Future<SalesRoute> create({
    required String name,
    required RouteKind kind,
    required List<String> customerIds,
  }) async {
    final created = await _repo.createRoute(
      name: name,
      kind: kind,
      customerIds: customerIds,
    );
    await ref.read(auditLoggerProvider).routeCreated(created);
    await refresh();
    return created;
  }

  Future<SalesRoute> updateRoute({
    required String id,
    required String name,
    required RouteKind kind,
    required List<String> customerIds,
  }) async {
    final before = await _repo.routeById(id);
    final updated = await _repo.updateRoute(
      id: id,
      name: name,
      kind: kind,
      customerIds: customerIds,
    );
    if (before != null) {
      await ref.read(auditLoggerProvider).routeUpdated(before, updated);
    }
    await refresh();
    return updated;
  }

  Future<void> setActive(String id, bool active) async {
    final before = await _repo.routeById(id);
    await _repo.setRouteActive(id: id, active: active);
    final after = await _repo.routeById(id);
    if (before != null && after != null) {
      // setActive conceptually deletes/restores; log as delete/create-ish
      // update for clarity.
      await ref.read(auditLoggerProvider).routeUpdated(before, after);
    }
    await refresh();
  }
}

final routesControllerProvider =
    AsyncNotifierProvider<RoutesController, RouteListState>(
        RoutesController.new);
