import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/role_home_scaffold.dart';
import '../../../shared/widgets/temp_password_banner.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../auth/providers/auth_controller.dart';
import '../../dispatch/data/delivery_repository.dart';
import '../../dispatch/models/delivery.dart';

/// Driver's daily home: assigned & in-progress deliveries at top,
/// recent history at the bottom.
///
/// Business rule enforced in the repository: one delivery can be
/// in_progress at a time per driver. If one's active, other assigned
/// ones show as visually blocked until it's done.
/// Reactive driver-home data: watches the driver's deliveries in local Drift
/// and partitions them into assigned / in-progress / recent-completed. Emits a
/// fresh value whenever local deliveries change (e.g. after an FCM-triggered
/// pull writes a newly-assigned row) — so the home auto-loads new jobs without
/// a manual refresh.
final driverHomeStreamProvider =
    StreamProvider.autoDispose<_DriverHomeData>((ref) {
  final user = ref.watch(authControllerProvider).valueOrNull;
  if (user == null) {
    return Stream.value(const _DriverHomeData(
        assigned: [], inProgress: null, recentCompleted: []));
  }
  final repo = ref.watch(deliveryRepositoryProvider);
  final now = DateTime.now();
  final fromDate =
      DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
  return repo.watchList(driverId: user.id).map((all) {
    final assigned =
        all.where((d) => d.status == DeliveryStatus.assigned).toList();
    Delivery? active;
    for (final d in all) {
      if (d.status == DeliveryStatus.inProgress) {
        active = d;
        break;
      }
    }
    final completed = all
        .where((d) =>
            (d.status == DeliveryStatus.completed ||
                d.status == DeliveryStatus.cancelled) &&
            d.createdAt.isAfter(fromDate))
        .toList();
    return _DriverHomeData(
      assigned: assigned,
      inProgress: active,
      recentCompleted: completed,
    );
  });
});

