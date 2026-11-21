import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/services/device_gps_service.dart';
import '../../../core/services/sound_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/slide_to_confirm.dart';
import '../../audit/data/audit_repository.dart';
import '../../auth/providers/auth_controller.dart';
import '../../dispatch/data/delivery_repository.dart';
import '../../dispatch/models/delivery.dart';
import '../../reports/services/nominatim_client.dart';
import '../../salesperson/presentation/widgets/free_visit_buttons.dart';
import '../../salesperson/services/free_visit_photo_service.dart';
import '../../uploads/data/upload_queue_repository.dart';

/// A driver's free route: he marks the places he goes to as he goes — each with a picture taken
/// there, stamped with the coordinates — and ends the route when he is done. It is a job of his own
/// (job type "free"), so its report is the driver's Delivery Report with the start, the visits, the
/// distance of every leg and the way back.
class DriverFreeRouteScreen extends ConsumerStatefulWidget {
  const DriverFreeRouteScreen({super.key, required this.deliveryId});

  final String deliveryId;

  @override
  ConsumerState<DriverFreeRouteScreen> createState() => _DriverFreeRouteScreenState();
}

class _DriverFreeRouteScreenState extends ConsumerState<DriverFreeRouteScreen> {
  Delivery? _d;
  bool _loading = true;
  String? _loadError; // the route could not be read: a message and Retry instead of an endless spinner
  String _step = ''; // what Mark visit is doing now
  bool _marking = false;
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    Delivery? d;
    try {
      d = await ref.read(deliveryRepositoryProvider).byId(widget.deliveryId).timeout(const Duration(seconds: 15));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_d == null) _loadError = 'This route could not be opened. Please try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _d = d;
      _loading = false;
      _loadError = null;
    });
    // Already ended (e.g. opened again from the list): show its report screen instead.
    if (d != null && d.status != DeliveryStatus.inProgress) {
      context.pushReplacement('/driver/delivery/${d.id}');
    }
  }

  void _say(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _quietly(Future<void> f) {
    f.catchError((_) {});
  }

  /// Mark visit: the phone's GPS point, with the picture taken there.
  Future<void> _markVisit() async {
    final d = _d;
    if (_marking || d == null) return;
    setState(() {
      _marking = true;
      _step = 'Getting your location...';
    });
    try {
      final gate = await ref.read(deviceGpsServiceProvider).getFixMandatory();
      if (!mounted) return;
      switch (gate.outcome) {
        case GpsOutcome.serviceDisabled:
          _say('Turn on your device location (GPS) to mark a visit, then try again.');
          return;
        case GpsOutcome.permissionBlocked:
          _say('Location permission is blocked. Enable it for Opstation in your phone Settings, then try again.');
          return;
        case GpsOutcome.permissionDenied:
          _say('Location permission is required to mark a visit. Please allow it and try again.');
          return;
        default:
          break;
      }
      final fix = gate.fix;
      if (fix == null) {
        _say('GPS is not responding, so the visit was not saved. Step outside or near a window for a few seconds, then try again.');
        return;
      }
      // The camera opens first. Closing it without a picture marks nothing; a camera that cannot be
      // opened still marks the visit (without a picture).
      setState(() => _step = 'Opening the camera...');
      final shot = await ref.read(freeVisitPhotoServiceProvider).shoot(lat: fix.lat, lng: fix.lng);
      if (!mounted) return;
      if (shot.result == FreeVisitShotResult.cancelled) {
        _say('Visit not marked. Take the picture to mark the visit.');
        return;
      }
      setState(() => _step = 'Saving the visit...');
      final repo = ref.read(deliveryRepositoryProvider);
      final user = ref.read(authControllerProvider).valueOrNull;
      final stopNumber = d.stops.length + 1;
      String? remote;
      if (shot.path != null) {
        remote = freeRoutePhotoRemotePath(
            deliveryId: d.id, driverName: user?.name ?? d.driverName ?? 'driver', stopNumber: stopNumber, at: DateTime.now());
        try {
          // Queued first: the visit only points at the picture once it is queued.
          await ref.read(uploadQueueRepositoryProvider).enqueue(
                localPath: shot.path!,
                remotePath: remote,
                bucket: 'opstation-photos',
                entityType: 'delivery_stop',
                entityId: '${d.id}#visit$stopNumber',
              );
        } catch (_) {
          remote = null;
        }
      }
      final stop = await repo
          .addFreeVisit(
            deliveryId: d.id,
            lat: fix.lat,
            lng: fix.lng,
            accuracy: fix.accuracy,
            photoRemotePath: remote,
          )
          .timeout(const Duration(seconds: 20), onTimeout: () => throw StateError('The phone took too long to save the visit. Please try again.'));
      ref.read(soundControllerProvider.notifier).play(AppSound.visitMarked);
      _say(shot.path == null
          ? 'Visit $stopNumber marked (the camera could not be opened, so no picture)'
          : 'Visit $stopNumber marked with a photo \u2713');
      await _reload();
      // The place name, without keeping the driver waiting.
      final nomi = ref.read(nominatimClientProvider);
      _quietly(() async {
        final name = await nomi.reverseGeocode(fix.lat, fix.lng);
        if (name != null && name.trim().isNotEmpty) {
          await repo.renameStop(stop.id, name);
          if (mounted) await _reload();
        }
      }());
    } catch (e) {
      _say('Could not mark the visit: ${'$e'.replaceFirst('Bad state: ', '')}');
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  /// Slide to end: the point the driver is at is the return location.
  Future<void> _end() async {
    final d = _d;
    if (d == null || _ending) return;
    if (d.stops.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('End the free route with no visits?'),
          content: const Text('You have not marked any visit on this route.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep going')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End it')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _ending = true);
    try {
      final repo = ref.read(deliveryRepositoryProvider);
      final gps = ref.read(deviceGpsServiceProvider);
      final quick = await gps.getQuickFix(); // the return location, without waiting
      await repo.endDelivery(deliveryId: d.id, lat: quick?.lat, lng: quick?.lng, accuracy: quick?.accuracy);
      _quietly(ref.read(auditLoggerProvider).deliveryCompleted(deliveryId: d.id, early: false));
      ref.read(soundControllerProvider.notifier).play(AppSound.routeEnd);
      if (quick == null) {
        _quietly(() async {
          final fix = await gps.getFix(timeout: const Duration(seconds: 20));
          if (fix != null) await repo.recordEnd(d.id, lat: fix.lat, lng: fix.lng, accuracy: fix.accuracy);
        }());
      }
      if (!mounted) return;
      context.pushReplacement('/driver/delivery/${d.id}'); // the finished route, with its report
    } catch (e) {
      _say('$e'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _ending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Free route', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? Center(
                  child: _loadError == null
                      ? const Text('This route was not found.')
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_loadError!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _loading = true;
                                _loadError = null;
                              });
                              _reload();
                            },
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Try again'),
                          ),
                        ]),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: AppColors.primaryLight.withOpacity(0.6), borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        const Icon(Icons.add_road, color: AppColors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${d.stops.length} visit${d.stops.length == 1 ? '' : 's'} marked',
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                            if (d.startedAt != null)
                              Text('Started ${DateFormat('hh:mm a').format(d.startedAt!)}',
                                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
                          ]),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    const Text('VISITS',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.0, color: AppColors.textSecondaryLight)),
                    const SizedBox(height: 8),
                    if (d.stops.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text('Tap Mark visit at each place you reach.\nIt takes a picture and marks the visit here.',
                              textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondaryLight)),
                        ),
                      )
                    else
                      for (final s in d.stops)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                              radius: 16,
                              backgroundColor: AppColors.success,
                              child: Text('${s.sequence + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                            ),
                            title: Text(s.customerName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(s.deliveredAt == null ? '' : DateFormat('hh:mm a').format(s.deliveredAt!)),
                            trailing: s.photoPaths.isNotEmpty
                                ? const Icon(Icons.photo_camera_outlined, size: 18, color: AppColors.success)
                                : null,
                          ),
                        ),
                  ],
                ),
      bottomNavigationBar: (d == null || d.status != DeliveryStatus.inProgress)
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  FreeVisitButton(busy: _marking, step: _step, onPressed: _markVisit),
                  const SizedBox(height: 8),
                  SlideToConfirm(
                    key: const ValueKey('slide-end-free'),
                    label: _ending ? 'Ending...' : 'Slide to end free route',
                    icon: Icons.flag_outlined,
                    color: AppColors.success,
                    onConfirmed: _end,
                    disabled: _ending || _marking,
                  ),
                ]),
              ),
            ),
    );
  }
}
