import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/initial_avatar.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/customer.dart';
import '../../salesperson/models/trip.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';

/// Admin drill-down: shows today's active + completed trips for a single
/// salesperson, with customer-by-customer visit timeline.
class SalespersonMonitoringScreen extends ConsumerWidget {
  final String userId;
  const SalespersonMonitoringScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_salespersonDayProvider(userId));
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Salesperson today',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_salespersonDayProvider(userId)),
          ),
        ],
      ),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) {
          if (d.user == null) {
            return const Center(child: Text('User not found.'));
          }
          return _Body(data: d);
        },
      ),
    );
  }
}

class _DayData {
  final TeamUser? user;
  final Trip? active;
  final List<Trip> completedToday;
  _DayData({
    required this.user,
    required this.active,
    required this.completedToday,
  });
}

final _salespersonDayProvider =
    FutureProvider.autoDispose.family<_DayData, String>((ref, userId) async {
  final teamRepo = ref.watch(teamRepositoryProvider);
  final salesRepo = ref.watch(salespersonRepositoryProvider);
  final user = await teamRepo.byId(userId);
  final active = await salesRepo.activeTripForUser(userId);
  final completed =
      await salesRepo.tripsClosedOnLocalDateForUser(DateTime.now(), userId);
  return _DayData(
    user: user,
    active: active,
    completedToday: completed,
  );
});

class _Body extends StatelessWidget {
  final _DayData data;
  const _Body({required this.data});

  @override
  Widget build(BuildContext context) {
    final u = data.user!;
    final trips = [
      if (data.active != null) data.active!,
      ...data.completedToday,
    ];

    int totalVisits = 0;
    int totalCollected = 0;
    for (final t in trips) {
      totalVisits += t.verifiedCount;
      totalCollected += t.totalCollected;
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _HeaderCard(user: u, isOnRoute: data.active != null),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Verified visits',
                value: '$totalVisits',
                color: AppColors.success,
                icon: Icons.check_circle_outline,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatTile(
                label: 'Total collected',
                value: 'Rs $totalCollected',
                color: AppColors.primary,
                icon: Icons.payments_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (trips.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: const Center(
              child: Text(
                'No trips today.',
                style: TextStyle(color: AppColors.textSecondaryLight),
              ),
            ),
          )
        else
          for (final t in trips) _TripCard(trip: t),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final TeamUser user;
  final bool isOnRoute;
  const _HeaderCard({required this.user, required this.isOnRoute});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              InitialAvatar(initials: user.initials),
              if (isOnRoute)
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: AppColors.success,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  user.email,
                  style: const TextStyle(
                    color: AppColors.textSecondaryLight,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                StatusBadge(
                  label: isOnRoute ? 'On route' : 'Idle',
                  tone: isOnRoute
                      ? StatusBadgeTone.success
                      : StatusBadgeTone.neutral,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  final Trip trip;
  const _TripCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    final isActive = trip.isOpen;
    final started = DateFormat('HH:mm').format(trip.startedAt);
    final ended =
        trip.endedAt != null ? DateFormat('HH:mm').format(trip.endedAt!) : '—';

    // Determine per-customer status in order.
    final byCustomerStatus = trip.statusByCustomer;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive
              ? AppColors.success.withOpacity(0.4)
              : AppColors.borderLight,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  trip.routeName,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              StatusBadge(
                label: isActive
                    ? 'In progress'
                    : (trip.closeReason == TripCloseReason.cutoff
                        ? 'Cut-off'
                        : 'Completed'),
                tone: isActive
                    ? StatusBadgeTone.info
                    : (trip.closeReason == TripCloseReason.cutoff
                        ? StatusBadgeTone.warning
                        : StatusBadgeTone.success),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Started $started · ${isActive ? "Still out" : "Ended $ended"} · '
            '${trip.verifiedCount}/${trip.totalStops} verified · Rs ${trip.totalCollected}',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondaryLight,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),
          // Visit timeline: one row per customer on the route, in order.
          for (final customer in trip.stopSnapshot)
            _TimelineRow(
              customer: customer,
              status: byCustomerStatus[customer.id] ?? VisitStatus.pending,
              visits: trip.visits
                  .where((v) => v.customerId == customer.id)
                  .toList(),
            ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final Customer customer;
  final VisitStatus status;
  final List<Visit> visits;

  const _TimelineRow({
    required this.customer,
    required this.status,
    required this.visits,
  });

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;
    switch (status) {
      case VisitStatus.verified:
        icon = Icons.check_circle;
        color = AppColors.success;
        break;
      case VisitStatus.outside:
        icon = Icons.warning_amber_rounded;
        color = AppColors.warningDark;
        break;
      case VisitStatus.skipped:
        icon = Icons.skip_next;
        color = AppColors.textSecondaryLight;
        break;
      case VisitStatus.noLocation:
        icon = Icons.location_off_outlined;
        color = AppColors.danger;
        break;
      case VisitStatus.pending:
        icon = Icons.radio_button_unchecked;
        color = AppColors.textTertiaryLight;
        break;
    }

    // Pick the most recent visit to display details.
    Visit? last;
    for (final v in visits) {
      if (last == null || v.timestamp.isAfter(last.timestamp)) last = v;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  customer.shopName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitleFor(status, last),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
                if (last != null && status != VisitStatus.pending)
                  _coordsRow(last),
              ],
            ),
          ),
          if (last != null && last.amount > 0)
            Text(
              'Rs ${last.amount}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }


  Widget _coordsRow(Visit? v) {
    if (v == null) return const SizedBox.shrink();
    final lat = v.capturedLat;
    final lng = v.capturedLng;
    if (lat == null || lng == null) return const SizedBox.shrink();
    final formatted = '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: formatted));
      },
      onLongPress: () async {
        final uri = Uri.parse(
          'https://www.google.com/maps/search/?api=1&query=${lat},${lng}',
        );
        try { await launchUrl(uri, mode: LaunchMode.externalApplication); } catch (_) {}
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on_outlined, size: 10, color: AppColors.textSecondaryLight),
          const SizedBox(width: 3),
          Text(
            formatted,
            style: const TextStyle(fontSize: 10, color: AppColors.textSecondaryLight),
          ),
          const SizedBox(width: 3),
          const Icon(Icons.copy, size: 9, color: AppColors.textTertiaryLight),
        ],
      ),
    );
  }

  String _subtitleFor(VisitStatus s, Visit? last) {
    switch (s) {
      case VisitStatus.pending:
        return 'Not yet visited';
      case VisitStatus.skipped:
        if (last?.skipReason != null && last!.skipReason!.isNotEmpty) {
          return 'Skipped · ${last.skipReason}';
        }
        return 'Skipped';
      case VisitStatus.verified:
        if (last == null) return 'Verified';
        return 'Verified at ${DateFormat('HH:mm').format(last.timestamp)}';
      case VisitStatus.outside:
        if (last == null) return 'Outside geofence';
        final d = last.distanceMeters?.round();
        return d != null
            ? 'Outside geofence · ${d}m away · ${DateFormat('HH:mm').format(last.timestamp)}'
            : 'Outside geofence · ${DateFormat('HH:mm').format(last.timestamp)}';
      case VisitStatus.noLocation:
        if (last == null) return 'No location';
        return 'No location · ${DateFormat('HH:mm').format(last.timestamp)}';
    }
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }
}
