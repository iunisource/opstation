import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../audit/data/audit_repository.dart';
import '../../auth/providers/auth_controller.dart';
import '../data/delivery_repository.dart';
import '../models/delivery.dart';
import '../pdf/delivery_pdf_builder.dart';

/// Read + act screen for an existing delivery.
///
/// Actions depend on status:
///   draft       -> Edit, Assign (if driver set), Delete
///   assigned    -> Edit, Unassign (back to draft), Cancel
///   in_progress -> Cancel
///   completed   -> (none)
///   cancelled   -> (none)
class DeliveryDetailScreen extends ConsumerStatefulWidget {
  final String deliveryId;
  const DeliveryDetailScreen({super.key, required this.deliveryId});

  @override
  ConsumerState<DeliveryDetailScreen> createState() =>
      _DeliveryDetailScreenState();
}

class _DeliveryDetailScreenState
    extends ConsumerState<DeliveryDetailScreen> {
  late Future<Delivery?> _future;
  bool _busy = false;
  Delivery? _delivery;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref
        .read(deliveryRepositoryProvider)
        .byId(widget.deliveryId)
        .then((d) {
      if (mounted) setState(() => _delivery = d);
      return d;
    });
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Delivery',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          if (_delivery != null)
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'Export PDF',
              onPressed: () => _exportPdf(_delivery!),
            ),
        ],
      ),
      body: FutureBuilder<Delivery?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final d = snap.data;
          if (d == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Delivery not found.'),
              ),
            );
          }
          return _buildBody(d);
        },
      ),
    );
  }

  Widget _buildBody(Delivery d) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusChip(d.status),
                const SizedBox(height: 14),
                _infoBlock(d),
                const SizedBox(height: 16),
                _totalsBox(d),
                const SizedBox(height: 20),
                const Text(
                  'STOPS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 8),
                for (int i = 0; i < d.stops.length; i++)
                  _stopRow(d.stops[i], i),
                if (d.notes != null && d.notes!.trim().isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const Text(
                    'NOTES',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: AppColors.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.borderLight.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(d.notes!, style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ],
            ),
          ),
        ),
        _actionBar(d),
      ],
    );
  }

  Widget _statusChip(DeliveryStatus s) {
    Color c;
    switch (s) {
      case DeliveryStatus.draft:
        c = AppColors.textTertiaryLight;
        break;
      case DeliveryStatus.assigned:
        c = AppColors.primary;
        break;
      case DeliveryStatus.inProgress:
        c = AppColors.warningDark;
        break;
      case DeliveryStatus.completed:
        c = AppColors.success;
        break;
      case DeliveryStatus.cancelled:
        c = AppColors.danger;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        s.label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: c,
        ),
      ),
    );
  }

  /// Small badge shown on settled stops that were marked outside the
  /// geofence or without a GPS fix. Mirrors the driver-side chip so
  /// admins and drivers see the same visual vocabulary. Never shown
  /// for verified or pending stops.
  Widget _verificationBadge(DeliveryStop s) {
    final isOutside = s.verification == DeliveryStopVerification.outside;
    final color = isOutside
        ? AppColors.warningDark
        : AppColors.textSecondaryLight;
    final icon = isOutside ? Icons.location_searching : Icons.location_off;
    String label;
    if (isOutside) {
      final dist = s.distanceMeters;
      if (dist == null) {
        label = 'OUTSIDE';
      } else if (dist >= 1000) {
        label = '${(dist / 1000).toStringAsFixed(1)}km';
      } else {
        label = '${dist}m';
      }
    } else {
      label = 'NO GPS';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 9, color: color),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoBlock(Delivery d) {
    final fmt = DateFormat('d MMM y · HH:mm');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow(Icons.person_outline, 'Driver',
            d.driverName ?? 'Not assigned'),
        const SizedBox(height: 8),
        _infoRow(Icons.person_add_alt_outlined, 'Created by',
            d.createdByName.isEmpty ? '—' : d.createdByName),
        const SizedBox(height: 8),
        _infoRow(Icons.calendar_today_outlined, 'Created',
            fmt.format(d.createdAt)),
        if (d.startedAt != null) ...[
          const SizedBox(height: 8),
          _infoRow(Icons.play_arrow_outlined, 'Started',
              fmt.format(d.startedAt!)),
        ],
        if (d.completedAt != null) ...[
          const SizedBox(height: 8),
          _infoRow(
              Icons.check_circle_outline, 'Completed', fmt.format(d.completedAt!)),
        ],
      ],
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondaryLight),
        const SizedBox(width: 10),
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondaryLight,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _totalsBox(Delivery d) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primaryLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(child: _cell('${d.stops.length}', 'STOPS')),
          Container(width: 1, height: 32, color: AppColors.borderLight),
          // Show only the cash total — that's the actionable figure for
          // the driver. Credit stops don't involve physical collection,
          // so totalling them here would suggest the driver is
          // responsible for that money, which they aren't. "Cash to
          // collect" phrases this unambiguously.
          Expanded(
              child: _cell('Rs ${d.cashAmount}', 'CASH TO COLLECT')),
        ],
      ),
    );
  }

  Widget _cell(String value, String label) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center),
        const SizedBox(height: 2),
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

  Widget _stopRow(DeliveryStop s, int i) {
    Color statusColor;
    switch (s.status) {
      case DeliveryStopStatus.pending:
        statusColor = AppColors.textTertiaryLight;
        break;
      case DeliveryStopStatus.delivered:
        statusColor = AppColors.success;
        break;
      case DeliveryStopStatus.failed:
        statusColor = AppColors.danger;
        break;
    }
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
          CircleAvatar(
            radius: 14,
            backgroundColor: AppColors.primaryLight,
            child: Text(
              '${i + 1}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
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
                  s.customerName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (s.customerCode.isNotEmpty) s.customerCode,
                    if (s.itemDescription.isNotEmpty) s.itemDescription,
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: s.paymentType == PaymentType.cash
                            ? AppColors.successLight
                            : AppColors.warningLight,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        s.paymentType.label,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: s.paymentType == PaymentType.cash
                              ? AppColors.successDark
                              : AppColors.warningDark,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Rs ${s.amount}',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        s.status.label,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: statusColor,
                        ),
                      ),
                    ),
                    if (s.status != DeliveryStopStatus.pending &&
                        (s.verification ==
                                DeliveryStopVerification.outside ||
                            s.verification ==
                                DeliveryStopVerification.noLocation)) ...[
                      const SizedBox(width: 4),
                      _verificationBadge(s),
                    ],
                  ],
                ),
                if (s.failureReason != null &&
                    s.failureReason!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Failure: ${s.failureReason!}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.danger,
                    ),
                  ),
                ],
                if (s.status != DeliveryStopStatus.pending &&
                    s.photoPaths.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _DispatchPhotoStrip(paths: s.photoPaths),
                ],
                if (s.status != DeliveryStopStatus.pending &&
                    s.capturedLat != null &&
                    s.capturedLng != null) ...[
                  const SizedBox(height: 6),
                  _DispatchCoordsRow(
                      lat: s.capturedLat!, lng: s.capturedLng!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar(Delivery d) {
    final actions = <Widget>[];
    switch (d.status) {
      case DeliveryStatus.draft:
        actions.add(_actionBtn(
          icon: Icons.edit_outlined,
          label: 'Edit',
          primary: false,
          onTap: () => _edit(d),
        ));
        actions.add(_actionBtn(
          icon: Icons.send_outlined,
          label: 'Assign',
          primary: true,
          onTap: d.driverId == null ? null : () => _assign(d),
        ));
        actions.add(_actionBtn(
          icon: Icons.delete_outline,
          label: 'Delete',
          primary: false,
          destructive: true,
          onTap: () => _delete(d),
        ));
        break;
      case DeliveryStatus.assigned:
        actions.add(_actionBtn(
          icon: Icons.edit_outlined,
          label: 'Edit',
          primary: false,
          onTap: () => _edit(d),
        ));
        actions.add(_actionBtn(
          icon: Icons.undo_outlined,
          label: 'Unassign',
          primary: false,
          onTap: () => _unassign(d),
        ));
        actions.add(_actionBtn(
          icon: Icons.cancel_outlined,
          label: 'Cancel',
          primary: false,
          destructive: true,
          onTap: () => _cancel(d),
        ));
        break;
      case DeliveryStatus.inProgress:
        actions.add(_actionBtn(
          icon: Icons.cancel_outlined,
          label: 'Cancel',
          primary: false,
          destructive: true,
          onTap: () => _cancel(d),
        ));
        break;
      case DeliveryStatus.completed:
      case DeliveryStatus.cancelled:
        return const SizedBox.shrink();
    }
    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        10 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: const Border(
          top: BorderSide(color: AppColors.borderLight, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          for (int i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: actions[i]),
          ],
        ],
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required bool primary,
    bool destructive = false,
    required VoidCallback? onTap,
  }) {
    final color = destructive ? AppColors.danger : null;
    if (primary) {
      return ElevatedButton.icon(
        onPressed: _busy ? null : onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
      );
    }
    return OutlinedButton.icon(
      onPressed: _busy ? null : onTap,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label,
          style: TextStyle(color: color)),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        side: destructive ? const BorderSide(color: AppColors.danger) : null,
      ),
    );
  }

  // ---- Actions -------------------------------------------------------

  Future<void> _edit(Delivery d) async {
    final result =
        await context.push<bool>('/dispatch/delivery/${d.id}/edit');
    if (result == true && mounted) setState(_reload);
  }

  Future<void> _assign(Delivery d) async {
    setState(() => _busy = true);
    try {
      await ref.read(deliveryRepositoryProvider).assign(d.id);
      await ref.read(auditLoggerProvider).deliveryAssigned(
            deliveryId: d.id,
            driverName: d.driverName ?? 'driver',
          );
      if (mounted) setState(_reload);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Assign failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unassign(Delivery d) async {
    setState(() => _busy = true);
    try {
      await ref.read(deliveryRepositoryProvider).unassign(d.id);
      await ref
          .read(auditLoggerProvider)
          .deliveryUnassigned(deliveryId: d.id);
      if (mounted) setState(_reload);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Unassign failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Delivery d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel delivery?'),
        content: const Text(
            'This will mark the delivery as cancelled. The record stays for audit.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel delivery'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final prev = d.status.wire;
      await ref.read(deliveryRepositoryProvider).cancel(d.id);
      await ref.read(auditLoggerProvider).deliveryCancelled(
            deliveryId: d.id,
            previousStatus: prev,
          );
      if (mounted) setState(_reload);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Cancel failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Delivery d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete draft?'),
        content: const Text('This draft will be permanently removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(deliveryRepositoryProvider).deleteDraft(d.id);
      await ref
          .read(auditLoggerProvider)
          .deliveryDraftDeleted(deliveryId: d.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Read-only photo thumbnail strip for dispatch/admin detail view.
/// Tap to open full-screen swipeable viewer.
class _DispatchPhotoStrip extends StatelessWidget {
  final List<String> paths;
  const _DispatchPhotoStrip({required this.paths});

  static const _size = 60.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _size,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: paths.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (_) => _DispatchPhotoViewer(
                paths: paths,
                initialIndex: i,
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(
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
                    size: 18, color: AppColors.textTertiaryLight),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DispatchPhotoViewer extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  const _DispatchPhotoViewer(
      {required this.paths, required this.initialIndex});

  @override
  State<_DispatchPhotoViewer> createState() => _DispatchPhotoViewerState();
}

class _DispatchPhotoViewerState extends State<_DispatchPhotoViewer> {
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
          style: const TextStyle(color: Colors.white),
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
            child: Image.file(
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

/// Inline coordinates row for the dispatch/admin stop view.
/// Shows the actual drop-off GPS position.
/// Tap → copy to clipboard. Long-press → open in Maps.
class _DispatchCoordsRow extends StatelessWidget {
  final double lat;
  final double lng;
  const _DispatchCoordsRow({required this.lat, required this.lng});

  String get _formatted =>
      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: _formatted));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Drop-off coordinates copied'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
      onLongPress: () async {
        final uri = Uri.parse(
          'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
        );
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.my_location,
              size: 10, color: AppColors.textSecondaryLight),
          const SizedBox(width: 4),
          Text(
            _formatted,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textSecondaryLight,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.copy, size: 9, color: AppColors.textTertiaryLight),
        ],
      ),
    );
  }
}
