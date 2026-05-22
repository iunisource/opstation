import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/device_gps_service.dart';
import '../../../core/services/sound_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/storage/photo_url.dart';
import '../../../shared/widgets/slide_to_confirm.dart';
import '../../audit/data/audit_repository.dart';
import '../../auth/providers/auth_controller.dart';
import '../../customers/data/customer_repository.dart';
import '../../salesperson/models/customer.dart';
import '../../dispatch/data/delivery_repository.dart';
import '../../dispatch/models/delivery.dart';
import '../../dispatch/pdf/delivery_pdf_builder.dart';
import '../../uploads/data/upload_queue_repository.dart';
import '../services/delivery_photo_capture_service.dart';
import '../../../core/services/sms_service.dart';
import '../../../core/database/app_database_provider.dart';

/// The stop-by-stop execution view for a driver.
///
/// On open, an `assigned` delivery is NOT auto-started — the driver
/// must slide-to-start. This is a deliberate commitment signal
/// (matching the slide-to-complete gesture at the end) and lets the
/// driver review the stops before locking themselves into the one-
/// active-per-driver rule.
///
/// When every stop is settled, the repo auto-completes the delivery.
/// The driver can also slide-to-complete early to close remaining
/// pending stops as failed with a system reason.
class DeliveryExecutionScreen extends ConsumerStatefulWidget {
  final String deliveryId;
  const DeliveryExecutionScreen({super.key, required this.deliveryId});

  @override
  ConsumerState<DeliveryExecutionScreen> createState() =>
      _DeliveryExecutionScreenState();
}

