import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/models/trip.dart';
import '../providers/report_service.dart';

/// Bottom-sheet that asks "which report?" and "preview or share?"
/// then invokes the report service. Returns nothing.
///
/// Caller invokes: `showExportPdfSheet(context, trip: trip)`.
Future<void> showExportPdfSheet(BuildContext context, {required Trip trip}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ExportSheet(trip: trip),
  );
}

class _ExportSheet extends ConsumerStatefulWidget {
  final Trip trip;
  const _ExportSheet({required this.trip});

  @override
  ConsumerState<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<_ExportSheet> {
  ReportKind _selected = ReportKind.visit;
  bool _busy = false;

  // Trip Summary is a reimbursement document: Generate records the claim once, Share only sends the copy.
  bool? _generated; // null = still checking
  DateTime? _generatedAt;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkStatus());
  }

  Future<void> _checkStatus() async {
    final actor = ref.read(authControllerProvider).valueOrNull;
    final issued = await ref.read(reportServiceProvider).registerReportIssue(
          type: 'trip_summary',
          key: widget.trip.id,
          orgId: actor?.organizationId,
          by: actor?.id,
          claim: false,
        );
    if (mounted) setState(() => _generated = issued);
  }

  Future<void> _run(_Action action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final service = ref.read(reportServiceProvider);
    final actor = ref.read(authControllerProvider).valueOrNull;
    final summary = _selected == ReportKind.summary;
    final fname = _selected.filename(widget.trip);
    try {
      switch (action) {
        case _Action.generate:
          final bytes = await service.buildBytes(
              kind: ReportKind.summary, trip: widget.trip, actor: actor, claim: true);
          if (!mounted) return;
          setState(() {
            _busy = false;
            _bytes = bytes;
            _generated = true;
            _generatedAt = DateTime.now();
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Generated and sent for approval. You can share it now.')),
          );
          return;
        case _Action.share:
          if (!summary) {
            // Visit Report is not a reimbursement document: Share as before.
            await service.share(kind: _selected, trip: widget.trip, actor: actor);
          } else {
            final bytes = _bytes ??
                await service.buildBytes(kind: ReportKind.summary, trip: widget.trip, actor: actor);
            try {
              await Printing.sharePdf(bytes: bytes, filename: fname);
            } on PlatformException {
              // Platform without a share sheet (e.g. emulator) — ignore.
            }
          }
          break;
        case _Action.preview:
          if (summary && _bytes != null) {
            final bytes = _bytes!;
            await Printing.layoutPdf(onLayout: (_) async => bytes, name: fname);
          } else {
            await service.preview(kind: _selected, trip: widget.trip, actor: actor);
          }
          break;
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  Widget _spinner() => const SizedBox(
      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));

  /// Preview / Generate / Share for the Trip Summary (the reimbursement document).
  Widget _summaryActions() {
    final isAdmin = ref.read(reportServiceProvider).isAdminActor;
    final generated = _generated == true;
    final canShare = generated || isAdmin;
    final status = _generated == null
        ? ('Checking…', Colors.grey.shade700, const Color(0xFFF3F4F6), Icons.hourglass_empty)
        : generated
            ? (
                _generatedAt == null
                    ? 'Generated · sent for approval'
                    : 'Generated ${DateFormat('d MMM, h:mm a').format(_generatedAt!)} · sent for approval',
                const Color(0xFF047857),
                const Color(0xFFECFDF5),
                Icons.check_circle_outline
              )
            : ('Not generated yet', Colors.grey.shade700, const Color(0xFFF3F4F6), Icons.radio_button_unchecked);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!isAdmin)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: status.$3, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Icon(status.$4, size: 16, color: status.$2),
            const SizedBox(width: 8),
            Expanded(child: Text(status.$1, style: TextStyle(fontSize: 12.5, color: status.$2))),
          ]),
        ),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _run(_Action.preview),
            icon: const Icon(Icons.preview_outlined, size: 18),
            label: Text(generated ? 'View PDF' : 'Preview'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
        ),
        if (!isAdmin) ...[
          const SizedBox(width: 12),
          Expanded(
            child: generated
                ? OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Generated'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  )
                : ElevatedButton.icon(
                    onPressed: _busy || _generated == null ? null : () => _run(_Action.generate),
                    icon: _busy ? _spinner() : const Icon(Icons.bolt, size: 18),
                    label: const Text('Generate'),
                    style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
                  ),
          ),
        ],
      ]),
      const SizedBox(height: 10),
      ElevatedButton.icon(
        onPressed: _busy || !canShare ? null : () => _run(_Action.share),
        icon: _busy && isAdmin ? _spinner() : const Icon(Icons.ios_share, size: 18),
        label: const Text('Share'),
        style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      if (!isAdmin && !generated && _generated != null)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Generate records this trip for reimbursement, once.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: Colors.grey)),
        ),
    ]);
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
            const Text(
              'Export PDF',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              widget.trip.routeName,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 16),
            _KindTile(
              title: 'Visit Report',
              subtitle: 'Per-customer detail: time, amount, distance, notes',
              selected: _selected == ReportKind.visit,
              onTap: () => setState(() => _selected = ReportKind.visit),
            ),
            const SizedBox(height: 8),
            _KindTile(
              title: 'Trip Summary',
              subtitle: 'One page: totals, score, coverage breakdown',
              selected: _selected == ReportKind.summary,
              onTap: () => setState(() => _selected = ReportKind.summary),
            ),
            const SizedBox(height: 18),
            if (_selected == ReportKind.summary)
              _summaryActions()
            else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(_Action.preview),
                    icon: const Icon(Icons.preview_outlined, size: 18),
                    label: const Text('Preview'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
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
          ],
        ),
      ),
    );
  }
}

enum _Action { preview, generate, share }

class _KindTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _KindTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primaryLight.withOpacity(0.5)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.borderLight,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.primary : AppColors.textTertiaryLight,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondaryLight,
                    ),
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
