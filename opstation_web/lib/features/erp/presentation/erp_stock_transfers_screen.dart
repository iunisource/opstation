import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

String _stStatusLabel(String s) {
  switch (s) {
    case 'in_transit':
      return 'In Transit';
    case 'pending':
      return 'Draft';
    default:
      return s.isEmpty ? '' : s[0].toUpperCase() + s.substring(1);
  }
}

Color _stStatusColor(String s) {
  switch (s) {
    case 'completed':
      return AppTheme.success;
    case 'in_transit':
      return AppTheme.primary;
    case 'rejected':
      return AppTheme.danger;
    case 'cancelled':
      return Colors.grey;
    default:
      return Colors.orange; // draft / pending
  }
}

class ErpStockTransfersScreen extends ConsumerStatefulWidget {
  const ErpStockTransfersScreen({super.key});
  @override
  ConsumerState<ErpStockTransfersScreen> createState() =>
      _ErpStockTransfersScreenState();
}

class _ErpStockTransfersScreenState
    extends ConsumerState<ErpStockTransfersScreen> {
  List<Map<String, dynamic>> _transfers = [];
  List<Map<String, dynamic>> _allBranches = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final branchId = _branchId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final client = Supabase.instance.client;
      final baseQuery = client.from('stock_transfers').select(
          '*, from_branch:branches!from_branch_id(name), to_branch:branches!to_branch_id(name)').eq('org_id', orgId);
      final transfers = branchId != null
          ? await baseQuery
              .or('from_branch_id.eq.$branchId,and(to_branch_id.eq.$branchId,status.not.in.(draft,pending,cancelled))')
              .order('created_at', ascending: false)
          : await baseQuery.order('created_at', ascending: false);
      final branches = await client
          .from('branches')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      setState(() {
        _transfers = List<Map<String, dynamic>>.from(transfers);
        _allBranches = List<Map<String, dynamic>>.from(branches);
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _openTransfer(Map<String, dynamic>? transfer) {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => _StockTransferVoucherScreen(
              transfer: transfer, branches: _allBranches, onUpdated: _load),
        ))
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(children: [
            const Text('Stock Transfers',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () => _openTransfer(null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Transfer'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
            ),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.border)),
                    child: Column(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        decoration: const BoxDecoration(
                            color: AppTheme.background,
                            borderRadius:
                                BorderRadius.vertical(top: Radius.circular(12))),
                        child: const Row(children: [
                          Expanded(
                              flex: 2,
                              child: Text('Voucher #',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text('From',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text('To',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text('Date',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: AppTheme.textSecondary))),
                          SizedBox(
                              width: 120,
                              child: Text('Status',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: AppTheme.textSecondary))),
                        ]),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: _transfers.isEmpty
                            ? const Center(
                                child: Text('No stock transfers yet.',
                                    style: TextStyle(
                                        color: AppTheme.textSecondary)))
                            : ListView.separated(
                                itemCount: _transfers.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final t = _transfers[i];
                                  final status =
                                      t['status'] as String? ?? 'pending';
                                  final date = t['transfer_date'] as String?;
                                  return InkWell(
                                    onTap: () => _openTransfer(t),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 20, vertical: 14),
                                      child: Row(children: [
                                        Expanded(
                                            flex: 2,
                                            child: Text(
                                                t['voucher_number'] as String? ??
                                                    '—',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600))),
                                        Expanded(
                                            flex: 2,
                                            child: Text(
                                                t['from_branch']?['name']
                                                        as String? ??
                                                    '-',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600))),
                                        Expanded(
                                            flex: 2,
                                            child: Text(
                                                t['to_branch']?['name']
                                                        as String? ??
                                                    '-',
                                                style: const TextStyle(
                                                    color: AppTheme.primary,
                                                    fontWeight:
                                                        FontWeight.w600))),
                                        Expanded(
                                            flex: 2,
                                            child: Text(
                                                date ?? '-',
                                                style: const TextStyle(
                                                    color: AppTheme
                                                        .textSecondary))),
                                        SizedBox(
                                          width: 120,
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 4),
                                              decoration: BoxDecoration(
                                                  color: _stStatusColor(status)
                                                      .withOpacity(0.1),
                                                  borderRadius:
                                                      BorderRadius.circular(6)),
                                              child: Text(
                                                  _stStatusLabel(status),
                                                  style: TextStyle(
                                                      color: _stStatusColor(
                                                          status),
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w600)),
                                            ),
                                          ),
                                        ),
                                      ]),
                                    ),
                                  );
                                }),
                      ),
                    ]),
                  ),
                ),
        ),
        const SizedBox(height: 16),
      ]),
    );
  }
}