class _DeliveryExecutionScreenState
    extends ConsumerState<DeliveryExecutionScreen> {
  Delivery? _delivery;
  bool _loading = true;
  bool _starting = false;
  String? _startError;

  /// Pre-loaded snapshot of all customers, keyed by id. Used synchronously
  /// by stop cards to show the customer's saved address and to offer an
  /// "Open in Maps" action. Loaded once on screen open; staleness across
  /// customer edits is acceptable at this granularity.
  Map<String, Customer> _customerIndex = const {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final repo = ref.read(deliveryRepositoryProvider);
    final d = await repo.byId(widget.deliveryId);
    final allCustomers =
        await ref.read(customerRepositoryProvider).all(includeInactive: true);
    if (!mounted) return;
    setState(() {
      _delivery = d;
      _customerIndex = {for (final c in allCustomers) c.id: c};
      _loading = false;
    });
  }

  /// Triggered by the slide-to-start at the bottom of an assigned
  /// delivery. Flips status to in_progress and plays the route-start
  /// chime. Same error paths as the previous auto-start behavior —
  /// the one-active-per-driver rule still applies.
  Future<void> _handleStart() async {
    if (_starting) return;
    setState(() => _starting = true);
    final repo = ref.read(deliveryRepositoryProvider);
    final user = ref.read(authControllerProvider).valueOrNull;
    final d = _delivery;
    if (d == null || user == null) {
      setState(() => _starting = false);
      return;
    }
    try {
      await repo.startDelivery(id: d.id, driverId: user.id);
      await ref.read(auditLoggerProvider).deliveryStarted(deliveryId: d.id);
      ref.read(soundControllerProvider.notifier).play(AppSound.routeStart);
      await _reload();
    } catch (e) {
      setState(() {
        _startError = e.toString().replaceFirst('Bad state: ', '');
        _starting = false;
      });
    }
  }

  Future<void> _reload() async {
    final d = await ref.read(deliveryRepositoryProvider).byId(widget.deliveryId);
    if (!mounted) return;
    setState(() => _delivery = d);
  }

  Future<void> _exportPdf(Delivery d) async {
    final user = ref.read(authControllerProvider).valueOrNull;
    final orgName = user?.organizationName ?? 'Opstation';
    try {
      final bytes = Uint8List.fromList(await DeliveryPdfBuilder.build(
        delivery: d,
        orgName: orgName,
      ));
      final filename =
          'delivery_${d.id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.pdf';
      await Printing.sharePdf(bytes: bytes, filename: filename);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('PDF error: $e')));
      }
    }
  }

  Future<DeviceFix?> _tryGps() async {
    try {
      return await ref
          .read(deviceGpsServiceProvider)
          .getFix(timeout: const Duration(seconds: 4));
    } catch (_) {
      return null;
    }
  }

  /// Compute the cloud paths for a list of local photo paths under a
  /// delivery stop. Returns local→remote pairs in input order so the
  /// caller can both store remotes on the row and queue uploads with
  /// the matching locals. See trip_controller.markVisit for the same
  /// pattern on the salesperson side.
  List<({String local, String remote})> _buildStopPhotoPaths({
    required DeliveryStop stop,
    required List<String> localPaths,
  }) {
    final user = ref.read(authControllerProvider).valueOrNull;
    final safeDriver = (user?.name ?? 'driver').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final date = DateTime.now().toIso8601String().split('T').first;
    final stopIndex = _delivery?.stops.indexWhere((s) => s.id == stop.id) ?? 0;
    return [
      for (int i = 0; i < localPaths.length; i++)
        (
          local: localPaths[i],
          remote:
              'deliveries/${widget.deliveryId}/${safeDriver}_${date}_stop${stopIndex + 1}_$i.${localPaths[i].split('.').last}'
        ),
    ];
  }

  Future<void> _handleMarkDelivered(DeliveryStop stop) async {
    final result = await showModalBottomSheet<_DeliveredResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MarkDeliveredSheet(
        stop: stop,
        deliveryId: widget.deliveryId,
      ),
    );
    if (result == null) return;

    final fix = await _tryGps();
    final customer = await _customerFor(stop.customerId);
    final dist = (fix != null && customer != null &&
            customer.latitude != null &&
            customer.longitude != null)
        ? _distanceMeters(fix.lat, fix.lng, customer.latitude!,
            customer.longitude!)
        : null;

    // Compute cloud paths up front. The row stores remote paths (so
    // the web admin can build URLs from them); the upload queue gets
    // local→remote pairs so it can find the file on disk to upload.
    final pathPairs = _buildStopPhotoPaths(
      stop: stop,
      localPaths: result.photoPaths,
    );
    final remotePaths = [for (final p in pathPairs) p.remote];

    try {
      await ref.read(deliveryRepositoryProvider).markStopDelivered(
            stopId: stop.id,
            cashReceived: result.cashReceived,
            lat: fix?.lat,
            lng: fix?.lng,
            distanceMeters: dist,
            photoPaths: remotePaths, // Cloud paths, not local
          );
      // Mark for sync — SyncController.flushPending picks this up after
      // network restores; pushAll handles it on login. SMS fires post-push,
      // not here. Raw SQL avoids needing a Drift import in this widget.
      await ref.read(appDatabaseProvider).customStatement(
        "UPDATE delivery_stops SET sync_status = 'pending' WHERE id = ?",
        [stop.id],
      );
      // Enqueue background uploads using the matching local→remote pairs.
      for (final pair in pathPairs) {
        await ref.read(uploadQueueRepositoryProvider).enqueue(
              localPath: pair.local,
              remotePath: pair.remote,
              bucket: 'opstation-photos',
              entityType: 'delivery_stop',
              entityId: stop.id,
            );
      }
      await ref.read(auditLoggerProvider).stopDelivered(
            deliveryId: widget.deliveryId,
            stopId: stop.id,
            customerName: stop.customerName,
            cashReceived: result.cashReceived,
          );
      // SMS firing moved to SyncController — fires after pushDeliveryStop
      // so offline-marked stops also notify the customer once synced.
      // Same gating as before (cashReceived > 0).
      final autoCompleted = await _maybeNotifyAutoComplete();
      ref.read(soundControllerProvider.notifier).play(
            autoCompleted ? AppSound.routeEnd : AppSound.visitMarked,
          );
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _handleMarkFailed(DeliveryStop stop) async {
    final result = await showModalBottomSheet<_FailedResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MarkFailedSheet(
        stop: stop,
        deliveryId: widget.deliveryId,
      ),
    );
    if (result == null || result.reason.isEmpty) return;

    final fix = await _tryGps();
    final customer = await _customerFor(stop.customerId);
    final dist = (fix != null && customer != null &&
            customer.latitude != null &&
            customer.longitude != null)
        ? _distanceMeters(fix.lat, fix.lng, customer.latitude!,
            customer.longitude!)
        : null;

    // Same pattern as _handleMarkDelivered — cloud paths to the row,
    // local→remote pairs to the upload queue.
    final pathPairs = _buildStopPhotoPaths(
      stop: stop,
      localPaths: result.photoPaths,
    );
    final remotePaths = [for (final p in pathPairs) p.remote];

    try {
      await ref.read(deliveryRepositoryProvider).markStopFailed(
            stopId: stop.id,
            reason: result.reason,
            lat: fix?.lat,
            lng: fix?.lng,
            distanceMeters: dist,
            photoPaths: remotePaths, // Cloud paths, not local
          );
      for (final pair in pathPairs) {
        await ref.read(uploadQueueRepositoryProvider).enqueue(
              localPath: pair.local,
              remotePath: pair.remote,
              bucket: 'opstation-photos',
              entityType: 'delivery_stop',
              entityId: stop.id,
            );
      }
      await ref.read(auditLoggerProvider).stopFailed(
            deliveryId: widget.deliveryId,
            stopId: stop.id,
            customerName: stop.customerName,
            reason: result.reason,
          );
      final autoCompleted = await _maybeNotifyAutoComplete();
      ref.read(soundControllerProvider.notifier).play(
            autoCompleted ? AppSound.routeEnd : AppSound.visitMarked,
          );
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Emits the 'delivery completed' audit line if the repo just flipped
  /// status to completed via auto-complete. Returns true when that
  /// transition happened so callers can play the route-end chime
  /// instead of the per-action tick.
  Future<bool> _maybeNotifyAutoComplete() async {
    final before = _delivery;
    final fresh = await ref
        .read(deliveryRepositoryProvider)
        .byId(widget.deliveryId);
    if (before != null &&
        fresh != null &&
        before.status == DeliveryStatus.inProgress &&
        fresh.status == DeliveryStatus.completed) {
      await ref
          .read(auditLoggerProvider)
          .deliveryCompleted(deliveryId: fresh.id, early: false);
      return true;
    }
    return false;
  }

  Future<void> _handleCompleteEarly() async {
    final d = _delivery;
    if (d == null) return;
    final remaining = d.pendingCount;
    if (remaining == 0) return;
    // The slide-to-complete gesture itself is the confirmation —
    // replaces the older tap-then-dialog flow. Slide commits
    // immediately on release at the right edge.
    try {
      await ref
          .read(deliveryRepositoryProvider)
          .completeEarly(deliveryId: d.id);
      await ref
          .read(auditLoggerProvider)
          .deliveryCompleted(deliveryId: d.id, early: true);
      ref.read(soundControllerProvider.notifier).play(AppSound.routeEnd);
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Customer? _customerFor(String id) => _customerIndex[id];

  int _distanceMeters(double aLat, double aLng, double bLat, double bLng) {
    // Haversine, returns meters. Small angle math keeps it reasonable
    // over the ~100m distances that matter at customer stops.
    const earth = 6371000.0;
    final dLat = _deg(bLat - aLat);
    final dLng = _deg(bLng - aLng);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg(aLat)) *
            math.cos(_deg(bLat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return (2 * earth * math.asin(math.sqrt(h))).round();
  }

  double _deg(double d) => d * math.pi / 180.0;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        appBar: null,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final d = _delivery;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: const Center(child: Text('Delivery not found.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Delivery',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          if (d.status == DeliveryStatus.completed)
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'Export PDF',
              onPressed: () => _exportPdf(d),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            if (_startError != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.danger.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: AppColors.danger.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: AppColors.danger, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _startError!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            _HeaderStats(delivery: d),
            const SizedBox(height: 16),
            const Text(
              'STOPS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                color: AppColors.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 8),
            for (final s in d.stops)
              _StopCard(
                stop: s,
                customer: _customerIndex[s.customerId],
                canAct: d.status == DeliveryStatus.inProgress,
                onMarkDelivered: () => _handleMarkDelivered(s),
                onMarkFailed: () => _handleMarkFailed(s),
              ),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomBar(d),
    );
  }

  /// Bottom action area. Three states, mutually exclusive:
  ///
  /// - ASSIGNED -> slide-to-start (blue). Fires [_handleStart] on
  ///   release at the right edge; no separate confirm tap needed.
  /// - IN_PROGRESS with pending stops -> slide-to-complete (red).
  ///   Closes remaining pending stops as failed + stamps completedAt.
  /// - Otherwise (completed / cancelled / in_progress with zero
  ///   pending) -> no bottom bar; the repo auto-completes or the
  ///   delivery is already closed.
  Widget? _buildBottomBar(Delivery d) {
    final user = ref.read(authControllerProvider).valueOrNull;
    final isThisDriver = user != null && user.id == d.driverId;

    if (d.status == DeliveryStatus.assigned && isThisDriver) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SlideToConfirm(
            label: _starting ? 'Starting...' : 'Slide to start delivery',
            icon: Icons.local_shipping_outlined,
            color: AppColors.primary,
            onConfirmed: _handleStart,
            disabled: _starting,
          ),
        ),
      );
    }
    if (d.status == DeliveryStatus.inProgress && d.pendingCount > 0) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SlideToConfirm(
            label: 'Slide to complete (${d.pendingCount} remaining)',
            icon: Icons.flag_outlined,
            color: AppColors.danger,
            onConfirmed: _handleCompleteEarly,
          ),
        ),
      );
    }
    return null;
  }
}

