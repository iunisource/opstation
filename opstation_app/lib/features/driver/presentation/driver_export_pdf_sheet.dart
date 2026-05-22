import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import '../../dispatch/models/delivery.dart';
import '../pdf/driver_summary_pdf_builder.dart';
import '../services/driver_report_context_builder.dart';

Future<void> showDriverExportSheet(
  BuildContext context, {
  required Delivery delivery,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _DriverExportSheet(delivery: delivery),
  );
}

class _DriverExportSheet extends ConsumerStatefulWidget {
  final Delivery delivery;
  const _DriverExportSheet({required this.delivery});

  @override
  ConsumerState<_DriverExportSheet> createState() => _DriverExportSheetState();
}

class _DriverExportSheetState extends ConsumerState<_DriverExportSheet> {
  bool _busy = false;

  String get _orgName =>
      ref.read(authControllerProvider).valueOrNull?.organizationName ?? 'Opstation';

  Future<List<int>> _buildPdf() async {
    final ctx = await ref
        .read(driverReportContextBuilderProvider)
        .build(widget.delivery);
    return DriverSummaryPdfBuilder.build(ctx: ctx, orgName: _orgName);
  }

  Future<void> _preview() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(await _buildPdf()),
        name: _filename(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _buildPdf();
      await Printing.sharePdf(
          bytes: Uint8List.fromList(bytes), filename: _filename());
      if (mounted) Navigator.of(context).pop();
    } on PlatformException {
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  String _filename() {
    final date = widget.delivery.completedAt ?? widget.delivery.createdAt;
    final ds =
        '${date.year.toString().padLeft(4, '0')}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
    return 'driver_trip_summary_$ds.pdf';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text('Driver Trip Summary',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              '${widget.delivery.deliveredCount}/${widget.delivery.stops.length} delivered · '
              'Rs ${widget.delivery.cashCollected} collected',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondaryLight),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primaryLight.withOpacity(0.5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.primary),
              ),
              child: Row(
                children: const [
                  Icon(Icons.picture_as_pdf_outlined,
                      color: AppColors.primary, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Driver Trip Summary',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text(
                          'Sequenced stops · distances · total KM · reimbursement',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondaryLight),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _preview,
                    icon: const Icon(Icons.preview_outlined, size: 18),
                    label: const Text('Preview'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _share,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.ios_share, size: 18),
                    label: const Text('Share'),
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 48)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
