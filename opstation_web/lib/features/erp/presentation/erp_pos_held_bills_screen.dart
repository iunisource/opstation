import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpPosHeldBillsScreen extends ConsumerStatefulWidget {
  const ErpPosHeldBillsScreen({super.key});
  @override ConsumerState<ErpPosHeldBillsScreen> createState() => _ErpPosHeldBillsScreenState();
}

class _ErpPosHeldBillsScreenState extends ConsumerState<ErpPosHeldBillsScreen> {
  List<Map<String, dynamic>> _bills = [];
  bool _loading = true;
  String _search = '';

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  @override void initState() { super.initState(); _load(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      var q = Supabase.instance.client.from('pos_held_bills')
          .select('*, pos_sessions(session_number, branches(name))')
          .eq('org_id', orgId)
          .eq('status', 'held');
      final branchId = _branchId;
      if (branchId != null) q = q.eq('branch_id', branchId);
      final rows = await q.order('held_at', ascending: false).limit(200);
      setState(() { _bills = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (e) { _snack('Error: $e'); setState(() => _loading = false); }
  }

  Future<void> _cancelBill(Map<String, dynamic> bill) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Cancel held bill?'),
      content: const Text('This will permanently discard this held bill.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel Bill'), style: ElevatedButton.styleFrom(backgroundColor: Colors.red)),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('pos_held_bills').update({'status': 'cancelled'}).eq('id', bill['id'] as String);
      await _load();
      _snack('Bill cancelled');
    } catch (e) { _snack('Failed: $e'); }
  }

  Future<void> _continueBill(Map<String, dynamic> bill) async {
    final orgId = _orgId; if (orgId == null) return;
    final branchId = bill['branch_id'] as String;
    try {
      // Find active session for this branch
      final sessions = await Supabase.instance.client.from('pos_sessions')
          .select('*, branches(name)')
          .eq('org_id', orgId).eq('branch_id', branchId).eq('status', 'open')
          .order('opened_at', ascending: false).limit(1);
      if ((sessions as List).isEmpty) {
        _snack('No active session for branch "${bill['pos_sessions']?['branches']?['name'] ?? ''}" — open a session first');
        return;
      }
      final session = sessions.first as Map<String, dynamic>;
      // Navigate to POS session and pass the bill to restore
      if (mounted) {
        Navigator.pop(context, bill);
      }
    } catch (e) { _snack('Failed: $e'); }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _search.toLowerCase();
    if (q.isEmpty) return _bills;
    return _bills.where((b) {
      final cust = (b['customer_name'] as String? ?? '').toLowerCase();
      final branch = (b['pos_sessions']?['branches']?['name'] as String? ?? '').toLowerCase();
      final sess = (b['pos_sessions']?['session_number'] as String? ?? '').toLowerCase();
      return cust.contains(q) || branch.contains(q) || sess.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) => _load());
    final filtered = _filtered;

    return Container(color: AppTheme.background, child: Column(children: [
      // Header
      Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(24, 20, 24, 16), child: Row(children: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to POS',
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 4),
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Bills on Hold', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          SizedBox(height: 2),
          Text('Saved bills awaiting completion', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ])),
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
      ])),
      const Divider(height: 1),
      // Search
      Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
        child: TextField(
          decoration: const InputDecoration(hintText: 'Search by customer, branch or session...', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
          onChanged: (v) => setState(() => _search = v),
        )),
      const Divider(height: 1),
      // Table header
      Container(color: const Color(0xFFF8F9FA), padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Row(children: const [
          Expanded(flex: 2, child: Text('Date & Time', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(flex: 1, child: Text('Session', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(flex: 2, child: Text('Customer', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(flex: 3, child: Text('Items', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(flex: 1, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          SizedBox(width: 160),
        ])),
      const Divider(height: 1),
      // Body
      Expanded(child: _loading
        ? const Center(child: CircularProgressIndicator())
        : filtered.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.pause_circle_outline, size: 64, color: Colors.grey.shade200),
              const SizedBox(height: 12),
              Text(_bills.isEmpty ? 'No bills on hold' : 'No results', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
            ]))
          : ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final b = filtered[i];
                final ts = b['held_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(b['held_at'] as String).toLocal()) : '-';
                final sess = b['pos_sessions']?['session_number'] as String? ?? '-';
                final branch = b['pos_sessions']?['branches']?['name'] as String? ?? '-';
                final cust = b['customer_name'] as String? ?? 'Walk-in';
                final items = (b['items'] as List?) ?? [];
                final tot = (b['total'] as num?)?.toDouble() ?? 0;
                final itemsSummary = items.take(2).map((it) {
                  final name = (it as Map)['name'] as String? ?? '-';
                  final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
                  return '${qty.toStringAsFixed(0)}x $name';
                }).join(', ') + (items.length > 2 ? ' +${items.length - 2} more' : '');

                return Container(color: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: Row(children: [
                    Expanded(flex: 2, child: Text(ts, style: const TextStyle(fontSize: 12))),
                    Expanded(flex: 1, child: Text(sess, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text(branch, style: const TextStyle(fontSize: 12))),
                    Expanded(flex: 2, child: Row(children: [
                      Icon(Icons.person_outline, size: 14, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(child: Text(cust, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                    ])),
                    Expanded(flex: 3, child: Text(itemsSummary, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                    Expanded(flex: 1, child: Text('Rs. ${tot.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.orange))),
                    SizedBox(width: 160, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton.icon(
                        icon: const Icon(Icons.close, size: 14),
                        label: const Text('Cancel', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        onPressed: () => _cancelBill(b),
                      ),
                      const SizedBox(width: 6),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.play_arrow, size: 14),
                        label: const Text('Continue', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
                        onPressed: () => _continueBill(b),
                      ),
                    ])),
                  ]));
              })),
    ]));
  }
}