class _HeaderStats extends StatelessWidget {
  final Delivery delivery;
  const _HeaderStats({required this.delivery});

  @override
  Widget build(BuildContext context) {
    final progress = delivery.stops.isEmpty
        ? 0.0
        : (delivery.deliveredCount + delivery.failedCount) /
            delivery.stops.length;
    final completed = delivery.status == DeliveryStatus.completed;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: completed
            ? AppColors.successLight
            : AppColors.primaryLight.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                completed
                    ? Icons.check_circle
                    : Icons.local_shipping_outlined,
                color: completed ? AppColors.success : AppColors.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                completed ? 'Completed' : delivery.status.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color:
                      completed ? AppColors.successDark : AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _stat(
                  '${delivery.deliveredCount}/${delivery.stops.length}',
                  'DELIVERED',
                ),
              ),
              Expanded(
                child: _stat(
                  '${delivery.failedCount}',
                  'FAILED',
                ),
              ),
              Expanded(
                child: _stat(
                  'Rs ${delivery.cashCollected}',
                  'COLLECTED',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white.withOpacity(0.5),
              color: completed ? AppColors.success : AppColors.primary,
            ),
          ),
          // Verification summary — only shown when there's something to
          // flag. Silent on the happy path so the header stays calm.
          if (delivery.outsideGeofenceCount > 0 ||
              delivery.noLocationCount > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.location_searching,
                    size: 13, color: AppColors.warningDark),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _verificationSummary(delivery),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.warningDark,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Human-readable summary like "2 outside geofence, 1 no GPS" or
  /// "1 stop outside geofence". Returns empty if nothing to flag
  /// (caller is expected to guard).
  String _verificationSummary(Delivery d) {
    final parts = <String>[];
    if (d.outsideGeofenceCount > 0) {
      parts.add(
        '${d.outsideGeofenceCount} outside geofence',
      );
    }
    if (d.noLocationCount > 0) {
      parts.add('${d.noLocationCount} no GPS');
    }
    return parts.join(' · ');
  }

