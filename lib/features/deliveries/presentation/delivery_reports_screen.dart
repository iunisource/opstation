import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/auth_controller.dart';

/// Delivery Reports — dispatch-focused list of deliveries with date,
/// driver, and status filters. Each row links to the existing
/// /deliveries/:id detail view.
class DeliveryReportsScreen extends ConsumerStatefulWidget {
  const DeliveryReportsScreen({super.key});

  @override
  ConsumerState<DeliveryReportsScreen> createState() =>
      _DeliveryReportsScreenState();
}

class _DeliveryReportsScreenState
    extends ConsumerState<DeliveryReportsScreen> {
  static const _border = Color(0xFFE5E7EB);
  static const _muted = Color(0xFF6B7280);
  static const _zebra = Color(0xFFFAFAFA);

  DateTime _from = DateTime.now().subtract(const Duration(days: 30));
  DateTime _to = DateTime.now();
  String? _driverId;
  String? _status;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _deliveries = [];
  List<Map<String, dynamic>> _drivers = [];

  @override
  void initState() {
    super.initState();
    _load();
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

      final client = Supabase.instance.client;

      final usersResp = await client
          .from('users')
          .select('id, name, role')
          .eq('org_id', orgId);
      final drivers = (usersResp as List)
          .cast<Map<String, dynamic>>()
          .where((u) => u['role'] == 'driver')
          .toList()
        ..sort((a, b) => ((a['name'] as String?) ?? '')
            .toLowerCase()
            .compareTo(((b['name'] as String?) ?? '').toLowerCase()));

      var q = client
          .from('deliveries')
          .select(
              'id, driver_id, driver_name, status, created_at, started_at, completed_at, notes')
          .eq('org_id', orgId)
          .gte('created_at', _from.toIso8601String())
          .lte('created_at',
              _to.add(const Duration(days: 1)).toIso8601String());

      if (_driverId != null) {
        q = q.eq('driver_id', _driverId!);
      }
      if (_status != null) {
        q = q.eq('status', _status!);
      }

      final resp = await q.order('created_at', ascending: false);
      final deliveries = (resp as List).cast<Map<String, dynamic>>();

      setState(() {
        _loading = false;
        _drivers = drivers;
        _deliveries = deliveries;
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

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    try {
      final d = DateTime.parse(iso).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
    } catch (_) {
      return iso;
    }
  }

  String _fmtDateOnly(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
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
                              style:
                                  const TextStyle(color: Color(0xFFDC2626))),
                        ),
                      )
                    : _table(),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      color: Colors.white,
      child: Row(
        children: [
          const Text('Delivery Reports',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(width: 12),
          Text('· ${_deliveries.length} deliveries',
              style: const TextStyle(fontSize: 13, color: _muted)),
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
            width: 220,
            child: DropdownButtonFormField<String?>(
              value: _driverId,
              decoration: const InputDecoration(
                labelText: 'Driver',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('All drivers')),
                for (final d in _drivers)
                  DropdownMenuItem(
                      value: d['id'] as String,
                      child: Text((d['name'] as String?) ?? '')),
              ],
              onChanged: (v) => setState(() => _driverId = v),
            ),
          ),
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String?>(
              value: _status,
              decoration: const InputDecoration(
                labelText: 'Status',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              items: const [
                DropdownMenuItem(value: null, child: Text('All statuses')),
                DropdownMenuItem(value: 'pending', child: Text('Pending')),
                DropdownMenuItem(
                    value: 'in_progress', child: Text('In progress')),
                DropdownMenuItem(value: 'completed', child: Text('Completed')),
                DropdownMenuItem(value: 'cancelled', child: Text('Cancelled')),
              ],
              onChanged: (v) => setState(() => _status = v),
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
                _from = DateTime.now().subtract(const Duration(days: 30));
                _to = DateTime.now();
                _driverId = null;
                _status = null;
              });
              _load();
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  Widget _table() {
    if (_deliveries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(48),
          child: Text('No deliveries match the selected filters.',
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
            for (var i = 0; i < _deliveries.length; i++)
              _dataRow(_deliveries[i], i.isEven),
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
          Expanded(flex: 2, child: Text('Driver', style: _hStyle)),
          Expanded(flex: 2, child: Text('Status', style: _hStyle)),
          Expanded(flex: 2, child: Text('Started', style: _hStyle)),
          Expanded(flex: 2, child: Text('Completed', style: _hStyle)),
          SizedBox(width: 80, child: Text('Action', style: _hStyle)),
        ],
      ),
    );
  }

  Widget _dataRow(Map<String, dynamic> d, bool zebra) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: zebra ? Colors.white : _zebra,
        border: const Border(top: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(_fmtDate(d['created_at'] as String?),
                style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            flex: 2,
            child: Text((d['driver_name'] as String?) ?? '—',
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(
            flex: 2,
            child: _statusBadge((d['status'] as String?) ?? 'unknown'),
          ),
          Expanded(
            flex: 2,
            child: Text(_fmtDate(d['started_at'] as String?),
                style: const TextStyle(color: _muted, fontSize: 13)),
          ),
          Expanded(
            flex: 2,
            child: Text(_fmtDate(d['completed_at'] as String?),
                style: const TextStyle(color: _muted, fontSize: 13)),
          ),
          SizedBox(
            width: 80,
            child: TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 14),
              label: const Text('View', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => context.go('/deliveries/${d['id']}'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String status) {
    final bg = {
      'pending': const Color(0xFFFEF3C7),
      'in_progress': const Color(0xFFDBEAFE),
      'completed': const Color(0xFFD1FAE5),
      'cancelled': const Color(0xFFFEE2E2),
    };
    final fg = {
      'pending': const Color(0xFF92400E),
      'in_progress': const Color(0xFF1E40AF),
      'completed': const Color(0xFF065F46),
      'cancelled': const Color(0xFF991B1B),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg[status] ?? const Color(0xFFE5E7EB),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          status,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: fg[status] ?? _muted,
          ),
        ),
      ),
    );
  }

  static const _hStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: _muted,
  );
}