class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen> {
  @override
  void initState() {
    super.initState();
    // Proactively ask for GPS permission on first login as a driver,
    // so the mid-delivery permission prompt (on first Mark delivered /
    // Mark failed tap) doesn't interrupt the driver's workflow.
    //
    // Gated by a per-user config flag so we only ever ask once per
    // account. If the driver dismisses, we don't nag on subsequent
    // opens — they'll get the native OS prompt on first stop action
    // anyway. That's the fallback, not the happy path.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybePromptForGps();
    });
  }

  Future<void> _maybePromptForGps() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) return;
    final db = ref.read(appDatabaseProvider);
    final key = 'driver.gps_prompt_shown.${user.id}';
    final already = await db.getConfig(key);
    if (already == '1') return;

    // If the OS has already granted permission (e.g. from a previous
    // install that shared the grant), we can mark shown without
    // bothering the user.
    final current = await Geolocator.checkPermission();
    if (current == LocationPermission.always ||
        current == LocationPermission.whileInUse) {
      await db.setConfig(key, '1');
      return;
    }

    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Enable location'),
        content: const Text(
          'Opstation uses your location to verify deliveries at each '
          'stop. Allowing now means no interruptions mid-delivery.\n\n'
          'Your location is captured only when you mark a stop as '
          'delivered or failed \u2014 not continuously in the background.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Maybe later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );

    // Record that we prompted either way, to avoid re-asking next open.
    await db.setConfig(key, '1');

    if (proceed == true) {
      try {
        // Triggers the native OS permission prompt if not yet granted.
        await Geolocator.requestPermission();
      } catch (_) {
        // Swallow — driver can still work without GPS; stops just won't
        // have coords attached.
      }
    }
  }

  Future<_DriverHomeData> _load() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) {
      return const _DriverHomeData(
          assigned: [], inProgress: null, recentCompleted: []);
    }
    final repo = ref.read(deliveryRepositoryProvider);
    final assigned = await repo.list(
      statuses: {DeliveryStatus.assigned},
      driverId: user.id,
    );
    final active = await repo.activeForDriver(user.id);
    final now = DateTime.now();
    final fromDate = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    final completed = await repo.list(
      statuses: {DeliveryStatus.completed, DeliveryStatus.cancelled},
      driverId: user.id,
      from: fromDate,
    );
    return _DriverHomeData(
      assigned: assigned,
      inProgress: active,
      recentCompleted: completed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final firstName = user?.name.split(' ').first ?? 'Driver';
    final dateStr = DateFormat('EEEE, d MMMM y').format(DateTime.now());

    return RoleHomeScaffold(
      appBarTitle: 'Home',
      body: StreamBuilder<_DriverHomeData>(
        stream: ref.watch(driverHomeStreamProvider.stream),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data ??
              const _DriverHomeData(
                  assigned: [], inProgress: null, recentCompleted: []);
          return RefreshIndicator(
            // Pull-to-refresh now triggers an actual Supabase fetch so
            // newly-assigned deliveries (e.g. created from the web admin)
            // appear without forcing the driver to log out and back in.
            // Local DB rebuild after the pull picks up the new rows.
            onRefresh: () async {
              final orgId = ref
                  .read(authControllerProvider)
                  .valueOrNull
                  ?.organizationId;
              if (orgId != null && orgId.isNotEmpty) {
                try {
                  await ref
                      .read(supabasePullServiceProvider)
                      .pullOrgData(orgId);
                } catch (_) {
                  // Network error → fall through; UI still rebuilds
                  // off whatever's in local DB.
                }
              }
              if (mounted) setState(() {});
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                const SizedBox(height: 8),
                Text(
                  'Hi, $firstName',
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  dateStr,
                  style: TextStyle(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withOpacity(0.65),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 24),
                const TempPasswordBanner(),
                if (data.inProgress != null) ...[
                  const _SectionTitle(
                      'IN PROGRESS', AppColors.warningDark),
                  const SizedBox(height: 8),
                  _ActiveDeliveryCard(
                    delivery: data.inProgress!,
                    onTap: () => _openActive(data.inProgress!),
                  ),
                  const SizedBox(height: 20),
                ],
                _SectionTitle(
                  data.inProgress == null
                      ? 'ASSIGNED TO YOU'
                      : 'QUEUED (COMPLETE ACTIVE FIRST)',
                  AppColors.textSecondaryLight,
                ),
                const SizedBox(height: 8),
                if (data.assigned.isEmpty)
                  _EmptyCard(
                    icon: Icons.local_shipping_outlined,
                    title: data.inProgress == null
                        ? 'No assigned deliveries'
                        : 'Nothing queued',
                    subtitle: data.inProgress == null
                        ? 'Your dispatch manager will assign deliveries here.'
                        : 'Complete the active delivery; more will appear here as they\'re assigned.',
                  )
                else
                  for (final d in data.assigned)
                    _AssignedDeliveryCard(
                      delivery: d,
                      blocked: data.inProgress != null,
                      onTap: () =>
                          _openAssigned(d, blocked: data.inProgress != null),
                    ),
                if (data.recentCompleted.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const _SectionTitle('RECENT (LAST 7 DAYS)',
                          AppColors.textSecondaryLight),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () =>
                            context.push('/driver/reports'),
                        icon: const Icon(Icons.picture_as_pdf_outlined, size: 14),
                        label: const Text('Reports'),
                        style: TextButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 28),
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            context.push('/driver/history'),
                        icon: const Icon(Icons.history, size: 14),
                        label: const Text('History'),
                        style: TextButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 28),
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final d in data.recentCompleted)
                    _CompletedDeliveryCard(delivery: d),
                ] else ...[
                  // Even when the 7-day window is empty, the driver
                  // might have older history worth opening.
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/driver/history'),
                    icon: const Icon(Icons.history, size: 16),
                    label: const Text('View all past deliveries'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 42),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/driver/reports'),
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                    label: const Text('Delivery reports & PDF export'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 42),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openActive(Delivery d) async {
    final changed =
        await context.push<bool>('/driver/delivery/${d.id}');
    if (changed == true && mounted) setState(() {});
  }

  Future<void> _openAssigned(Delivery d, {required bool blocked}) async {
    if (blocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Complete the active delivery before starting another.'),
        ),
      );
      return;
    }
    final changed =
        await context.push<bool>('/driver/delivery/${d.id}');
    if (changed == true && mounted) setState(() {});
  }
}

class _DriverHomeData {
  final List<Delivery> assigned;
  final Delivery? inProgress;
  final List<Delivery> recentCompleted;

  const _DriverHomeData({
    required this.assigned,
    required this.inProgress,
    required this.recentCompleted,
  });
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final Color color;
  const _SectionTitle(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
        color: color,
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.warningLight,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(icon,
                  color: AppColors.warningDark, size: 28),
            ),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withOpacity(0.65),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveDeliveryCard extends StatelessWidget {
  final Delivery delivery;
  final VoidCallback onTap;
  const _ActiveDeliveryCard({required this.delivery, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final progress = delivery.stops.isEmpty
        ? 0.0
        : (delivery.deliveredCount + delivery.failedCount) /
            delivery.stops.length;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.warningDark, AppColors.warning],
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.local_shipping,
                    color: Colors.white, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'Tap to resume',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right, color: Colors.white),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _stat('${delivery.stops.length}', 'STOPS'),
                ),
                Expanded(
                  child: _stat(
                    '${delivery.deliveredCount}/${delivery.stops.length}',
                    'DONE',
                  ),
                ),
                Expanded(
                  child: _stat(
                      'Rs ${delivery.cashCollected}', 'COLLECTED'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.white.withOpacity(0.3),
                color: Colors.white,
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

class _AssignedDeliveryCard extends StatelessWidget {
  final Delivery delivery;
  final bool blocked;
  final VoidCallback onTap;
  const _AssignedDeliveryCard({
    required this.delivery,
    required this.blocked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Opacity(
        opacity: blocked ? 0.6 : 1.0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${delivery.stops.length}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${delivery.stops.length} ${delivery.stops.length == 1 ? "stop" : "stops"} · Rs ${delivery.cashAmount} to collect',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Assigned ${DateFormat('d MMM · HH:mm').format(delivery.createdAt)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  blocked ? Icons.lock_outline : Icons.chevron_right,
                  size: 20,
                  color: blocked
                      ? AppColors.textTertiaryLight
                      : AppColors.textSecondaryLight,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompletedDeliveryCard extends StatefulWidget {
  final Delivery delivery;
  const _CompletedDeliveryCard({required this.delivery});

  @override
  State<_CompletedDeliveryCard> createState() =>
      _CompletedDeliveryCardState();
}

class _CompletedDeliveryCardState extends State<_CompletedDeliveryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final delivery = widget.delivery;
    final when = delivery.completedAt ?? delivery.createdAt;
    final isCancelled = delivery.status == DeliveryStatus.cancelled;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    isCancelled
                        ? Icons.cancel_outlined
                        : Icons.check_circle_outline,
                    size: 20,
                    color: isCancelled
                        ? AppColors.danger
                        : AppColors.success,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isCancelled
                              ? 'Cancelled · ${delivery.stops.length} stops'
                              : '${delivery.deliveredCount}/${delivery.stops.length} delivered · Rs ${delivery.cashCollected} collected',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                        ),
                        Text(
                          DateFormat('d MMM · HH:mm').format(when),
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondaryLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                    color: AppColors.textSecondaryLight,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) _expandedDetails(delivery, isCancelled),
        ],
      ),
    );
  }

  Widget _expandedDetails(Delivery delivery, bool isCancelled) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 16),
          if (!isCancelled) ...[
            // Counts bar: small inline summary of outcomes.
            Row(
              children: [
                _miniStat(Icons.check, 'Delivered',
                    '${delivery.deliveredCount}', AppColors.success),
                const SizedBox(width: 12),
                _miniStat(Icons.close, 'Failed',
                    '${delivery.failedCount}', AppColors.danger),
                if (delivery.outsideGeofenceCount > 0) ...[
                  const SizedBox(width: 12),
                  _miniStat(Icons.location_searching, 'Outside',
                      '${delivery.outsideGeofenceCount}',
                      AppColors.warningDark),
                ],
              ],
            ),
            const SizedBox(height: 10),
          ],
          // Stop-by-stop summary. Kept compact — one line per stop, no
          // photos / full addresses. Tap "Open delivery" to see the
          // full detail view.
          for (final stop in delivery.stops)
            _stopLine(stop, isCancelled: isCancelled),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () {
              GoRouter.of(context)
                  .push('/driver/delivery/${delivery.id}');
            },
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Open delivery'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 0),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(
      IconData icon, String label, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(value,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color)),
        const SizedBox(width: 3),
        Text(label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondaryLight,
            )),
      ],
    );
  }

  Widget _stopLine(DeliveryStop stop, {required bool isCancelled}) {
    IconData icon;
    Color color;
    switch (stop.status) {
      case DeliveryStopStatus.delivered:
        icon = Icons.check_circle;
        color = AppColors.success;
        break;
      case DeliveryStopStatus.failed:
        icon = Icons.cancel;
        color = AppColors.danger;
        break;
      case DeliveryStopStatus.pending:
        icon = Icons.remove_circle_outline;
        color = AppColors.textTertiaryLight;
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              stop.customerName,
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!isCancelled &&
              stop.status == DeliveryStopStatus.delivered &&
              stop.paymentType == PaymentType.cash &&
              stop.cashReceived != null)
            Text(
              'Rs ${stop.cashReceived}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (stop.status == DeliveryStopStatus.failed &&
              stop.failureReason != null) ...[
            Flexible(
              child: Text(
                stop.failureReason!,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.danger,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
