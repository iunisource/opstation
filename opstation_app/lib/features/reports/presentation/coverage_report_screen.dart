import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/sales_route.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';
import '../providers/report_service.dart';
import '../services/coverage_context_builder.dart';

/// Admin-facing Coverage Report: period + optional route/user filter +
/// Preview/Share PDF. Also renders a live in-app preview so the admin
/// can see the numbers before generating a PDF.
class CoverageReportScreen extends ConsumerStatefulWidget {
  const CoverageReportScreen({super.key});

  @override
  ConsumerState<CoverageReportScreen> createState() =>
      _CoverageReportScreenState();
}

enum _Period { week, month, custom }

class _CoverageReportScreenState
    extends ConsumerState<CoverageReportScreen> {
  _Period _period = _Period.week;
  DateTimeRange? _custom;
  String? _routeId;
  String? _userId;
  bool _busy = false;

  DateTimeRange _currentRange() {
    final now = DateTime.now();
    switch (_period) {
      case _Period.week:
        return DateTimeRange(
          start: DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 6)),
          end: now,
        );
      case _Period.month:
        return DateTimeRange(
          start: DateTime(now.year, now.month, 1),
          end: now,
        );
      case _Period.custom:
        return _custom ??
            DateTimeRange(
              start: DateTime(now.year, now.month, now.day)
                  .subtract(const Duration(days: 6)),
              end: now,
            );
    }
  }

  Future<void> _run(_Action action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final range = _currentRange();
    final to = DateTime(
        range.end.year, range.end.month, range.end.day, 23, 59, 59);
    final actor = ref.read(authControllerProvider).valueOrNull;
    final svc = ref.read(reportServiceProvider);
    try {
      if (action == _Action.preview) {
        await svc.previewCoverage(
          from: range.start,
          to: to,
          actor: actor,
          routeIdFilter: _routeId,
          userIdFilter: _userId,
        );
      } else {
        await svc.shareCoverage(
          from: range.start,
          to: to,
          actor: actor,
          routeIdFilter: _routeId,
          userIdFilter: _userId,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final range = _currentRange();
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Coverage report',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _periodChip(
                        'This week', _period == _Period.week, () {
                      setState(() {
                        _period = _Period.week;
                        _custom = null;
                      });
                    }),
                    _periodChip(
                        'This month', _period == _Period.month, () {
                      setState(() {
                        _period = _Period.month;
                        _custom = null;
                      });
                    }),
                    _periodChip(
                      _custom == null
                          ? 'Date range'
                          : '${DateFormat('d MMM').format(_custom!.start)} – ${DateFormat('d MMM').format(_custom!.end)}',
                      _period == _Period.custom,
                      _pickRange,
                      icon: Icons.calendar_today_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _routeDropdown()),
                    const SizedBox(width: 8),
                    Expanded(child: _userDropdown()),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _CoveragePreview(
              from: range.start,
              to: DateTime(range.end.year, range.end.month, range.end.day,
                  23, 59, 59),
              routeId: _routeId,
              userId: _userId,
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _busy ? null : () => _run(_Action.preview),
                      icon: const Icon(Icons.preview_outlined, size: 18),
                      label: const Text('Preview PDF'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed:
                          _busy ? null : () => _run(_Action.share),
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.ios_share, size: 18),
                      label: const Text('Share'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _periodChip(String label, bool selected, VoidCallback onTap,
      {IconData? icon}) {
    return InkWell(
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 13,
                  color: selected
                      ? Colors.white
                      : Theme.of(context).textTheme.bodyMedium?.color),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected
                    ? Colors.white
                    : Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _routeDropdown() {
    final salesRepo = ref.watch(salespersonRepositoryProvider);
    return FutureBuilder<List<SalesRoute>>(
      future: salesRepo.allRoutesIncludingInactive(),
      builder: (context, snap) {
        final routes = snap.data ?? const <SalesRoute>[];
        return DropdownButtonFormField<String?>(
          value: _routeId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Route',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            prefixIcon: const Icon(Icons.route_outlined, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All routes'),
            ),
            for (final r in routes)
              DropdownMenuItem<String?>(
                value: r.id,
                child: Text(r.isActive ? r.name : '${r.name} (inactive)',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _routeId = v),
        );
      },
    );
  }

  Widget _userDropdown() {
    final teamRepo = ref.watch(teamRepositoryProvider);
    return FutureBuilder<List<TeamUser>>(
      future: teamRepo.all(includeInactive: false),
      builder: (context, snap) {
        final users = (snap.data ?? const <TeamUser>[])
            .where((u) => u.role == UserRole.salesperson)
            .toList();
        return DropdownButtonFormField<String?>(
          value: _userId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Salesperson',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            prefixIcon: const Icon(Icons.person_outline, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All salespersons'),
            ),
            for (final u in users)
              DropdownMenuItem<String?>(
                value: u.id,
                child: Text(u.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _userId = v),
        );
      },
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _custom,
    );
    if (picked != null) {
      setState(() {
        _custom = picked;
        _period = _Period.custom;
      });
    }
  }
}

enum _Action { preview, share }

/// In-app preview of the coverage numbers, so the admin sees the data
/// before triggering a PDF. Rebuilds whenever filters change.
class _CoveragePreview extends ConsumerWidget {
  final DateTime from;
  final DateTime to;
  final String? routeId;
  final String? userId;

  const _CoveragePreview({
    required this.from,
    required this.to,
    required this.routeId,
    required this.userId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<CoverageReportContext>(
      future: ref.read(coverageContextBuilderProvider).build(
            from: from,
            to: to,
            routeIdFilter: routeId,
            userIdFilter: userId,
          ),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final ctx = snap.data!;
        if (ctx.totalTrips == 0) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No trips in the selected period / filters.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TopStats(ctx: ctx),
              const SizedBox(height: 16),
              _SectionHead(title: 'By route',
                  count: ctx.routeCoverages.length),
              const SizedBox(height: 6),
              for (final rc in ctx.routeCoverages)
                _RouteRowWidget(rc: rc),
              const SizedBox(height: 16),
              _SectionHead(
                  title: 'By salesperson',
                  count: ctx.salespersonCoverages.length),
              const SizedBox(height: 6),
              for (final sc in ctx.salespersonCoverages)
                _SpRowWidget(sc: sc),
            ],
          ),
        );
      },
    );
  }
}

