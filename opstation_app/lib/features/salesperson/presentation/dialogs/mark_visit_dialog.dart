import 'dart:io';

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDeviceFix());
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _crCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshDeviceFix() async {
    if (_fetchingDeviceFix) return;
    setState(() {
      _fetchingDeviceFix = true;
      _deviceFix = null;
    });
    final gps = ref.read(deviceGpsServiceProvider);
    final fix = await gps.getFix();
    if (!mounted) return;
    setState(() {
      _deviceFix = fix == null
          ? const SimulatedFix.unavailable()
          : SimulatedFix(lat: fix.lat, lng: fix.lng, accuracyMeters: fix.accuracy);
      _fetchingDeviceFix = false;
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
    final accuracyWarn = tripState?.accuracyWarnThresholdMeters ?? 50;
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
                        _GpsBanner(
                          fix: fix, distance: distance,
                          hasLocation: hasLocation, radius: radius, accuracyWarn: accuracyWarn,
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

class _GpsBanner extends StatelessWidget {
  final SimulatedFix fix;
  final double? distance;
  final bool hasLocation;
  final double radius;
  final double accuracyWarn;

  const _GpsBanner({
    required this.fix, required this.distance,
    required this.hasLocation, required this.radius, required this.accuracyWarn,
  });

  @override
  Widget build(BuildContext context) {
    if (!fix.available) {
      return _box(AppColors.dangerLight, AppColors.dangerDark, Icons.gps_off,
          'GPS unavailable — visit will be marked No Location');
    }
    if (!hasLocation) {
      return _box(AppColors.warningLight, AppColors.warningDark, Icons.location_off_outlined,
          'Customer has no saved location — visit will be marked No Location');
    }
    final acc = fix.accuracyMeters ?? 0;
    final accBad = acc > accuracyWarn;
    final outside = distance != null && distance! > radius;
    return Column(children: [
      _box(
        accBad ? AppColors.warningLight : AppColors.successLight,
        accBad ? AppColors.warningDark : AppColors.successDark,
        Icons.gps_fixed,
        accBad ? 'GPS captured (±${acc.round()}m — weak signal)'
               : 'GPS captured (±${acc.round()}m — good signal)',
      ),
      if (outside) ...[
        const SizedBox(height: 8),
        _box(AppColors.dangerLight, AppColors.dangerDark, Icons.warning_amber_outlined,
            '${GeoUtils.formatDistance(distance!)} from customer — outside ${radius.round()}m range'),
      ],
      const SizedBox(height: 8),
      _AccuracyBar(accuracy: acc, warn: accuracyWarn),
    ]);
  }

  Widget _box(Color bg, Color fg, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(icon, color: fg, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text,
            style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w500))),
      ]),
    );
  }
}

class _DistanceRow extends StatelessWidget {
  final double distance;
  final double radius;
  const _DistanceRow({required this.distance, required this.radius});

  @override
  Widget build(BuildContext context) {
    final inRange = distance <= radius;
    final color = inRange ? AppColors.success : AppColors.danger;
    final ratio = (distance / (radius * 2)).clamp(0.0, 1.0);
    return Row(children: [
      const Text('Distance:',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
      const SizedBox(width: 8),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            backgroundColor: AppColors.borderLight,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text(GeoUtils.formatDistance(distance),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    ]);
  }
}

class _AccuracyBar extends StatelessWidget {
  final double accuracy;
  final double warn;
  const _AccuracyBar({required this.accuracy, required this.warn});

  @override
  Widget build(BuildContext context) {
    final ratio = (accuracy / (warn * 2)).clamp(0.0, 1.0);
    final good = accuracy <= warn;
    return Row(children: [
      const Text('GPS accuracy:',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
      const SizedBox(width: 8),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: 1 - ratio, minHeight: 6,
            backgroundColor: AppColors.borderLight,
            valueColor: AlwaysStoppedAnimation(good ? AppColors.success : AppColors.warningDark),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text('±${accuracy.round()}m',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: good ? AppColors.success : AppColors.warningDark)),
    ]);
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