  Widget _stat(String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.textSecondaryLight,
          ),
        ),
      ],
    );
  }
}

class _StopCard extends StatelessWidget {
  final DeliveryStop stop;
  final Customer? customer;
  final bool canAct;
  final VoidCallback onMarkDelivered;
  final VoidCallback onMarkFailed;

  const _StopCard({
    required this.stop,
    required this.customer,
    required this.canAct,
    required this.onMarkDelivered,
    required this.onMarkFailed,
  });

  /// Opens Google Maps (or the system default) for navigation to this
  /// customer. Prefers saved lat/lng if we have them; falls back to a
  /// search by address text. Uses externalApplication mode so the OS
  /// route-chooser appears (Google Maps vs Apple Maps vs Waze).
  Future<void> _openInMaps(BuildContext context) async {
    if (customer == null) return;
    Uri? uri;
    if (customer!.latitude != null && customer!.longitude != null) {
      uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${customer!.latitude},${customer!.longitude}',
      );
    } else if (customer!.address.trim().isNotEmpty) {
      final q = Uri.encodeComponent(customer!.address);
      uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$q');
    }
    if (uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No location or address saved for this customer.'),
        ),
      );
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open maps.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = stop.status == DeliveryStopStatus.pending;
    final delivered = stop.status == DeliveryStopStatus.delivered;
    final failed = stop.status == DeliveryStopStatus.failed;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: pending
              ? AppColors.borderLight
              : (delivered ? AppColors.success : AppColors.danger)
                  .withOpacity(0.4),
          width: pending ? 1 : 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: pending
                    ? AppColors.primaryLight
                    : (delivered ? AppColors.success : AppColors.danger),
                child: Text(
                  '${stop.sequence + 1}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: pending ? AppColors.primary : Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stop.customerName,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      stop.customerCode,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondaryLight,
                      ),
                    ),
                    if (customer != null &&
                        customer!.address.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2, right: 4),
                            child: Icon(Icons.place_outlined,
                                size: 13,
                                color: AppColors.textSecondaryLight),
                          ),
                          Expanded(
                            child: Text(
                              customer!.address,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondaryLight,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (customer != null &&
                        (customer!.latitude != null ||
                            customer!.address.trim().isNotEmpty)) ...[
                      const SizedBox(height: 6),
                      Builder(
                        builder: (ctx) => InkWell(
                          onTap: () => _openInMaps(ctx),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.primaryLight,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.directions,
                                    size: 13, color: AppColors.primary),
                                SizedBox(width: 4),
                                Text(
                                  'Open in Maps',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (stop.itemDescription.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        stop.itemDescription,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                    if (stop.driverNote != null &&
                        stop.driverNote!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.warningLight,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: AppColors.warningDark, width: 0.4),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline,
                                size: 14, color: AppColors.warningDark),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                stop.driverNote!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.warningDark,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (stop.soInvoiceNumber != null &&
                        stop.soInvoiceNumber!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.receipt_long_outlined,
                              size: 12, color: Colors.grey.shade600),
                          const SizedBox(width: 4),
                          Text(
                            'SO/Inv ${stop.soInvoiceNumber}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade700,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          'Rs ${stop.amount}',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: stop.paymentType == PaymentType.cash
                                ? AppColors.successLight
                                : AppColors.warningLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            stop.paymentType.label.toUpperCase(),
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: stop.paymentType == PaymentType.cash
                                  ? AppColors.successDark
                                  : AppColors.warningDark,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _statusChip(stop.status),
                  if (stop.status != DeliveryStopStatus.pending &&
                      stop.verification !=
                          DeliveryStopVerification.verified &&
                      stop.verification !=
                          DeliveryStopVerification.pending) ...[
                    const SizedBox(height: 4),
                    _verificationChip(stop.verification,
                        stop.distanceMeters),
                  ],
                  // Coordinates of the actual drop-off location —
                  // where the driver was standing when they marked
                  // the stop. Shown on settled stops that have a GPS
                  // fix. Tap to copy, long-press to open in Maps.
                  if (stop.status != DeliveryStopStatus.pending &&
                      stop.capturedLat != null &&
                      stop.capturedLng != null) ...[
                    const SizedBox(height: 4),
                    _CoordsButton(
                      lat: stop.capturedLat!,
                      lng: stop.capturedLng!,
                    ),
                  ],
                ],
              ),
            ],
          ),
          if (delivered && stop.cashReceived != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.successLight,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.payments,
                      size: 14, color: AppColors.successDark),
                  const SizedBox(width: 6),
                  Text(
                    'Collected Rs ${stop.cashReceived}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.successDark,
                    ),
                  ),
                  if (stop.paymentType == PaymentType.cash &&
                      stop.cashReceived != stop.amount) ...[
                    const SizedBox(width: 6),
                    Text(
                      '(short by Rs ${stop.amount - stop.cashReceived!})',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.danger,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (failed && stop.failureReason != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.danger.withOpacity(0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      size: 14, color: AppColors.danger),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      stop.failureReason!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // PoD photo thumbnails — shown on any settled stop that has
          // photos. Tap a thumbnail to view full-screen.
          if (!pending && stop.photoPaths.isNotEmpty) ...[
            const SizedBox(height: 10),
            _SettledPhotoStrip(paths: stop.photoPaths),
          ],
          if (pending && canAct) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onMarkFailed,
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Mark failed'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: onMarkDelivered,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Mark delivered'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusChip(DeliveryStopStatus s) {
    Color color;
    switch (s) {
      case DeliveryStopStatus.pending:
        color = AppColors.textTertiaryLight;
        break;
      case DeliveryStopStatus.delivered:
        color = AppColors.success;
        break;
      case DeliveryStopStatus.failed:
        color = AppColors.danger;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        s.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  /// Verification chip shown below the status chip for stops that were
  /// marked outside the geofence or without a GPS fix. Never shown for
  /// verified stops — we don't want to clutter the happy path.
  ///
  /// For `outside`, includes the distance (rounded to the nearest
  /// meaningful unit — e.g. "420m" or "2.4km") so the driver/admin
  /// can immediately see how far off the mark was.
  Widget _verificationChip(
      DeliveryStopVerification v, int? distanceMeters) {
    Color color;
    IconData icon;
    String label;
    switch (v) {
      case DeliveryStopVerification.outside:
        color = AppColors.warningDark;
        icon = Icons.location_searching;
        final dist = distanceMeters;
        if (dist == null) {
          label = 'OUTSIDE';
        } else if (dist >= 1000) {
          label = 'OUTSIDE · ${(dist / 1000).toStringAsFixed(1)}km';
        } else {
          label = 'OUTSIDE · ${dist}m';
        }
        break;
      case DeliveryStopVerification.noLocation:
        color = AppColors.textSecondaryLight;
        icon = Icons.location_off;
        label = 'NO GPS';
        break;
      case DeliveryStopVerification.verified:
      case DeliveryStopVerification.pending:
        // Shouldn't be rendered; parent guards.
        return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeliveredResult {
  /// Null for credit stops (no cash was collected).
  final int? cashReceived;
  final List<String> photoPaths;
  const _DeliveredResult({
    required this.cashReceived,
    this.photoPaths = const [],
  });
}

class _FailedResult {
  final String reason;
  final List<String> photoPaths;
  const _FailedResult({required this.reason, this.photoPaths = const []});
}

class _MarkDeliveredSheet extends ConsumerStatefulWidget {
  final DeliveryStop stop;
  final String deliveryId;
  const _MarkDeliveredSheet({
    required this.stop,
    required this.deliveryId,
  });

  @override
  ConsumerState<_MarkDeliveredSheet> createState() =>
      _MarkDeliveredSheetState();
}

class _MarkDeliveredSheetState extends ConsumerState<_MarkDeliveredSheet> {
  late final TextEditingController _cashCtrl;
  final List<String> _photoPaths = [];

  @override
  void initState() {
    super.initState();
    _cashCtrl = TextEditingController(
      text: widget.stop.amount.toString(),
    );
  }

  @override
  void dispose() {
    _cashCtrl.dispose();
    super.dispose();
  }

  Future<void> _addPhoto() async {
    try {
      final svc = ref.read(deliveryPhotoCaptureServiceProvider);
      final path = await svc.capture(
        deliveryId: widget.deliveryId,
        stopId: widget.stop.id,
      );
      if (path != null && mounted) {
        setState(() => _photoPaths.add(path));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCredit = widget.stop.paymentType == PaymentType.credit;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Mark delivered',
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                widget.stop.customerName,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 20),
              if (isCredit)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.warningLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.credit_score_outlined,
                          size: 18, color: AppColors.warningDark),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Credit delivery — no cash collected at drop. Customer is on account.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.warningDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                const Text(
                  'CASH RECEIVED',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _cashCtrl,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: InputDecoration(
                    prefixText: 'Rs ',
                    hintText: '${widget.stop.amount}',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Dispatched amount: Rs ${widget.stop.amount}. Edit if the '
                  'customer paid a different amount.',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              // PoD photo strip — optional but encouraged.
              const Text(
                'PROOF OF DELIVERY (OPTIONAL)',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 8),
              _PhotoStrip(
                paths: _photoPaths,
                onAdd: _addPhoto,
                onRemove: (i) =>
                    setState(() => _photoPaths.removeAt(i)),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 46)),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () {
                        int? cash;
                        if (!isCredit) {
                          cash = int.tryParse(_cashCtrl.text.trim());
                          if (cash == null || cash < 0) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Enter a valid cash amount (0 or more).'),
                              ),
                            );
                            return;
                          }
                        }
                        Navigator.of(context).pop(
                          _DeliveredResult(
                            cashReceived: cash,
                            photoPaths: List.unmodifiable(_photoPaths),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        backgroundColor: AppColors.success,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Confirm delivered'),
                    ),
                  ),
                ],
              ),
            ],
          ),    // Column
        ),      // Padding
      ),        // SafeArea
    );          // AnimatedPadding
  }
}

