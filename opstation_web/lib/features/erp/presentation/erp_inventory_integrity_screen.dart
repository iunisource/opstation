// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Inventory Integrity Check — two different questions, deliberately separate.
///
/// PRODUCTS tab (rpc_inventory_integrity): is the stock DATA sane right now?
/// Missing cost price, stock<>layers, negative layers, zero-cost layers. This is
/// a check on STATE.
///
/// DOCUMENTS tab (rpc_inventory_gl_reconciliation): did each transaction POST
/// consistently? For every document that moved stock, does the value the General
/// Ledger recorded equal the value the inventory cost ledger recorded? This is a
/// check on FLOW, and it should always be empty.
///
/// The distinction matters. On 14 July two bugs cost real money, and BOTH left
/// every product looking perfectly healthy on the Products tab:
///
///   - POS sales posted COGS to the GL twice while consuming inventory once.
///     Product state: clean. The P&L: overstated by the duplicate.
///   - Purchase returns moved inventory correctly but posted the offset to an
///     expense account instead of Accounts Payable. Layers: consistent.
///     Accounts Payable: overstated by Rs 214,270.
///
/// Neither appeared in any total. Both were found only because a human noticed a
/// single number looked wrong. The Documents tab is the check that should have
/// caught them.
class ErpInventoryIntegrityScreen extends ConsumerStatefulWidget {
  const ErpInventoryIntegrityScreen({super.key});
  @override
  ConsumerState<ErpInventoryIntegrityScreen> createState() => _State();
}

