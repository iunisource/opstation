import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../orders/presentation/order_create_modal.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/services/sound_controller.dart';
import '../../../core/utils/geo_utils.dart';
import '../../../shared/widgets/status_badge.dart';
import '../models/customer.dart';
import '../models/trip.dart';
import '../providers/trip_controller.dart';
import '../../reports/presentation/export_pdf_sheet.dart';
import 'dialogs/mark_visit_dialog.dart';
import 'dialogs/skip_visit_dialog.dart';
import 'widgets/status_count_cell.dart';

/// The in-progress route screen: counters at top, filterable stop list,
/// "Slide to complete" at the bottom. When the trip is closed, switches
/// to the completion view with Start Again / Export Report.
class RouteInProgressScreen extends ConsumerStatefulWidget {
  const RouteInProgressScreen({super.key});

  @override
  ConsumerState<RouteInProgressScreen> createState() =>
      _RouteInProgressScreenState();
}

class _RouteInProgressScreenState extends ConsumerState<RouteInProgressScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Customer> _filter(Trip trip) {
    final stops = trip.stopSnapshot;
    final q = _searchCtrl.text.trim().toLowerCase();
    final searched = q.isEmpty
        ? stops
        : stops.where((c) {
            return c.shopName.toLowerCase().contains(q) ||
                c.address.toLowerCase().contains(q) ||
                c.code.toLowerCase().contains(q) ||
                c.phone.toLowerCase().contains(q);
          }).toList();

    // Reorder: pending stops stay at the top (in their original order),
    // touched stops (verified / outside / noLocation / skipped) drop to
    // the bottom. Preserves the routing sequence for whatever's still
    // to do while surfacing it prominently.
    final byCustomer = trip.statusByCustomer;
    final pending = <Customer>[];
    final done = <Customer>[];
    for (final c in searched) {
      final status = byCustomer[c.id] ?? VisitStatus.pending;
      if (status == VisitStatus.pending) {
        pending.add(c);
      } else {
        done.add(c);
      }
    }
    return [...pending, ...done];
  }

  Future<void> _openMarkVisit(Customer customer) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => MarkVisitDialog(customer: customer),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Visit marked'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _openSkip(Customer customer) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SkipVisitDialog(customer: customer),
    );
  }

  Future<void> _completeTrip() async {
    await ref.read(tripControllerProvider.notifier).completeTrip();
    ref.read(soundControllerProvider.notifier).play(AppSound.routeEnd);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Route completed!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _showExport(Trip trip) async {
    await showExportPdfSheet(context, trip: trip);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tripControllerProvider);

    return async.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Failed to load trip: $e'),
          ),
        ),
      ),
      data: (state) => _buildForState(context, state),
    );
  }

  Widget _buildForState(BuildContext context, TripState state) {
    // The screen shows either the active trip OR the most recent completed
    // trip (so the user can still see completion + export after closing).
    final trip = state.active ??
        (state.completedToday.isNotEmpty ? state.completedToday.last : null);

    if (trip == null) {
      return Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: const Text('No route'),
        ),
        body: const Center(child: Text('No active or completed trip to show.')),
      );
    }

    final isCompleted = trip.isClosed;

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          trip.routeName,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: StatusBadge(
                label: isCompleted ? 'Completed' : 'In progress',
                tone:
                    isCompleted ? StatusBadgeTone.success : StatusBadgeTone.info,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _ProgressHeader(trip: trip),
          if (!isCompleted) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  hintText: 'Search stops...',
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
              ),
            ),
          ],
          Expanded(
            child: _StopsList(
              trip: trip,
              filtered: _filter(trip),
              readOnly: isCompleted,
              onMarkVisit: _openMarkVisit,
              onSkip: _openSkip,
            ),
          ),
          if (!isCompleted)
            _SlideToComplete(onComplete: _completeTrip)
          else
            _CompletedFooter(onStartAgain: () => Navigator.of(context).pop(), onExport: () => _showExport(trip)),
        ],
      ),
    );
  }
}

/// The route header, collapsed to one line.
///
/// It previously stacked a progress bar, a collection strip, and a four-cell KPI
/// row — around 200px before the first stop appeared. A rep with 30 stops spends
/// the day scrolling past figures they glance at once. So: a single summary line
/// they can tap to expand when they actually want the breakdown.
class _ProgressHeader extends StatefulWidget {
  final Trip trip;
  const _ProgressHeader({required this.trip});

