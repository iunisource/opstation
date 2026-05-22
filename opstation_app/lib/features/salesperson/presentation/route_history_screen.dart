import 'dart:io';
import '../../../core/storage/photo_url.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../auth/providers/auth_controller.dart';
import '../data/salesperson_repository.dart';
import '../models/customer.dart';
import '../models/trip.dart';

/// Salesperson-facing route history: list of their completed (and active)
/// trips, each expandable to show the visit sequence inline. No PDFs.
class RouteHistoryScreen extends ConsumerStatefulWidget {
  const RouteHistoryScreen({super.key});

  @override
  ConsumerState<RouteHistoryScreen> createState() =>
      _RouteHistoryScreenState();
}

enum _Period { week, month, all }

class _RouteHistoryScreenState extends ConsumerState<RouteHistoryScreen> {
  _Period _period = _Period.week;
  bool _refreshing = false;

  Future<void> _refreshFromServer() async {
    if (_refreshing) return;
    final user = ref.read(authControllerProvider).valueOrNull;
    final orgId = user?.organizationId;
    if (orgId == null) return;

    setState(() => _refreshing = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Refreshing…'),
        duration: Duration(seconds: 1),
      ),
    );
    try {
      await ref.read(supabasePullServiceProvider).pullOrgData(orgId);
      if (mounted) setState(() {}); // rebuild FutureBuilder so trips reload
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Refresh failed')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Route history',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Sync from server',
            onPressed: _refreshing ? null : _refreshFromServer,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                _PeriodChip(
                  label: 'Last 7 days',
                  selected: _period == _Period.week,
                  onTap: () => setState(() => _period = _Period.week),
                ),
                _PeriodChip(
                  label: 'This month',
                  selected: _period == _Period.month,
                  onTap: () => setState(() => _period = _Period.month),
                ),
                _PeriodChip(
                  label: 'All',
                  selected: _period == _Period.all,
                  onTap: () => setState(() => _period = _Period.all),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshFromServer,
              child: _TripList(period: _period),
            ),
          ),
        ],
      ),
    );
  }
}

class _TripList extends ConsumerWidget {
  final _Period period;
  const _TripList({required this.period});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (user == null) return const SizedBox.shrink();
    final repo = ref.watch(salespersonRepositoryProvider);

    final now = DateTime.now();
    late DateTime start;
    switch (period) {
      case _Period.week:
        start = DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 6));
        break;
      case _Period.month:
        start = DateTime(now.year, now.month, 1);
        break;
      case _Period.all:
        start = DateTime(now.year - 5, 1, 1);
        break;
    }

    return FutureBuilder<List<Trip>>(
      future: repo.tripsInRangeForUser(start, now, user.id),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final trips = (snap.data ?? const <Trip>[]).toList();
        trips.sort((a, b) {
          final ae = a.endedAt ?? a.startedAt;
          final be = b.endedAt ?? b.startedAt;
          return be.compareTo(ae);
        });
        if (trips.isEmpty) {
          // Use ListView (not Center) so RefreshIndicator pull-to-refresh
          // still works even when the list is empty.
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [
              SizedBox(height: 120),
              Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No trips in this period.'),
                ),
              ),
            ],
          );
        }
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: trips.length,
          itemBuilder: (_, i) => _TripExpansionTile(trip: trips[i]),
        );
      },
    );
  }
}

class _TripExpansionTile extends StatelessWidget {
  final Trip trip;
  const _TripExpansionTile({required this.trip});