class _State extends ConsumerState<ErpInventoryIntegrityScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  String _filter = 'ALL';
  String _search = '';

  // Documents tab
  bool _docLoading = true;
  bool _baselining = false;
  List<Map<String, dynamic>> _docRows = [];
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadDocs();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String _d(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _loadDocs() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _docLoading = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'rpc_inventory_gl_reconciliation_active',
        params: {
          'p_org_id': orgId,
          'p_from': _d(_from),
          'p_to': _d(_to),
          'p_branch_id': null,
        },
      );
      if (!mounted) return;
      setState(() {
        _docRows = List<Map<String, dynamic>>.from(res as List);
        _docLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _docLoading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Reconciliation error: $e')));
    }
  }

  // Mark every currently-flagged document as reviewed (a dated baseline). The
  // report reads through the _active RPC, which then hides them — so only NEW
  // divergences appear afterward.
  Future<void> _baselineReviewed() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Mark all as reviewed?'),
        content: Text('This marks the ${_docRows.length} document(s) currently shown as '
            'reviewed, so they leave this list. Use it once you have accepted the '
            'current backlog as explained. New divergences after today will still '
            'appear. You can undo this.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mark reviewed')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _baselining = true);
    try {
      final n = await Supabase.instance.client.rpc('rpc_baseline_recon', params: {
        'p_org': orgId, 'p_from': _d(_from), 'p_to': _d(_to),
        'p_user': userId, 'p_note': 'Baseline via Inventory Integrity',
      });
      if (!mounted) return;
      await _loadDocs();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n document(s) marked reviewed')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _baselining = false);
    }
  }

  Future<void> _clearBaseline() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Undo baseline?'),
        content: const Text('This brings every previously-reviewed document back into '
            'the list. Use it if you want to re-examine the backlog.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Undo')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _baselining = true);
    try {
      final n = await Supabase.instance.client.rpc('rpc_clear_recon_baseline', params: {'p_org': orgId});
      if (!mounted) return;
      await _loadDocs();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n document(s) restored')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _baselining = false);
    }
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (r != null && mounted) {
      setState(() { _from = r.start; _to = r.end; });
      _loadDocs();
    }
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final res = await client
          .rpc('rpc_inventory_integrity', params: {'p_org': orgId});
      var rows = List<Map<String, dynamic>>.from(res as List);

      // In-transit + pending purchase-return awareness. Both lower physical
      // stock while the cost layer stays put: an in-transit transfer keeps its
      // layer until the goods are received, and a saved-but-not-invoiced
      // purchase return keeps its layer until the return invoice (PRI) is
      // posted. In both cases the STOCK <> LAYERS gap is a normal timing window,
      // not corruption. Build the expected gap per product and drop any product
      // whose ONLY gap is fully explained by it.
      try {
        final expected = <String, double>{};
        // (a) in-transit stock transfers (dispatched, not yet received)
        final trs = await client
            .from('stock_transfers')
            .select('id')
            .eq('org_id', orgId)
            .eq('status', 'in_transit');
        final ids = (trs as List).map((e) => e['id'] as String).toList();
        if (ids.isNotEmpty) {
          final items = await client
              .from('stock_transfer_items')
              .select('product_id, quantity')
              .inFilter('transfer_id', ids);
          for (final r in (items as List)) {
            final pid = r['product_id'] as String?;
            if (pid == null) continue;
            expected[pid] = (expected[pid] ?? 0) + ((r['quantity'] as num?)?.toDouble() ?? 0);
          }
        }
        // (b) purchase returns saved but not yet invoiced (layer consumed at PRI)
        try {
          final pr = await client
              .rpc('rpc_pending_purchase_return_qty', params: {'p_org': orgId});
          for (final r in (pr as List)) {
            final pid = r['product_id'] as String?;
            if (pid == null) continue;
            expected[pid] = (expected[pid] ?? 0) + ((r['qty'] as num?)?.toDouble() ?? 0);
          }
        } catch (_) {/* ignore if the helper RPC is unavailable */}

        if (expected.isNotEmpty) {
          rows = rows.where((r) {
            if (r['issue'] != 'STOCK <> LAYERS') return true;      // other issues stay
            if (((r['neg_layers'] as num?)?.toInt() ?? 0) != 0) return true; // real neg-layer issue
            final pid = r['product_id'] as String?;
            final it = pid != null ? (expected[pid] ?? 0) : 0;
            if (it == 0) return true;
            final stock = (r['stock_qty'] as num?)?.toDouble() ?? 0;
            final layer = (r['layer_qty'] as num?)?.toDouble() ?? 0;
            // keep only if the gap is NOT fully explained by in-transit + pending returns
            return (stock + it - layer).abs() > 0.001;
          }).toList();
        }
      } catch (_) {/* if the lookup fails, show the raw list */}

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load error: $e')));
    }
  }

  List<Map<String, dynamic>> get _visible {
    final q = _search.trim().toLowerCase();
    return _rows.where((r) {
      if (_filter != 'ALL' && r['issue'] != _filter) return false;
      if (q.isEmpty) return true;
      final n = (r['name'] as String? ?? '').toLowerCase();
      final s = (r['sku'] as String? ?? '').toLowerCase();
      return n.contains(q) || s.contains(q);
    }).toList();
  }

  int _count(String issue) => _rows.where((r) => r['issue'] == issue).length;

  // Print whichever tab is showing — Products or Documents. The single header
  // button previously always printed Products, so the Documents tab's print
  // preview showed the wrong section.
  void _printActive() {
    if (_tabs.index == 1) {
      if (_docRows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nothing to print — GL and inventory ledger agree')));
        return;
      }
      _printDocs();
    } else {
      if (_rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nothing to print — inventory is clean')));
        return;
      }
      _print();
    }
  }

  void _printDocs() {
    final list = _docRows;
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final gen = '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}';
    String esc(Object? v) => (v ?? '').toString().replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final body = list.map((r) {
      final diff = (r['difference'] as num?)?.toDouble() ?? 0;
      return '<tr>'
          '<td>${esc(r['doc_type'])}</td>'
          '<td>${esc(r['voucher_no'])}</td>'
          '<td>${esc(r['voucher_date'])}</td>'
          '<td style="text-align:right">${_fmt(r['gl_value'] as num?)}</td>'
          '<td style="text-align:right">${_fmt(r['ledger_value'] as num?)}</td>'
          '<td style="text-align:right">${_fmt(diff)}</td>'
          '<td>${esc(r['note'])}</td>'
          '</tr>';
    }).join();
    final htmlStr = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>GL vs Inventory Reconciliation</title>'
        '<style>'
        'body{font-family:Arial,Helvetica,sans-serif;color:#222;margin:24px}'
        'h1{font-size:18px;margin:0 0 2px}'
        '.muted{color:#666;font-size:12px;margin:2px 0}'
        'table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}'
        'th{background:#f4f5f7}'
        '</style></head><body>'
        '<h1>$orgName &mdash; GL vs Inventory Reconciliation</h1>'
        '<div class="muted">Generated: $gen &middot; ${_d(_from)} to ${_d(_to)} &middot; ${list.length} document(s) disagree</div>'
        '<table><thead><tr>'
        '<th>Document</th><th>Voucher</th><th>Date</th>'
        '<th style="text-align:right">GL value</th>'
        '<th style="text-align:right">Ledger value</th>'
        '<th style="text-align:right">Difference</th>'
        '<th>What it means</th>'
        '</tr></thead><tbody>$body</tbody></table>'
        '<script>window.onload=function(){window.print();}</script>'
        '</body></html>';
    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 4), () => html.Url.revokeObjectUrl(url));
  }

  void _print() {
    final list = _visible;
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final gen = '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}';
    String esc(Object? v) => (v ?? '').toString().replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final body = list.map((r) {
      final g = _fixGuide(r['issue'] as String?);
      final fix = ([g.what, ...g.steps]).map(esc).join('<br>&bull; ');
      return '<tr>'
          '<td>${esc(r['name'])}</td>'
          '<td>${esc(r['sku'])}</td>'
          '<td>${esc(r['issue'])}</td>'
          '<td style="text-align:right">${_fmt(r['cost_price'] as num?)}</td>'
          '<td style="text-align:right">${_fmt(r['stock_qty'] as num?)}</td>'
          '<td style="text-align:right">${_fmt(r['layer_qty'] as num?)}</td>'
          '<td style="font-size:11px">$fix</td>'
          '</tr>';
    }).join();
    final htmlStr = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Inventory Integrity</title>'
        '<style>'
        'body{font-family:Arial,Helvetica,sans-serif;color:#222;margin:24px}'
        'h1{font-size:18px;margin:0 0 2px}'
        '.muted{color:#666;font-size:12px;margin:2px 0}'
        'table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}'
        'th{background:#f4f5f7}'
        '</style></head><body>'
        '<h1>$orgName &mdash; Inventory Integrity Check</h1>'
        '<div class="muted">Generated: $gen &middot; ${list.length} product(s) flagged</div>'
        '<table><thead><tr>'
        '<th>Product</th><th>SKU</th><th>Issue</th>'
        '<th style="text-align:right">Cost</th>'
        '<th style="text-align:right">Stock</th>'
        '<th style="text-align:right">Layers</th>'
        '<th>How to fix</th>'
        '</tr></thead><tbody>$body</tbody></table>'
        '<script>window.onload=function(){window.print();}</script>'
        '</body></html>';
    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 4), () => html.Url.revokeObjectUrl(url));
  }


  Color _issueColor(String? issue) {
    switch (issue) {
      case 'NO COST PRICE': return Colors.red;
      case 'STOCK <> LAYERS': return Colors.orange;
      case 'NEGATIVE LAYERS': return Colors.deepPurple;
      case 'ZERO-COST LAYERS': return Colors.brown;
      default: return Colors.grey;
    }
  }

  // Plain-language cause + step-by-step remedy for each issue type. Keyed on the
  // exact issue string the RPC emits so the "How to fix" button can look it up.
  ({String what, String why, List<String> steps}) _fixGuide(String? issue) {
    switch (issue) {
      case 'NO COST PRICE':
        return (
          what: 'This product has stock on hand but no cost value anywhere.',
          why: 'No cost layer was ever created for it — usually opening stock was '
              'entered without a cost, or the product was never received through a '
              'Purchase Invoice. Until a cost exists, its inventory value and the '
              'COGS on every sale of it are booked as ZERO, which understates cost '
              'of goods sold and overstates profit.',
          steps: [
            'Open the product and confirm the correct unit cost.',
            'If the stock came from opening balances: go to Opening Stock, edit '
                'this product’s line and enter the unit cost, then re-post so a '
                'cost layer is created.',
            'If it should have been purchased: post the missing Purchase Invoice '
                '(or GRN + PI) with the real unit cost so a cost layer is created.',
            'As a last resort, set the cost on the Product profile and run a Stock '
                'Adjustment (Revalue) to write the cost onto the on-hand quantity.',
          ],
        );
      case 'STOCK <> LAYERS':
        return (
          what: 'The stock-on-hand quantity does not equal the total quantity held '
              'in the cost layers.',
          why: 'Something changed the on-hand quantity without creating (or '
              'consuming) a matching cost layer — most often opening stock entered '
              'as a quantity without a cost, a manual quantity edit, or a movement '
              'that half-posted. The two ledgers have drifted apart, so valuation '
              'will not tie to the quantity report.',
          steps: [
            'Open the Inventory Ledger for this product and compare movements '
                'against the cost layers to find where they diverge.',
            'If opening stock was entered without cost, fix the Opening Stock line '
                '(add the cost) and re-post.',
            'If a quantity was edited manually, reverse that edit or post a Stock '
                'Adjustment so the on-hand quantity and the layers agree again.',
            'Re-run this check — the product should drop off once quantity = layers.',
          ],
        );
      case 'NEGATIVE LAYERS':
        return (
          what: 'The cost layers for this product have gone negative — more was '
              'sold or issued than was ever received.',
          why: 'Sales/issues were posted before the corresponding receipts, so the '
              'FIFO layers ran below zero. COGS on those sales was booked with no '
              'real cost behind it, so both inventory value and profit are wrong '
              'until the receipts are in place.',
          steps: [
            'Post the missing receipt — the Purchase Invoice / GRN or Opening Stock '
                'that should have brought this product in — dated on or before the '
                'earliest sale.',
            'Confirm the receipt quantity covers everything that was issued.',
            'Let the system re-cost; the layers should return to zero-or-positive.',
            'If the negative is genuinely a data error (not a missing receipt), post '
                'a Stock Adjustment to correct the quantity.',
          ],
        );
      case 'ZERO-COST LAYERS':
        return (
          what: 'A cost layer exists for this product but at a cost of zero.',
          why: 'Goods were received without a unit cost — a GRN or Purchase Invoice '
              'posted at 0, or an opening layer created with no value. The quantity '
              'is right but its value is zero, so COGS when it sells will be zero '
              'and profit will be overstated.',
          steps: [
            'Find the source document — open the product’s Inventory Ledger and '
                'locate the receipt that created the zero-cost layer.',
            'Open that GRN / Purchase Invoice, enter the correct unit cost, and '
                're-post so the layer revalues.',
            'If it was opening stock, edit the Opening Stock line with the real cost '
                'and re-post.',
            'Re-run this check to confirm the layer now carries a value.',
          ],
        );
      default:
        return (
          what: 'This product was flagged by the integrity check.',
          why: 'The stock data for this item is inconsistent.',
          steps: [
            'Review the product’s Inventory Ledger and cost layers.',
            'Correct the source document or post a Stock Adjustment, then re-run '
                'this check.',
          ],
        );
    }
  }

  // Per-branch reality for one product — the "review each" data. Read-only.
  Future<List<Map<String, dynamic>>> _loadDetail(String productId) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return [];
    final res = await Supabase.instance.client.rpc(
      'rpc_inventory_integrity_detail',
      params: {'p_org': orgId, 'p_product': productId},
    );
    return List<Map<String, dynamic>>.from(res as List);
  }

  static const _modeLabels = {
    'consolidate': 'Consolidate layers — clean out negative layers, no value change',
    'trust_physical': 'Trust physical stock — rebuild layers to on-hand (posts a GL adjustment)',
    'trust_layers': 'Trust cost layers — move on-hand quantity to match the layers',
  };

  Future<void> _applyReconcile(BuildContext dialogCtx, String productId,
      String productName, Map<String, dynamic> branchRow, String mode) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final userId = ref.read(currentUserProvider)?.id;
    final branchId = branchRow['branch_id'] as String?;
    final branchName = branchRow['branch_name'] as String? ?? '—';
    if (orgId == null || branchId == null) return;

    // ── In-transit guard ──────────────────────────────────────────────────
    // A dispatched-but-not-received transfer takes stock out of PHYSICAL at the
    // source, but its cost layer legitimately stays until the goods are received.
    // So during transit the layers are higher than on-hand by exactly the
    // in-transit qty — that is NOT drift. Reconciling here (trust physical) would
    // delete the cost backing the in-transit stock. Block it and point the user
    // to receive/cancel the transfer instead.
    try {
      final client = Supabase.instance.client;
      final trs = await client
          .from('stock_transfers')
          .select('id, voucher_number')
          .eq('org_id', orgId)
          .eq('from_branch_id', branchId)
          .eq('status', 'in_transit');
      final trList = (trs as List).cast<Map<String, dynamic>>();
      if (trList.isNotEmpty) {
        final ids = trList.map((e) => e['id'] as String).toList();
        final items = await client
            .from('stock_transfer_items')
            .select('quantity, transfer_id')
            .inFilter('transfer_id', ids)
            .eq('product_id', productId);
        double q = 0;
        final hitIds = <String>{};
        for (final r in (items as List)) {
          final qty = (r['quantity'] as num?)?.toDouble() ?? 0;
          if (qty != 0) { q += qty; hitIds.add(r['transfer_id'] as String); }
        }
        if (q > 0) {
          final vnos = trList
              .where((t) => hitIds.contains(t['id']))
              .map((t) => (t['voucher_number'] ?? t['id']).toString())
              .join(', ');
          if (!mounted) return;
          await showDialog<void>(
            context: dialogCtx,
            builder: (c) => AlertDialog(
              title: const Text('Stock is in transit'),
              content: Text(
                  '$productName has ${q % 1 == 0 ? q.toStringAsFixed(0) : q.toStringAsFixed(2)} unit(s) '
                  'dispatched from $branchName and not yet received ($vnos).\n\n'
                  'That is why on-hand is below the cost layers — it is normal for an '
                  'in-transit transfer, not a real discrepancy. Receive (or cancel) the '
                  'transfer first; reconciling now would delete the cost backing the '
                  'in-transit stock.'),
              actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
            ),
          );
          return;
        }
      }
    } catch (_) {/* if the check fails, fall through — the DB guard also protects */}

    final ok = await showDialog<bool>(
      context: dialogCtx,
      builder: (c) => AlertDialog(
        title: const Text('Apply reconciliation?'),
        content: Text('$productName\nBranch: $branchName\n\n${_modeLabels[mode]}\n\n'
            'This is recorded in the reconciliation log and can be reviewed. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await Supabase.instance.client.rpc('rpc_reconcile_inventory', params: {
        'p_org': orgId, 'p_branch': branchId, 'p_product': productId,
        'p_mode': mode, 'p_cost': null, 'p_user': userId,
      });
      if (!mounted) return;
      Navigator.of(dialogCtx).pop(); // close the How-to-fix dialog
      _load();
      _loadDocs();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$res')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reconcile failed: $e')));
    }
  }

  Widget _branchBreakdown(Map<String, dynamic> r) {
    final pid = r['product_id'] as String?;
    if (pid == null) return const SizedBox.shrink();
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _loadDetail(pid),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final rows = snap.data ?? [];
        if (rows.isEmpty) return const SizedBox.shrink();
        Widget cell(String t, {bool bold = false, Color? color, TextAlign align = TextAlign.right}) =>
            Text(t, textAlign: align, style: TextStyle(fontSize: 11.5,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color));
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('This product, branch by branch',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          const Text('Where physical stock and cost layers disagree is where the fix goes.',
              style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
                border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
                child: Row(children: [
                  Expanded(flex: 3, child: cell('Branch', bold: true, align: TextAlign.left)),
                  Expanded(flex: 2, child: cell('Stock', bold: true)),
                  Expanded(flex: 2, child: cell('Layers', bold: true)),
                  Expanded(flex: 3, child: cell('Layer value', bold: true)),
                  Expanded(flex: 1, child: cell('Neg', bold: true)),
                  const SizedBox(width: 44, child: Text('Fix', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700))),
                ]),
              ),
              const Divider(height: 1),
              ...rows.map((d) {
                final stock = (d['stock_qty'] as num?)?.toDouble() ?? 0;
                final layer = (d['layer_qty'] as num?)?.toDouble() ?? 0;
                final mismatch = (stock - layer).abs() > 0.001;
                final neg = (d['neg_layers'] as num?)?.toInt() ?? 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(children: [
                    Expanded(flex: 3, child: cell(d['branch_name'] as String? ?? '—', align: TextAlign.left)),
                    Expanded(flex: 2, child: cell(_fmt(stock))),
                    Expanded(flex: 2, child: cell(_fmt(layer),
                        bold: mismatch, color: mismatch ? AppTheme.danger : null)),
                    Expanded(flex: 3, child: cell(_fmt(d['layer_value'] as num?))),
                    Expanded(flex: 1, child: cell(neg == 0 ? '—' : '$neg',
                        color: neg > 0 ? Colors.deepPurple : null)),
                    SizedBox(width: 44, child: Center(
                      child: (!mismatch && neg == 0)
                        ? const Text('—', style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))
                        : PopupMenuButton<String>(
                      icon: const Icon(Icons.build_outlined, size: 16),
                      tooltip: 'Reconcile this branch',
                      padding: EdgeInsets.zero,
                      onSelected: (mode) => _applyReconcile(
                          context, pid, r['name'] as String? ?? '-', d, mode),
                      itemBuilder: (_) => [
                        if (mismatch) const PopupMenuItem(value: 'trust_physical',
                            child: Text('Trust physical stock', style: TextStyle(fontSize: 12))),
                        if (mismatch) const PopupMenuItem(value: 'trust_layers',
                            child: Text('Trust cost layers', style: TextStyle(fontSize: 12))),
                        if (!mismatch && neg > 0) const PopupMenuItem(value: 'consolidate',
                            child: Text('Consolidate layers', style: TextStyle(fontSize: 12))),
                      ],
                    ))),
                  ]),
                );
              }),
            ]),
          ),
        ]);
      },
    );
  }

  void _showFix(Map<String, dynamic> r) {
    final issue = r['issue'] as String?;
    final g = _fixGuide(issue);
    final color = _issueColor(issue);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.build_circle_outlined, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['name'] as String? ?? '-',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(issue ?? '-',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
            ]),
          ),
        ]),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(g.what, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(g.why, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.4)),
              const SizedBox(height: 16),
              const Text('How to fix', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              ...List.generate(g.steps.length, (i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 20, height: 20, alignment: Alignment.center,
                    decoration: BoxDecoration(color: color.withOpacity(0.14), shape: BoxShape.circle),
                    child: Text('${i + 1}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(g.steps[i], style: const TextStyle(fontSize: 12.5, height: 1.4))),
                ]),
              )),
              const SizedBox(height: 16),
              _branchBreakdown(r),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
      ),
    );
  }

  String _fmt(num? v) {
    final d = (v ?? 0).toDouble();
    if (d == d.roundToDouble()) return d.toStringAsFixed(0);
    return d.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Inventory Integrity Check', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            SizedBox(height: 2),
            Text('Products at risk: missing cost, stock/layer mismatch, negative or zero-cost layers',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ])),
          IconButton(icon: const Icon(Icons.print_outlined), tooltip: 'Print / PDF',
              onPressed: _printActive),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () { _load(); _loadDocs(); }),
        ])),
      Container(
        color: Colors.white,
        child: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          indicatorColor: AppTheme.primary,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          tabs: [
            Tab(text: 'Products (${_rows.length})'),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Documents'),
                if (_docRows.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                        color: AppTheme.danger, borderRadius: BorderRadius.circular(8)),
                    child: Text('${_docRows.length}',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white, fontWeight: FontWeight.w800)),
                  ),
                ],
              ]),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _productsTab(),
          _documentsTab(),
        ]),
      ),
    ]);
  }

  // ── Tab 2: does the GL agree with the inventory ledger, document by document?
  Widget _documentsTab() {
    if (_docLoading) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.date_range, size: 16),
            label: Text('${_d(_from)}  \u2192  ${_d(_to)}',
                style: const TextStyle(fontSize: 12)),
            onPressed: _pickRange,
          ),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.undo, size: 15),
            label: const Text('Undo baseline', style: TextStyle(fontSize: 12)),
            onPressed: _baselining ? null : _clearBaseline,
          ),
          const SizedBox(width: 8),
          if (_docRows.isNotEmpty)
            ElevatedButton.icon(
              icon: _baselining
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.done_all, size: 16),
              label: Text(_baselining ? 'Marking\u2026' : 'Mark all ${_docRows.length} as reviewed'),
              onPressed: _baselining ? null : _baselineReviewed,
            ),
        ]),
        const SizedBox(height: 14),
        if (_docRows.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green.withOpacity(0.30)),
            ),
            child: const Row(children: [
              Icon(Icons.verified_outlined, color: Colors.green),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('General Ledger and inventory ledger agree',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text(
                      'Every document that moved stock posted the same value to both. '
                      'This is what you want to see.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
            ]),
          )
        else ...[
          // Loud on purpose. A control report that is normally empty is a report
          // nobody opens — and both of the bugs this exists to catch were
          // invisible precisely because nothing anywhere raised its voice.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.danger.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.danger.withOpacity(0.40)),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AppTheme.danger, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      '${_docRows.length} document${_docRows.length == 1 ? '' : 's'} '
                      'where the General Ledger and the inventory ledger disagree',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.danger)),
                  const SizedBox(height: 3),
                  const Text(
                      'Each of these posted one value to the GL and a different value to the '
                      'cost ledger. One of your reports is wrong for every row below.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border)),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
                child: const Row(children: [
                  Expanded(flex: 2, child: Text('Document', style: _h)),
                  Expanded(flex: 2, child: Text('Voucher', style: _h)),
                  Expanded(flex: 2, child: Text('Date', style: _h)),
                  Expanded(flex: 2, child: Text('GL value', style: _h, textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text('Ledger value', style: _h, textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text('Difference', style: _h, textAlign: TextAlign.right)),
                  Expanded(flex: 4, child: Text('What it means', style: _h)),
                ]),
              ),
              const Divider(height: 1),
              ..._docRows.map((r) {
                final diff = (r['difference'] as num?)?.toDouble() ?? 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Expanded(flex: 2, child: Text('${r['doc_type'] ?? '-'}',
                        style: const TextStyle(fontSize: 12))),
                    Expanded(flex: 2, child: Text('${r['voucher_no'] ?? '-'}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                    Expanded(flex: 2, child: Text('${r['voucher_date'] ?? '-'}',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text(_fmt(r['gl_value'] as num?),
                        textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                    Expanded(flex: 2, child: Text(_fmt(r['ledger_value'] as num?),
                        textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                    Expanded(flex: 2, child: Text(_fmt(diff),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.danger))),
                    Expanded(flex: 4, child: Text('${r['note'] ?? ''}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                  ]),
                );
              }),
            ]),
          ),
        ],
        const SizedBox(height: 24),
      ]),
    );
  }

  Widget _productsTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Summary chips
            Wrap(spacing: 10, runSpacing: 10, children: [
              _summaryChip('ALL', 'All issues', _rows.length),
              _summaryChip('NO COST PRICE', 'No cost price', _count('NO COST PRICE')),
              _summaryChip('STOCK <> LAYERS', 'Stock \u2260 layers', _count('STOCK <> LAYERS')),
              _summaryChip('NEGATIVE LAYERS', 'Negative layers', _count('NEGATIVE LAYERS')),
              _summaryChip('ZERO-COST LAYERS', 'Zero-cost layers', _count('ZERO-COST LAYERS')),
            ]),
            const SizedBox(height: 16),
            SizedBox(width: 320, child: TextField(
              decoration: const InputDecoration(
                labelText: 'Search product (name or SKU)', isDense: true,
                prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _search = v),
            )),
            const SizedBox(height: 12),
            if (_rows.isEmpty)
              Container(padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(color: Colors.green.withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
                child: const Row(children: [
                  Icon(Icons.check_circle, color: Colors.green),
                  SizedBox(width: 10),
                  Text('No integrity issues found. Inventory is clean.', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ]))
            else
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                child: Column(children: [
                  Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('Product', style: _h)),
                      Expanded(flex: 2, child: Text('SKU', style: _h)),
                      Expanded(flex: 2, child: Text('Issue', style: _h)),
                      Expanded(flex: 1, child: Text('Cost', style: _h, textAlign: TextAlign.right)),
                      Expanded(flex: 1, child: Text('Stock', style: _h, textAlign: TextAlign.right)),
                      Expanded(flex: 1, child: Text('Layers', style: _h, textAlign: TextAlign.right)),
                      Expanded(flex: 2, child: Text('How to fix', style: _h, textAlign: TextAlign.center)),
                    ])),
                  const Divider(height: 1),
                  ..._visible.map((r) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      Expanded(flex: 4, child: Text(r['name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Text(r['sku'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: _issueColor(r['issue'] as String?).withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
                        child: Text(r['issue'] as String? ?? '-', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _issueColor(r['issue'] as String?))),
                      ))),
                      Expanded(flex: 1, child: Text(_fmt(r['cost_price'] as num?), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text(_fmt(r['stock_qty'] as num?), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text(_fmt(r['layer_qty'] as num?), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Center(child: OutlinedButton.icon(
                        onPressed: () => _showFix(r),
                        icon: const Icon(Icons.help_outline, size: 15),
                        label: const Text('How to fix', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _issueColor(r['issue'] as String?),
                          side: BorderSide(color: _issueColor(r['issue'] as String?).withOpacity(0.4)),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ))),
                    ]),
                  )),
                ]),
              ),
            const SizedBox(height: 24),
          ]));
  }

  static const _h = TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary);

  Widget _summaryChip(String key, String label, int count) {
    final active = _filter == key;
    final color = key == 'ALL' ? AppTheme.primary : _issueColor(key);
    return InkWell(
      onTap: () => setState(() => _filter = key),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.12) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? color : AppTheme.border, width: active ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$count', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}
