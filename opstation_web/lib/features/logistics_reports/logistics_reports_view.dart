import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/responsive.dart';
import '../../core/widgets/salesperson_picker.dart';
import 'logistics_report_rows.dart';

/// The Logistics Reports page, drawn from the data it is given (the screen loads it and makes the
/// reports): the drivers' jobs — deliveries, pickups and the free routes they ran — each with a
/// button for its report (the delivery report with the distances).
class LogisticsReportsView extends StatelessWidget {
  const LogisticsReportsView({
    super.key,
    required this.range,
    required this.onPickRange,
    required this.drivers,
    required this.driverId,
    required this.onDriver,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.jobs,
    required this.busyId,
    required this.onJobReport,
  });

  final DateTimeRange? range;
  final VoidCallback onPickRange;
  final List<Map<String, dynamic>> drivers;
  final String? driverId;
  final ValueChanged<String?> onDriver;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final List<JobRow> jobs;

  /// The job whose report is being made (its button shows a spinner).
  final String? busyId;
  final ValueChanged<String> onJobReport;

  static const _head = TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary);

  String _date(DateTime? d) => d == null ? '-' : DateFormat('d MMM yyyy').format(d);

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  Color _statusColor(String s) {
    switch (s) {
      case 'Completed':
      case 'Done':
        return AppTheme.success;
      case 'In progress':
      case 'Active':
        return AppTheme.primary;
      case 'Assigned':
        return AppTheme.warning;
    }
    return AppTheme.textSecondary;
  }

  Widget _reportButton({required String id, required IconData icon, required Color color, required String tooltip, required VoidCallback? onPressed}) {
    if (busyId == id) {
      return const SizedBox(width: 40, height: 36, child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))));
    }
    return IconButton(
      icon: Icon(icon, size: 20, color: onPressed == null ? AppTheme.border : color),
      onPressed: busyId != null ? null : onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
    );
  }

  Widget _headerRow(List<Widget> cells) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
        child: Row(children: cells),
      );

  Widget _jobsTable() {
    return Column(children: [
      _headerRow(const [
        Expanded(flex: 2, child: Text('Date', style: _head)),
        Expanded(flex: 2, child: Text('Driver', style: _head)),
        Expanded(flex: 2, child: Text('Type', style: _head)),
        Expanded(flex: 1, child: Text('Stops', style: _head)),
        Expanded(flex: 1, child: Text('Done', style: _head)),
        Expanded(flex: 1, child: Text('Failed', style: _head)),
        Expanded(flex: 2, child: Text('Status', style: _head)),
        SizedBox(width: 80, child: Text('Report', style: _head)),
      ]),
      const Divider(height: 1),
      Expanded(
        child: jobs.isEmpty
            ? const Center(child: Text('No driver jobs found for the selected filters', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: jobs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final j = jobs[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    child: Row(children: [
                      Expanded(flex: 2, child: Text(_date(j.date), style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Text(j.driver, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(flex: 2, child: Text(j.type, style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text('${j.stops}', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text('${j.delivered}', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text('${j.failed}', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: _pill(j.status, _statusColor(j.status)))),
                      SizedBox(
                        width: 80,
                        child: _reportButton(
                          id: j.id,
                          icon: Icons.summarize_outlined,
                          color: AppTheme.primary,
                          tooltip: j.canReport ? 'Delivery report with distances' : 'Available once the job has started',
                          onPressed: j.canReport ? () => onJobReport(j.id) : null,
                        ),
                      ),
                    ]),
                  );
                },
              ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 700;
    final count = '${jobs.length} job${jobs.length == 1 ? '' : 's'}';
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 16 : 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Logistics Reports', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppTheme.textPrimary),
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text(range == null ? 'Select date range' : '${DateFormat('d MMM').format(range!.start)} - ${DateFormat('d MMM').format(range!.end)}'),
            onPressed: onPickRange,
          ),
          SalespersonPicker(users: drivers, value: driverId, onChanged: onDriver, allLabel: 'All drivers'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Text(count, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary)),
          ),
        ]),
        const SizedBox(height: 16),
        if (loading)
          const Center(child: CircularProgressIndicator())
        else
          Expanded(
            child: HScrollOnNarrow(
              minWidth: 900,
              child: Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                child: error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
                            const SizedBox(height: 12),
                            const Text('Could not load reports', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                            const SizedBox(height: 6),
                            SelectableText(error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFDC2626), fontSize: 12)),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
                          ]),
                        ),
                      )
                    : _jobsTable(),
              ),
            ),
          ),
      ]),
    );
  }
}
