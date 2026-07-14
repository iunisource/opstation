import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/services/device_gps_service.dart';
import '../../../../core/services/sound_controller.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/geo_utils.dart';
import '../../models/customer.dart';
import '../../providers/mock_gps_service.dart';
import '../../providers/trip_controller.dart';

class MarkVisitDialog extends ConsumerStatefulWidget {
  final Customer customer;
  const MarkVisitDialog({super.key, required this.customer});

  @override
  ConsumerState<MarkVisitDialog> createState() => _MarkVisitDialogState();
}

class _MarkVisitDialogState extends ConsumerState<MarkVisitDialog> {
  final _amountCtrl = TextEditingController();
  final _crCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final List<String> _photos = [];

  bool _submitting = false;
  String? _errorText;

  SimulatedFix? _deviceFix;
  bool _fetchingDeviceFix = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refreshDeviceFix();
      _startGpsPolling();
    });
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _crCtrl.dispose();
    _notesCtrl.dispose();
    _gpsPoll?.cancel();
    super.dispose();
  }

  Timer? _gpsPoll;

  /// A GPS fix arrives coarse and sharpens over several seconds — the first
  /// reading indoors can be 100m+ wide, which is why reps standing inside a shop
  /// were being marked "outside range". A single shot at dialog-open captured
  /// that first bad fix and kept it. So poll: every 2s we take a fresh fix and
  /// keep the BEST one seen, and the health bar shows the rep whether to wait a
  /// moment or go ahead. Polling stops once the fix is good enough to be useless
  /// to improve further, or when the sheet closes.
  Future<void> _refreshDeviceFix({bool silent = false}) async {
    if (_fetchingDeviceFix) return;
    if (!silent) {
      setState(() {
        _fetchingDeviceFix = true;
        _deviceFix = null;
      });
    } else {
      _fetchingDeviceFix = true;
    }
    final gps = ref.read(deviceGpsServiceProvider);
    final fix = await gps.getFix();
    if (!mounted) return;
    setState(() {
      final next = fix == null
          ? const SimulatedFix.unavailable()
          : SimulatedFix(lat: fix.lat, lng: fix.lng, accuracyMeters: fix.accuracy);
      // Keep whichever fix is tighter — a later reading is not automatically
      // a better one.
      final cur = _deviceFix;
      final curAcc = (cur != null && cur.available) ? (cur.accuracyMeters ?? 9999) : 9999;
      final nextAcc = next.available ? (next.accuracyMeters ?? 9999) : 9999;
      _deviceFix = (cur == null || !cur.available || nextAcc < curAcc) ? next : cur;
      _fetchingDeviceFix = false;
    });
  }

  void _startGpsPolling() {
    _gpsPoll?.cancel();
    _gpsPoll = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!mounted) { t.cancel(); return; }
      final f = _deviceFix;
      final acc = (f != null && f.available) ? (f.accuracyMeters ?? 9999) : 9999;
      // Good enough — no point burning battery chasing decimetres.
      if (acc <= 15) { t.cancel(); return; }
      if (t.tick > 20) { t.cancel(); return; }   // give up after ~40s
      await _refreshDeviceFix(silent: true);
    });
  }

  SimulatedFix get _currentFix => _deviceFix ?? const SimulatedFix.unavailable();

  double? get _distance {
    final fix = _currentFix;
    if (!fix.available || fix.lat == null || fix.lng == null || !widget.customer.hasLocation) {
      return null;
    }
    return GeoUtils.distanceMeters(
      widget.customer.latitude!, widget.customer.longitude!,
      fix.lat!, fix.lng!,
    );
  }

  Future<void> _pickPhoto() async {
    if (_photos.length >= 5) return;
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
        maxWidth: 1920,
      );
      if (picked != null && mounted) {
        setState(() => _photos.add(picked.path));
      }
    } catch (e) {
      if (mounted) setState(() => _errorText = 'Could not open camera. Check permissions.');
    }
  }

  Future<void> _submit() async {
    final amountText = _amountCtrl.text.trim();
    final amount = amountText.isEmpty ? 0 : (int.tryParse(amountText) ?? -1);
    if (amount < 0) { setState(() => _errorText = 'Amount must be a valid number.'); return; }
    if (amount > 0 && _crCtrl.text.trim().isEmpty) {
      setState(() => _errorText = 'Receipt number is required when amount > 0.');
      return;
    }
    setState(() { _submitting = true; _errorText = null; });
    final fix = _currentFix;
    try {
      await ref.read(tripControllerProvider.notifier).markVisit(
        customer: widget.customer,
        capturedLat: fix.lat,
        capturedLng: fix.lng,
        accuracyMeters: fix.accuracyMeters,
        amount: amount,
        receiptNumber: _crCtrl.text.trim().isEmpty ? null : _crCtrl.text.trim(),
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        photoPaths: List.unmodifiable(_photos),
      );
      ref.read(soundControllerProvider.notifier).play(AppSound.visitMarked);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _errorText = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fix = _currentFix;
    final distance = _distance;
    final tripState = ref.watch(tripControllerProvider).valueOrNull;
    final radius = tripState?.geofenceRadiusMeters ?? 100;
    final inRange = distance != null && distance <= radius;
    final hasLocation = widget.customer.hasLocation;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: DraggableScrollableSheet(
          initialChildSize: 0.95,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.primaryLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.location_on_outlined, color: AppColors.primary),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Mark visit',
                                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                                Text(widget.customer.shopName,
                                    style: TextStyle(
                                      color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
                                    ),
                                    overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: _fetchingDeviceFix ? null : _refreshDeviceFix,
                            icon: _fetchingDeviceFix
                                ? const SizedBox(width: 18, height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.my_location, color: AppColors.primary),
                            tooltip: 'Refresh GPS',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // GPS Banner
                      if (_fetchingDeviceFix)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.primaryLight,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(children: [
                            SizedBox(width: 14, height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2)),
                            SizedBox(width: 10),
                            Text('Fetching GPS location...',
                                style: TextStyle(color: AppColors.primaryDark,
                                    fontSize: 13, fontWeight: FontWeight.w500)),
                          ]),
                        )
                      else
                        _LocationHealthBar(
                          fix: fix,
                          distance: distance,
                          radius: radius,
                          searching: _fetchingDeviceFix || (_gpsPoll?.isActive ?? false),
                          onRetry: _refreshDeviceFix,
                        ),
                      const SizedBox(height: 16),

                      // Amount
                      TextField(
                        controller: _amountCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                          hintText: 'Collection amount (Rs)',
                          prefixIcon: Icon(Icons.payments_outlined),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _crCtrl,
                        decoration: const InputDecoration(
                          hintText: 'CR# (required when amount > 0)',
                          prefixIcon: Icon(Icons.receipt_long_outlined),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _notesCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          hintText: 'Notes (optional)',
                          prefixIcon: Icon(Icons.notes),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Photos
                      Row(children: [
                        const Icon(Icons.photo_camera_outlined,
                            size: 16, color: AppColors.textSecondaryLight),
                        const SizedBox(width: 6),
                        Text('Photos (optional) ${_photos.length}/5',
                            style: const TextStyle(
                                color: AppColors.textSecondaryLight, fontSize: 13)),
                      ]),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10, runSpacing: 10,
                        children: [
                          for (int i = 0; i < _photos.length; i++)
                            _PhotoThumb(
                              path: _photos[i],
                              onRemove: () => setState(() => _photos.removeAt(i)),
                            ),
                          if (_photos.length < 5)
                            _AddPhotoTile(onTap: _pickPhoto),
                        ],
                      ),
                      const SizedBox(height: 20),

                      if (_errorText != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.dangerLight,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(children: [
                            const Icon(Icons.error_outline, color: AppColors.dangerDark, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_errorText!,
                                style: const TextStyle(color: AppColors.dangerDark, fontSize: 13))),
                          ]),
                        ),
                        const SizedBox(height: 12),
                      ],

                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: _submitting ? null : _submit,
                            icon: _submitting
                                ? const SizedBox(width: 16, height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.check_circle_outline, size: 18),
                            label: const Text('Mark visit'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: inRange && hasLocation
                                  ? AppColors.primary : AppColors.warningDark,
                            ),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final String path;
  final VoidCallback onRemove;
  const _PhotoThumb({required this.path, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Container(
        width: 64, height: 64,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.hardEdge,
        child: Image.file(File(path), fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: AppColors.primaryLight,
              child: const Icon(Icons.image, color: AppColors.primary),
            )),
      ),
      Positioned(
        top: -4, right: -4,
        child: InkWell(
          onTap: onRemove,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(color: AppColors.dangerDark, shape: BoxShape.circle),
            child: const Icon(Icons.close, size: 12, color: Colors.white),
          ),
        ),
      ),
    ]);
  }
}

