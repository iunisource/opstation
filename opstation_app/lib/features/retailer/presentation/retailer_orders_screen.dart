import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import 'retailer_shell.dart';

/// `retailer_my_orders()` returns rows straight from `sales_orders` scoped to
/// the caller — so a retailer sees their REAL order, in the same lifecycle your
/// team works. When ordering lands (Phase 3) it will write a draft sales_order
/// with source='retailer', which means it appears here immediately and flows
/// through the existing SO → DO → SI pipeline. No parallel order table.
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
          Center(child: Text(t.somethingWentWrong,
              style: TextStyle(color: AppColors.textSecondaryLight))),
        ]),
        data: (rows) {
          if (rows.isEmpty) {
            return ListView(children: [
              const SizedBox(height: 130),
              Center(child: Column(children: [
                Icon(Icons.receipt_long_outlined,
                    size: 40, color: AppColors.textSecondaryLight),
                const SizedBox(height: 10),
                Text(t.noOrders,
                    style: TextStyle(color: AppColors.textSecondaryLight)),
              ])),
            ]);
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
            itemBuilder: (_, i) {
              final o = rows[i];
              final status = '${o['status'] ?? ''}';
              final vno = (o['voucher_number'] as String?) ?? '—';
              final date = o['voucher_date'];
              final total = (o['grand_total'] as num?)?.toDouble();
              return ListTile(
                title: Text(vno,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                subtitle: Text(
                  [
                    if (date != null) df.format(DateTime.parse('$date')),
                    if (total != null) rs(total),
                  ].join('  •  '),
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.textSecondaryLight),
                ),
                trailing: _StatusChip(status: status),
              );
            },
          );
        },
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final s = status.toLowerCase();
    Color c;
    if (s == 'delivered' || s == 'completed' || s == 'invoiced') {
      c = Colors.teal;
    } else if (s == 'cancelled') {
      c = AppColors.danger;
    } else if (s == 'draft') {
      c = AppColors.textSecondaryLight;
    } else {
      c = AppColors.primary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: c),
      ),
    );
  }
}