class _TopStats extends StatelessWidget {
  final CoverageReportContext ctx;
  const _TopStats({required this.ctx});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _statCard('${ctx.totalTrips}', 'TRIPS')),
        const SizedBox(width: 8),
        Expanded(
            child: _statCard(
                '${ctx.totalUniqueCustomersVisited}', 'UNIQUE VISITS')),
        const SizedBox(width: 8),
        Expanded(child: _statCard('${ctx.totalRoutesAssessed}', 'ROUTES')),
        const SizedBox(width: 8),
        Expanded(
            child: _statCard(
                'Rs ${ctx.totalCollected}', 'COLLECTED')),
      ],
    );
  }

  Widget _statCard(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.primaryLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: AppColors.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  final String title;
  final int count;
  const _SectionHead({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.textSecondaryLight,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '($count)',
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textTertiaryLight,
          ),
        ),
      ],
    );
  }
}

class _RouteRowWidget extends StatelessWidget {
  final RouteCoverage rc;
  const _RouteRowWidget({required this.rc});

  @override
  Widget build(BuildContext context) {
    final coverage = rc.coveragePercent;
    Color coverageColor;
    if (coverage >= 70) {
      coverageColor = AppColors.success;
    } else if (coverage >= 40) {
      coverageColor = AppColors.warningDark;
    } else {
      coverageColor = AppColors.danger;
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  rc.route.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${coverage.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: coverageColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${rc.verifiedCustomerIds.length} verified · ${rc.outsideCustomerIds.length} outside · ${rc.unvisitedCustomers.length} unvisited · ${rc.tripsRun} trips · Rs ${rc.totalCollected}',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }
}

class _SpRowWidget extends StatelessWidget {
  final SalespersonCoverage sc;
  const _SpRowWidget({required this.sc});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sc.user.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  '${sc.tripsRun} trips · ${sc.verifiedVisits} verified · ${sc.outsideVisits} outside · Rs ${sc.totalCollected}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${sc.uniqueCustomersVisited}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
