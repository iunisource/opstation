import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Orders placed by retailers from the app.
///
/// A retailer order is NOT a separate document type — `retailer_place_order`
/// writes a real `sales_orders` row with source='retailer', status='draft' and
/// voucher_number NULL. So this screen is a review queue over draft SOs, not a
/// converter like Field Orders. Confirming one simply moves it into the normal
/// SO → DO → SI pipeline.
///
/// The one wrinkle: the voucher-number trigger on sales_orders is BEFORE INSERT,
/// and these rows were inserted with a NULL number deliberately (no sense
/// burning a number on an order that may be rejected). So confirmation has to
/// mint the number explicitly via next_voucher_number.
class ErpRetailerOrdersScreen extends ConsumerStatefulWidget {
  const ErpRetailerOrdersScreen({super.key});

  @override
  ConsumerState<ErpRetailerOrdersScreen> createState() =>
      _ErpRetailerOrdersScreenState();
}

class _ErpRetailerOrdersScreenState
    extends ConsumerState<ErpRetailerOrdersScreen> {
  final _client = Supabase.instance.client;
  final _money = NumberFormat('#,##0.00');
  final _df = DateFormat('d MMM yyyy');

  bool _loading = true;
  bool _saving = false;
  String _filter = 'pending'; // pending | confirmed | rejected | all
  String? _orgId;

  List<Map<String, dynamic>> _orders = [];
  Map<String, dynamic>? _open; // currently opened order
  List<Map<String, dynamic>> _lines = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    _orgId = orgId;
    setState(() => _loading = true);
    try {
      var q = _client
          .from('sales_orders')
          .select()
          .eq('org_id', orgId)
          .eq('source', 'retailer');

      if (_filter == 'pending') {
        q = q.eq('status', 'draft');
      } else if (_filter != 'all') {
        q = q.eq('status', _filter);
      }

      final rows = List<Map<String, dynamic>>.from(
          await q.order('created_at', ascending: false));

      // Names and totals, batched — never per-row.
      final custIds = <String>{
        for (final o in rows)
          if (o['customer_id'] != null) o['customer_id'] as String
      };
      final branchIds = <String>{
        for (final o in rows)
          if (o['branch_id'] != null) o['branch_id'] as String
      };
      final orderIds = [for (final o in rows) o['id'] as String];

      final custNames = <String, String>{};
      if (custIds.isNotEmpty) {
        final cs = await _client
            .from('customers')
            .select('id, shop_name, code')
            .inFilter('id', custIds.toList());
        for (final c in cs as List) {
          custNames[c['id'] as String] = '${c['shop_name'] ?? '-'}';
        }
      }
      final branchNames = <String, String>{};
      if (branchIds.isNotEmpty) {
        final bs = await _client
            .from('branches')
            .select('id, name')
            .inFilter('id', branchIds.toList());
        for (final b in bs as List) {
          branchNames[b['id'] as String] = '${b['name'] ?? '-'}';
        }
      }

      // sales_orders has no total column — value is derived from lines, exactly
      // as everywhere else in the system.
      final totals = <String, double>{};
      final counts = <String, int>{};
      if (orderIds.isNotEmpty) {
        final items = await _client
            .from('sales_order_items')
            .select('sales_order_id, quantity, unit_price, discount')
            .inFilter('sales_order_id', orderIds);
        for (final it in items as List) {
          final id = it['sales_order_id'] as String?;
          if (id == null) continue;
          totals[id] = (totals[id] ?? 0) +
              (_d(it['quantity']) * _d(it['unit_price']) - _d(it['discount']));
          counts[id] = (counts[id] ?? 0) + 1;
        }
      }

      for (final o in rows) {
        o['_customer'] = custNames[o['customer_id']] ?? '—';
        o['_branch'] = branchNames[o['branch_id']] ?? '—';
        o['_total'] = totals[o['id'] as String] ?? 0;
        o['_lines'] = counts[o['id'] as String] ?? 0;
      }

      if (!mounted) return;
      setState(() {
        _orders = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Load failed: $e');
    }
  }

  Future<void> _openOrder(Map<String, dynamic> o) async {
    setState(() {
      _open = o;
      _lines = [];
    });
    try {
      final items = await _client
          .from('sales_order_items')
          .select('id, product_id, quantity, unit_price, discount')
          .eq('sales_order_id', o['id']);
      final rows = List<Map<String, dynamic>>.from(items);
      final pids = <String>{
        for (final l in rows)
          if (l['product_id'] != null) l['product_id'] as String
      };
      final names = <String, String>{};
      if (pids.isNotEmpty) {
        final ps = await _client
            .from('products')
            .select('id, name, sku')
            .inFilter('id', pids.toList());
        for (final p in ps as List) {
          names[p['id'] as String] =
              '${p['name'] ?? ''}${(p['sku'] ?? '').toString().isEmpty ? '' : ' (${p['sku']})'}';
        }
      }
      for (final l in rows) {
        l['_name'] = names[l['product_id']] ?? '—';
      }
      if (!mounted) return;
      setState(() => _lines = rows);
    } catch (e) {
      _snack('Could not load lines: $e');
    }
  }

  /// Confirm: mint the voucher number (the BEFORE INSERT trigger cannot, since
  /// these rows were created with a NULL number on purpose) and move the order
  /// into the normal SO lifecycle.
  Future<void> _confirm() async {
    final o = _open;
    if (o == null || _orgId == null) return;
    if (_lines.isEmpty) {
      _snack('This order has no items.');
      return;
    }
    setState(() => _saving = true);
    try {
      final patch = <String, dynamic>{
        'status': 'confirmed',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      // Only mint if it does not already have one — re-confirming must not burn
      // a second number.
      if ((o['voucher_number'] as String?) == null ||
          (o['voucher_number'] as String).isEmpty) {
        final year = DateTime.now().year;
        try {
          final vnum = await _client.rpc('next_voucher_number', params: {
            'p_org_id': _orgId,
            'p_branch_id': o['branch_id'],
            'p_type': 'SO',
            'p_year': year,
          });
          if (vnum != null) patch['voucher_number'] = vnum.toString();
        } catch (e) {
          _snack('Could not assign a voucher number: $e');
          setState(() => _saving = false);
          return;
        }
      }

      await _client.from('sales_orders').update(patch).eq('id', o['id']);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _open = null;
      });
      _snack('Order confirmed.');
      _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Confirm failed: $e');
    }
  }

  Future<void> _reject() async {
    final o = _open;
    if (o == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reject order'),
        content: Text(
            'Reject this order from ${o['_customer']}?\n\n'
            'It stays visible to the retailer, marked as rejected. Nothing is posted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await _client.from('sales_orders').update({
        'status': 'rejected',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', o['id']);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _open = null;
      });
      _snack('Order rejected.');
      _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Reject failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Retailer Orders',
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4)),
          const SizedBox(width: 18),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              value: _filter,
              isExpanded: true,
              decoration:
                  const InputDecoration(labelText: 'Status', isDense: true),
              items: const [
                DropdownMenuItem(value: 'pending', child: Text('Pending review')),
                DropdownMenuItem(value: 'confirmed', child: Text('Confirmed')),
                DropdownMenuItem(value: 'rejected', child: Text('Rejected')),
                DropdownMenuItem(value: 'all', child: Text('All')),
              ],
              onChanged: (v) {
                setState(() {
                  _filter = v ?? 'pending';
                  _open = null;
                });
                _load();
              },
            ),
          ),
          const Spacer(),
          IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh'),
        ]),
        const SizedBox(height: 2),
        const Text('Orders placed by retailers from the app. Confirm to move into the normal Sales Order flow.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        const SizedBox(height: 20),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 5, child: _list()),
                  const SizedBox(width: 20),
                  Expanded(flex: 4, child: _detail()),
                ]),
        ),
      ]),
    );
  }

  Widget _list() {
    if (_orders.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.inbox_outlined,
              size: 34, color: AppTheme.textSecondary),
          const SizedBox(height: 8),
          Text(
            _filter == 'pending'
                ? 'No retailer orders awaiting review.'
                : 'Nothing here.',
            style: const TextStyle(color: AppTheme.textSecondary),
          ),
        ]),
      );
    }
    return ListView.separated(
      itemCount: _orders.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final o = _orders[i];
        final selected = _open?['id'] == o['id'];
        final status = '${o['status'] ?? ''}';
        return InkWell(
          onTap: () => _openOrder(o),
          child: Container(
            color: selected ? AppTheme.primary.withValues(alpha: 0.06) : null,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${o['_customer']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        o['voucher_number'] ?? 'unnumbered',
                        '${o['_branch']}',
                        if (o['voucher_date'] != null)
                          _df.format(DateTime.parse('${o['voucher_date']}')),
                      ].join('  •  '),
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text('${o['_lines']} lines',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ),
              Expanded(
                flex: 2,
                child: Text('Rs. ${_money.format(o['_total'])}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              _statusChip(status),
            ]),
          ),
        );
      },
    );
  }

  Widget _statusChip(String s) {
    Color c;
    String label = s;
    switch (s.toLowerCase()) {
      case 'draft':
        c = Colors.orange;
        label = 'pending';
        break;
      case 'rejected':
        c = AppTheme.danger;
        break;
      case 'confirmed':
        c = AppTheme.primary;
        break;
      default:
        c = Colors.teal;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _detail() {
    final o = _open;
    if (o == null) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: const Center(
          child: Text('Select an order to review',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
      );
    }
    final pending = '${o['status']}' == 'draft';
    final total = _lines.fold<double>(
        0,
        (s, l) =>
            s + (_d(l['quantity']) * _d(l['unit_price']) - _d(l['discount'])));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${o['_customer']}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text('${o['_branch']}',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                ],
              ),
            ),
            _statusChip('${o['status']}'),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _lines.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _lines.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final l = _lines[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${l['_name']}',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                              Text(
                                '${_d(l['quantity']).toStringAsFixed(0)} × Rs. ${_money.format(_d(l['unit_price']))}',
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          'Rs. ${_money.format(_d(l['quantity']) * _d(l['unit_price']) - _d(l['discount']))}',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ]),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text('Rs. ${_money.format(total)}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800)),
              ],
            ),
            if (pending) ...[
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.close, size: 17),
                    label: const Text('Reject'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      side: BorderSide(
                          color: AppTheme.danger.withValues(alpha: 0.4)),
                      minimumSize: const Size(0, 44),
                    ),
                    onPressed: _saving ? null : _reject,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(_saving ? 'Working…' : 'Confirm Order'),
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 44)),
                    onPressed: _saving ? null : _confirm,
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              const Text(
                'Confirming assigns a voucher number and moves this into the Sales Order flow.',
                style:
                    TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