// ============================================================================
// Full-screen master-detail voucher (handles new + existing) with the
// dispatch -> approve workflow.
// ============================================================================
class _StockTransferVoucherScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic>? transfer; // null = new
  final List<Map<String, dynamic>> branches;
  final VoidCallback onUpdated;
  const _StockTransferVoucherScreen(
      {required this.transfer, required this.branches, required this.onUpdated});
  @override
  ConsumerState<_StockTransferVoucherScreen> createState() =>
      _StockTransferVoucherScreenState();
}

class _StockTransferVoucherScreenState
    extends ConsumerState<_StockTransferVoucherScreen> {
  Map<String, dynamic>? _transfer;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  // Inline line editing
  int _lineSeq = 0;
  final Map<String, TextEditingController> _qtyCtrls = {};
  final List<String> _removedLineIds = [];
  bool _loading = true;
  bool _busy = false;

  // Header edit state (draft only).
  String? _fromBranchId;
  String? _toBranchId;
  DateTime _date = DateTime.now();
  final _notesCtrl = TextEditingController();

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;

  String get _status => (_transfer?['status'] as String?) ?? 'draft';
  bool get _isNew => _transfer == null;
  bool get _isDraft =>
      _isNew || _status == 'draft' || _status == 'pending';
  bool get _isInTransit => _status == 'in_transit';

  @override
  void initState() {
    super.initState();
    _transfer = widget.transfer;
    if (_transfer != null) {
      _fromBranchId = _transfer!['from_branch_id'] as String?;
      _toBranchId = _transfer!['to_branch_id'] as String?;
      final d = _transfer!['transfer_date'] as String?;
      if (d != null) _date = DateTime.tryParse(d) ?? DateTime.now();
      _notesCtrl.text = (_transfer!['notes'] as String?) ?? '';
    } else {
      _fromBranchId = ref.read(selectedBranchProvider)?['id'] as String?;
    }
    _load();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    for (final c in _qtyCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final client = Supabase.instance.client;
      final products = await client
          .from('products')
          .select('id, name, sku, base_uom_id')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name')
          .limit(10000);
      final uoms =
          await client.from('uoms').select().eq('org_id', orgId).order('name');
      List<Map<String, dynamic>> items = [];
      Map<String, dynamic>? fresh = _transfer;
      if (_transfer != null) {
        final rows = await client
            .from('stock_transfer_items')
            .select('*, products(name, sku), uoms(name, abbreviation)')
            .eq('transfer_id', _transfer!['id']);
        items = List<Map<String, dynamic>>.from(rows);
        fresh = await client
            .from('stock_transfers')
            .select(
                '*, from_branch:branches!from_branch_id(name), to_branch:branches!to_branch_id(name)')
            .eq('id', _transfer!['id'])
            .single();
      }
      setState(() {
        _products = List<Map<String, dynamic>>.from(products);
        _uoms = List<Map<String, dynamic>>.from(uoms);
        for (final c in _qtyCtrls.values) {
          c.dispose();
        }
        _qtyCtrls.clear();
        _removedLineIds.clear();
        _items = items.map(_normalizeLine).toList();
        if (fresh != null) _transfer = fresh;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  String _branchName(String? id) {
    final b = widget.branches.firstWhere((e) => e['id'] == id,
        orElse: () => const {});
    return (b['name'] as String?) ?? '-';
  }

  Future<String> _nextVoucherNo() async {
    final orgId = _orgId!;
    final year = DateTime.now().year;
    final existing = await Supabase.instance.client
        .from('stock_transfers')
        .select('voucher_number')
        .eq('org_id', orgId)
        .like('voucher_number', 'ST-$year-%');
    final n = (existing as List).length + 1;
    return 'ST-$year-${n.toString().padLeft(4, '0')}';
  }

  // ── Save draft (create or update header) ──────────────────────────────────
  Future<bool> _persistAll() async {
    if (_fromBranchId == null || _toBranchId == null) {
      _snack('Both branches are required');
      return false;
    }
    if (_fromBranchId == _toBranchId) {
      _snack('Source and destination must differ');
      return false;
    }
    final client = Supabase.instance.client;
    final payload = {
      'from_branch_id': _fromBranchId,
      'to_branch_id': _toBranchId,
      'transfer_date': DateFormat('yyyy-MM-dd').format(_date),
      'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (_isNew) {
      final id = 'st_${DateTime.now().millisecondsSinceEpoch}';
      final vno = await _nextVoucherNo();
      await client.from('stock_transfers').insert({
        'id': id,
        'org_id': _orgId,
        'voucher_number': vno,
        'status': 'draft',
        'created_by': _userId,
        ...payload,
      });
      _transfer = {
        'id': id,
        'voucher_number': vno,
        'status': 'draft',
        'from_branch_id': _fromBranchId,
        'to_branch_id': _toBranchId,
      };
    } else {
      await client
          .from('stock_transfers')
          .update(payload)
          .eq('id', _transfer!['id']);
    }
    await _persistLines();
    return true;
  }

  Future<void> _persistLines() async {
    final client = Supabase.instance.client;
    for (final id in _removedLineIds) {
      await client.from('stock_transfer_items').delete().eq('id', id);
    }
    _removedLineIds.clear();
    for (final line in _items) {
      final pid = line['product_id'] as String?;
      final qty = (line['quantity'] as num?)?.toDouble() ?? 0;
      if (pid == null || qty <= 0) continue;
      final payload = {
        'transfer_id': _transfer!['id'],
        'product_id': pid,
        'uom_id': line['uom_id'],
        'quantity': qty,
        'unit_cost': 0,
      };
      if (line['id'] == null) {
        final id = 'sti_${DateTime.now().microsecondsSinceEpoch}_${_lineSeq++}';
        await client.from('stock_transfer_items').insert({'id': id, ...payload});
        line['id'] = id;
      } else {
        await client
            .from('stock_transfer_items')
            .update(payload)
            .eq('id', line['id']);
      }
    }
  }

  Future<void> _saveDraft() async {
    setState(() => _busy = true);
    try {
      final ok = await _persistAll();
      if (ok) {
        _snack('Saved');
        widget.onUpdated();
        await _load();
      }
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Items (inline line editor) ────────────────────────────────────────────
  Map<String, dynamic> _normalizeLine(Map<String, dynamic> r) {
    return {
      '_k': 'ln_${_lineSeq++}',
      'id': r['id'],
      'product_id': r['product_id'],
      'uom_id': r['uom_id'],
      'quantity': (r['quantity'] as num?)?.toDouble() ?? 0,
      'product_name': r['products']?['name'],
      'sku': r['products']?['sku'],
      'uom_abbr': r['uoms']?['abbreviation'],
    };
  }

  String? _uomAbbr(String? id) {
    if (id == null) return null;
    final u = _uoms.firstWhere((e) => e['id'] == id, orElse: () => const {});
    return u['abbreviation'] as String?;
  }

  TextEditingController _qtyCtrl(Map<String, dynamic> line) {
    final k = line['_k'] as String;
    return _qtyCtrls.putIfAbsent(
        k,
        () => TextEditingController(
            text: _fmtQty((line['quantity'] as num?)?.toDouble() ?? 1)));
  }

  void _addBlankLine() {
    setState(() {
      _items.add({
        '_k': 'ln_${_lineSeq++}',
        'id': null,
        'product_id': null,
        'uom_id': null,
        'quantity': 1.0,
        'product_name': null,
        'sku': null,
        'uom_abbr': null,
      });
    });
  }

  void _removeLine(Map<String, dynamic> line) {
    setState(() {
      final id = line['id'] as String?;
      if (id != null) _removedLineIds.add(id);
      _qtyCtrls.remove(line['_k'])?.dispose();
      _items.remove(line);
    });
  }

  // ── Dispatch: decrement SOURCE, move to in_transit ────────────────────────
  Future<void> _dispatch() async {
    if (_items.where((i) => i['product_id'] != null).isEmpty) {
      _snack('Add items before dispatching');
      return;
    }
    final client = Supabase.instance.client;
    final orgId = _orgId!;
    final fromBranchId = _transfer!['from_branch_id'] as String;

    final lines = _items
        .where((i) =>
            i['product_id'] != null &&
            ((i['quantity'] as num?)?.toDouble() ?? 0) > 0)
        .toList();

    // Stock availability (informational, non-blocking).
    final pids = lines.map((i) => i['product_id'] as String).toList();
    final srcRows = await client
        .from('inventory_stock')
        .select('product_id, quantity')
        .eq('org_id', orgId)
        .eq('branch_id', fromBranchId)
        .inFilter('product_id', pids);
    final srcQty = <String, double>{};
    for (final s in srcRows as List) {
      srcQty[s['product_id'] as String] =
          (s['quantity'] as num?)?.toDouble() ?? 0;
    }
    final shortfalls = <String>[];
    for (final it in lines) {
      final pid = it['product_id'] as String;
      final need = (it['quantity'] as num).toDouble();
      final have = srcQty[pid] ?? 0;
      if (have < need) {
        final name = it['product_name'] as String? ?? pid;
        shortfalls.add('$name: have ${_fmtQty(have)}, sending ${_fmtQty(need)}');
      }
    }

    // Hard stop: cannot send stock the source branch doesn't have.
    if (shortfalls.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Cannot dispatch'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${_branchName(fromBranchId)} does not have enough stock to send:'),
              const SizedBox(height: 8),
              ...shortfalls.map((s) => Text('• $s',
                  style:
                      const TextStyle(fontSize: 12, color: AppTheme.danger))),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).pop(),
                child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Dispatch Transfer'),
        content: Text(
            'Stock will leave ${_branchName(fromBranchId)} now and sit in transit until the destination approves it.'),
        actions: [
          TextButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('Dispatch')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      // Commit any unsaved header/line edits first — the RPC reads from the DB.
      final ok = await _persistAll();
      if (!ok) {
        setState(() => _busy = false);
        return;
      }
      await client.rpc('post_stock_transfer_dispatch', params: {
        'p_id': _transfer!['id'],
        'p_user': _userId,
      });
      _snack('Dispatched — awaiting approval at destination');
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Approve / Receive: increment DESTINATION, mark completed ──────────────
  Future<void> _receive() async {
    final client = Supabase.instance.client;
    final toBranchId = _transfer!['to_branch_id'] as String;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Transfer'),
        content: Text(
            'Confirm receipt at ${_branchName(toBranchId)}. The in-transit stock will be added to this branch.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('Approve & Receive')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await client.rpc('post_stock_transfer_receipt', params: {
        'p_id': _transfer!['id'],
        'p_user': _userId,
      });
      _snack('Approved — stock received at destination');
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Reject (in_transit) / Cancel (draft) ──────────────────────────────────
  Future<void> _rejectOrCancel() async {
    final client = Supabase.instance.client;
    final inTransit = _isInTransit;
    final fromBranchId = _transfer!['from_branch_id'] as String;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(inTransit ? 'Reject Transfer' : 'Cancel Transfer'),
        content: Text(inTransit
            ? 'Rejecting will return the in-transit stock to ${_branchName(fromBranchId)}.'
            : 'Cancel this draft transfer?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('No')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
              child: Text(inTransit ? 'Reject' : 'Cancel Transfer')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      if (inTransit) {
        await client.rpc('post_stock_transfer_reject', params: {
          'p_id': _transfer!['id'],
          'p_user': _userId,
        });
      } else {
        await client.from('stock_transfers').update({
          'status': 'cancelled',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', _transfer!['id']);
      }
      _snack(inTransit ? 'Rejected — stock returned to source' : 'Cancelled');
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtQty(double q) => q % 1 == 0 ? q.toInt().toString() : q.toString();

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final editable = _isDraft;
    final selectedBranchId =
        ref.watch(selectedBranchProvider)?['id'] as String?;
    // Approval is only possible while standing in the destination branch.
    final canApprove = _toBranchId != null && selectedBranchId == _toBranchId;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              _transfer?['voucher_number'] as String? ?? 'New Stock Transfer',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text('${_branchName(_fromBranchId)} → ${_branchName(_toBranchId)}',
              style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w400)),
        ]),
        actions: [
          if (!_isNew)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: _stStatusColor(_status).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(_stStatusLabel(_status),
                    style: TextStyle(
                        color: _stStatusColor(_status),
                        fontWeight: FontWeight.w700,
                        fontSize: 12)),
              ),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _headerCard(editable),
                    const SizedBox(height: 20),
                    Row(children: [
                      const Text('Items',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      if (editable)
                        OutlinedButton.icon(
                            onPressed: _addBlankLine,
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add line')),
                    ]),
                    const SizedBox(height: 12),
                    Expanded(child: _itemsCard(editable)),
                    const SizedBox(height: 16),
                    _actionBar(canApprove),
                  ]),
            ),
    );
  }

  Widget _headerCard(bool editable) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Wrap(
        spacing: 20,
        runSpacing: 14,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          _hField(
              'From Branch',
              SizedBox(
                width: 220,
                child: _readonly(_branchName(_fromBranchId)),
              )),
          _hField(
              'To Branch',
              SizedBox(
                width: 220,
                child: editable
                    ? DropdownButtonFormField<String>(
                        value: _toBranchId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder()),
                        items: widget.branches
                            .where((b) => b['id'] != _fromBranchId)
                            .map((b) => DropdownMenuItem(
                                value: b['id'] as String,
                                child: Text(b['name'] as String,
                                    overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: (v) => setState(() => _toBranchId = v),
                      )
                    : _readonly(_branchName(_toBranchId)),
              )),
          _hField(
              'Date',
              SizedBox(
                width: 160,
                child: editable
                    ? InkWell(
                        onTap: () async {
                          final p = await showDatePicker(
                              context: context,
                              initialDate: _date,
                              firstDate: DateTime(2000),
                              lastDate: DateTime.now()
                                  .add(const Duration(days: 365)));
                          if (p != null) setState(() => _date = p);
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(
                              isDense: true, border: OutlineInputBorder()),
                          child: Text(DateFormat('d MMM yyyy').format(_date)),
                        ),
                      )
                    : _readonly(DateFormat('d MMM yyyy').format(_date)),
              )),
          _hField(
              'Notes',
              SizedBox(
                width: 260,
                child: editable
                    ? TextField(
                        controller: _notesCtrl,
                        decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder()),
                      )
                    : _readonly(_notesCtrl.text.isEmpty ? '—' : _notesCtrl.text),
              )),
        ],
      ),
    );
  }

  Widget _hField(String label, Widget child) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      child,
    ]);
  }

  Widget _readonly(String v) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.border)),
        child: Text(v, overflow: TextOverflow.ellipsis),
      );

  Widget _itemsCard(bool editable) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
          child: const Row(children: [
            Expanded(
                flex: 5,
                child: Text('Product',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            Expanded(
                flex: 2,
                child: Text('UOM',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            Expanded(
                flex: 2,
                child: Text('Quantity',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            SizedBox(width: 48),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _items.isEmpty
              ? Center(
                  child: editable
                      ? TextButton.icon(
                          onPressed: _addBlankLine,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add the first line'))
                      : const Text('No items.',
                          style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  itemCount: _items.length + (editable ? 1 : 0),
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    if (editable && i == _items.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                              onPressed: _addBlankLine,
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Add line')),
                        ),
                      );
                    }
                    return _lineRow(_items[i], editable);
                  }),
        ),
      ]),
    );
  }

  Widget _lineRow(Map<String, dynamic> line, bool editable) {
    final hasProduct = line['product_id'] != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(children: [
        // Product
        Expanded(
          flex: 5,
          child: (editable && !hasProduct)
              ? _productPicker(line)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(line['product_name'] as String? ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (line['sku'] != null)
                      Text(line['sku'] as String,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary)),
                  ]),
        ),
        const SizedBox(width: 8),
        // UOM (auto base unit, read-only)
        Expanded(
          flex: 2,
          child: Text(line['uom_abbr'] as String? ?? '—',
              style: const TextStyle(color: AppTheme.textSecondary)),
        ),
        const SizedBox(width: 8),
        // Quantity
        Expanded(
          flex: 2,
          child: editable
              ? SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _qtyCtrl(line),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder()),
                    onChanged: (v) =>
                        line['quantity'] = double.tryParse(v.trim()) ?? 0,
                  ),
                )
              : Text(_fmtQty((line['quantity'] as num?)?.toDouble() ?? 0),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        SizedBox(
            width: 48,
            child: editable
                ? IconButton(
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: AppTheme.danger),
                    onPressed: () => _removeLine(line))
                : const SizedBox.shrink()),
      ]),
    );
  }

  Widget _productPicker(Map<String, dynamic> line) {
    return RawAutocomplete<Map<String, dynamic>>(
      displayStringForOption: (o) => o['name'] as String? ?? '',
      optionsBuilder: (tev) {
        final q = tev.text.toLowerCase().trim();
        if (q.isEmpty) return _products.take(50);
        return _products.where((p) {
          final name = (p['name'] as String? ?? '').toLowerCase();
          final sku = (p['sku'] as String? ?? '').toLowerCase();
          return name.contains(q) || sku.contains(q);
        }).take(50);
      },
      fieldViewBuilder: (ctx, ctrl, focus, onSubmit) => SizedBox(
        height: 38,
        child: TextField(
          controller: ctrl,
          focusNode: focus,
          decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search product…',
              prefixIcon: Icon(Icons.search, size: 16),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder()),
          onSubmitted: (_) => onSubmit(),
        ),
      ),
      optionsViewBuilder: (ctx, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300, maxWidth: 460),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: options
                  .map((o) => ListTile(
                        dense: true,
                        title: Text(o['name'] as String? ?? ''),
                        subtitle: o['sku'] != null
                            ? Text(o['sku'] as String,
                                style: const TextStyle(fontSize: 11))
                            : null,
                        onTap: () => onSelected(o),
                      ))
                  .toList(),
            ),
          ),
        ),
      ),
      onSelected: (o) {
        setState(() {
          line['product_id'] = o['id'];
          line['product_name'] = o['name'];
          line['sku'] = o['sku'];
          line['uom_id'] = o['base_uom_id'];
          line['uom_abbr'] = _uomAbbr(o['base_uom_id'] as String?);
        });
      },
    );
  }

  Widget _actionBar(bool canApprove) {
    final children = <Widget>[];
    if (_isNew) {
      children.add(ElevatedButton.icon(
        onPressed: _busy ? null : _saveDraft,
        icon: const Icon(Icons.save_outlined, size: 18),
        label: const Text('Save Draft'),
        style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
      ));
    } else if (_isDraft) {
      children.addAll([
        OutlinedButton.icon(
            onPressed: _busy ? null : _saveDraft,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save')),
        const SizedBox(width: 10),
        ElevatedButton.icon(
          onPressed: _busy ? null : _dispatch,
          icon: const Icon(Icons.local_shipping_outlined, size: 18),
          label: const Text('Dispatch'),
          style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
        ),
        const Spacer(),
        TextButton(
            onPressed: _busy ? null : _rejectOrCancel,
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('Cancel Transfer')),
      ]);
    } else if (_isInTransit) {
      if (canApprove) {
        children.addAll([
          ElevatedButton.icon(
            onPressed: _busy ? null : _receive,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('Approve & Receive'),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.success,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
              onPressed: _busy ? null : _rejectOrCancel,
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
              child: const Text('Reject')),
        ]);
      } else {
        children.add(Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.hourglass_top,
              size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 6),
          Text('Awaiting approval at ${_branchName(_toBranchId)}',
              style: const TextStyle(color: AppTheme.textSecondary)),
        ]));
      }
    } else {
      children.add(Text(
          'This transfer is ${_stStatusLabel(_status).toLowerCase()}.',
          style: const TextStyle(color: AppTheme.textSecondary)));
    }
    return Row(children: children);
  }
}
