import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/initial_avatar.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../admin_settings/providers/org_settings_controller.dart';
import '../providers/monitoring_controller.dart';
import '../providers/delivery_monitoring_provider.dart';
import '../../dispatch/models/delivery.dart';

class MonitoringScreen extends ConsumerStatefulWidget {
  const MonitoringScreen({super.key});

  @override
  ConsumerState<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends ConsumerState<MonitoringScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabs;
  Timer? _autoRefresh;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    // Keep the admin picture live while the screen stays open — the
    // providers pull from Supabase on each rebuild, so this re-pull every
    // couple of minutes replaces the old logout/login dance.
    _autoRefresh = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _refreshAll(),
    );
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Admin returns to an app left open overnight → refresh immediately.
    if (state == AppLifecycleState.resumed && mounted) {
      _refreshAll();
    }
  }

  void _refreshAll() {
    if (!mounted) return;
    ref.invalidate(liveMonitoringProvider);
    ref.invalidate(leaderboardProvider);
    try {
      ref.read(deliveryMonitoringProvider.notifier).refresh();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Team monitoring',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refreshAll,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.podcasts), text: 'Live'),
            Tab(icon: Icon(Icons.local_shipping_outlined), text: 'Deliveries'),
            Tab(icon: Icon(Icons.emoji_events_outlined), text: 'Leaderboard'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _LiveTab(),
          _DeliveriesTab(),
          _LeaderboardTab(),
        ],
      ),
    );
  }
}

// ---- LIVE TAB ---------------------------------------------------------