  @override
  State<_ProgressHeader> createState() => _ProgressHeaderState();
}

class _ProgressHeaderState extends State<_ProgressHeader> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final pct = trip.completionPercent.round();
    final collected = trip.visits.fold<int>(0, (sum, v) => sum + v.amount);
    final receipts = trip.visits.where((v) => v.amount > 0).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Column(children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(children: [
              // Progress ring beats a full-width bar: same information, a tenth
              // of the width.
              SizedBox(
                width: 30, height: 30,
                child: Stack(alignment: Alignment.center, children: [
                  CircularProgressIndicator(
                    value: trip.completionPercent / 100,
                    strokeWidth: 3.5,
                    backgroundColor: AppColors.borderLight,
                    valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                  ),
                  Text('$pct',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                ]),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      _Pip(trip.verifiedCount, AppColors.success, Icons.check),
                      const SizedBox(width: 9),
                      _Pip(trip.outsideCount, AppColors.warningDark, Icons.warning_amber_rounded),
                      const SizedBox(width: 9),
                      _Pip(trip.skippedCount, AppColors.textSecondaryLight, Icons.skip_next),
                      const SizedBox(width: 9),
                      _Pip(trip.pendingCount, AppColors.primary,
                          trip.isClosed ? Icons.remove_circle_outline : Icons.schedule),
                    ]),
                    const SizedBox(height: 3),
                    Text(
                      collected > 0
                          ? 'Rs ${_thousands(collected)} collected · $receipts receipt${receipts == 1 ? '' : 's'}'
                          : 'Nothing collected yet',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: collected > 0 ? AppColors.success : AppColors.textSecondaryLight,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20, color: AppColors.textSecondaryLight),
            ]),
          ),
          if (_expanded) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                StatusCountCell(
                  icon: Icons.check_circle,
                  iconColor: AppColors.success,
                  count: trip.verifiedCount,
                  label: 'Verified',
                ),
                StatusCountCell(
                  icon: Icons.warning_amber_rounded,
                  iconColor: AppColors.warningDark,
                  count: trip.outsideCount,
                  label: 'Outside',
                ),
                StatusCountCell(
                  icon: Icons.skip_next,
                  iconColor: AppColors.textSecondaryLight,
                  count: trip.skippedCount,
                  label: 'Skipped',
                ),
                StatusCountCell(
                  icon: trip.isClosed ? Icons.remove_circle_outline : Icons.schedule,
                  iconColor: AppColors.primary,
                  count: trip.pendingCount,
                  // Once the trip is closed nothing can still be "pending" —
                  // customers that never got a real visit are "Missed".
                  label: trip.isClosed ? 'Missed' : 'Pending',
                ),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

/// A count with an icon, small enough for four to sit on one line.
class _Pip extends StatelessWidget {
  final int count;
  final Color color;
  final IconData icon;
  const _Pip(this.count, this.color, this.icon);

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 2),
          Text('$count',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
        ],
      );
}

class _StopsList extends ConsumerWidget {
  final Trip trip;
  final List<Customer> filtered;
  final bool readOnly;
  final Future<void> Function(Customer) onMarkVisit;
  final Future<void> Function(Customer) onSkip;

