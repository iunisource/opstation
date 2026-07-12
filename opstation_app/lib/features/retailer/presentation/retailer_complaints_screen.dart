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
    final df = DateFormat('d MMM yyyy');

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
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 90),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
              itemBuilder: (_, i) {
                final c = rows[i];
                final status = '${c['status'] ?? ''}'.toLowerCase();
                final done = status == 'resolved' || status == 'closed';
                final created = c['created_at'];
                return ListTile(
                  leading: Icon(
                    done ? Icons.check_circle : Icons.schedule,
                    color: done ? Colors.teal : AppColors.primary,
                    size: 22,
                  ),
                  title: Text('${c['subject'] ?? ''}',
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w700)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ('${c['description'] ?? ''}'.trim().isNotEmpty)
                        Text('${c['description']}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5)),
                      if (created != null)
                        Text(df.format(DateTime.parse('$created').toLocal()),
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondaryLight)),
                    ],
                  ),
                  isThreeLine:
                      '${c['description'] ?? ''}'.trim().isNotEmpty,
                  trailing: Text(
                    done ? t.resolved : t.open_,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: done ? Colors.teal : AppColors.primary),
                  ),
                );
              },
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
