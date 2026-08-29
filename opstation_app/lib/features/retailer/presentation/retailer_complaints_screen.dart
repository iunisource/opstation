import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';

final retailerComplaintsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await Supabase.instance.client.rpc('retailer_my_complaints');
  if (res is! List) return [];
  return [for (final r in res) Map<String, dynamic>.from(r as Map)];
});

/// Complaints are the only thing a retailer INITIATES other than an order, so
/// the form is deliberately two fields — subject (required by the RPC) and an
/// optional detail. The complaints already coming through the web portal are
/// one-liners ("Salesman nahi ata"); a long form would just stop people using
/// it and push them back to phoning the salesman.
class RetailerComplaintsScreen extends ConsumerStatefulWidget {
  const RetailerComplaintsScreen({super.key});

  @override
  ConsumerState<RetailerComplaintsScreen> createState() =>
      _RetailerComplaintsScreenState();
}

class _RetailerComplaintsScreenState
    extends ConsumerState<RetailerComplaintsScreen> {
  Future<void> _raise(T t) async {
    final subjCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    var saving = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: StatefulBuilder(builder: (ctx, setS) {
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(t.newComplaint,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: subjCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: t.subject,
                hintText: t.subjectHint,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              minLines: 3,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: t.details,
                alignLabelWithHint: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (subjCtrl.text.trim().isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text(t.subjectRequired)),
                          );
                          return;
                        }
                        setS(() => saving = true);
                        try {
                          await Supabase.instance.client
                              .rpc('retailer_log_complaint', params: {
                            'p_subject': subjCtrl.text.trim(),
                            'p_description': descCtrl.text.trim(),
                          });
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (!mounted) return;
                          ref.invalidate(retailerComplaintsProvider);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(t.complaintSent)),
                          );
                        } catch (_) {
                          setS(() => saving = false);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text(t.somethingWentWrong)),
                            );
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(t.send,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ]);
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final async = ref.watch(retailerComplaintsProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(retailerComplaintsProvider),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => ListView(children: [
            const SizedBox(height: 140),
            Center(child: Text(t.somethingWentWrong,
                style: TextStyle(color: AppColors.textSecondaryLight))),
          ]),
          data: (rows) {
            if (rows.isEmpty) {
              return ListView(children: [
                const SizedBox(height: 130),
                Center(child: Column(children: [
                  Icon(Icons.report_problem_outlined,
                      size: 40, color: AppColors.textSecondaryLight),
                  const SizedBox(height: 10),
                  Text(t.noComplaints,
                      style: TextStyle(color: AppColors.textSecondaryLight)),
                ])),
              ]);
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _ComplaintCard(complaint: rows[i]),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _raise(t),
        icon: const Icon(Icons.add),
        label: Text(t.newComplaint),
      ),
    );
  }
}

/// A collapsible complaint card. Collapsed: subject + status. Expanded: the full
/// description and the history trail (opened -> in progress -> resolved), each
/// with who did it, when, and any remark.
class _ComplaintCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> complaint;
  const _ComplaintCard({required this.complaint});
  @override
  ConsumerState<_ComplaintCard> createState() => _ComplaintCardState();
}

class _ComplaintCardState extends ConsumerState<_ComplaintCard> {
  bool _expanded = false;
  bool _loading = false;
  List<Map<String, dynamic>> _events = [];

  final _df = DateFormat('d MMM yyyy, h:mm a');

  Color _statusColor(String s) {
    switch (s.toLowerCase()) {
      case 'resolved':
      case 'closed':
        return Colors.teal;
      case 'in_progress':
        return Colors.orange.shade700;
      default:
        return AppColors.primary;
    }
  }

  Future<void> _toggle() async {
    setState(() => _expanded = !_expanded);
    if (_expanded && _events.isEmpty) {
      setState(() => _loading = true);
      try {
        final res = await Supabase.instance.client.rpc(
            'retailer_complaint_thread',
            params: {'p_complaint_id': widget.complaint['id']});
        final m = res is Map ? Map<String, dynamic>.from(res) : {};
        final ev = (m['events'] as List?) ?? [];
        if (mounted) {
          setState(() {
            _events = [for (final e in ev) Map<String, dynamic>.from(e as Map)];
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final c = widget.complaint;
    final status = '${c['status'] ?? 'open'}';
    final sc = _statusColor(status);
    final created = c['created_at'];
    final desc = '${c['description'] ?? ''}'.trim();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(children: [
              Icon(
                  status.toLowerCase() == 'resolved' ||
                          status.toLowerCase() == 'closed'
                      ? Icons.check_circle
                      : Icons.schedule,
                  color: sc,
                  size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${c['subject'] ?? ''}',
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w700)),
                    if (created != null)
                      Text(
                          DateFormat('d MMM yyyy')
                              .format(DateTime.parse('$created').toLocal()),
                          style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondaryLight)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: sc.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(t.statusLabel(status),
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, color: sc)),
              ),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  color: AppColors.textSecondaryLight),
            ]),
          ),
        ),
        if (_expanded) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (desc.isNotEmpty) ...[
                  Text(desc, style: const TextStyle(fontSize: 13, height: 1.35)),
                  const SizedBox(height: 12),
                ],
                Text(t.complaintHistory.toUpperCase(),
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: AppColors.textSecondaryLight)),
                const SizedBox(height: 8),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  for (var i = 0; i < _events.length; i++)
                    _eventRow(t, _events[i], i == _events.length - 1),
              ],
            ),
          ),
        ],
      ]),
    );
  }

  Widget _eventRow(T t, Map<String, dynamic> e, bool last) {
    final status = '${e['status'] ?? ''}';
    final sc = _statusColor(status);
    final actor = '${e['actor'] ?? ''}'.trim();
    final note = '${e['note'] ?? ''}'.trim();
    final at = e['at'];
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(top: 3),
              decoration: BoxDecoration(color: sc, shape: BoxShape.circle)),
          if (!last)
            Expanded(
                child: Container(
                    width: 2,
                    color: AppColors.borderLight,
                    margin: const EdgeInsets.symmetric(vertical: 2))),
        ]),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.statusLabel(status),
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: sc)),
              Text(
                [
                  if (at != null)
                    _df.format(DateTime.parse('$at').toLocal()),
                  if (actor.isNotEmpty) actor,
                ].join('  •  '),
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondaryLight),
              ),
              if (note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('${t.remark}: $note',
                      style: const TextStyle(fontSize: 12.5, height: 1.3)),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
