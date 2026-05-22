import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../models/order.dart';
import '../services/order_service.dart';
import 'order_detail_modal.dart';

/// Accountant-facing Orders dashboard.
///
/// Lists every order in the current org (last 90 days by default),
/// with filters for status, salesperson, date range, and a search box
/// over customer name / code / notes. Click a row to view + edit
/// status via the OrderDetailModal.
class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  static const _border = Color(0xFFE5E7EB);
  static const _muted = Color(0xFF6B7280);
  static const _zebra = Color(0xFFFAFAFA);

  DateTime _from = DateTime.now().subtract(const Duration(days: 90));
  DateTime _to = DateTime.now();
  OrderStatus? _statusFilter;
  String? _salespersonId;
  String _searchQ = '';
  final TextEditingController _searchCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  List<Order> _orders = [];
  List<Map<String, dynamic>> _salespeople = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = ref.read(authControllerProvider).valueOrNull;
      final orgId = auth?.orgId;
      if (orgId == null) {
        setState(() {
          _loading = false;
          _error = 'No organization context';
        });
        return;
      }
      final svc = ref.read(orderServiceProvider);
      final results = await Future.wait([
        svc.listByOrg(
          orgId: orgId,
          fromInclusive: _from,
          toExclusive: _to.add(const Duration(days: 1)),
          status: _statusFilter,
          salespersonId: _salespersonId,
        ),
        svc.listSalespeople(orgId),
      ]);
      setState(() {
        _loading = false;
        _orders = results[0] as List<Order>;
        _salespeople = results[1] as List<Map<String, dynamic>>;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pickDate(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _from = picked;
        } else {
          _to = picked;
        }
      });
    }
  }

  List<Order> get _filteredBySearch {
    final q = _searchQ.trim().toLowerCase();
    if (q.isEmpty) return _orders;
    return _orders.where((o) {
      final inName = (o.customerName ?? '').toLowerCase().contains(q);
      final inCode = (o.customerCode ?? '').toLowerCase().contains(q);
      final inNotes = (o.notes ?? '').toLowerCase().contains(q);
      final inSalesperson =
          (o.salespersonName ?? '').toLowerCase().contains(q);
      return inName || inCode || inNotes || inSalesperson;
    }).toList();
  }

  Future<void> _openDetail(Order o) async {
    final changed = await OrderDetailModal.show(context, o);
    if (changed == true) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          _filterBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('Error: $_error',
                              style: const TextStyle(
                                  color: Color(0xFFDC2626))),
                        ),
                      )
                    : _table(),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final shown = _filteredBySearch.length;
    final total = _orders.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      color: Colors.white,
      child: Row(
        children: [
          const Text('Orders',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(width: 12),
          Text(
            shown == total
                ? '· $total order${total == 1 ? '' : 's'}'
                : '· $shown of $total',
            style: const TextStyle(fontSize: 13, color: _muted),
          ),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      color: Colors.white,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: () => _pickDate(true),
            icon: const Icon(Icons.calendar_today, size: 14),
            label: Text('From ${_fmtDateOnly(_from)}',
                style: const TextStyle(fontSize: 12)),
          ),
          OutlinedButton.icon(
            onPressed: () => _pickDate(false),
            icon: const Icon(Icons.calendar_today, size: 14),
            label: Text('To ${_fmtDateOnly(_to)}',
                style: const TextStyle(fontSize: 12)),
          ),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<OrderStatus?>(
              value: _statusFilter,
              decoration: const InputDecoration(
                labelText: 'Status',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('All statuses')),
                for (final s in OrderStatus.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (v) => setState(() => _statusFilter = v),
            ),
          ),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String?>(
              value: _salespersonId,
              decoration: const InputDecoration(
                labelText: 'Salesperson',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('All salespeople')),
                for (final s in _salespeople)
                  DropdownMenuItem(
                    value: s['id'] as String,
                    child: Text((s['name'] as String?) ?? ''),
                  ),
              ],
              onChanged: (v) => setState(() => _salespersonId = v),
            ),
          ),
          ElevatedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.search, size: 16),
            label: const Text('Apply'),
          ),
          OutlinedButton(
            onPressed: () {
              setState(() {
                _from = DateTime.now().subtract(const Duration(days: 90));
                _to = DateTime.now();
                _statusFilter = null;
                _salespersonId = null;
                _searchQ = '';
                _searchCtrl.clear();
              });
              _load();
            },
            child: const Text('Reset'),
          ),
          SizedBox(
            width: 280,
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search by customer, notes, salesperson…',
                prefixIcon: Icon(Icons.search, size: 16),
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              ),
              onChanged: (v) => setState(() => _searchQ = v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table() {
    final rows = _filteredBySearch;
    if (rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(48),
          child: Text('No orders match the selected filters.',
              style: TextStyle(color: _muted)),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            _headerRow(),
            for (var i = 0; i < rows.length; i++)
              _dataRow(rows[i], i.isEven),
          ],
        ),
      ),
    );
  }

  Widget _headerRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: _zebra,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(8),
          topRight: Radius.circular(8),
        ),
      ),
      child: Row(
        children: const [
          Expanded(flex: 2, child: Text('Created', style: _hStyle)),
          Expanded(flex: 3, child: Text('Customer', style: _hStyle)),
          Expanded(flex: 2, child: Text('Salesperson', style: _hStyle)),
          Expanded(flex: 3, child: Text('Notes', style: _hStyle)),
          Expanded(flex: 2, child: Text('Status', style: _hStyle)),
          SizedBox(width: 60),
        ],
      ),
    );
  }

  Widget _dataRow(Order o, bool zebra) {
    return InkWell(
      onTap: () => _openDetail(o),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: zebra ? Colors.white : _zebra,
          border: const Border(top: BorderSide(color: _border)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(_fmtDateTime(o.createdAt),
                  style: const TextStyle(fontSize: 13)),
            ),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(o.customerName ?? '—',
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  if (o.customerCode != null)
                    Text('#${o.customerCode}',
                        style: const TextStyle(
                            fontSize: 12, color: _muted)),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(o.salespersonName ?? '—',
                  style: const TextStyle(fontSize: 13)),
            ),
            Expanded(
              flex: 3,
              child: Text(
                (o.notes ?? '').isEmpty ? '—' : o.notes!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
            ),
            Expanded(flex: 2, child: _statusBadge(o.status)),
            const SizedBox(
              width: 60,
              child:
                  Icon(Icons.chevron_right, size: 20, color: _muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(OrderStatus s) {
    final (bg, fg) = _palette(s);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(s.label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
      ),
    );
  }

  (Color, Color) _palette(OrderStatus s) {
    switch (s) {
      case OrderStatus.inReview:
        return (const Color(0xFFFEF3C7), const Color(0xFF92400E));
      case OrderStatus.approved:
        return (const Color(0xFFD1FAE5), const Color(0xFF065F46));
      case OrderStatus.declined:
        return (const Color(0xFFFEE2E2), const Color(0xFF991B1B));
      case OrderStatus.dispatched:
        return (const Color(0xFFDBEAFE), const Color(0xFF1E40AF));
      case OrderStatus.onHold:
        return (const Color(0xFFF3E8FF), const Color(0xFF6B21A8));
      case OrderStatus.cancelled:
        return (const Color(0xFFE5E7EB), const Color(0xFF374151));
      case OrderStatus.delivered:
        return (const Color(0xFFC7F9CC), const Color(0xFF14532D));
    }
  }

  static String _fmtDateOnly(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _fmtDateTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static const _hStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: _muted,
  );
}
