import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin_settings/providers/org_settings_controller.dart';
import 'customer_repository.dart';

/// Category + Group source for the customer form dropdowns.
///
/// Primary source is [orgSettingsProvider] (admin-managed list). We also
/// merge in any values that happen to already exist on customers in the
/// DB, so that custom values entered via the "Other..." field don't
/// disappear from the dropdown before admin gets around to canonicalising
/// them.
final customerCategoriesProvider = FutureProvider<List<String>>((ref) async {
  final settings = await ref.watch(orgSettingsProvider.future);
  final repo = ref.watch(customerRepositoryProvider);
  final all = await repo.all(includeInactive: true);
  final set = <String>{...settings.categories};
  for (final c in all) {
    if (c.category != null && c.category!.isNotEmpty) set.add(c.category!);
  }
  final list = set.toList()..sort();
  return list;
});

final customerGroupsProvider = FutureProvider<List<String>>((ref) async {
  final settings = await ref.watch(orgSettingsProvider.future);
  final repo = ref.watch(customerRepositoryProvider);
  final all = await repo.all(includeInactive: true);
  final set = <String>{...settings.groups};
  for (final c in all) {
    if (c.group != null && c.group!.isNotEmpty) set.add(c.group!);
  }
  final list = set.toList()..sort();
  return list;
});
