import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/providers/auth_controller.dart';

/// Whether New Product Launch (NPL) is switched on for this org (Admin Settings).
final nplEnabledProvider = FutureProvider<bool>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  final orgId = user?.organizationId;
  if (orgId == null) return false;
  try {
    final res = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('org_id', orgId)
        .eq('key', 'org.npl_enabled')
        .maybeSingle();
    return (res?['value'] as String?) == 'true';
  } catch (_) {
    return false;
  }
});

/// Active launches that have at least one outlet on MY routes, with my progress.
/// Empty when NPL is off, offline, or SQL 465 has not been run.
final nplMyLaunchesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  if (!(await ref.watch(nplEnabledProvider.future))) return const [];
  try {
    final r = await Supabase.instance.client.rpc('npl_my_launches');
    return [for (final e in (r as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
  } catch (_) {
    return const [];
  }
});

/// customer id -> the launches aimed at that outlet (for the route stop cards).
final nplOutletIndexProvider =
    FutureProvider.autoDispose<Map<String, List<Map<String, dynamic>>>>((ref) async {
  final launches = await ref.watch(nplMyLaunchesProvider.future);
  final out = <String, List<Map<String, dynamic>>>{};
  for (final l in launches) {
    try {
      final r = await Supabase.instance.client
          .rpc('npl_my_launch_detail', params: {'p_launch': l['id']});
      final m = Map<String, dynamic>.from(r as Map);
      final launch = Map<String, dynamic>.from(m['launch'] as Map);
      for (final rt in (m['routes'] as List? ?? const [])) {
        for (final o in ((rt as Map)['outlets'] as List? ?? const [])) {
          final om = Map<String, dynamic>.from(o as Map);
          final list = out.putIfAbsent('${om['customer_id']}', () => []);
          if (list.any((e) => e['launch_id'] == launch['id'])) continue;
          list.add({
            'launch_id': launch['id'],
            'name': launch['name'],
            'product_id': launch['product_id'],
            'product_name': launch['product_name'],
            'schemes': launch['schemes'],
            'orders': om['orders'],
            'qty': om['qty'],
            'outcome': om['outcome'],
            'reason': om['reason'],
          });
        }
      }
    } catch (_) {/* skip this launch */}
  }
  return out;
});
