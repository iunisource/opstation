import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/sales_route.dart';
import '../../salesperson/models/trip.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';
import '../providers/report_service.dart';

/// Combined Trip Summary: a multi-date, distance-only reimbursement sheet.
/// Pick a salesperson (or all) and a period; the PDF lists each day's total
/// road distance and a grand total, with Rate/km and Total Amount left blank
/// for finance. Optionally scoped to one salesperson via [scopedUserId].
class CombinedTripSummaryScreen extends ConsumerStatefulWidget {
  final String? scopedUserId;
  const CombinedTripSummaryScreen({super.key, this.scopedUserId});

  @override
  ConsumerState<CombinedTripSummaryScreen> createState() =>
      _CombinedTripSummaryScreenState();
}

enum _Period { week, month, custom }

enum _Action { preview, share }

class _CombinedTripSummaryScreenState
    extends ConsumerState<CombinedTripSummaryScreen> {
  _Period _period = _Period.month;
  DateTimeRange? _custom;
  String? _userId;
  String? _routeId;
  bool _busy = false;

  bool get _isScoped => widget.scopedUserId != null;

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
              start: DateTime(now.year, now.month, 1),
              end: now,
            );
    }
  }

  String _periodLabel(DateTimeRange r) =>
      '${DateFormat('d MMM y').format(r.start)} - ${DateFormat('d MMM y').format(r.end)}';

  Future<_LoadResult> _loadTrips(DateTime start, DateTime end) async {
    final teamRepo = ref.read(scopedTeamRepositoryProvider);
    final salesRepo = ref.read(salespersonRepositoryProvider);
    final users = await teamRepo.all(includeInactive: true);
    final userNames = {for (final u in users) u.id: u.name};

    final targetIds = <String>[];
    final effectiveUserId = widget.scopedUserId ?? _userId;
    if (effectiveUserId != null) {
      targetIds.add(effectiveUserId);
    } else {
      for (final u in users) {
        if (u.role == UserRole.salesperson) targetIds.add(u.id);
      }
    }

    final trips = <Trip>[];
    for (final uid in targetIds) {
      trips.addAll(await salesRepo.tripsInRangeForUser(start, end, uid));
    }
    final filtered =
        _routeId == null ? trips : trips.where((t) => t.routeId == _routeId).toList();
    return _LoadResult(trips: filtered, userNames: userNames);
  }

  Future<void> _run(_Action action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final range = _currentRange();
    final start = DateTime(range.start.year, range.start.month, range.start.day);
    final end = DateTime(range.end.year, range.end.month, range.end.day);
    final actor = ref.read(authControllerProvider).valueOrNull;
    try {
      final loaded = await _loadTrips(start, end);
      if (loaded.trips.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No trips in the selected period.')),
          );
        }
        return;
      }
      final effectiveUserId = widget.scopedUserId ?? _userId;
      final showSalesperson = effectiveUserId == null;
      final salespersonLabel = effectiveUserId == null
          ? 'All salespersons'
          : (loaded.userNames[effectiveUserId] ?? 'Salesperson');

      final svc = ref.read(reportServiceProvider);
      final bytes = await svc.buildCombinedSummaryBytes(
        trips: loaded.trips,
        userNames: loaded.userNames,
        showSalesperson: showSalesperson,
        periodLabel: _periodLabel(range),
        salespersonLabel: salespersonLabel,
        actor: actor,
      );
      final fname = 'combined_summary_${_ymd(start)}_${_ymd(end)}.pdf';
      if (action == _Action.preview) {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: fname);
      } else {
        try {
          await Printing.sharePdf(bytes: bytes, filename: fname);
        } on PlatformException {
          // Platform without a share sheet (e.g. emulator) — ignore.
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final range = _currentRange();
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Combined trip summary',
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
                    _periodChip('This week', _period == _Period.week, () {
                      setState(() {
                        _period = _Period.week;
                        _custom = null;
                      });
                    }),
                    _periodChip('This month', _period == _Period.month, () {
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
                if (!_isScoped) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: _userDropdown()),
                      const SizedBox(width: 8),
                      Expanded(child: _routeDropdown()),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _DaysPreview(
              start: DateTime(range.start.year, range.start.month, range.start.day),
              end: DateTime(range.end.year, range.end.month, range.end.day),
              load: _loadTrips,
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
                      onPressed: _busy ? null : () => _run(_Action.preview),
                      icon: const Icon(Icons.preview_outlined, size: 18),
                      label: const Text('Preview PDF'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : () => _run(_Action.share),
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.ios_share, size: 18),
                      label: const Text('Share'),
                      style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 48)),
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
              color: selected ? AppColors.primary : AppColors.borderLight),
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

  Widget _userDropdown() {
    final teamRepo = ref.watch(scopedTeamRepositoryProvider);
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

class _LoadResult {
  final List<Trip> trips;
  final Map<String, String> userNames;
  _LoadResult({required this.trips, required this.userNames});
}

/// Lightweight in-app list of the days that will appear in the report. It shows
/// the routes and trip count per day; the road distances are computed when the
/// PDF is previewed or shared (that's the network-heavy step).
class _DaysPreview extends StatelessWidget {
  final DateTime start;
  final DateTime end;
  final Future<_LoadResult> Function(DateTime, DateTime) load;

  const _DaysPreview(
      {required this.start, required this.end, required this.load});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LoadResult>(
      future: load(start, end),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final trips = snap.data?.trips ?? const <Trip>[];
        final names = snap.data?.userNames ?? const <String, String>{};
        if (trips.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No trips in the selected period / filters.',
                  textAlign: TextAlign.center),
            ),
          );
        }
        // Group by (salesperson, day).
        final groups = <String, _DayGroup>{};
        for (final t in trips) {
          final d = DateTime(t.startedAt.year, t.startedAt.month, t.startedAt.day);
          final key = '${t.userId}|${d.toIso8601String()}';
          final g = groups.putIfAbsent(
            key,
            () => _DayGroup(date: d, salesperson: names[t.userId] ?? t.userName),
          );
          g.trips += 1;
          if (t.routeName.trim().isNotEmpty) g.routes.add(t.routeName.trim());
        }
        final list = groups.values.toList()
          ..sort((a, b) {
            final s = a.salesperson.compareTo(b.salesperson);
            return s != 0 ? s : a.date.compareTo(b.date);
          });
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          children: [
            Text(
              '${list.length} day${list.length == 1 ? '' : 's'} · ${trips.length} trip${trips.length == 1 ? '' : 's'} — distances are calculated in the PDF.',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondaryLight),
            ),
            const SizedBox(height: 10),
            for (final g in list)
              Container(
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
                            DateFormat('EEE, d MMM y').format(g.date),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text('${g.trips} trip${g.trips == 1 ? '' : 's'}',
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondaryLight)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${g.salesperson} · ${g.routes.join(', ')}',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondaryLight),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DayGroup {
  final DateTime date;
  final String salesperson;
  final Set<String> routes = {};
  int trips = 0;
  _DayGroup({required this.date, required this.salesperson});
}