class _LiveTab extends ConsumerWidget {
  const _LiveTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(liveMonitoringProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (list) {
        if (list.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No salespersons on the team yet.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final onRoute = list.where((s) => s.isOnRoute).length;
        final idle = list.where((s) => !s.isOnRoute).length;

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(liveMonitoringProvider);
            await ref.read(liveMonitoringProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: _SummaryTile(
                      icon: Icons.directions_walk,
                      iconBg: AppColors.successLight,
                      iconFg: AppColors.successDark,
                      value: '$onRoute',
                      label: 'On route now',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SummaryTile(
                      icon: Icons.pause_circle_outline,
                      iconBg: AppColors.borderLight,
                      iconFg: AppColors.textSecondaryLight,
                      value: '$idle',
                      label: 'Idle',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              for (final s in list) _LiveRow(summary: s),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }
}

class _LiveRow extends StatelessWidget {
  final LiveSalespersonSummary summary;
  const _LiveRow({required this.summary});

  @override
  Widget build(BuildContext context) {
    final isOnRoute = summary.isOnRoute;
    final active = summary.active;

    return InkWell(
      onTap: () =>
          context.push('/admin/monitoring/user/${summary.user.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isOnRoute
                ? AppColors.success.withOpacity(0.4)
                : AppColors.borderLight,
            width: isOnRoute ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Stack(
              alignment: Alignment.bottomRight,
              children: [
                InitialAvatar(initials: summary.user.initials),
                if (isOnRoute)
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          summary.user.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isOnRoute)
                        const StatusBadge(
                          label: 'On route',
                          tone: StatusBadgeTone.success,
                        )
                      else
                        const StatusBadge(
                          label: 'Idle',
                          tone: StatusBadgeTone.neutral,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (active != null)
                    Text(
                      '${active.routeName} · '
                      '${active.visits.length}/${active.totalStops} stops · '
                      'Started ${_fmtElapsed(active.startedAt)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondaryLight,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else if (summary.lastActivity != null)
                    Text(
                      'Last seen ${DateFormat('HH:mm').format(summary.lastActivity!)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondaryLight,
                      ),
                    )
                  else
                    const Text(
                      'No activity today',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textTertiaryLight,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right,
                size: 20, color: AppColors.textTertiaryLight),
          ],
        ),
      ),
    );
  }

  String _fmtElapsed(DateTime started) {
    final diff = DateTime.now().difference(started);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    final h = diff.inHours;
    final m = diff.inMinutes - h * 60;
    return '${h}h ${m}m ago';
  }
}


// ---- DELIVERIES TAB ---------------------------------------------------

class _DeliveriesTab extends ConsumerWidget {
  const _DeliveriesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(deliveryMonitoringProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (list) {
        if (list.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_shipping_outlined, size: 48, color: AppColors.textTertiaryLight),
                  SizedBox(height: 12),
                  Text('No active deliveries right now.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondaryLight)),
                ],
              ),
            ),
          );
        }

        final inProgress = list.where((d) => d.status == DeliveryStatus.inProgress).length;
        final assigned = list.where((d) => d.status == DeliveryStatus.assigned).length;

        return RefreshIndicator(
          onRefresh: () async {
            ref.read(deliveryMonitoringProvider.notifier).refresh();
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(children: [
                Expanded(child: _SummaryTile(
                  icon: Icons.drive_eta,
                  iconBg: AppColors.successLight,
                  iconFg: AppColors.successDark,
                  value: '$inProgress',
                  label: 'In progress',
                )),
                const SizedBox(width: 12),
                Expanded(child: _SummaryTile(
                  icon: Icons.assignment_outlined,
                  iconBg: AppColors.warningLight,
                  iconFg: AppColors.warningDark,
                  value: '$assigned',
                  label: 'Assigned',
                )),
              ]),
              const SizedBox(height: 16),
              for (final d in list) _DeliveryRow(summary: d),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }
}

class _DeliveryRow extends StatelessWidget {
  final LiveDeliverySummary summary;
  const _DeliveryRow({required this.summary});

  @override
  Widget build(BuildContext context) {
    final isActive = summary.status == DeliveryStatus.inProgress;
    final pct = summary.totalStops == 0 ? 0.0
        : (summary.deliveredCount / summary.totalStops);

    return InkWell(
      onTap: () => context.push('/dispatch/delivery/${summary.delivery.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive
                ? AppColors.success.withOpacity(0.4)
                : AppColors.warningDark.withOpacity(0.3),
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: isActive ? AppColors.successLight : AppColors.warningLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(
                  isActive ? Icons.drive_eta : Icons.assignment_outlined,
                  color: isActive ? AppColors.successDark : AppColors.warningDark,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(summary.driverName,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    Text(
                      isActive ? 'In progress' : 'Assigned — not started',
                      style: TextStyle(
                        fontSize: 12,
                        color: isActive ? AppColors.successDark : AppColors.warningDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text('Rs ${summary.cashCollected}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 6,
                backgroundColor: AppColors.borderLight,
                valueColor: AlwaysStoppedAnimation(
                  isActive ? AppColors.success : AppColors.warningDark,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              _Chip('${summary.deliveredCount} delivered', AppColors.success),
              const SizedBox(width: 6),
              if (summary.failedCount > 0)
                _Chip('${summary.failedCount} failed', AppColors.danger),
              const SizedBox(width: 6),
              _Chip('${summary.pendingCount} pending', AppColors.textSecondaryLight),
            ]),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w700)),
    );
  }
}

// ---- LEADERBOARD TAB --------------------------------------------------

class _LeaderboardTab extends ConsumerStatefulWidget {
  const _LeaderboardTab();

  @override
  ConsumerState<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends ConsumerState<_LeaderboardTab> {
  LeaderboardPeriod _period = LeaderboardPeriod.today;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(leaderboardProvider(_period));
    final settingsAsync = ref.watch(orgSettingsProvider);
    final bands = settingsAsync.valueOrNull;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: _PeriodSelector(
            selected: _period,
            onChanged: (p) => setState(() => _period = p),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (entries) {
              if (entries.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No salespersons on the team yet.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              final totalCollected =
                  entries.fold<int>(0, (s, e) => s + e.collected);
              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(leaderboardProvider);
                  await ref.read(leaderboardProvider(_period).future);
                },
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  itemCount: entries.length + 1,
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return _TotalCollectionBanner(amount: totalCollected);
                    }
                    final entry = entries[i - 1];
                    return _LeaderboardRow(
                      rank: i,
                      entry: entry,
                      badMax: bands?.scoreBadMax ?? 40,
                      okMax: bands?.scoreOkMax ?? 70,
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  final LeaderboardPeriod selected;
  final ValueChanged<LeaderboardPeriod> onChanged;

  const _PeriodSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final p in LeaderboardPeriod.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () => onChanged(p),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      selected == p ? AppColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: selected == p
                        ? AppColors.primary
                        : AppColors.borderLight,
                  ),
                ),
                child: Text(
                  _label(p),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected == p
                        ? Colors.white
                        : Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _label(LeaderboardPeriod p) {
    switch (p) {
      case LeaderboardPeriod.today:
        return 'Today';
      case LeaderboardPeriod.week:
        return 'This week';
      case LeaderboardPeriod.month:
        return 'This month';
    }
  }
}

class _LeaderboardRow extends StatelessWidget {
  final int rank;
  final LeaderboardEntry entry;
  final int badMax;
  final int okMax;

  const _LeaderboardRow({
    required this.rank,
    required this.entry,
    required this.badMax,
    required this.okMax,
  });

  Color _bandColor(double score) {
    if (score < badMax) return AppColors.danger;
    if (score < okMax) return AppColors.warningDark;
    return AppColors.success;
  }

  @override
  Widget build(BuildContext context) {
    final score = entry.visitScore;
    final bandColor = _bandColor(score);

    return InkWell(
      onTap: () =>
          context.push('/admin/monitoring/user/${entry.user.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            _RankBadge(rank: rank),
            const SizedBox(width: 12),
            InitialAvatar(initials: entry.user.initials),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.user.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // Stat chips: score, verified (green), unverified (amber),
                  // and total collected. Wrap in a single Wrap so they reflow
                  // gracefully on narrow screens.
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _StatChip(
                        label: '${score.round()}%',
                        color: bandColor,
                      ),
                      _StatChip(
                        label: '${entry.verifiedVisits} verified',
                        color: AppColors.success,
                      ),
                      _StatChip(
                        label: '${entry.unverifiedVisits} unverified',
                        color: AppColors.warningDark,
                      ),
                      _StatChip(
                        label: 'Rs ${entry.collected}',
                        color: AppColors.textSecondaryLight,
                      ),
                    ],
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

class _RankBadge extends StatelessWidget {
  final int rank;
  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    switch (rank) {
      case 1:
        bg = const Color(0xFFFEF3C7);
        fg = const Color(0xFF92400E);
        break;
      case 2:
        bg = const Color(0xFFE5E7EB);
        fg = const Color(0xFF374151);
        break;
      case 3:
        bg = const Color(0xFFFEE2E2);
        fg = const Color(0xFF991B1B);
        break;
      default:
        bg = AppColors.borderLight;
        fg = AppColors.textSecondaryLight;
    }
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        '$rank',
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconFg;
  final String value;
  final String label;

  const _SummaryTile({
    required this.icon,
    required this.iconBg,
    required this.iconFg,
    required this.value,
    required this.label,
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
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: iconFg, size: 18),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
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

/// Prominent 'Total Collection' banner shown above the leaderboard list.
/// Sums the `collected` field across every leaderboard entry for the
/// selected period.
class _TotalCollectionBanner extends StatelessWidget {
  final int amount;
  const _TotalCollectionBanner({required this.amount});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryDark],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.payments_outlined,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TOTAL COLLECTION',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Colors.white.withOpacity(0.85),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Rs ${_fmtNumber(amount)}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
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

String _fmtNumber(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  int count = 0;
  for (int i = s.length - 1; i >= 0; i--) {
    buf.write(s[i]);
    count++;
    if (count % 3 == 0 && i != 0) buf.write(',');
  }
  return buf.toString().split('').reversed.join();
}