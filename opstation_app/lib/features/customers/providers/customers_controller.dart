import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/models/customer.dart';
import '../data/customer_repository.dart';
import '../../../core/sync/sync_controller.dart';

enum CustomerActiveFilter { all, active, inactive }

enum CustomerLocationFilter { all, hasLocation, noLocation }

class CustomerFilters {
  final String query;
  final CustomerActiveFilter activeFilter;
  final CustomerLocationFilter locationFilter;
  final String? category;
  final String? group;

  const CustomerFilters({
    this.query = '',
    this.activeFilter = CustomerActiveFilter.active,
    this.locationFilter = CustomerLocationFilter.all,
    this.category,
    this.group,
  });

  CustomerFilters copyWith({
    String? query,
    CustomerActiveFilter? activeFilter,
    CustomerLocationFilter? locationFilter,
    String? category,
    bool clearCategory = false,
    String? group,
    bool clearGroup = false,
  }) {
    return CustomerFilters(
      query: query ?? this.query,
      activeFilter: activeFilter ?? this.activeFilter,
      locationFilter: locationFilter ?? this.locationFilter,
      category: clearCategory ? null : (category ?? this.category),
      group: clearGroup ? null : (group ?? this.group),
    );
  }

  bool get isDefault =>
      query.isEmpty &&
      activeFilter == CustomerActiveFilter.active &&
      locationFilter == CustomerLocationFilter.all &&
      category == null &&
      group == null;
}

class CustomersState {
  final List<Customer> all;
  final CustomerFilters filters;

  const CustomersState({
    this.all = const [],
    this.filters = const CustomerFilters(),
  });

  CustomersState copyWith({
    List<Customer>? all,
    CustomerFilters? filters,
  }) {
    return CustomersState(
      all: all ?? this.all,
      filters: filters ?? this.filters,
    );
  }

  List<Customer> get filtered {
    final q = filters.query.trim().toLowerCase();
    return all.where((c) {
      // Active filter
      switch (filters.activeFilter) {
        case CustomerActiveFilter.active:
          if (!c.isActive) return false;
          break;
        case CustomerActiveFilter.inactive:
          if (c.isActive) return false;
          break;
        case CustomerActiveFilter.all:
          break;
      }
      // Location filter
      switch (filters.locationFilter) {
        case CustomerLocationFilter.hasLocation:
          if (!c.hasLocation) return false;
          break;
        case CustomerLocationFilter.noLocation:
          if (c.hasLocation) return false;
          break;
        case CustomerLocationFilter.all:
          break;
      }
      if (filters.category != null && c.category != filters.category) {
        return false;
      }
      if (filters.group != null && c.group != filters.group) return false;
      // Search
      if (q.isEmpty) return true;
      return c.shopName.toLowerCase().contains(q) ||
          c.phone.toLowerCase().contains(q) ||
          c.code.toLowerCase().contains(q) ||
          c.address.toLowerCase().contains(q) ||
          c.contactPerson.toLowerCase().contains(q);
    }).toList();
  }

  /// All categories in the data (non-null, deduped, sorted).
  List<String> get allCategories {
    final set = <String>{};
    for (final c in all) {
      if (c.category != null && c.category!.isNotEmpty) set.add(c.category!);
    }
    return set.toList()..sort();
  }

  /// All groups in the data.
  List<String> get allGroups {
    final set = <String>{};
    for (final c in all) {
      if (c.group != null && c.group!.isNotEmpty) set.add(c.group!);
    }
    return set.toList()..sort();
  }
}

class CustomersController extends AsyncNotifier<CustomersState> {
  CustomerRepository get _repo => ref.read(customerRepositoryProvider);

  @override
  Future<CustomersState> build() async {
    final all = await _repo.all();
    return CustomersState(all: all);
  }

  Future<void> refresh() async {
    final all = await _repo.all();
    final current = state.valueOrNull;
    state = AsyncData((current ?? const CustomersState()).copyWith(all: all));
  }

  void updateFilters(CustomerFilters filters) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(filters: filters));
  }

  AuditActor _currentActor() {
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) {
      return const AuditActor(id: 'unknown', name: 'Unknown', role: 'unknown');
    }
    return AuditActor(
      id: user.id,
      name: user.name,
      role: user.role.label,
    );
  }

  /// Push customer edits up right away when online (and let flushPending drain
  /// them on reconnect when offline) — instead of waiting for the manual sync.
  void _kickSync() {
    ref.read(syncControllerProvider.notifier).noteCustomerChanged();
  }

  Future<Customer> create(Customer c) async {
    final result = await _repo.create(c, _currentActor());
    await refresh();
    _kickSync();
    return result;
  }

  Future<Customer> updateCustomer(Customer updated, Customer previous) async {
    final result = await _repo.update(updated, previous, _currentActor());
    await refresh();
    _kickSync();
    return result;
  }

  Future<void> setActive(String id, bool active) async {
    await _repo.setActive(id: id, active: active, actor: _currentActor());
    await refresh();
    _kickSync();
  }

  Future<Customer> setLocation(
      String id, double lat, double lng) async {
    final result = await _repo.setLocation(
      id: id,
      latitude: lat,
      longitude: lng,
      actor: _currentActor(),
    );
    await refresh();
    _kickSync();
    return result;
  }
}

final customersControllerProvider =
    AsyncNotifierProvider<CustomersController, CustomersState>(
        CustomersController.new);

/// Can the current user edit customers?
/// Admin / Master Admin / Surveyor can edit.
/// Salesperson / Driver / Dispatch are read-only.
bool canEditCustomers(UserRole? role) {
  if (role == null) return false;
  return role == UserRole.admin ||
      role == UserRole.masterAdmin ||
      role == UserRole.superAdmin ||
      role == UserRole.surveyor;
}

/// Can the current user create/delete customers?
/// Surveyor can add + edit but not delete/deactivate.
bool canManageCustomers(UserRole? role) {
  if (role == null) return false;
  return role == UserRole.admin ||
      role == UserRole.masterAdmin ||
      role == UserRole.superAdmin;
}
