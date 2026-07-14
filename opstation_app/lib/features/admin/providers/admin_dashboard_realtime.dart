import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/providers/auth_controller.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import 'admin_dashboard_stats.dart';

/// Keeps the admin dashboard's figures live.
///
/// The problem: `adminDashboardStatsProvider` is a FutureProvider reading local
/// Drift rows. It computes once and caches, and nothing invalidates it — so an
/// admin who opened the app at 9am was still looking at 9am's numbers at 6pm.
/// Logging out and back in was the only way to see the day's real collections.
///
/// Why not poll: the admin is watching OTHER people's visits, on other devices.
/// This phone has no local event to react to. A 60s timer would work but spends
/// a query a minute per admin, all day, mostly to learn nothing changed.
///
/// So: a Supabase Realtime subscription. The server pushes when a visit or trip
/// row changes; we pull the delta into Drift and invalidate the stats. One
/// websocket, zero queries until something actually happens — cheaper than
/// polling AND instant.
final adminDashboardRealtimeProvider = Provider<void>((ref) {
  final orgId = ref.watch(orgIdProvider);
  if (orgId == null || orgId.isEmpty) return;

  final client = Supabase.instance.client;
  Timer? debounce;

  // A rep marking a visit writes several rows at once (visit + trip update).
  // Without a debounce that is three pulls in a second, each dragging the whole
  // org's data down. Coalesce them.
  void scheduleRefresh() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 900), () async {
      try {
        await ref.read(supabasePullServiceProvider).pullOrgData(orgId);
      } catch (_) {
        // Offline or a transient failure: the next event (or a manual
        // pull-to-refresh) will catch up. Never surface this to the admin.
      }
      ref.invalidate(adminDashboardStatsProvider);
    });
  }

  final channel = client.channel('admin_dash_$orgId')
    // `visits` carries no org_id column, so it cannot be filtered server-side.
    // We subscribe to all of them and let pullOrgData fetch only this org's rows.
    // The 900ms debounce means a burst of visits costs one pull, not one each —
    // and an event from another org costs a single wasted pull, no more.
    ..onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'visits',
      callback: (_) => scheduleRefresh(),
    )
    ..onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'trips',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'org_id',
        value: orgId,
      ),
      callback: (_) => scheduleRefresh(),
    )
    ..subscribe();

  ref.onDispose(() {
    debounce?.cancel();
    client.removeChannel(channel);
  });
});