class _MarkFailedSheet extends ConsumerStatefulWidget {
  final DeliveryStop stop;
  final String deliveryId;
  const _MarkFailedSheet({
    required this.stop,
    required this.deliveryId,
  });

  @override
  ConsumerState<_MarkFailedSheet> createState() => _MarkFailedSheetState();
}

class _MarkFailedSheetState extends ConsumerState<_MarkFailedSheet> {
  static const _reasons = [
    'Customer not available',
    'Refused delivery',
    'Wrong address',
    'Shop closed',
    'Payment not ready',
    'Vehicle issue',
    'Other',
  ];

  String? _selected;
  final TextEditingController _otherCtrl = TextEditingController();
  final List<String> _photoPaths = [];

  @override
  void dispose() {
    _otherCtrl.dispose();
    super.dispose();
  }

  Future<void> _addPhoto() async {
    try {
      final svc = ref.read(deliveryPhotoCaptureServiceProvider);
      final path = await svc.capture(
        deliveryId: widget.deliveryId,
        stopId: widget.stop.id,
      );
      if (path != null && mounted) {
        setState(() => _photoPaths.add(path));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          controller: scrollCtrl,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Mark failed',
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Reason (required)',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 16),
              for (final r in _reasons)
                RadioListTile<String>(
                  value: r,
                  groupValue: _selected,
                  onChanged: (v) => setState(() => _selected = v),
                  title: Text(r, style: const TextStyle(fontSize: 14)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              if (_selected == 'Other') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _otherCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Describe what happened',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  maxLines: 2,
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                'PHOTOS (OPTIONAL)',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 8),
              _PhotoStrip(
                paths: _photoPaths,
                onAdd: _addPhoto,
                onRemove: (i) => setState(() => _photoPaths.removeAt(i)),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 46)),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () {
                        if (_selected == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Pick a reason.'),
                            ),
                          );
                          return;
                        }
                        String finalReason = _selected!;
                        if (_selected == 'Other') {
                          final note = _otherCtrl.text.trim();
                          if (note.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content:
                                    Text('Describe what happened.'),
                              ),
                            );
                            return;
                          }
                          finalReason = 'Other: $note';
                        }
                        Navigator.of(context).pop(
                          _FailedResult(
                            reason: finalReason,
                            photoPaths: List.unmodifiable(_photoPaths),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        backgroundColor: AppColors.danger,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Confirm failed'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact coordinates chip for settled stops. Shows lat/lng truncated
/// to 5 decimal places (~1m precision — more than enough for PoD).
///
/// Tap  → copies "lat, lng" to clipboard + shows a brief snackbar.
/// Long-press → opens Google Maps at the captured location.
class _CoordsButton extends StatelessWidget {
  final double lat;
  final double lng;
  const _CoordsButton({required this.lat, required this.lng});

  String get _formatted =>
      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _formatted));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Coordinates copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _openMaps(BuildContext context) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
    );
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open maps.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _copy(context),
      onLongPress: () => _openMaps(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: AppColors.primary.withOpacity(0.25),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.my_location,
              size: 9,
              color: AppColors.primary,
            ),
            const SizedBox(width: 3),
            Text(
              _formatted,
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Read-only photo thumbnail strip for settled stops.
/// Tap any thumbnail to open a full-screen viewer.
class _SettledPhotoStrip extends StatelessWidget {
  final List<String> paths;
  const _SettledPhotoStrip({required this.paths});

  static const _size = 64.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _size,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: paths.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          return GestureDetector(
            onTap: () => _viewFull(context, i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: PhotoUrl.isRemote(paths[i])
                  ? Image.network(
                      PhotoUrl.build(paths[i]),
                      width: _size,
                      height: _size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: _size,
                        height: _size,
                        color: AppColors.borderLight,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined,
                            size: 20, color: AppColors.textTertiaryLight),
                      ),
                    )
                  : Image.file(
                      File(paths[i]),
                      width: _size,
                      height: _size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: _size,
                        height: _size,
                        color: AppColors.borderLight,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined,
                            size: 20, color: AppColors.textTertiaryLight),
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }

  void _viewFull(BuildContext context, int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _PhotoViewer(
          paths: paths,
          initialIndex: initialIndex,
        ),
      ),
    );
  }
}

