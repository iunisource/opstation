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
  final client = Supabase.instance.client;
  final res = await client.rpc('retailer_my_orders');
  if (res is! List) return [];
  final orders = [for (final r in res) Map<String, dynamic>.from(r as Map)];

  // sales_orders has NO total column anywhere in this system — order value is
  // always DERIVED from its lines. Reading a `grand_total` here would render
  // Rs. 0.00 for every order, exactly the bug the quotation list had.
  final ids = [for (final o in orders) o['id'] as String];
  if (ids.isNotEmpty) {
    try {
      final items = await client
          .from('sales_order_items')
          .select('sales_order_id, quantity, unit_price, discount')
          .inFilter('sales_order_id', ids);
      final totals = <String, double>{};
      for (final it in items as List) {
        final soId = it['sales_order_id'] as String?;
        if (soId == null) continue;
        final q = (it['quantity'] as num?)?.toDouble() ?? 0;
        final p = (it['unit_price'] as num?)?.toDouble() ?? 0;
        final d = (it['discount'] as num?)?.toDouble() ?? 0;
        totals[soId] = (totals[soId] ?? 0) + (q * p - d);
      }
      for (final o in orders) {
        o['_total'] = totals[o['id']] ?? 0;
      }
    } catch (_) {/* leave _total unset; the row just shows no amount */}
  }
  return orders;
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
              final total = (o['_total'] as num?)?.toDouble();
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
