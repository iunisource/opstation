import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';

/// All field orders this salesperson has punched/submitted, over a date range.
/// Online read (field orders are an online-only write on the create side), so
/// this mirrors OrderCreateModal's direct-Supabase approach rather than Drift.
///
/// Tile: customer · order date · remarks · value · status. Tap → products.
///   value  = Σ(field_order_items.quantity × price_at_submit)
///   date   = field_orders.submitted_at ?? created_at  (range filters created_at)
class MyOrdersScreen extends ConsumerStatefulWidget {
  const MyOrdersScreen({super.key});
  @override
  ConsumerState<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends ConsumerState<MyOrdersScreen> {
  bool _loading = true;
  String? _error;
  List<_OrderVM> _orders = [];

  late DateTime _from;
  late DateTime _to;

  final _df = DateFormat('d MMM yyyy');

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1); // start of current month
    _to = DateTime(now.year, now.month, now.day);
    _load();
  }

  Future<void> _load() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    final orgId = user?.organizationId;
    final userId = user?.id;
    if (orgId == null || userId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final fromIso = DateTime(_from.year, _from.month, _from.day)
          .toIso8601String();
      final toExclusive = DateTime(_to.year, _to.month, _to.day)
          .add(const Duration(days: 1))
          .toIso8601String();

      final orderRows = await client
          .from('field_orders')
          .select('id, customer_id, status, notes, submitted_at, created_at')
          .eq('org_id', orgId)
          .eq('salesperson_id', userId)
          .gte('created_at', fromIso)
          .lt('created_at', toExclusive)
          .order('created_at', ascending: false);
      final orders = List<Map<String, dynamic>>.from(orderRows);
      final orderIds = [for (final o in orders) o['id'] as String];
      final customerIds = <String>{
        for (final o in orders)
          if (o['customer_id'] != null) o['customer_id'] as String
      }.toList();

      // Items grouped by order (also harvest product ids for name lookup).
      final itemsByOrder = <String, List<Map<String, dynamic>>>{};
      final productIds = <String>{};
      if (orderIds.isNotEmpty) {
        final itemRows = await client
            .from('field_order_items')
            .select('field_order_id, product_id, uom_id, quantity, price_at_submit')
            .inFilter('field_order_id', orderIds);
        for (final r in itemRows as List) {
          final m = Map<String, dynamic>.from(r as Map);
          itemsByOrder
              .putIfAbsent(m['field_order_id'] as String, () => [])
              .add(m);
          final pid = m['product_id'] as String?;
          if (pid != null) productIds.add(pid);
        }
      }

      final custMap = <String, Map<String, dynamic>>{};
      if (customerIds.isNotEmpty) {
        final custRows = await client
            .from('customers')
            .select('id, shop_name, code')
            .inFilter('id', customerIds);
        for (final r in custRows as List) {
          final m = Map<String, dynamic>.from(r as Map);
          custMap[m['id'] as String] = m;
        }
      }

      final prodMap = <String, Map<String, dynamic>>{};
      if (productIds.isNotEmpty) {
        final prodRows = await client
            .from('products')
            .select('id, name, sku')
            .inFilter('id', productIds.toList());
        for (final r in prodRows as List) {
          final m = Map<String, dynamic>.from(r as Map);
          prodMap[m['id'] as String] = m;
        }
      }

      final vms = <_OrderVM>[];
      for (final o in orders) {
        final oid = o['id'] as String;
        final items = itemsByOrder[oid] ?? const [];
        double total = 0;
        final lines = <_LineVM>[];
        for (final it in items) {
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          final price = (it['price_at_submit'] as num?)?.toDouble() ?? 0;
          total += qty * price;
          final pid = it['product_id'] as String?;
          final p = pid != null ? prodMap[pid] : null;
          lines.add(_LineVM(
            name: (p?['name'] as String?) ?? 'Product',
            sku: (p?['sku'] as String?) ?? '',
            qty: qty,
            price: price,
          ));
        }
        final cust =
            o['customer_id'] != null ? custMap[o['customer_id']] : null;
        final dateStr =
            (o['submitted_at'] as String?) ?? (o['created_at'] as String?);
        vms.add(_OrderVM(
          id: oid,
          customerName: (cust?['shop_name'] as String?) ?? '—',
          customerCode: (cust?['code'] as String?) ?? '',
          date: dateStr != null ? DateTime.tryParse(dateStr)?.toLocal() : null,
          notes: (o['notes'] as String?)?.trim(),
          status: (o['status'] as String?) ?? 'submitted',
          total: total,
          lines: lines,
        ));
      }

      if (!mounted) return;
      setState(() {
        _orders = vms;
        _loading = false;
      });
    } catch (e) {
      final s = e.toString().toLowerCase();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = (s.contains('socket') ||
                s.contains('network') ||
                s.contains('connection'))
            ? 'No connection — pull to retry when online.'
            : 'Failed to load orders.';
      });
    }
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final initial = isFrom ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_from.isAfter(_to)) _from = _to;
      }
    });
    _load();
  }

  double get _rangeTotal => _orders.fold(0.0, (s, o) => s + o.total);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('My Orders'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimaryLight,
        elevation: 0.5,
      ),
      body: Column(children: [
        _dateBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _body(),
          ),
        ),
      ]),
    );
  }

  Widget _dateBar() {
    Widget field(String label, DateTime value, bool isFrom) {
      return Expanded(
        child: InkWell(
          onTap: () => _pickDate(isFrom: isFrom),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Row(children: [
              Icon(Icons.calendar_today_outlined,
                  size: 15, color: AppColors.textSecondaryLight),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textTertiaryLight,
                        letterSpacing: 0.5)),
                Text(_df.format(value),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ]),
          ),
        ),
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(children: [
        Row(children: [
          field('FROM', _from, true),
          const SizedBox(width: 10),
          field('TO', _to, false),
        ]),
        if (!_loading && _error == null && _orders.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text('${_orders.length} order${_orders.length == 1 ? '' : 's'}',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondaryLight)),
            const Spacer(),
            Text('Rs. ${_money(_rangeTotal)}',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ],
      ]),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _scrollable(_notice(Icons.cloud_off_outlined, _error!));
    }
    if (_orders.isEmpty) {
      return _scrollable(_notice(
          Icons.receipt_long_outlined, 'No orders in this date range.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: _orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _orderTile(_orders[i]),
    );
  }

  // Lets pull-to-refresh work even when the body is a centered message.
  Widget _scrollable(Widget child) => ListView(
        padding: const EdgeInsets.only(top: 120),
        children: [child],
      );

  Widget _notice(IconData icon, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: AppColors.textTertiaryLight),
            const SizedBox(height: 10),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondaryLight)),
          ]),
        ),
      );

  Widget _orderTile(_OrderVM o) {
    return InkWell(
      onTap: () => _showDetail(o),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    o.customerCode.isEmpty
                        ? o.customerName
                        : '${o.customerName}  ·  ${o.customerCode}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(o.date != null ? _df.format(o.date!) : '—',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondaryLight)),
                if (o.notes != null && o.notes!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(o.notes!,
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondaryLight,
                          fontStyle: FontStyle.italic),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('Rs. ${_money(o.total)}',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _statusChip(o.status),
          ]),
        ]),
      ),
    );
  }

  void _showDetail(_OrderVM o) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(children: [
          const SizedBox(height: 10),
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(children: [
              Expanded(
                child: Text(o.customerName,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              _statusChip(o.status),
              IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Icon(Icons.calendar_today_outlined,
                  size: 13, color: AppColors.textSecondaryLight),
              const SizedBox(width: 6),
              Text(o.date != null ? _df.format(o.date!) : '—',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.textSecondaryLight)),
              if (o.customerCode.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text('#${o.customerCode}',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondaryLight)),
              ],
            ]),
          ),
          if (o.notes != null && o.notes!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Note: ${o.notes!}',
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondaryLight,
                        fontStyle: FontStyle.italic)),
              ),
            ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: o.lines.isEmpty
                ? Center(
                    child: Text('No products on this order.',
                        style:
                            TextStyle(color: AppColors.textSecondaryLight)))
                : ListView.separated(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: o.lines.length,
                    separatorBuilder: (_, __) => const Divider(height: 16),
                    itemBuilder: (_, i) {
                      final l = o.lines[i];
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l.name,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600)),
                                if (l.sku.isNotEmpty)
                                  Text(l.sku,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color:
                                              AppColors.textSecondaryLight)),
                                const SizedBox(height: 2),
                                Text(
                                    '${_qty(l.qty)} × Rs. ${l.price.toStringAsFixed(2)}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textSecondaryLight)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text('Rs. ${_money(l.qty * l.price)}',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700)),
                        ],
                      );
                    },
                  ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
                16, 12, 16, 12 + MediaQuery.of(ctx).padding.bottom),
            decoration: BoxDecoration(
              color: Colors.white,
              border:
                  Border(top: BorderSide(color: AppColors.borderLight)),
            ),
            child: Row(children: [
              Text('${o.lines.length} item${o.lines.length == 1 ? '' : 's'}',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondaryLight)),
              const Spacer(),
              Text('Rs. ${_money(o.total)}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _statusChip(String status) {
    final s = status.toLowerCase();
    Color bg;
    Color fg;
    String label;
    switch (s) {
      case 'approved':
      case 'accepted':
        bg = AppColors.successLight;
        fg = AppColors.successDark;
        label = 'Approved';
        break;
      case 'rejected':
      case 'declined':
        bg = Colors.red.shade50;
        fg = Colors.red.shade700;
        label = 'Rejected';
        break;
      case 'submitted':
      case 'pending':
        bg = AppColors.warningLight;
        fg = AppColors.warningDark;
        label = 'Submitted';
        break;
      default:
        bg = AppColors.borderLight;
        fg = AppColors.textSecondaryLight;
        label = status.isEmpty
            ? '—'
            : status[0].toUpperCase() + status.substring(1);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  // Quantities can be whole or fractional depending on UoM.
  String _qty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  // Order values use 2 decimals to match the order-create screen.
  String _money(double v) {
    final neg = v < 0;
    final parts = v.abs().toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '${neg ? '-' : ''}$buf.${parts[1]}';
  }
}

class _OrderVM {
  final String id;
  final String customerName;
  final String customerCode;
  final DateTime? date;
  final String? notes;
  final String status;
  final double total;
  final List<_LineVM> lines;
  _OrderVM({
    required this.id,
    required this.customerName,
    required this.customerCode,
    required this.date,
    required this.notes,
    required this.status,
    required this.total,
    required this.lines,
  });
}

class _LineVM {
  final String name;
  final String sku;
  final double qty;
  final double price;
  _LineVM(
      {required this.name,
      required this.sku,
      required this.qty,
      required this.price});
}