/// Full-screen swipeable photo viewer. Shown when the driver or admin
/// taps a thumbnail on a settled stop.
class _PhotoViewer extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  const _PhotoViewer({required this.paths, required this.initialIndex});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _ctrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _ctrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_current + 1} / ${widget.paths.length}',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PageView.builder(
        controller: _ctrl,
        onPageChanged: (i) => setState(() => _current = i),
        itemCount: widget.paths.length,
        itemBuilder: (_, i) => InteractiveViewer(
          child: Center(
            child: PhotoUrl.isRemote(widget.paths[i])
                ? Image.network(
                    PhotoUrl.build(widget.paths[i]),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          size: 48, color: Colors.white54),
                    ),
                  )
                : Image.file(
                    File(widget.paths[i]),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          size: 48, color: Colors.white54),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
/// Max 3 photos — enough for PoD without overwhelming the UI.
class _PhotoStrip extends StatelessWidget {
  final List<String> paths;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  const _PhotoStrip({
    required this.paths,
    required this.onAdd,
    required this.onRemove,
  });

  static const _maxPhotos = 3;
  static const _size = 72.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _size,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          if (paths.length < _maxPhotos)
            GestureDetector(
              onTap: onAdd,
              child: Container(
                width: _size,
                height: _size,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.primary.withOpacity(0.4),
                    width: 1.5,
                  ),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined,
                        size: 22, color: AppColors.primary),
                    SizedBox(height: 4),
                    Text(
                      'Add photo',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          for (int i = 0; i < paths.length; i++)
            Stack(
              children: [
                Container(
                  width: _size,
                  height: _size,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    image: DecorationImage(
                      image: FileImage(File(paths[i])),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 10,
                  child: GestureDetector(
                    onTap: () => onRemove(i),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close,
                          size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
