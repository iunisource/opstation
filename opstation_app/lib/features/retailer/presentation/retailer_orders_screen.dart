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
                onTap: o['id'] == null
                    ? null
                    : () => _openOrder(context, o, t),
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

  Future<void> _openOrder(BuildContext context, Map<String, dynamic> o, T t) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RetailerLocaleScope(
        child: Builder(
          builder: (_) => _OrderDetailSheet(orderId: o['id'].toString(), header: o),
        ),
      ),
    );
  }
}

/// What an order actually contained — fetched on open via retailer_order_detail.
class _OrderDetailSheet extends StatefulWidget {
  final String orderId;
  final Map<String, dynamic> header;
  const _OrderDetailSheet({required this.orderId, required this.header});

  @override
  State<_OrderDetailSheet> createState() => _OrderDetailSheetState();
}

class _OrderDetailSheetState extends State<_OrderDetailSheet> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('retailer_order_detail', params: {'p_order_id': widget.orderId});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final items = (m['items'] as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _items = [for (final i in items) Map<String, dynamic>.from(i as Map)];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final df = DateFormat('d MMM yyyy');
    final vno = widget.header['voucher_number'] as String?;
    final status = '${widget.header['status'] ?? ''}';
    final total = _d(widget.header['total']);
    final at = widget.header['submitted_at'];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (_, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(vno ?? t.orderSummary,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (at != null) df.format(DateTime.parse('$at').toLocal()),
                      status.isNotEmpty
                          ? (status[0].toUpperCase() + status.substring(1))
                          : '',
                    ].where((s) => s.isNotEmpty).join('  •  '),
                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight),
                  ),
                ],
              ),
            ),
            Text(rs(total),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
                  ? Center(
                      child: Text(t.noProducts,
                          style: TextStyle(color: AppColors.textSecondaryLight)))
                  : ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6, top: 2),
                          child: Text(t.orderContents.toUpperCase(),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                  color: AppColors.textSecondaryLight)),
                        ),
                        for (final i in _items)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text((i['product'] as String?) ?? '-',
                                        style: const TextStyle(
                                            fontSize: 14, fontWeight: FontWeight.w600)),
                                    Text(
                                      [
                                        '${_d(i['qty']).toStringAsFixed(_d(i['qty']) % 1 == 0 ? 0 : 2)}'
                                            '${(i['uom'] as String?)?.isNotEmpty == true ? ' ${i['uom']}' : ''} × ${rs(_d(i['unit_price']))}',
                                        if ((i['sku'] as String?)?.isNotEmpty == true)
                                          i['sku'] as String,
                                      ].join('  •  '),
                                      style: TextStyle(
                                          fontSize: 12, color: AppColors.textSecondaryLight),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(rs(_d(i['line_total'])),
                                  style: const TextStyle(
                                      fontSize: 14, fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        const SizedBox(height: 8),
                        Text(t.priceNote,
                            style: TextStyle(
                                fontSize: 11.5, color: AppColors.textSecondaryLight)),
                      ],
                    ),
        ),
      ]),
    );
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
