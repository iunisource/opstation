import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/pdf/pdf_output.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';
import '../services/survey_reports_pdf.dart';

/// "Reports" menu on the survey screens: Audit report and Surveyor report,
/// each for a chosen date range (PDF).
class SurveyReportsButton extends ConsumerStatefulWidget {
  final bool compact;
  const SurveyReportsButton({super.key, this.compact = false});
  @override
  ConsumerState<SurveyReportsButton> createState() => _SurveyReportsButtonState();
}

class _SurveyReportsButtonState extends ConsumerState<SurveyReportsButton> {
  bool _busy = false;

  Future<void> _run(String kind) async {
    final user = ref.read(currentUserProvider);
    final orgId = user?.orgId;
    if (orgId == null) return;
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: now,
      initialDateRange: DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
      helpText: kind == 'audit' ? 'Audit report — date range' : 'Surveyor report — date range',
    );
    if (range == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final orgName = user?.orgName ?? '';
      final bytes = kind == 'audit'
          ? await SurveyReportsPdf.auditReport(orgId: orgId, orgName: orgName, from: range.start, to: range.end)
          : await SurveyReportsPdf.surveyorReport(orgId: orgId, orgName: orgName, from: range.start, to: range.end);
      await outputPdf(bytes, kind == 'audit' ? 'Survey Audit Report' : 'Surveyor Report');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError('Could not create the report', e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Reports',
      enabled: !_busy,
      onSelected: _run,
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'audit', child: ListTile(dense: true, leading: Icon(Icons.fact_check_outlined), title: Text('Audit report'))),
        PopupMenuItem(value: 'surveyor', child: ListTile(dense: true, leading: Icon(Icons.badge_outlined), title: Text('Surveyor report'))),
      ],
      child: IgnorePointer(
        child: OutlinedButton.icon(
          onPressed: () {},
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.assessment_outlined, size: 18),
          label: Text(widget.compact ? 'Reports' : 'Reports'),
        ),
      ),
    );
  }
}
