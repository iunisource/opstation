import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/notifications/global_transfer_alert.dart';
import '../../../core/widgets/product_picker.dart';
import '../../auth/auth_controller.dart';
import '../services/voucher_pdf.dart';
import '../../../core/utils/friendly_error.dart';

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
  const ErpStockTransfersScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpStockTransfersScreen> createState() =>
      _ErpStockTransfersScreenState();
}

class _ErpStockTransfersScreenState
    extends ConsumerState<ErpStockTransfersScreen> {
  List<Map<String, dynamic>> _transfers = [];
  List<Map<String, dynamic>> _allBranches = [];
  bool _loading = true;
  bool _focusHandled = false;
  String _statusFilter = 'all';
  bool _incomingOnly = false;
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matchesStatus(String filter, String status) {
    if (filter == 'all') return true;
    if (filter == 'draft') return status == 'draft' || status == 'pending';
    return status == filter;
  }

  /// Transfers after the "incoming only" toggle (to my branch), before the
  /// status chip is applied — used both for the table and for the chip counts.
  List<Map<String, dynamic>> _incomingBase() {
    if (!_incomingOnly || _branchId == null) return _transfers;
    return _transfers
        .where((t) => t['to_branch_id'] == _branchId)
        .toList();
  }

  List<Map<String, dynamic>> _visibleTransfers() {
    var base = _incomingBase();
    if (_statusFilter != 'all') {
      base = base
          .where((t) =>
              _matchesStatus(_statusFilter, t['status'] as String? ?? 'pending'))
          .toList();
    }
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base.where((t) {
      final voucher = (t['voucher_number'] as String? ?? '').toLowerCase();
      final date = (t['transfer_date'] as String? ?? '').toLowerCase();
      final notes = (t['notes'] as String? ?? '').toLowerCase();
      final from = (t['from_branch']?['name'] as String? ?? '').toLowerCase();
      final to = (t['to_branch']?['name'] as String? ?? '').toLowerCase();
      return voucher.contains(q) || date.contains(q) || notes.contains(q) ||
          from.contains(q) || to.contains(q);
    }).toList();
  }

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
              .or('from_branch_id.eq.$branchId,to_branch_id.eq.$branchId')
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
      // Deep-link from global search: open the exact transfer once.
      if (!_focusHandled && widget.focusId != null) {
        _focusHandled = true;
        final match = _transfers.where((t) => t['id'] == widget.focusId).toList();
        if (match.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openTransfer(match.first);
          });
        }
      }
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
        .then((_) {
      _load();
      ref.invalidate(transferPendingCountProvider); // an accept clears the badge
    });
  }

  /// Open a specific transfer by id (from the global "Open & Accept" alert),
  /// fetching it if it isn't in the current list. Clears the request.
  Future<void> _openRequestedTransfer(String id) async {
    ref.read(transferOpenRequestProvider.notifier).state = null;
    final inList = _transfers.where((t) => t['id'] == id).toList();
    if (inList.isNotEmpty) {
      _openTransfer(inList.first);
      return;
    }
    try {
      final row = await Supabase.instance.client
          .from('stock_transfers')
          .select(
              '*, from_branch:branches!from_branch_id(name), to_branch:branches!to_branch_id(name)')
          .eq('id', id)
          .maybeSingle();
      if (row != null && mounted) {
        _openTransfer(Map<String, dynamic>.from(row as Map));
      }
    } catch (_) {}
  }

  Widget _buildFilterBar() {
    final base = _incomingBase();
    int cnt(String f) => f == 'all'
        ? base.length
        : base.where((t) => _matchesStatus(f, t['status'] as String? ?? 'pending')).length;
    const filters = [
      ['all', 'All'],
      ['draft', 'Draft'],
      ['in_transit', 'In Transit'],
      ['completed', 'Completed'],
      ['rejected', 'Rejected'],
      ['cancelled', 'Cancelled'],
    ];
    final branchName = ref.read(selectedBranchProvider)?['name'] as String?;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Row(children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in filters)
                ChoiceChip(
                  label: Text('${f[1]} (${cnt(f[0])})', style: const TextStyle(fontSize: 12)),
                  selected: _statusFilter == f[0],
                  visualDensity: VisualDensity.compact,
                  selectedColor: AppTheme.primary.withOpacity(0.15),
                  labelStyle: TextStyle(
                      color: _statusFilter == f[0] ? AppTheme.primary : AppTheme.textSecondary,
                      fontWeight: _statusFilter == f[0] ? FontWeight.w700 : FontWeight.w500),
                  onSelected: (_) => setState(() => _statusFilter = f[0]),
                ),
            ],
          ),
        ),
        if (_branchId != null) ...[
          const SizedBox(width: 12),
          FilterChip(
            avatar: Icon(Icons.call_received,
                size: 15, color: _incomingOnly ? AppTheme.primary : AppTheme.textSecondary),
            label: Text(
                branchName != null ? 'Incoming to $branchName' : 'Incoming only',
                style: const TextStyle(fontSize: 12)),
            selected: _incomingOnly,
            visualDensity: VisualDensity.compact,
            selectedColor: AppTheme.primary.withOpacity(0.15),
            checkmarkColor: AppTheme.primary,
            labelStyle: TextStyle(
                color: _incomingOnly ? AppTheme.primary : AppTheme.textSecondary,
                fontWeight: _incomingOnly ? FontWeight.w700 : FontWeight.w500),
            onSelected: (v) => setState(() => _incomingOnly = v),
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    // "Open & Accept" from the app-global transfer alert asks us to open a
    // specific transfer (where Approve & Receive lives).
    ref.listen(transferOpenRequestProvider, (prev, next) {
      if (next != null) _openRequestedTransfer(next);
    });
    final filtered = _visibleTransfers();
    return Container(
      color: AppTheme.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(children: [
            const Text('Stock Transfers',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const Spacer(),
            SizedBox(
              width: 300,
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  hintText: 'Search voucher, date, remarks, branch…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: const OutlineInputBorder(),
                  suffixIcon: _search.isEmpty ? null : IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () => setState(() { _searchCtrl.clear(); _search = ''; }),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
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
        if (!_loading) _buildFilterBar(),
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
                          Expanded(
                              flex: 2,
                              child: Text('Remarks',
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
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(
                                    _transfers.isEmpty
                                        ? 'No stock transfers yet.'
                                        : 'No transfers match this filter.',
                                    style: const TextStyle(
                                        color: AppTheme.textSecondary)))
                            : ListView.separated(
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final t = filtered[i];
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
                                        Expanded(
                                            flex: 2,
                                            child: Text(
                                                (t['notes'] as String?)?.isNotEmpty == true
                                                    ? t['notes'] as String : '—',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    color: AppTheme.textSecondary))),
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
  // Session cache for the org-wide product & UOM catalogue — these rarely change
  // during a session, so opening several transfers in a row skips the two
  // heaviest fetches. Short TTL keeps a freshly-added product from staying hidden
  // for long.
  static List<Map<String, dynamic>>? _catProducts;
  static List<Map<String, dynamic>>? _catUoms;
  static String? _catOrg;
  static DateTime? _catAt;

  Map<String, dynamic>? _transfer;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _uoms = [];
  Map<String, double> _inHand = {}; // product_id -> qty at SOURCE branch
  bool _loading = true;
  bool _busy = false;
  Map<String, String> _userNames = {}; // id -> name, for the audit trail

  // Header edit state (draft only).
  String? _fromBranchId;
  String? _toBranchId;
  DateTime _date = DateTime.now();
  final _notesCtrl = TextEditingController();

  // Inline add-row state (quotation-style picker loop)
  String? _addProductId;
  String? _addUomId;
  final _addQtyCtrl = TextEditingController(text: '1');
  final _addQtyFocus = FocusNode();

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
    _addQtyCtrl.dispose();
    _addQtyFocus.dispose();
    super.dispose();
  }

  // Products + UOMs are org-wide and rarely change; serve from a 2-minute cache.
  Future<void> _ensureCatalog(String orgId, SupabaseClient client) async {
    final okc = _catOrg == orgId &&
        _catProducts != null && _catUoms != null && _catAt != null &&
        DateTime.now().difference(_catAt!).inSeconds < 120;
    if (okc) return;
    final res = await Future.wait([
      client.from('products')
          .select('id, name, sku, base_uom_id')
          .eq('org_id', orgId).eq('is_active', true).order('name').limit(10000),
      client.from('uoms').select().eq('org_id', orgId).order('name'),
    ]);
    _catProducts = List<Map<String, dynamic>>.from(res[0] as List);
    _catUoms = List<Map<String, dynamic>>.from(res[1] as List);
    _catOrg = orgId;
    _catAt = DateTime.now();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final client = Supabase.instance.client;

      // Kick off all independent queries at once instead of one-after-another:
      //  - the catalogue (cached), and (when editing) this voucher's items + row.
      final catalogF = _ensureCatalog(orgId, client);
      Future<List<Map<String, dynamic>>>? itemsF;
      Future<Map<String, dynamic>>? freshF;
      if (_transfer != null) {
        final tid = _transfer!['id'];
        itemsF = client
            .from('stock_transfer_items')
            .select('*, products(name, sku), uoms(name, abbreviation)')
            .eq('transfer_id', tid)
            .then((r) => List<Map<String, dynamic>>.from(r as List));
        freshF = client
            .from('stock_transfers')
            .select('*, from_branch:branches!from_branch_id(name), to_branch:branches!to_branch_id(name)')
            .eq('id', tid)
            .single()
            .then((r) => Map<String, dynamic>.from(r as Map));
      }

      await catalogF;
      final items = itemsF == null ? <Map<String, dynamic>>[] : await itemsF;
      final Map<String, dynamic>? fresh = freshF == null ? _transfer : await freshF;

      // These two depend on `fresh` (source branch + actor ids) — run them
      // together once we have it.
      final srcBranch = (fresh?['from_branch_id'] as String?) ?? _fromBranchId;
      final ids = <String>{
        for (final k in ['created_by', 'dispatched_by', 'approved_by'])
          if (fresh?[k] != null) fresh![k] as String,
      };
      final namesF = ids.isEmpty
          ? Future.value(<String, String>{})
          : client.from('users').select('id, name').inFilter('id', ids.toList()).then((us) {
              final m = <String, String>{};
              for (final u in us as List) { m[u['id'] as String] = (u['name'] as String?) ?? '—'; }
              return m;
            }).catchError((_) => <String, String>{});
      final inHandF = srcBranch == null
          ? Future.value(<String, double>{})
          : client.from('inventory_stock')
              .select('product_id, quantity')
              .eq('org_id', orgId).eq('branch_id', srcBranch)
              .then((rows) {
                final m = <String, double>{};
                for (final s in rows as List) {
                  final pid = s['product_id'] as String;
                  m[pid] = (m[pid] ?? 0) + ((s['quantity'] as num?)?.toDouble() ?? 0);
                }
                return m;
              }).catchError((_) => <String, double>{});

      final results = await Future.wait([namesF, inHandF]);
      final names = results[0] as Map<String, String>;
      final inHand = results[1] as Map<String, double>;

      if (!mounted) return;
      setState(() {
        _products = _catProducts ?? [];
        _uoms = _catUoms ?? [];
        _items = items;
        if (fresh != null) _transfer = fresh;
        _userNames = names;
        _inHand = inHand;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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
    // Preferred: atomic, race-safe number from the DB function.
    try {
      final res = await Supabase.instance.client
          .rpc('next_stock_transfer_number', params: {'p_org_id': orgId});
      if (res is String && res.isNotEmpty) return res;
    } catch (_) {/* fall back below if the function isn't deployed yet */}
    // Fallback: MAX-based (not count-based, so gaps don't cause reuse). The
    // unique index still guards against collisions; the caller retries once.
    final year = DateTime.now().year;
    final existing = await Supabase.instance.client
        .from('stock_transfers')
        .select('voucher_number')
        .eq('org_id', orgId)
        .like('voucher_number', 'ST-$year-%');
    int mx = 0;
    for (final r in existing as List) {
      final tail = (r['voucher_number'] as String?)?.split('-').last ?? '';
      final v = int.tryParse(tail) ?? 0;
      if (v > mx) mx = v;
    }
    return 'ST-$year-${(mx + 1).toString().padLeft(4, '0')}';
  }

  // ── Save draft (create or update header) ──────────────────────────────────
  Future<void> _saveDraft() async {
    if (_fromBranchId == null || _toBranchId == null) {
      _snack('Both branches are required');
      return;
    }
    if (_fromBranchId == _toBranchId) {
      _snack('Source and destination must differ');
      return;
    }
    setState(() => _busy = true);
    try {
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
        var vno = await _nextVoucherNo();
        // Retry once if the unique index rejects a colliding number (race).
        for (var attempt = 0; ; attempt++) {
          try {
            await client.from('stock_transfers').insert({
              'id': id,
              'org_id': _orgId,
              'voucher_number': vno,
              'status': 'draft',
              'created_by': _userId,
              ...payload,
            });
            break;
          } on PostgrestException catch (e) {
            if (e.code == '23505' && attempt < 3) {
              vno = await _nextVoucherNo();
              continue;
            }
            rethrow;
          }
        }
        _transfer = {'id': id, 'voucher_number': vno, 'status': 'draft'};
        _snack('Draft $vno created');
      } else {
        await client
            .from('stock_transfers')
            .update(payload)
            .eq('id', _transfer!['id']);
        _snack('Saved');
      }
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack(friendlyError('That did not save', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Items ─────────────────────────────────────────────────────────────────
  // ── Items: inline add-row with quotation-style picker loop ────────────────
  Future<void> _ensureSaved() async {
    if (_transfer == null) {
      await _saveDraft();
    }
  }

  // Open the product picker (search + up/down/enter), set product + default
  // UOM, then focus Qty. Shared by the "+ Add product" tap and the Enter loop.
  Future<bool> _pickAddProduct() async {
    if (!_isDraft) return false;
    await _ensureSaved();
    if (_transfer == null) return false; // save failed (branches missing)
    final p = await pickProduct(context, _products, title: 'Add product');
    if (p == null || p.isEmpty) return false; // dismissed → loop ends
    setState(() {
      _addProductId = p['id'] as String?;
      _addUomId = p['base_uom_id'] as String?;
      _addQtyCtrl.text = '1';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _addQtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _addQtyCtrl.text.length);
      _addQtyFocus.requestFocus();
    });
    return true;
  }

  Future<bool> _addItem() async {
    if (_transfer == null) { _snack('Save the transfer first'); return false; }
    if (_addProductId == null || _addUomId == null) { _snack('Pick a product first'); return false; }
    final qty = double.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) { _snack('Quantity must be > 0'); return false; }
    // Hard stock check: qty being added + qty already on this voucher for the
    // same product must not exceed what the source branch has in hand.
    final have = _inHand[_addProductId] ?? 0;
    double alreadyOnVoucher = 0;
    for (final it in _items) {
      if (it['product_id'] == _addProductId) {
        alreadyOnVoucher += (it['quantity'] as num?)?.toDouble() ?? 0;
      }
    }
    if (qty + alreadyOnVoucher > have) {
      final name = _products.firstWhere((p) => p['id'] == _addProductId,
          orElse: () => const {})['name'] as String? ?? 'This product';
      _snack(alreadyOnVoucher > 0
          ? 'Not enough stock: $name has ${_fmtQty(have)} in hand, '
              '${_fmtQty(alreadyOnVoucher)} already on this voucher'
          : 'Not enough stock: $name has only ${_fmtQty(have)} in hand');
      return false;
    }
    try {
      final client = Supabase.instance.client;
      // Merge into the existing line for this product+UOM rather than adding a
      // second row. A product appearing twice on one transfer makes the cost
      // posting write two records for the same product+cost-layer, which the DB
      // blocks (inventory_cost_consumption_uniq) at dispatch.
      Map<String, dynamic>? existing;
      for (final it in _items) {
        if (it['product_id'] == _addProductId && it['uom_id'] == _addUomId) {
          existing = it;
          break;
        }
      }
      if (existing != null) {
        final newQty =
            ((existing['quantity'] as num?)?.toDouble() ?? 0) + qty;
        await client
            .from('stock_transfer_items')
            .update({'quantity': newQty}).eq('id', existing['id']);
      } else {
        await client.from('stock_transfer_items').insert({
          'id': 'sti_${DateTime.now().millisecondsSinceEpoch}',
          'transfer_id': _transfer!['id'],
          'product_id': _addProductId,
          'uom_id': _addUomId,
          'quantity': qty,
          'unit_cost': 0,
        });
      }
      setState(() { _addProductId = null; _addUomId = null; _addQtyCtrl.text = '1'; });
      await _load();
      return true;
    } catch (e) {
      _snack(friendlyError('That did not save', e));
      return false;
    }
  }

  /// Collapse any duplicate (product + UOM) lines into one, summing quantities.
  /// Guards the cost-consumption uniqueness rule that a product appearing on two
  /// lines would violate at dispatch. Runs before dispatch so transfers created
  /// by bulk import or older data are healed too. Returns true if it merged.
  Future<bool> _mergeDuplicateItems() async {
    final byKey = <String, List<Map<String, dynamic>>>{};
    for (final it in _items) {
      byKey.putIfAbsent('${it['product_id']}|${it['uom_id']}', () => []).add(it);
    }
    final dups = byKey.values.where((g) => g.length > 1).toList();
    if (dups.isEmpty) return false;
    final client = Supabase.instance.client;
    for (final g in dups) {
      final keep = g.first;
      var sum = 0.0;
      for (final it in g) {
        sum += (it['quantity'] as num?)?.toDouble() ?? 0;
      }
      await client
          .from('stock_transfer_items')
          .update({'quantity': sum}).eq('id', keep['id']);
      for (final it in g.skip(1)) {
        await client
            .from('stock_transfer_items')
            .delete()
            .eq('id', it['id']);
      }
    }
    await _load();
    return true;
  }

  // Enter on Qty: add the line, then reopen the picker for the next product.
  Future<void> _addItemAndPickNext() async {
    final ok = await _addItem();
    if (!ok) return;
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    await _pickAddProduct();
  }

  Future<void> _removeItem(Map<String, dynamic> item) async {
    await Supabase.instance.client
        .from('stock_transfer_items')
        .delete()
        .eq('id', item['id']);
    _load();
  }

  // ── Dispatch: decrement SOURCE, move to in_transit ────────────────────────
  Future<void> _dispatch() async {
    if (_items.isEmpty) {
      _snack('Add items before dispatching');
      return;
    }
    // Heal any duplicate product lines first so the cost posting can't collide
    // on inventory_cost_consumption_uniq (same product on two lines).
    try {
      if (await _mergeDuplicateItems()) {
        _snack('Merged duplicate product lines');
      }
    } catch (e) {
      _snack('Could not merge duplicate lines: ${e.toString().split('\n').first}');
      return;
    }
    if (_items.isEmpty) return;
    final client = Supabase.instance.client;
    final orgId = _orgId!;
    final fromBranchId = _transfer!['from_branch_id'] as String;

    // ── Self-heal a "stuck" draft ────────────────────────────────────────────
    // A previous dispatch can leave source stock ALREADY deducted while the
    // voucher is still Draft — e.g. the connection dropped after the legacy
    // client loop decremented stock but before it flipped the status. Such a
    // voucher is a dead-end: it can't be re-dispatched (source now shows short)
    // and the destination can't receive it (still Draft). Detect it here from
    // the ledger and offer the correct recovery instead of the normal path.
    final needAgg = <String, double>{};
    for (final it in _items) {
      final pid = it['product_id'] as String;
      needAgg[pid] = (needAgg[pid] ?? 0) + (it['quantity'] as num).toDouble();
    }
    final moveRows = await client
        .from('inventory_movements')
        .select('product_id, quantity')
        .eq('org_id', orgId)
        .eq('reference_type', 'stock_transfer')
        .eq('reference_id', _transfer!['id'])
        .eq('branch_id', fromBranchId);
    final srcNet = <String, double>{}; // signed net at source for this transfer
    for (final m in moveRows as List) {
      final pid = m['product_id'] as String;
      srcNet[pid] = (srcNet[pid] ?? 0) + ((m['quantity'] as num?)?.toDouble() ?? 0);
    }
    final removed = <String, double>{}; // net qty already gone from source
    srcNet.forEach((pid, net) { if (net < -1e-6) removed[pid] = -net; });
    if (removed.values.any((v) => v > 0)) {
      // How complete is the deduction versus what the lines call for?
      final complete = needAgg.entries
          .every((e) => (removed[e.key] ?? 0) + 1e-6 >= e.value);
      if (complete) {
        await _resumeStuckDispatch();   // stock already gone → just go in-transit
      } else {
        await _reverseStuckDispatch(removed); // partial → put it back, stay draft
      }
      return;
    }

    // Stock availability — BLOCKING. Re-checked against the server right now
    // (stock may have changed since items were added). Needs are aggregated
    // per product so multiple lines of the same item are counted together.
    final pids = _items.map((i) => i['product_id'] as String).toSet().toList();
    final srcRows = await client
        .from('inventory_stock')
        .select('product_id, quantity')
        .eq('org_id', orgId)
        .eq('branch_id', fromBranchId)
        .inFilter('product_id', pids);
    final srcQty = <String, double>{};
    for (final s in srcRows as List) {
      final pid = s['product_id'] as String;
      srcQty[pid] =
          (srcQty[pid] ?? 0) + ((s['quantity'] as num?)?.toDouble() ?? 0);
    }
    final need = <String, double>{};
    final prodNames = <String, String>{};
    for (final it in _items) {
      final pid = it['product_id'] as String;
      need[pid] = (need[pid] ?? 0) + (it['quantity'] as num).toDouble();
      prodNames[pid] = it['products']?['name'] as String? ?? pid;
    }
    final shortfalls = <String>[];
    need.forEach((pid, n) {
      final have = srcQty[pid] ?? 0;
      if (have < n) {
        shortfalls.add(
            '${prodNames[pid]}: in hand ${_fmtQty(have)}, sending ${_fmtQty(n)}');
      }
    });
    // Keep the In Hand column in sync with what the server just told us.
    if (mounted) setState(() => _inHand = srcQty);

    if (shortfalls.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.block, color: AppTheme.danger, size: 20),
            SizedBox(width: 8),
            Text('Not Enough Stock'),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${_branchName(fromBranchId)} does not have enough stock to dispatch this transfer:'),
              const SizedBox(height: 8),
              ...shortfalls.map((s) => Text('• $s',
                  style: const TextStyle(fontSize: 12, color: AppTheme.danger))),
              const SizedBox(height: 8),
              const Text('Reduce the quantities or receive stock first.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ],
          ),
          actions: [
            ElevatedButton(
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
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('Dispatch')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      // Preferred: atomic server-side dispatch — decrements source stock, writes
      // the dated ledger movement, and flips status to in_transit in ONE
      // transaction, so a mid-loop failure can't half-move stock and a re-click
      // can't double-decrement. Falls back to the legacy client loop only if the
      // RPC isn't deployed (PGRST202).
      var serverDone = false;
      try {
        await client.rpc('dispatch_stock_transfer', params: {
          'p_transfer_id': _transfer!['id'],
          'p_user_id': _userId,
        });
        serverDone = true;
      } on PostgrestException catch (e) {
        if (e.code != 'PGRST202') rethrow;
      }
      if (!serverDone) {
      final now = DateTime.now().toUtc().toIso8601String();
      for (var i = 0; i < _items.length; i++) {
        final item = _items[i];
        final qty = (item['quantity'] as num).toDouble();
        final productId = item['product_id'] as String;
        final uomId = item['uom_id'] as String;
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_$i',
          'org_id': orgId,
          'product_id': productId,
          'branch_id': fromBranchId,
          'uom_id': uomId,
          'quantity': -qty,
          'movement_type': 'transfer',
          'reference_id': _transfer!['id'],
          'reference_type': 'stock_transfer',
          'moved_at': _movedAt(),
          'created_by': _userId,
        });
        final fromStock = await client
            .from('inventory_stock')
            .select()
            .eq('org_id', orgId)
            .eq('product_id', productId)
            .eq('branch_id', fromBranchId)
            .maybeSingle();
        if (fromStock != null) {
          await client.from('inventory_stock').update({
            'quantity': (fromStock['quantity'] as num).toDouble() - qty,
            'updated_at': now,
          }).eq('id', fromStock['id']);
        } else {
          await client.from('inventory_stock').insert({
            'id': 'is_${DateTime.now().microsecondsSinceEpoch}_$i',
            'org_id': orgId,
            'product_id': productId,
            'branch_id': fromBranchId,
            'uom_id': uomId,
            'quantity': -qty,
          });
        }
      }
      await client.from('stock_transfers').update({
        'status': 'in_transit',
        'dispatched_by': _userId,
        'dispatched_at': now,
        'updated_at': now,
      }).eq('id', _transfer!['id']);
      }
      _snack('Dispatched — awaiting approval at destination');
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack(friendlyError('That did not save', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Recovery: source stock already fully removed, but still Draft ─────────
  // The goods are genuinely gone from source, so the truthful state is
  // in-transit. Flip the status only (no second deduction), which lets the
  // destination receive it. No stock is touched here.
  Future<void> _resumeStuckDispatch() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.build_circle_outlined, color: AppTheme.primary, size: 20),
          SizedBox(width: 8),
          Text('Resume Dispatch'),
        ]),
        content: const Text(
            'The stock for this transfer was already removed from the source '
            'branch during an earlier dispatch, but the voucher was left in '
            'Draft. No stock will be moved again — this only marks it In Transit '
            'so the destination can receive it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('Mark In Transit')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await Supabase.instance.client.from('stock_transfers').update({
        'status': 'in_transit',
        'dispatched_by': _transfer!['dispatched_by'] ?? _userId,
        'dispatched_at': _transfer!['dispatched_at'] ?? now,
        'updated_at': now,
      }).eq('id', _transfer!['id']);
      _snack('Resumed — now In Transit, awaiting approval at destination');
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack(friendlyError('That did not save', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Recovery: source stock only PARTIALLY removed, still Draft ────────────
  // We can't safely mark this in-transit (the destination would receive more
  // than actually left source). Put back exactly what was removed and keep it
  // Draft, so the user can review and dispatch it cleanly.
  Future<void> _reverseStuckDispatch(Map<String, double> removed) async {
    final client = Supabase.instance.client;
    final orgId = _orgId!;
    final fromBranchId = _transfer!['from_branch_id'] as String;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: AppTheme.danger, size: 20),
          SizedBox(width: 8),
          Text('Incomplete Dispatch'),
        ]),
        content: const Text(
            'An earlier dispatch removed only part of this transfer’s stock '
            'from the source branch before it stopped. To avoid moving stock '
            'that never actually left, the partial deduction will be returned to '
            'the source branch and the voucher kept as Draft. You can then '
            'dispatch it again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('Return Stock & Keep Draft')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      var i = 0;
      for (final entry in removed.entries) {
        final productId = entry.key;
        final qty = entry.value; // positive amount to give back
        if (qty <= 1e-6) continue;
        final line = _items.firstWhere((it) => it['product_id'] == productId,
            orElse: () => const <String, dynamic>{});
        final uomId = line['uom_id'] as String?;
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${i}_rev',
          'org_id': orgId,
          'product_id': productId,
          'branch_id': fromBranchId,
          'uom_id': uomId,
          'quantity': qty,
          'movement_type': 'transfer',
          'reference_id': _transfer!['id'],
          'reference_type': 'stock_transfer',
          'moved_at': _movedAt(),
          'created_by': _userId,
        });
        final fromStock = await client
            .from('inventory_stock')
            .select()
            .eq('org_id', orgId)
            .eq('product_id', productId)
            .eq('branch_id', fromBranchId)
            .maybeSingle();
        if (fromStock != null) {
          await client.from('inventory_stock').update({
            'quantity': (fromStock['quantity'] as num).toDouble() + qty,
            'updated_at': now,
          }).eq('id', fromStock['id']);
        } else {
          await client.from('inventory_stock').insert({
            'id': 'is_${DateTime.now().microsecondsSinceEpoch}_${i}_rev',
            'org_id': orgId,
            'product_id': productId,
            'branch_id': fromBranchId,
            'uom_id': uomId,
            'quantity': qty,
          });
        }
        i++;
      }
      await client.from('stock_transfers').update({
        'status': 'draft',
        'updated_at': now,
      }).eq('id', _transfer!['id']);
      _snack('Partial deduction returned to source — voucher kept as Draft');
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack(friendlyError('That did not save', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Approve / Receive: increment DESTINATION, mark completed ──────────────
  Future<void> _receive() async {
    final client = Supabase.instance.client;
    final orgId = _orgId!;
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
      // Preferred: atomic server-side receive — moves destination stock, the
      // dated ledger movement AND the FIFO cost layers from the source branch
      // to the destination in one transaction (so COGS/valuation follow the
      // goods). Falls back to the legacy client loop only if the function
      // isn't deployed yet.
      var serverDone = false;
      try {
        await client.rpc('receive_stock_transfer', params: {
          'p_transfer_id': _transfer!['id'],
          'p_user_id': _userId,
        });
        serverDone = true;
      } on PostgrestException catch (e) {
        if (e.code != 'PGRST202') rethrow;
      }
      if (!serverDone) {
        final now = DateTime.now().toUtc().toIso8601String();
        for (var i = 0; i < _items.length; i++) {
          final item = _items[i];
          final qty = (item['quantity'] as num).toDouble();
          final productId = item['product_id'] as String;
          final uomId = item['uom_id'] as String;
          await client.from('inventory_movements').insert({
            'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${i}_in',
            'org_id': orgId,
            'product_id': productId,
            'branch_id': toBranchId,
            'uom_id': uomId,
            'quantity': qty,
            'movement_type': 'transfer',
            'reference_id': _transfer!['id'],
            'reference_type': 'stock_transfer',
            'moved_at': _movedAt(),
            'created_by': _userId,
          });
          final toStock = await client
              .from('inventory_stock')
              .select()
              .eq('org_id', orgId)
              .eq('product_id', productId)
              .eq('branch_id', toBranchId)
              .maybeSingle();
          if (toStock != null) {
            await client.from('inventory_stock').update({
              'quantity': (toStock['quantity'] as num).toDouble() + qty,
              'updated_at': now,
            }).eq('id', toStock['id']);
          } else {
            await client.from('inventory_stock').insert({
              'id': 'is_${DateTime.now().microsecondsSinceEpoch}_${i}_in',
              'org_id': orgId,
              'product_id': productId,
              'branch_id': toBranchId,
              'uom_id': uomId,
              'quantity': qty,
            });
          }
        }
        await client.from('stock_transfers').update({
          'status': 'completed',
          'approved_by': _userId,
          'approved_at': now,
          'updated_at': now,
        }).eq('id', _transfer!['id']);
      }
      _snack('Approved — stock received at destination');
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack(friendlyError('That did not save', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Reject (in_transit) / Cancel (draft) ──────────────────────────────────
  Future<void> _rejectOrCancel() async {
    final client = Supabase.instance.client;
    final orgId = _orgId!;
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
      final now = DateTime.now().toUtc().toIso8601String();
      if (inTransit) {
        // Return stock to source.
        for (var i = 0; i < _items.length; i++) {
          final item = _items[i];
          final qty = (item['quantity'] as num).toDouble();
          final productId = item['product_id'] as String;
          final uomId = item['uom_id'] as String;
          await client.from('inventory_movements').insert({
            'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${i}_ret',
            'org_id': orgId,
            'product_id': productId,
            'branch_id': fromBranchId,
            'uom_id': uomId,
            'quantity': qty,
            'movement_type': 'transfer',
            'reference_id': _transfer!['id'],
            'reference_type': 'stock_transfer',
            'moved_at': _movedAt(),
            'created_by': _userId,
          });
          final fromStock = await client
              .from('inventory_stock')
              .select()
              .eq('org_id', orgId)
              .eq('product_id', productId)
              .eq('branch_id', fromBranchId)
              .maybeSingle();
          if (fromStock != null) {
            await client.from('inventory_stock').update({
              'quantity': (fromStock['quantity'] as num).toDouble() + qty,
              'updated_at': now,
            }).eq('id', fromStock['id']);
          }
        }
      }
      await client.from('stock_transfers').update({
        'status': inTransit ? 'rejected' : 'cancelled',
        'updated_at': now,
      }).eq('id', _transfer!['id']);
      _snack(inTransit ? 'Rejected — stock returned to source' : 'Cancelled');
      widget.onUpdated();
      await _load();
    } catch (e) {
      _snack(friendlyError('That did not save', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtQty(double q) => q % 1 == 0 ? q.toInt().toString() : q.toString();

  /// Inventory movements post on the TRANSFER's voucher date (not the running
  /// date), keeping the current local time-of-day for same-day ordering.
  String _movedAt() {
    final nowL = DateTime.now();
    final ds = _transfer?['transfer_date'] as String?;
    final d = ds == null ? null : DateTime.tryParse(ds);
    if (d == null) return nowL.toUtc().toIso8601String();
    return DateTime(d.year, d.month, d.day, nowL.hour, nowL.minute, nowL.second)
        .toUtc()
        .toIso8601String();
  }

  String? _who(String? id) => id == null ? null : _userNames[id];
  String? _fmtDT(String? iso) {
    if (iso == null) return null;
    final d = DateTime.tryParse(iso);
    return d == null ? null : DateFormat('d MMM yyyy HH:mm').format(d.toLocal());
  }

  Future<void> _printTransfer() async {
    final t = _transfer;
    if (t == null) return;
    final user = ref.read(currentUserProvider);
    final items = _items.map((it) => {
          'product': it['products']?['name'] as String? ?? '',
          'sku': it['products']?['sku'] as String?,
          'uom': it['uoms']?['abbreviation'] as String? ?? '',
          'qty': (it['quantity'] as num?)?.toDouble() ?? 0,
        }).toList();
    final date = t['transfer_date'] != null
        ? DateFormat('d MMM yyyy').format(DateTime.parse(t['transfer_date'] as String))
        : null;
    await VoucherPdf.printStockTransfer(
      voucherNumber: t['voucher_number'] as String? ?? '-',
      orgName: user?.orgName ?? 'Opstation',
      fromBranch: _branchName(t['from_branch_id'] as String?),
      toBranch: _branchName(t['to_branch_id'] as String?),
      date: date,
      notes: t['notes'] as String?,
      status: _stStatusLabel(_status),
      items: items,
      generatedBy: _who(t['created_by'] as String?),
      generatedAt: _fmtDT(t['created_at'] as String?),
      dispatchedBy: _who(t['dispatched_by'] as String?),
      dispatchedAt: _fmtDT(t['dispatched_at'] as String?),
      approvedBy: _who(t['approved_by'] as String?),
      approvedAt: _fmtDT(t['approved_at'] as String?),
    );
  }

  // Full, searchable, scrollable view of every item on the transfer — the
  // inline card is space-constrained, so this modal shows all SKUs at once.
  void _showAllItems() {
    var q = '';
    showDialog(context: context, builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(width: 760, height: 620, child: StatefulBuilder(builder: (ctx, setSt) {
        final ql = q.trim().toLowerCase();
        final rows = _items.where((it) {
          if (ql.isEmpty) return true;
          final name = (it['products']?['name'] as String? ?? '').toLowerCase();
          final sku = (it['products']?['sku'] as String? ?? '').toLowerCase();
          return name.contains(ql) || sku.contains(ql);
        }).toList();
        final totalQty = rows.fold<double>(0, (s, it) => s + ((it['quantity'] as num?)?.toDouble() ?? 0));
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 14, 12, 8), child: Row(children: [
            Expanded(child: Text('${_transfer?['voucher_number'] ?? 'Transfer'} — all items (${_items.length})',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
            IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
          ])),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Search product or SKU…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
            onChanged: (v) => setSt(() => q = v),
          )),
          const SizedBox(height: 8),
          Container(
            color: AppTheme.background,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: const Row(children: [
              SizedBox(width: 34, child: Text('#', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
              Expanded(flex: 5, child: Text('Product', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
              Expanded(flex: 2, child: Text('UOM', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
              SizedBox(width: 100, child: Text('Quantity', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: rows.isEmpty
              ? const Center(child: Text('No matching items.', style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final it = rows[i];
                    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), child: Row(children: [
                      SizedBox(width: 34, child: Text('${i + 1}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(it['products']?['name'] as String? ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        if (it['products']?['sku'] != null) Text(it['products']['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      ])),
                      Expanded(flex: 2, child: Text(it['uoms']?['abbreviation'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      SizedBox(width: 100, child: Text(_fmtQty((it['quantity'] as num?)?.toDouble() ?? 0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                    ]));
                  })),
          const Divider(height: 1),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), child: Row(children: [
            Text('${rows.length} item${rows.length == 1 ? '' : 's'}${ql.isEmpty ? '' : ' (filtered)'}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const Spacer(),
            Text('Total qty: ${_fmtQty(totalQty)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ])),
        ]);
      })),
    ));
  }

  Widget _auditCard() {
    final t = _transfer;
    if (t == null) return const SizedBox.shrink();
    Widget line(IconData ic, Color c, String label, String? who, String? when) {
      if (who == null || who.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ic, size: 14, color: c),
          const SizedBox(width: 8),
          SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(child: Text('$who${when != null ? '  •  $when' : ''}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
        ]),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Audit Trail', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.textSecondary, letterSpacing: 0.6)),
        const SizedBox(height: 6),
        line(Icons.add_circle_outline, AppTheme.success, 'Generated by', _who(t['created_by'] as String?), _fmtDT(t['created_at'] as String?)),
        line(Icons.local_shipping_outlined, AppTheme.primary, 'Dispatched by', _who(t['dispatched_by'] as String?), _fmtDT(t['dispatched_at'] as String?)),
        line(Icons.check_circle_outline, AppTheme.success, 'Approved by', _who(t['approved_by'] as String?), _fmtDT(t['approved_at'] as String?)),
      ]),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final editable = _isDraft;
    final accessibleIds = (ref.watch(userBranchesProvider).valueOrNull ?? const [])
        .map((b) => b['id'] as String)
        .toSet();
    final canApprove = _toBranchId != null && accessibleIds.contains(_toBranchId);
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
            IconButton(
              icon: const Icon(Icons.print_outlined, color: AppTheme.textSecondary),
              tooltip: 'Print / PDF',
              onPressed: _printTransfer,
            ),
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
                      const SizedBox(width: 8),
                      Text('(${_items.length})',
                          style: const TextStyle(
                              fontSize: 14, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      if (_items.isNotEmpty) ...[
                        OutlinedButton.icon(
                            onPressed: _showAllItems,
                            icon: const Icon(Icons.zoom_out_map, size: 16),
                            label: Text('Show all (${_items.length})')),
                        const SizedBox(width: 10),
                      ],
                      if (editable)
                        ElevatedButton.icon(
                            onPressed: () => _pickAddProduct(),
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add product')),
                    ]),
                    const SizedBox(height: 12),
                    if (editable) _addRow(),
                    Expanded(child: _itemsCard(editable)),
                    if (!_isNew) ...[
                      const SizedBox(height: 16),
                      _auditCard(),
                    ],
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
          // From Branch is fixed to the branch you're currently in — a transfer
          // always originates from your own branch, so this is never a dropdown.
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

  Widget _addRow() {
    final prod = _addProductId == null
        ? null
        : _products.firstWhere((p) => p['id'] == _addProductId, orElse: () => {});
    final prodName = prod == null ? null : (prod['name'] as String?);
    final addHave =
        _addProductId == null ? null : (_inHand[_addProductId] ?? 0);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Expanded(
          flex: 4,
          child: InkWell(
            onTap: () => _pickAddProduct(),
            borderRadius: BorderRadius.circular(6),
            child: InputDecorator(
              decoration: const InputDecoration(
                  labelText: 'Product', isDense: true, border: OutlineInputBorder()),
              child: Text(prodName ?? 'Tap to pick a product',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: prodName == null ? AppTheme.textSecondary : null)),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: TextField(
            controller: _addQtyCtrl,
            focusNode: _addQtyFocus,
            decoration: const InputDecoration(
                labelText: 'Qty', isDense: true, border: OutlineInputBorder()),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _addItemAndPickNext(),
          ),
        ),
        if (addHave != null) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: (addHave > 0 ? AppTheme.success : AppTheme.danger)
                    .withOpacity(0.1),
                borderRadius: BorderRadius.circular(6)),
            child: Text('In hand: ${_fmtQty(addHave)}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: addHave > 0 ? AppTheme.success : AppTheme.danger)),
          ),
        ],
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.add_circle, color: AppTheme.primary),
          tooltip: 'Add',
          onPressed: _addProductId == null ? null : () => _addItem(),
        ),
      ]),
    );
  }

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
          child: Row(children: [
            const Expanded(
                flex: 4,
                child: Text('Product',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            const Expanded(
                flex: 2,
                child: Text('UOM',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            const Expanded(
                flex: 2,
                child: Text('Quantity',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            if (_isDraft)
              const Expanded(
                  flex: 2,
                  child: Text('In Hand',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: AppTheme.textSecondary))),
            const SizedBox(width: 48),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _items.isEmpty
              ? const Center(
                  child: Text('No items yet.',
                      style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final item = _items[i];
                    final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
                    final have =
                        _inHand[item['product_id'] as String? ?? ''] ?? 0;
                    final short = have < qty;
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Row(children: [
                        Expanded(
                            flex: 4,
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      item['products']?['name'] as String? ?? '',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  if (item['products']?['sku'] != null)
                                    Text(item['products']['sku'] as String,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: AppTheme.textSecondary)),
                                ])),
                        Expanded(
                            flex: 2,
                            child: Text(
                                item['uoms']?['abbreviation'] as String? ?? '-',
                                style: const TextStyle(
                                    color: AppTheme.textSecondary))),
                        Expanded(
                            flex: 2,
                            child: Text(_fmtQty(qty),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600))),
                        if (_isDraft)
                          Expanded(
                              flex: 2,
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Text(_fmtQty(have),
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: short
                                            ? AppTheme.danger
                                            : AppTheme.success)),
                                if (short) ...[
                                  const SizedBox(width: 4),
                                  const Icon(Icons.warning_amber_rounded,
                                      size: 14, color: AppTheme.danger),
                                ],
                              ])),
                        SizedBox(
                            width: 48,
                            child: editable
                                ? IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 18, color: AppTheme.danger),
                                    onPressed: () => _removeItem(item))
                                : const SizedBox.shrink()),
                      ]),
                    );
                  }),
        ),
      ]),
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
