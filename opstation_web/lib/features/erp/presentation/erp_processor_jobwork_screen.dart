import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/format/money.dart';
import '../../../core/widgets/product_picker.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/layout/main_layout.dart'; // exposes selectedBranchProvider
import '../../auth/auth_controller.dart';

/// Processor Job-work — a transformed return: input(s) sitting at a processor are
/// consumed and different output product(s) come back to a home branch, with the
/// processor's conversion fee accrued as a payable. Posting/voiding is done by
/// the post_processor_jobwork / void_processor_jobwork RPCs (all GL + FIFO there).
class ErpProcessorJobworkScreen extends ConsumerStatefulWidget {
  const ErpProcessorJobworkScreen({super.key});
  @override
  ConsumerState<ErpProcessorJobworkScreen> createState() =>
      _ErpProcessorJobworkScreenState();
}

class _ErpProcessorJobworkScreenState
    extends ConsumerState<ErpProcessorJobworkScreen> {
  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _list = [];
  List<Map<String, dynamic>> _processors = [];
  List<Map<String, dynamic>> _homes = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _suppliers = [];
  // input product_id -> set of finished-good (output) product_ids that use it in
  // an active BOM. Powers the "Suggest from inputs" action on the Outputs card.
  final Map<String, Set<String>> _outputsByInput = {};

  // Editor state — null _editing = list mode.
  Map<String, dynamic>? _editing; // the open header (or {} for a new one)
  String? _procId, _homeId, _supplierId;
  DateTime _date = DateTime.now();
  final _feeCtrl = TextEditingController(text: '0');
  final _notesCtrl = TextEditingController();
  List<Map<String, dynamic>> _inputs = [];  // {product_id,name,sku,uom_id,qty}
  List<Map<String, dynamic>> _outputs = [];
  // Cost heads: {label, rate (per output unit), is_fee}. is_fee → processor A/P;
  // otherwise → internal overhead/labor (applied overhead account).
  List<Map<String, dynamic>> _heads = [];
  String _status = 'draft';

  // Per-unit heads are multiplied by the total output quantity.
  double get _outQty =>
      _outputs.fold(0.0, (s, l) => s + ((l['qty'] as num?)?.toDouble() ?? 0));
  double get _feeTotal =>
      _heads.where((h) => h['is_fee'] == true)
          .fold(0.0, (s, h) => s + ((h['rate'] as num?)?.toDouble() ?? 0)) * _outQty;
  double get _ohTotal =>
      _heads.where((h) => h['is_fee'] != true)
          .fold(0.0, (s, h) => s + ((h['rate'] as num?)?.toDouble() ?? 0)) * _outQty;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _feeCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final branches = await client.from('branches')
          .select('id, name, is_virtual, supplier_id').eq('org_id', orgId).eq('is_active', true).order('name');
      final products = await client.from('products')
          .select('id, name, sku, base_uom_id, cost_price').eq('org_id', orgId).eq('is_active', true).limit(5000);
      final suppliers = await client.from('suppliers')
          .select('id, name').eq('org_id', orgId).order('name');
      final list = await client.from('processor_jobwork')
          .select('*')
          .eq('org_id', orgId).order('created_at', ascending: false).limit(200);
      // BOM map: which finished good(s) each input material typically produces.
      _outputsByInput.clear();
      try {
        final headers = await client.from('bom_headers')
            .select('id, product_id').eq('org_id', orgId).eq('status', 'active').limit(5000);
        final fgByBom = <String, String>{};
        for (final h in headers as List) {
          final bid = h['id'] as String?; final fg = h['product_id'] as String?;
          if (bid != null && fg != null) fgByBom[bid] = fg;
        }
        if (fgByBom.isNotEmpty) {
          final comps = await client.from('bom_components')
              .select('bom_id, product_id').inFilter('bom_id', fgByBom.keys.toList());
          for (final c in comps as List) {
            final inPid = c['product_id'] as String?;
            final fg = fgByBom[c['bom_id']];
            if (inPid != null && fg != null && fg != inPid) {
              (_outputsByInput[inPid] ??= <String>{}).add(fg);
            }
          }
        }
      } catch (_) {/* suggestions are optional — never block loading */}
      final all = List<Map<String, dynamic>>.from(branches);
      setState(() {
        _processors = all.where((b) => b['is_virtual'] == true).toList();
        _homes = all.where((b) => b['is_virtual'] != true).toList();
        _products = List<Map<String, dynamic>>.from(products);
        _suppliers = List<Map<String, dynamic>>.from(suppliers);
        _list = List<Map<String, dynamic>>.from(list);
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      _snack(friendlyError('Could not load job-work receipts', e));
    }
  }

  // ── Editor open/close ───────────────────────────────────────────────────
  void _newDoc() {
    setState(() {
      _editing = {};
      _procId = _processors.length == 1 ? _processors.first['id'] as String? : null;
      // Default the home branch to the user's currently selected branch (when it
      // is a real, non-processor branch); otherwise the sole branch, if only one.
      final sel = ref.read(selectedBranchProvider)?['id'] as String?;
      final selIsHome = sel != null && _homes.any((b) => b['id'] == sel);
      _homeId = selIsHome
          ? sel
          : (_homes.length == 1 ? _homes.first['id'] as String? : null);
      _supplierId = null;
      _date = DateTime.now();
      _feeCtrl.text = '0';
      _notesCtrl.text = '';
      _inputs = [];
      _outputs = [];
      _heads = [];
      _status = 'draft';
    });
  }

  Future<void> _openDoc(Map<String, dynamic> h) async {
    setState(() => _busy = true);
    try {
      final lines = await Supabase.instance.client
          .from('processor_jobwork_lines')
          .select('*')
          .eq('jobwork_id', h['id']);
      final ll = List<Map<String, dynamic>>.from(lines);
      List<Map<String, dynamic>> heads = [];
      try {
        final hs = await Supabase.instance.client
            .from('processor_jobwork_overheads')
            .select('*').eq('jobwork_id', h['id']).order('line_order');
        heads = [for (final o in hs as List) {
          'label': (o['label'] as String?) ?? '',
          'rate': (o['amount'] as num?)?.toDouble() ?? 0,
          'is_fee': o['is_fee'] == true,
        }];
      } catch (_) {/* overheads table may predate migration 261 */}
      Map<String, dynamic> mapLine(Map<String, dynamic> l) {
        final p = _products.firstWhere((x) => x['id'] == l['product_id'], orElse: () => {});
        return {
          'product_id': l['product_id'],
          'name': p['name'] ?? l['product_id'],
          'sku': p['sku'] ?? '',
          'uom_id': l['uom_id'],
          'qty': (l['quantity'] as num?)?.toDouble() ?? 0,
          'unit_cost': (l['unit_cost'] as num?)?.toDouble() ?? 0,
        };
      }
      setState(() {
        _editing = h;
        _procId = h['processor_branch_id'] as String?;
        _homeId = h['home_branch_id'] as String?;
        _supplierId = h['supplier_id'] as String?;
        _date = DateTime.tryParse('${h['jobwork_date']}') ?? DateTime.now();
        _feeCtrl.text = '${(h['fee_amount'] as num?)?.toDouble() ?? 0}';
        _notesCtrl.text = (h['notes'] as String?) ?? '';
        _status = (h['status'] as String?) ?? 'draft';
        _inputs = ll.where((l) => l['direction'] == 'input').map(mapLine).toList();
        _outputs = ll.where((l) => l['direction'] == 'output').map(mapLine).toList();
        _heads = heads;
        _busy = false;
      });
    } catch (e) {
      setState(() => _busy = false);
      _snack(friendlyError('Could not open', e));
    }
  }

  void _closeEditor() => setState(() => _editing = null);

  bool get _isNew => _editing != null && (_editing!['id'] == null);
  bool get _isDraft => _status == 'draft';

  Future<String> _nextVoucher() async {
    final orgId = _orgId!;
    final year = DateTime.now().year;
    final existing = await Supabase.instance.client
        .from('processor_jobwork')
        .select('voucher_number')
        .eq('org_id', orgId)
        .like('voucher_number', 'JW-$year-%');
    int mx = 0;
    for (final r in existing as List) {
      final tail = (r['voucher_number'] as String?)?.split('-').last ?? '';
      final v = int.tryParse(tail) ?? 0;
      if (v > mx) mx = v;
    }
    return 'JW-$year-${(mx + 1).toString().padLeft(4, '0')}';
  }

  Future<String?> _saveDraft() async {
    if (_procId == null || _homeId == null) { _snack('Pick the processor and home branch'); return null; }
    if (_inputs.isEmpty) { _snack('Add at least one input line'); return null; }
    if (_outputs.isEmpty) { _snack('Add at least one output line'); return null; }
    // ignore: avoid_print
    print('[jobwork] save: start (new=$_isNew inputs=${_inputs.length} outputs=${_outputs.length} heads=${_heads.length})');
    setState(() => _busy = true);
    // ignore: avoid_print
    print('[jobwork] save: busy=true rebuild requested');
    try {
      final client = Supabase.instance.client;
      final payload = {
        'processor_branch_id': _procId,
        'home_branch_id': _homeId,
        'supplier_id': _supplierId ??
            (_processors.firstWhere((p) => p['id'] == _procId, orElse: () => {})['supplier_id']),
        'jobwork_date': DateFormat('yyyy-MM-dd').format(_date),
        // Header fee is auto-calculated from the per-unit fee heads × output qty.
        'fee_amount': _feeTotal,
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      String id;
      if (_isNew) {
        id = 'jw_${DateTime.now().millisecondsSinceEpoch}';
        final vno = await _nextVoucher();
        // ignore: avoid_print
        print('[jobwork] save: voucher=$vno, inserting header');
        await client.from('processor_jobwork').insert({
          'id': id, 'org_id': _orgId, 'voucher_number': vno,
          'status': 'draft', 'created_by': _userId, ...payload,
        });
        // ignore: avoid_print
        print('[jobwork] save: header inserted');
        _editing = {'id': id, 'voucher_number': vno};
      } else {
        id = _editing!['id'] as String;
        await client.from('processor_jobwork').update(payload).eq('id', id);
        // ignore: avoid_print
        print('[jobwork] save: header updated');
      }
      // Replace all lines (draft only).
      await client.from('processor_jobwork_lines').delete().eq('jobwork_id', id);
      // ignore: avoid_print
      print('[jobwork] save: old lines deleted');
      final rows = <Map<String, dynamic>>[];
      void addLines(List<Map<String, dynamic>> src, String dir) {
        for (var i = 0; i < src.length; i++) {
          final l = src[i];
          rows.add({
            'id': 'pjl_${DateTime.now().microsecondsSinceEpoch}_${dir}_$i',
            'jobwork_id': id, 'direction': dir,
            'product_id': l['product_id'], 'uom_id': l['uom_id'],
            'quantity': l['qty'],
          });
        }
      }
      addLines(_inputs, 'input');
      addLines(_outputs, 'output');
      if (rows.isNotEmpty) await client.from('processor_jobwork_lines').insert(rows);
      // ignore: avoid_print
      print('[jobwork] save: ${rows.length} lines inserted');
      // Replace all cost heads (processor fee + internal overhead/labor).
      try {
        await client.from('processor_jobwork_overheads').delete().eq('jobwork_id', id);
        final headRows = <Map<String, dynamic>>[];
        for (var i = 0; i < _heads.length; i++) {
          final hh = _heads[i];
          final label = (hh['label'] as String?)?.trim() ?? '';
          final rate = (hh['rate'] as num?)?.toDouble() ?? 0;
          if (label.isEmpty && rate == 0) continue;
          headRows.add({
            'id': 'pjoh_${DateTime.now().microsecondsSinceEpoch}_$i',
            'jobwork_id': id,
            'label': label.isEmpty ? (hh['is_fee'] == true ? 'Processor fee' : 'Overhead') : label,
            'amount': rate,
            'is_fee': hh['is_fee'] == true,
            'line_order': i,
          });
        }
        if (headRows.isNotEmpty) {
          await client.from('processor_jobwork_overheads').insert(headRows);
        }
      } catch (_) {/* overheads table may predate migration 261 — skip gracefully */}
      // ignore: avoid_print
      print('[jobwork] save: heads written; all DB writes done');
      if (!mounted) return id;
      setState(() => _busy = false);
      // ignore: avoid_print
      print('[jobwork] save: busy=false rebuild requested');
      _snack('Saved');
      // ignore: avoid_print
      print('[jobwork] save: snackbar shown; done');
      return id;
    } catch (e, st) {
      // ignore: avoid_print
      print('[jobwork] save: FAILED $e\n$st');
      if (mounted) setState(() => _busy = false);
      _snack(friendlyError('Could not save', e));
      return null;
    }
  }

  Future<void> _post() async {
    final id = await _saveDraft();
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Post job-work receipt?'),
        content: const Text(
            'This consumes the input at the processor, receives the output at the '
            'home branch, and posts the fee as a payable. It can be voided but not edited afterwards.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Post')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final msg = await Supabase.instance.client
          .rpc('post_processor_jobwork', params: {'p_id': id, 'p_user': _userId});
      _snack('$msg');
      _closeEditor();
      await _load();
    } catch (e) {
      setState(() => _busy = false);
      _snack(friendlyError('Could not post', e));
    }
  }

  Future<void> _void(Map<String, dynamic> h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Void ${h['voucher_number'] ?? 'receipt'}?'),
        content: const Text(
            'This reverses the stock, cost layers and GL of this job-work receipt.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(context, true), child: const Text('Void')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final msg = await Supabase.instance.client
          .rpc('void_processor_jobwork', params: {'p_id': h['id'], 'p_user': _userId});
      _snack('$msg');
      _closeEditor();
      await _load();
    } catch (e) {
      setState(() => _busy = false);
      _snack(friendlyError('Could not void', e));
    }
  }

  // ── Line editing ────────────────────────────────────────────────────────
  Future<void> _addLine(List<Map<String, dynamic>> target) async {
    final p = await pickProduct(context, _products, title: 'Add product');
    if (p == null || p.isEmpty) return;
    setState(() {
      target.add({
        'product_id': p['id'], 'name': p['name'], 'sku': p['sku'] ?? '',
        'uom_id': p['base_uom_id'], 'qty': 1.0, 'unit_cost': 0.0,
      });
    });
  }

  /// Suggest output products from the current input lines: the finished goods
  /// whose active BOM lists one of these inputs as a component. Only the output
  /// product is proposed — the BOM's own material lines and overhead/labor heads
  /// are intentionally left out (this screen books a single processor fee, so
  /// pulling those would double-count). The user picks which to add and sets qty.
  Future<void> _suggestOutputs() async {
    final wanted = <String>{};
    for (final l in _inputs) {
      final pid = l['product_id'] as String?;
      if (pid != null) wanted.addAll(_outputsByInput[pid] ?? const <String>{});
    }
    // Don't re-suggest outputs already on the receipt.
    final already = _outputs.map((o) => o['product_id']).toSet();
    final candidates = wanted
        .where((id) => !already.contains(id))
        .map((id) => _products.firstWhere((p) => p['id'] == id, orElse: () => {}))
        .where((p) => p.isNotEmpty)
        .toList()
      ..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));

    if (candidates.isEmpty) {
      _snack('No BOM-based output found for these inputs. Use "Add product" to pick manually.');
      return;
    }
    final chosen = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) {
        final sel = <String>{...candidates.map((c) => c['id'] as String)}; // default: all checked
        return StatefulBuilder(builder: (ctx, setS) => AlertDialog(
          title: const Text('Suggested outputs'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Finished goods whose BOM uses your input material(s). Select which to add — you set the quantity after.',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final p in candidates)
                    CheckboxListTile(
                      dense: true,
                      value: sel.contains(p['id']),
                      onChanged: (v) => setS(() => v == true ? sel.add(p['id'] as String) : sel.remove(p['id'])),
                      title: Text('${p['name']}', style: const TextStyle(fontSize: 13.5)),
                      subtitle: ('${p['sku'] ?? ''}'.isNotEmpty)
                          ? Text('${p['sku']}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))
                          : null,
                    ),
                ]),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx,
                  candidates.where((c) => sel.contains(c['id'])).toList()),
              child: const Text('Add selected'),
            ),
          ],
        ));
      },
    );
    if (chosen == null || chosen.isEmpty) return;
    setState(() {
      for (final p in chosen) {
        _outputs.add({
          'product_id': p['id'], 'name': p['name'], 'sku': p['sku'] ?? '',
          'uom_id': p['base_uom_id'], 'qty': 1.0, 'unit_cost': 0.0,
        });
      }
    });
  }

  double get _inputCostEstimate {
    double c = 0;
    for (final l in _inputs) {
      final prod = _products.firstWhere((p) => p['id'] == l['product_id'], orElse: () => {});
      c += ((l['qty'] as num?)?.toDouble() ?? 0) * ((prod['cost_price'] as num?)?.toDouble() ?? 0);
    }
    return c;
  }

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('[jobwork] build: loading=$_loading editing=${_editing != null} isNew=$_isNew busy=$_busy '
        'inputs=${_inputs.length} outputs=${_outputs.length} heads=${_heads.length}');
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _editing == null
              ? _listView()
              : _editorView(),
    );
  }

  // ── List ────────────────────────────────────────────────────────────────
  Widget _listView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Processor Job-work',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: _processors.isEmpty ? null : _newDoc,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New Job-work'),
        ),
      ]),
      const SizedBox(height: 4),
      Text(
          _processors.isEmpty
              ? 'Add a processor / off-site location first (Branches → Processor).'
              : 'Transformed returns: input consumed at a processor, output received here, fee accrued as payable.',
          style: const TextStyle(color: AppTheme.textSecondary)),
      const SizedBox(height: 20),
      Expanded(
        child: _list.isEmpty
            ? const Center(child: Text('No job-work receipts yet.',
                style: TextStyle(color: AppTheme.textSecondary)))
            : Container(
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.border)),
                child: ListView.separated(
                  itemCount: _list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final h = _list[i];
                    final status = (h['status'] as String?) ?? 'draft';
                    return ListTile(
                      onTap: () => _openDoc(h),
                      title: Text('${h['voucher_number'] ?? '—'}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                          '${_procName(h['processor_branch_id'] as String?)} → ${_homeName(h['home_branch_id'] as String?)}  ·  ${h['jobwork_date'] ?? ''}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('Rs. ${money((h['total_cost'] as num?)?.toDouble() ?? (h['fee_amount'] as num?)?.toDouble() ?? 0)}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(width: 12),
                        _statusChip(status),
                      ]),
                    );
                  },
                ),
              ),
      ),
    ]);
  }

  Widget _statusChip(String s) {
    final c = s == 'posted' ? AppTheme.success : s == 'void' ? AppTheme.danger : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(s[0].toUpperCase() + s.substring(1),
          style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }

  // ── Editor ──────────────────────────────────────────────────────────────
  Widget _editorView() {
    final editable = _isDraft;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton(onPressed: _busy ? null : _closeEditor, icon: const Icon(Icons.arrow_back)),
        const SizedBox(width: 4),
        Text(_isNew ? 'New Job-work Receipt' : '${_editing!['voucher_number'] ?? 'Job-work'}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(width: 12),
        if (!_isNew) _statusChip(_status),
        const Spacer(),
        if (_status == 'posted')
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _void(_editing!),
            icon: const Icon(Icons.block, size: 16, color: AppTheme.danger),
            label: const Text('Void', style: TextStyle(color: AppTheme.danger)),
          ),
        if (editable) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _saveDraft(),
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('Save Draft'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _post,
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Post'),
          ),
        ],
      ]),
      const SizedBox(height: 16),
      Expanded(
        child: ListView(children: [
          _headerCard(editable),
          const SizedBox(height: 16),
          _linesCard('Inputs (consumed at processor)', _inputs, editable, isInput: true),
          const SizedBox(height: 16),
          _linesCard('Outputs (received at home)', _outputs, editable, isInput: false,
              onSuggest: _inputs.isEmpty ? null : _suggestOutputs),
          const SizedBox(height: 16),
          _headsCard(editable),
          const SizedBox(height: 16),
          _summaryCard(),
        ]),
      ),
    ]);
  }

  Widget _headerCard(bool editable) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Wrap(spacing: 20, runSpacing: 14, crossAxisAlignment: WrapCrossAlignment.end, children: [
        _field('Processor', SizedBox(width: 220, child: editable
            ? InkWell(
                onTap: () async {
                  final p = await pickProduct(context, _processors, title: 'Select processor');
                  if (p == null || p.isEmpty) return;
                  setState(() {
                    _procId = p['id'] as String?;
                    _supplierId = p['supplier_id'] as String?;
                  });
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.search, size: 18)),
                  child: Text(_procId == null ? 'Select processor' : _procName(_procId),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _procId == null ? AppTheme.textSecondary : null)),
                ),
              )
            : _ro(_procName(_procId)))),
        _field('Home branch', SizedBox(width: 200, child: editable
            ? DropdownButtonFormField<String>(
                value: _homes.any((b) => b['id'] == _homeId) ? _homeId : null,
                isExpanded: true,
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                hint: const Text('Select branch'),
                items: [for (final b in _homes) DropdownMenuItem(value: b['id'] as String, child: Text('${b['name']}'))],
                onChanged: (v) => setState(() => _homeId = v),
              )
            : _ro(_homeName(_homeId)))),
        _field('Processor (supplier)', SizedBox(width: 220, child: editable
            ? DropdownButtonFormField<String>(
                value: _suppliers.any((s) => s['id'] == _supplierId) ? _supplierId : null,
                isExpanded: true,
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                hint: const Text('Fee payable to…'),
                items: [for (final s in _suppliers) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}'))],
                onChanged: (v) => setState(() => _supplierId = v),
              )
            : _ro(_suppName(_supplierId)))),
        _field('Date', SizedBox(width: 160, child: editable
            ? InkWell(
                onTap: () async {
                  final p = await showDatePicker(context: context, initialDate: _date,
                      firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (p != null) setState(() => _date = p);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  child: Text(DateFormat('d MMM yyyy').format(_date)),
                ),
              )
            : _ro(DateFormat('d MMM yyyy').format(_date)))),
        // Auto: sum of the "processor fee" cost heads × total output qty.
        _field('Processor fee (auto)', SizedBox(width: 160,
            child: _ro('Rs ${money(_feeTotal)}'))),
        _field('Notes', SizedBox(width: 260, child: editable
            ? TextField(controller: _notesCtrl,
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()))
            : _ro(_notesCtrl.text.isEmpty ? '—' : _notesCtrl.text))),
      ]),
    );
  }

  Widget _linesCard(String title, List<Map<String, dynamic>> lines, bool editable,
      {required bool isInput, VoidCallback? onSuggest}) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Row(children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const Spacer(),
            if (editable && onSuggest != null)
              TextButton.icon(
                onPressed: onSuggest,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Suggest from inputs'),
              ),
            if (editable)
              TextButton.icon(
                onPressed: () => _addLine(lines),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add product'),
              ),
          ]),
        ),
        const Divider(height: 1),
        if (lines.isEmpty)
          const Padding(padding: EdgeInsets.all(18),
              child: Text('No lines yet.', style: TextStyle(color: AppTheme.textSecondary)))
        else
          for (int i = 0; i < lines.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _lineRow(lines, i, editable, isInput: isInput),
          ],
      ]),
    );
  }

  Widget _lineRow(List<Map<String, dynamic>> lines, int i, bool editable, {required bool isInput}) {
    final l = lines[i];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${l['name']}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          if ('${l['sku'] ?? ''}'.isNotEmpty)
            Text('${l['sku']}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        const SizedBox(width: 12),
        SizedBox(width: 110, child: editable
            ? TextFormField(
                initialValue: _fmtQty((l['qty'] as num?)?.toDouble() ?? 0),
                decoration: const InputDecoration(labelText: 'Qty', isDense: true, border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                onChanged: (v) => l['qty'] = double.tryParse(v) ?? 0,
              )
            : Text(_fmtQty((l['qty'] as num?)?.toDouble() ?? 0),
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w600))),
        if (!editable && !isInput && ((l['unit_cost'] as num?)?.toDouble() ?? 0) > 0) ...[
          const SizedBox(width: 12),
          SizedBox(width: 120, child: Text('@ ${money((l['unit_cost'] as num?)?.toDouble() ?? 0)}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        ],
        if (editable)
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
            onPressed: () => setState(() => lines.removeAt(i)),
          ),
      ]),
    );
  }

  Widget _summaryCard() {
    final inputEst = _inputCostEstimate;
    final fee = _feeTotal;
    final oh = _ohTotal;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: AppTheme.primary.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.primary.withOpacity(0.2))),
      child: Wrap(spacing: 28, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _sum('Input cost (est.)', 'Rs. ${money(inputEst)}'),
        _sum('Processor fee', 'Rs. ${money(fee)}'),
        _sum('Internal overhead', 'Rs. ${money(oh)}'),
        _sum('Output value', 'Rs. ${money(inputEst + fee + oh)}', bold: true),
        if (_isDraft)
          const SizedBox(
            width: 280,
            child: Text('Fee & overhead heads are per output unit × total output qty. Estimate uses product standard cost; posting values inputs at their actual FIFO cost.',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ),
      ]),
    );
  }

  // ── Cost heads: processor fee + internal overhead / labor ────────────────
  void _addHead({required bool isFee}) {
    setState(() => _heads.add({'label': '', 'rate': 0.0, 'is_fee': isFee}));
  }

  Widget _headsCard(bool editable) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Row(children: [
            const Expanded(child: Text('Cost heads (processor fee + overhead / labor)',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
            if (editable) ...[
              TextButton.icon(
                onPressed: () => _addHead(isFee: true),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Processor fee'),
              ),
              TextButton.icon(
                onPressed: () => _addHead(isFee: false),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Overhead / labor'),
              ),
            ],
          ]),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Text('Each head is a rate per output unit; the total below is the rate × total output qty (${_fmtQty(_outQty)}).',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        ),
        if (_heads.isEmpty)
          const Padding(padding: EdgeInsets.all(18),
              child: Text('No cost heads. Add the processor fee and any internal overhead / labor.',
                  style: TextStyle(color: AppTheme.textSecondary)))
        else
          for (int i = 0; i < _heads.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _headRow(i, editable),
          ],
      ]),
    );
  }

  Widget _headRow(int i, bool editable) {
    final hh = _heads[i];
    final isFee = hh['is_fee'] == true;
    final rate = (hh['rate'] as num?)?.toDouble() ?? 0;
    final lineTotal = rate * _outQty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: (isFee ? AppTheme.primary : AppTheme.textSecondary).withOpacity(0.12),
              borderRadius: BorderRadius.circular(6)),
          child: Text(isFee ? 'Processor fee' : 'Overhead',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700,
                  color: isFee ? AppTheme.primary : AppTheme.textSecondary)),
        ),
        const SizedBox(width: 12),
        Expanded(flex: 4, child: editable
            ? TextFormField(
                initialValue: '${hh['label'] ?? ''}',
                decoration: InputDecoration(
                    labelText: 'Head', hintText: isFee ? 'e.g. Stitching fee' : 'e.g. Labor, Electricity',
                    isDense: true, border: const OutlineInputBorder()),
                onChanged: (v) => hh['label'] = v,
              )
            : Text('${hh['label'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
        const SizedBox(width: 12),
        SizedBox(width: 120, child: editable
            ? TextFormField(
                initialValue: _fmtQty(rate),
                decoration: const InputDecoration(labelText: 'Rate / unit', isDense: true, border: OutlineInputBorder(), prefixText: 'Rs '),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                onChanged: (v) => setState(() => hh['rate'] = double.tryParse(v) ?? 0),
              )
            : Text('Rs ${money(rate)}', textAlign: TextAlign.right)),
        const SizedBox(width: 12),
        SizedBox(width: 110, child: Text('= Rs ${money(lineTotal)}',
            textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
        if (editable)
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
            onPressed: () => setState(() => _heads.removeAt(i)),
          ),
      ]),
    );
  }

  Widget _sum(String label, String value, {bool bold = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: bold ? 18 : 15, fontWeight: FontWeight.w800,
              color: bold ? AppTheme.primary : null)),
        ],
      );

  Widget _field(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          child,
        ],
      );

  Widget _ro(String v) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.border)),
        child: Text(v, overflow: TextOverflow.ellipsis),
      );

  String _procName(String? id) => _processors.firstWhere((b) => b['id'] == id, orElse: () => {})['name'] as String? ?? '—';
  String _homeName(String? id) => _homes.firstWhere((b) => b['id'] == id, orElse: () => {})['name'] as String? ?? '—';
  String _suppName(String? id) => _suppliers.firstWhere((b) => b['id'] == id, orElse: () => {})['name'] as String? ?? '—';
  String _fmtQty(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);
}