  @override
  Widget build(BuildContext context) {
    final started = DateFormat('d MMM · HH:mm').format(trip.startedAt);
    final ended = trip.endedAt == null
        ? 'Open'
        : DateFormat('HH:mm').format(trip.endedAt!);
    final score = trip.coveragePercent.round();
    final byCustomer = trip.statusByCustomer;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Theme(
        // Remove the default divider line between header and children.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          childrenPadding:
              const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Text(
            trip.routeName,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '$started → $ended · $score% · Rs ${trip.totalCollected}',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondaryLight,
              ),
            ),
          ),
          trailing: StatusBadge(
            label: trip.isOpen
                ? 'In progress'
                : (trip.closeReason == TripCloseReason.cutoff
                    ? 'Cut-off'
                    : 'Completed'),
            tone: trip.isOpen
                ? StatusBadgeTone.info
                : (trip.closeReason == TripCloseReason.cutoff
                    ? StatusBadgeTone.warning
                    : StatusBadgeTone.success),
          ),
          children: [
  _SummaryRow(trip: trip),
  const SizedBox(height: 8),
  if (trip.stopSnapshot.isEmpty)
    const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        '(Stop details unavailable for this trip)',
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: AppColors.textTertiaryLight,
        ),
      ),
    )
  else
    for (int i = 0; i < trip.stopSnapshot.length; i++)
      _VisitRow(
        index: i + 1,
        customer: trip.stopSnapshot[i],
        status: byCustomer[trip.stopSnapshot[i].id] ??
            VisitStatus.pending,
        visits: trip.visits
            .where((v) => v.customerId == trip.stopSnapshot[i].id)
            .toList(),
      ),
],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final Trip trip;
  const _SummaryRow({required this.trip});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.borderLight.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          _mini('Verified', '${trip.verifiedCount}', AppColors.success),
          const SizedBox(width: 12),
          _mini('Outside', '${trip.outsideCount}', AppColors.warningDark),
          const SizedBox(width: 12),
          _mini('Skipped', '${trip.skippedCount}',
              AppColors.textSecondaryLight),
          const SizedBox(width: 12),
          _mini('Pending', '${trip.pendingCount}',
              AppColors.textTertiaryLight),
        ],
      ),
    );
  }

  Widget _mini(String label, String value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }
}

class _VisitRow extends StatelessWidget {
  final int index;
  final Customer customer;
  final VisitStatus status;
  final List<Visit> visits;

  const _VisitRow({
    required this.index,
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

    Visit? latest;
    for (final v in visits) {
      if (latest == null || v.timestamp.isAfter(latest.timestamp)) latest = v;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '$index',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.textTertiaryLight,
              ),
            ),
          ),
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
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
                Text(
                  _subtitle(status, latest),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (latest != null && status != VisitStatus.pending)
                  _coordsRow(latest),
                if (latest != null && latest.photoPaths.isNotEmpty)
                  _photosRow(latest.photoPaths),
              ],
            ),
          ),
          if ((latest?.amount ?? 0) > 0)
            Text(
              'Rs ${latest!.amount}',
              style: const TextStyle(
                fontSize: 12,
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

  Widget _photosRow(List<String> paths) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        height: 48,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: paths.length,
          separatorBuilder: (_, __) => const SizedBox(width: 4),
          itemBuilder: (context, i) {
            final path = paths[i];
            final isRemote = PhotoUrl.isRemote(path);
            return GestureDetector(
              onTap: () => _showPhoto(context, path),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: isRemote
                    ? Image.network(PhotoUrl.build(path), width: 48, height: 48, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image))
                    : Image.file(File(path), width: 48, height: 48, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image)),
              ),
            );
          },
        ),
      ),
    );
  }

  void _showPhoto(BuildContext context, String path) {
    final isRemote = PhotoUrl.isRemote(path);
    showDialog(
      context: context,
      builder: (_) => Dialog(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: isRemote
              ? Image.network(PhotoUrl.build(path), fit: BoxFit.contain)
              : Image.file(File(path), fit: BoxFit.contain),
        ),
      ),
    );
  }

  String _subtitle(VisitStatus s, Visit? v) {
    switch (s) {
      case VisitStatus.pending:
        return 'Not visited';
      case VisitStatus.skipped:
        if ((v?.skipReason ?? '').isNotEmpty) {
          return 'Skipped · ${v!.skipReason}';
        }
        return 'Skipped';
      case VisitStatus.verified:
        if (v == null) return 'Verified';
        return 'Verified at ${DateFormat('HH:mm').format(v.timestamp)}';
      case VisitStatus.outside:
        if (v == null) return 'Outside geofence';
        final d = v.distanceMeters?.round();
        return d != null
            ? 'Outside · ${d}m away · ${DateFormat('HH:mm').format(v.timestamp)}'
            : 'Outside · ${DateFormat('HH:mm').format(v.timestamp)}';
      case VisitStatus.noLocation:
        if (v == null) return 'No location';
        return 'No location · ${DateFormat('HH:mm').format(v.timestamp)}';
    }
  }
}

class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.borderLight,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected
                  ? Colors.white
                  : Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
        ),
      ),
    );
  }
}