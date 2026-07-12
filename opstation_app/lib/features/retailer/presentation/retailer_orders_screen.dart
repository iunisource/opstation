import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import 'retailer_shell.dart';

/// The retailer's own order requests.
///
/// `retailer_my_orders()` reads `retailer_orders` — the REQUEST, not a sales
/// order. Nothing exists in sales_orders until staff approve it, so this screen
/// shows the honest thing: what they asked for and where it stands. Once
/// approved it also carries the SO number, which is the retailer's proof the
/// order is real.
final retailerOrdersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await Supabase.instance.client.rpc('retailer_my_orders');
  if (res is! List) return [];
  return [for (final r in res) Map<String, dynamic>.from(r as Map)];
});

class RetailerOrdersScreen extends ConsumerWidget {
  const RetailerOrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = T.of(context);
    final async = ref.watch(retailerOrdersProvider);
    final df = DateFormat('d MMM yyyy');

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(retailerOrdersProvider),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ListView(children: [
          const SizedBox(height: 140),
          Center(
              child: Text(t.somethingWentWrong,
                  style: TextStyle(color: AppColors.textSecondaryLight))),
        ]),
        data: (rows) {
          if (rows.isEmpty) {
            return ListView(children: [
              const SizedBox(height: 130),
              Center(
                child: Column(children: [
                  Icon(Icons.receipt_long_outlined,
                      size: 40, color: AppColors.textSecondaryLight),
                  const SizedBox(height: 10),
                  Text(t.noOrders,
                      style: TextStyle(color: AppColors.textSecondaryLight)),
                ]),
              ),
            ]);
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
            itemBuilder: (_, i) {
              final o = rows[i];
              final status = '${o['status'] ?? ''}';
              final vno = o['voucher_number'] as String?;
              final reason = o['reject_reason'] as String?;
              final total = (o['total'] as num?)?.toDouble() ?? 0;
              final lines = (o['lines'] as num?)?.toInt() ?? 0;
              final at = o['submitted_at'];

              return ListTile(
                leading: _statusIcon(status),
                title: Text(
                  vno ?? '${lines} ${lines == 1 ? t.item : t.items}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if (at != null)
                          df.format(DateTime.parse('$at').toLocal()),
                        rs(total),
                      ].join('  •  '),
                      style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textSecondaryLight),
                    ),
                    if (status == 'rejected' &&
                        reason != null &&
                        reason.trim().isNotEmpty)
                      Text(reason,
                          style: TextStyle(
                              fontSize: 11.5, color: AppColors.danger)),
                  ],
                ),
                isThreeLine: status == 'rejected' &&
                    reason != null &&
                    reason.trim().isNotEmpty,
                trailing: _StatusChip(status: status, t: t),
              );
            },
          );
        },
      ),
    );
  }

  Widget _statusIcon(String s) {
    switch (s) {
      case 'approved':
        return const Icon(Icons.check_circle, color: Colors.teal, size: 22);
      case 'rejected':
        return Icon(Icons.cancel, color: AppColors.danger, size: 22);
      default:
        return const Icon(Icons.schedule, color: Colors.orange, size: 22);
    }
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  final T t;
  const _StatusChip({required this.status, required this.t});

  @override
  Widget build(BuildContext context) {
    late Color c;
    late String label;
    switch (status) {
      case 'approved':
        c = Colors.teal;
        label = t.isUrdu ? 'منظور' : 'Approved';
        break;
      case 'rejected':
        c = AppColors.danger;
        label = t.isUrdu ? 'مسترد' : 'Rejected';
        break;
      default:
        c = Colors.orange;
        label = t.isUrdu ? 'زیر غور' : 'Pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style:
              TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
    );
  }
}