class _AddPhotoTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AddPhotoTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 64, height: 64,
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.primary.withOpacity(0.3)),
        ),
        alignment: Alignment.center,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo_outlined, color: AppColors.primary, size: 20),
            SizedBox(height: 2),
            Text('Add', style: TextStyle(color: AppColors.primary,
                fontSize: 10, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// Live GPS quality, so a rep knows whether to wait two seconds or go ahead.
///
/// Marking is never blocked — the rep is standing in the shop and knows it. But
/// a fix that is still 90m wide will record the visit as "outside range" through
/// no fault of theirs, and today they had no way to see that coming. This shows
/// the accuracy sharpening in real time, exactly like WhatsApp's location screen.
class _LocationHealthBar extends StatelessWidget {
  final SimulatedFix fix;
  final double? distance;
  final double radius;
  final bool searching;
  final VoidCallback onRetry;

  const _LocationHealthBar({
    required this.fix,
    required this.distance,
    required this.radius,
    required this.searching,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final acc = fix.available ? fix.accuracyMeters : null;

    // Bands chosen against the geofence, not in the abstract: a 100m fence with a
    // 90m error is a coin toss, which is precisely the failure the reps hit.
    final Color tone;
    final String label;
    final double bar;
    if (acc == null) {
      tone = AppColors.textSecondaryLight;
      label = searching ? 'Finding your location…' : 'Location unavailable';
      bar = 0.08;
    } else if (acc <= 20) {
      tone = AppColors.success;
      label = 'Strong signal — ready';
      bar = 1.0;
    } else if (acc <= 50) {
      tone = AppColors.warningDark;
      label = searching ? 'Improving… you can wait a moment' : 'Fair signal';
      bar = 0.6;
    } else {
      tone = AppColors.dangerDark;
      label = searching ? 'Weak — waiting for a better fix…' : 'Weak signal';
      bar = 0.28;
    }

    final inRange = distance != null && distance! <= radius;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: 0.30)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (searching)
            SizedBox(
              width: 13, height: 13,
              child: CircularProgressIndicator(strokeWidth: 2, color: tone),
            )
          else
            Icon(
              acc == null ? Icons.location_disabled
                : acc <= 20 ? Icons.gps_fixed
                : Icons.gps_not_fixed,
              size: 15, color: tone,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: tone)),
          ),
          if (acc != null)
            Text('±${acc.round()} m',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: tone)),
          if (!searching)
            InkWell(
              onTap: onRetry,
              child: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.refresh, size: 16, color: AppColors.textSecondaryLight),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: bar),
            duration: const Duration(milliseconds: 400),
            builder: (_, v, __) => LinearProgressIndicator(
              value: v,
              minHeight: 5,
              backgroundColor: AppColors.borderLight,
              valueColor: AlwaysStoppedAnimation(tone),
            ),
          ),
        ),
        if (distance != null) ...[
          const SizedBox(height: 7),
          Row(children: [
            Icon(inRange ? Icons.check_circle : Icons.error_outline,
                size: 13,
                color: inRange ? AppColors.success : AppColors.warningDark),
            const SizedBox(width: 5),
            Text(
              inRange
                  ? '${distance!.round()} m from the shop — inside the ${radius.round()} m fence'
                  : '${distance!.round()} m from the shop — outside the ${radius.round()} m fence',
              style: TextStyle(
                fontSize: 11.5,
                color: inRange ? AppColors.success : AppColors.warningDark,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}