  const _StopsList({
    required this.trip,
    required this.filtered,
    required this.readOnly,
    required this.onMarkVisit,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        for (int i = 0; i < filtered.length; i++) ...[
          _StopCard(
            index: trip.stopSnapshot.indexOf(filtered[i]) + 1,
            customer: filtered[i],
            visit: ref
                .read(tripControllerProvider.notifier)
                .latestVisitFor(filtered[i].id),
            canVisit:
                ref.read(tripControllerProvider.notifier).canVisit(filtered[i].id),
            readOnly: readOnly,
            onMarkVisit: () => onMarkVisit(filtered[i]),
            onSkip: () => onSkip(filtered[i]),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _StopCard extends StatefulWidget {
  final int index;
  static const _tones = {
    VisitStatus.verified: AppColors.success,
    VisitStatus.outside: AppColors.warningDark,
    VisitStatus.noLocation: AppColors.warningDark,
    VisitStatus.skipped: AppColors.textSecondaryLight,
  };

  final Customer customer;
  final Visit? visit;
  final bool canVisit;
  final bool readOnly;
  final VoidCallback onMarkVisit;
  final VoidCallback onSkip;

  const _StopCard({
    required this.index,
    required this.customer,
    required this.visit,
    required this.canVisit,
    required this.readOnly,
    required this.onMarkVisit,
    required this.onSkip,
  });

  @override
  State<_StopCard> createState() => _StopCardState();
}

class _StopCardState extends State<_StopCard> {
  /// A finished stop starts collapsed, but the rep can open it again — to
  /// re-check a phone number, reopen the map, or place an order for a shop they
  /// have already collected from. Collapsing must not mean losing access.
  bool _open = false;

  int get index => widget.index;
  Customer get customer => widget.customer;
  Visit? get visit => widget.visit;
  bool get canVisit => widget.canVisit;
  bool get readOnly => widget.readOnly;
  VoidCallback get onMarkVisit => widget.onMarkVisit;
  VoidCallback get onSkip => widget.onSkip;

  Widget _collapsed(BuildContext context, VisitStatus status) {
    final tone = _StopCard._tones[status] ?? AppColors.textSecondaryLight;
    final amount = visit?.amount ?? 0;
    return InkWell(
      onTap: () => setState(() => _open = true),
      borderRadius: BorderRadius.circular(10),
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(children: [
        SizedBox(
          width: 22,
          child: Text('$index',
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondaryLight,
                  fontWeight: FontWeight.w600)),
        ),
        Icon(
          status == VisitStatus.verified ? Icons.check_circle
            : status == VisitStatus.skipped ? Icons.skip_next
            : Icons.warning_amber_rounded,
          size: 16, color: tone,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(customer.shopName,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (amount > 0) ...[
          Text('Rs ${_thousands(amount)}',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w800,
                  color: AppColors.success)),
        ] else
          Text(status.label,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: tone)),
        const SizedBox(width: 6),
        const Icon(Icons.expand_more, size: 17, color: AppColors.textSecondaryLight),
      ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = visit?.status;

    // A stop that is done and cannot be revisited collapses to a single line.
    // A rep on a 30-stop route should not scroll past a full card — with a phone
    // number, a map button and an Order button — for a shop they finished an
    // hour ago. The line keeps what they might still want to check: that it was
    // done, and what was collected.
    final settled = status != null && !canVisit;
    if (settled && !readOnly && !_open) return _collapsed(context, status);

    // An expanded-but-settled stop gets a tap target to fold it away again.
    if (settled && !readOnly && _open) {
      return Stack(children: [
        _fullCard(context, status),
        Positioned(
          top: 4, right: 4,
          child: InkWell(
            onTap: () => setState(() => _open = false),
            borderRadius: BorderRadius.circular(20),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.expand_less, size: 20, color: AppColors.textSecondaryLight),
            ),
          ),
        ),
      ]);
    }

    return _fullCard(context, status);
  }

  Widget _fullCard(BuildContext context, VisitStatus? status) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$index',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      customer.shopName,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    if (customer.address.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        customer.address,
                        style: const TextStyle(
                          color: AppColors.textSecondaryLight,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.phone,
                            size: 12, color: AppColors.textSecondaryLight),
                        const SizedBox(width: 4),
                        Text(
                          customer.phone,
                          style: const TextStyle(
                              color: AppColors.textSecondaryLight, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (customer.category != null)
                          _MiniChip(text: customer.category!),
                        if (customer.group != null)
                          _MiniChip(text: customer.group!),
                        _MiniChip(text: '#${customer.code}'),
                      ],
                    ),
                  ],
                ),
              ),
              if (status != null) _statusBadge(status),
            ],
          ),
          if (visit != null) ...[
            const SizedBox(height: 10),
            _VisitMeta(visit: visit!),
          ],
          if (!readOnly) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.borderLight),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.directions, size: 20),
                    color: AppColors.primary,
                    tooltip: 'Directions',
                    onPressed: () {
                      // TODO: wire directions intent
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.borderLight),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.phone, size: 20),
                    color: AppColors.successDark,
                    tooltip: 'Call',
                    onPressed: () {
                      // TODO: wire phone intent
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => OrderCreateModal.show(
                      context,
                      customerId: customer.id,
                      customerName: customer.shopName,
                      customerCode: customer.code,
                    ),
                    icon: const Icon(Icons.add_shopping_cart, size: 18),
                    label: const Text('Order'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.primary),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canVisit ? onSkip : null,
                    icon: const Icon(Icons.skip_next, size: 18),
                    label: const Text('Skip'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      foregroundColor: AppColors.textPrimaryLight,
                      side: const BorderSide(color: AppColors.borderLight),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: canVisit ? onMarkVisit : null,
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: Text(visit != null && visit!.allowsRevisit
                        ? 'Revisit'
                        : 'Mark visit'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      minimumSize: const Size(0, 44),
                      disabledBackgroundColor: AppColors.borderLight,
                      disabledForegroundColor: AppColors.textTertiaryLight,
                    ),
                  ),
                ),
              ],
            ),
            if (!canVisit && visit != null) ...[
              const SizedBox(height: 6),
              Text(
                visit!.status == VisitStatus.skipped
                    ? 'Skipped for today.'
                    : 'Closed for today (amount collected).',
                style: const TextStyle(
                  color: AppColors.textSecondaryLight,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _statusBadge(VisitStatus s) {
    switch (s) {
      case VisitStatus.verified:
        return const StatusBadge(
            label: 'Verified', tone: StatusBadgeTone.success);
      case VisitStatus.outside:
        return const StatusBadge(
            label: 'Outside', tone: StatusBadgeTone.warning);
      case VisitStatus.noLocation:
        return const StatusBadge(
            label: 'No location', tone: StatusBadgeTone.danger);
      case VisitStatus.skipped:
        return const StatusBadge(
            label: 'Skipped', tone: StatusBadgeTone.neutral);
      case VisitStatus.pending:
        return const StatusBadge(
            label: 'Pending', tone: StatusBadgeTone.neutral);
    }
  }
}

class _VisitMeta extends StatelessWidget {
  final Visit visit;
  const _VisitMeta({required this.visit});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (visit.amount > 0) parts.add('Rs ${visit.amount}');
    if (visit.receiptNumber != null) parts.add('CR# ${visit.receiptNumber}');
    if (visit.distanceMeters != null) {
      parts.add(GeoUtils.formatDistance(visit.distanceMeters!));
    }
    final time = TimeOfDay.fromDateTime(visit.timestamp).format(context);
    parts.add(time);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.scaffoldLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline,
              size: 14, color: AppColors.textSecondaryLight),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              parts.join(' · '),
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondaryLight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String text;
  const _MiniChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.borderLight,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.textSecondaryLight,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Slide-to-confirm bar (replaces the native Slidable for zero deps).
class _SlideToComplete extends StatefulWidget {
  final VoidCallback onComplete;
  const _SlideToComplete({required this.onComplete});

  @override
  State<_SlideToComplete> createState() => _SlideToCompleteState();
}

class _SlideToCompleteState extends State<_SlideToComplete> {
  double _dragX = 0;
  static const double _trackInset = 4;
  static const double _handleSize = 44;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxDrag = constraints.maxWidth - _handleSize - _trackInset * 2;
            final ratio = (_dragX / maxDrag).clamp(0.0, 1.0);
            return Container(
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.successLight,
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: AppColors.success.withOpacity(0.4)),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Opacity(
                      opacity: (1 - ratio).clamp(0.0, 1.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Text(
                            'Slide to complete route',
                            style: TextStyle(
                              color: AppColors.successDark,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          SizedBox(width: 8),
                          Icon(Icons.arrow_forward,
                              color: AppColors.successDark, size: 18),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: _trackInset + _dragX,
                    top: _trackInset,
                    bottom: _trackInset,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (d) {
                        setState(() {
                          _dragX = (_dragX + d.delta.dx).clamp(0.0, maxDrag);
                        });
                      },
                      onHorizontalDragEnd: (_) {
                        if (_dragX >= maxDrag * 0.85) {
                          setState(() => _dragX = maxDrag);
                          widget.onComplete();
                        } else {
                          setState(() => _dragX = 0);
                        }
                      },
                      child: Container(
                        width: _handleSize,
                        decoration: const BoxDecoration(
                          color: AppColors.success,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.chevron_right,
                            color: Colors.white, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CompletedFooter extends StatelessWidget {
  final VoidCallback onStartAgain;
  final VoidCallback onExport;

  const _CompletedFooter({required this.onStartAgain, required this.onExport});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: const Border(top: BorderSide(color: AppColors.borderLight)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.textPrimaryLight.withOpacity(0.9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: const [
                  Icon(Icons.check_circle, color: Colors.white, size: 18),
                  SizedBox(width: 10),
                  Text(
                    'Route completed!',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onStartAgain,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Back to home'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: AppColors.successDark,
                  side: const BorderSide(color: AppColors.success),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onExport,
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('Export report'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 12500 -> 12,500. Reps read these numbers aloud to shopkeepers; an unspaced
/// figure invites a misread.
String _thousands(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
