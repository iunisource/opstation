import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../dispatch/models/delivery.dart';
import '../../dispatch/data/delivery_repository.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/providers/auth_controller.dart';

/// Live delivery summary per driver.
class LiveDeliverySummary {
  final String driverId;
  final String driverName;
  final Delivery delivery;

  const LiveDeliverySummary({
    required this.driverId,
    required this.driverName,
    required this.delivery,
  });

  int get totalStops => delivery.stops.length;
  int get deliveredCount => delivery.deliveredCount;
  int get failedCount => delivery.failedCount;
  int get pendingCount => delivery.stops.where((s) => s.status == DeliveryStopStatus.pending).length;
  int get cashCollected => delivery.cashCollected;
  DeliveryStatus get status => delivery.status;
}

/// Watches Supabase Realtime for delivery changes and updates local state.
class DeliveryMonitoringNotifier extends AsyncNotifier<List<LiveDeliverySummary>> {
  RealtimeChannel? _channel;

  @override
  Future<List<LiveDeliverySummary>> build() async {
    await _subscribeRealtime();
    ref.onDispose(() => _channel?.unsubscribe());
    return _fetchLive();
  }

  Future<List<LiveDeliverySummary>> _fetchLive() async {
    final repo = ref.read(deliveryRepositoryProvider);
    final deliveries = await repo.list(
      statuses: {DeliveryStatus.assigned, DeliveryStatus.inProgress},
    );
    return deliveries
        .where((d) => d.driverId != null)
        .map((d) => LiveDeliverySummary(
              driverId: d.driverId!,
              driverName: d.driverName ?? 'Driver',
              delivery: d,
            ))
        .toList();
  }

  Future<void> _subscribeRealtime() async {
    final orgId = ref.read(orgIdProvider);
    _channel = Supabase.instance.client
        .channel('delivery_monitoring')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'deliveries',
          callback: (_) async {
            // Re-fetch on any change
            state = AsyncData(await _fetchLive());
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'delivery_stops',
          callback: (_) async {
            state = AsyncData(await _fetchLive());
          },
        )
        .subscribe();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _fetchLive());
  }
}

final deliveryMonitoringProvider =
    AsyncNotifierProvider<DeliveryMonitoringNotifier, List<LiveDeliverySummary>>(
        DeliveryMonitoringNotifier.new);
