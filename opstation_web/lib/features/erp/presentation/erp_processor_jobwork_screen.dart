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
/// consumed and different output product(s) come back to a home branch. Cost
/// heads are per-unit rates × total output qty: "processor fee" heads accrue to
/// the processor's A/P; "overhead / labor" heads to the applied-overhead account.
/// Posting/voiding is done by post_processor_jobwork / void_processor_jobwork.
///
/// Structure notes (deliberate): every editable row owns a stable
/// TextEditingController and a stable key, so rebuilds never tear text fields
/// down; totals are computed from state on demand; after a save the editor is
/// closed and the list reloaded (never re-rendered in place).
class ErpProcessorJobworkScreen extends ConsumerStatefulWidget {
  const ErpProcessorJobworkScreen({super.key});
  @override
  ConsumerState<ErpProcessorJobworkScreen> createState() =>
      _ErpProcessorJobworkScreenState();
}

/// One product line (input or output) with its own qty controller.
class _Line {
  final String key;
  final String productId;
  final String name;
  final String sku;
  final String? uomId;
  final TextEditingController qtyCtrl;
  final double unitCost;
  _Line({
    required this.productId,
    required this.name,
    required this.sku,
    required this.uomId,
    required double qty,
    this.unitCost = 0,
  })  : key = 'ln_${DateTime.now().microsecondsSinceEpoch}_$productId',
        qtyCtrl = TextEditingController(text: _fmt(qty));
  double get qty => double.tryParse(qtyCtrl.text.trim()) ?? 0;
  void dispose() => qtyCtrl.dispose();
}

/// One cost head: label + per-unit rate; isFee → processor A/P, else overhead.
class _Head {
  final String key;
  final bool isFee;
  final TextEditingController labelCtrl;
  final TextEditingController rateCtrl;
  _Head({required this.isFee, String label = '', double rate = 0})
      : key = 'hd_${DateTime.now().microsecondsSinceEpoch}_${isFee ? 'f' : 'o'}',
        labelCtrl = TextEditingController(text: label),
        rateCtrl = TextEditingController(text: _fmt(rate));
  double get rate => double.tryParse(rateCtrl.text.trim()) ?? 0;
  String get label => labelCtrl.text.trim();
  void dispose() { labelCtrl.dispose(); rateCtrl.dispose(); }
}

String _fmt(double q) {
  if (q.isNaN || q.isInfinite) return '0';
  return q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);
}

double _safe(double v) => (v.isNaN || v.isInfinite) ? 0 : v;

class _ErpProcessorJobworkScreenState
    extends ConsumerState<ErpProcessorJobworkScreen> {
  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _list = [];
  List<Map<String, dynamic>> _processors = [];
  List<Map<String, dynamic>> _homes = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _suppliers = [];
  final Map<String, Set<String>> _outputsByInput = {}; // BOM: input -> finished goods
  // BOM overhead/labor suggestions, keyed by finished-good product_id:
  // [{label, rate}] where rate is per output unit (bom amount / bom output_qty).
  final Map<String, List<Map<String, dynamic>>> _ohSuggestByFg = {};

  // Editor state — null _editing = list mode.
  Map<String, dynamic>? _editing;
  String? _procId, _homeId, _supplierId;
  DateTime _date = DateTime.now();
  final _notesCtrl = TextEditingController();
  final List<_Line> _inputs = [];
  final List<_Line> _outputs = [];
  final List<_Head> _heads = [];
  String _status = 'draft';

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _disposeRows();
    super.dispose();
  }

  void _disposeRows() {
    for (final l in _inputs) { l.dispose(); }
    for (final l in _outputs) { l.dispose(); }
    for (final h in _heads) { h.dispose(); }
    _inputs.clear(); _outputs.clear(); _heads.clear();
  }

  // Inline notice banner instead of a floating SnackBar (the SnackBar overlay is
  // the one element present in every blank-after-save case and absent on a
  // plain open). Auto-clears after a few seconds.
  String? _notice;
  bool _noticeIsError = false;
  int _noticeSeq = 0;
  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    final seq = ++_noticeSeq;
    setState(() { _notice = m; _noticeIsError = error; });
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _noticeSeq == seq) setState(() => _notice = null);
    });
  }

  Widget _noticeBanner() {
    final n = _notice;
    if (n == null) return const SizedBox.shrink();
    final c = _noticeIsError ? AppTheme.danger : AppTheme.success;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
          color: c.withOpacity(0.10), borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withOpacity(0.4))),
      child: Row(children: [
        Icon(_noticeIsError ? Icons.error_outline : Icons.check_circle_outline, size: 18, color: c),
        const SizedBox(width: 8),
        Expanded(child: Text(n, style: TextStyle(color: c, fontWeight: FontWeight.w600))),
        IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => setState(() => _notice = null)),
      ]),
    );
  }

  // ── Totals (computed on demand from row controllers) ─────────────────────
  double get _outQty => _safe(_outputs.fold(0.0, (s, l) => s + l.qty));
  double get _feeTotal =>
      _safe(_heads.where((h) => h.isFee).fold(0.0, (s, h) => s + h.rate) * _outQty);
  double get _ohTotal =>
      _safe(_heads.where((h) => !h.isFee).fold(0.0, (s, h) => s + h.rate) * _outQty);
  double get _inputCostEstimate {
    double c = 0;
    for (final l in _inputs) {
      final prod = _products.firstWhere((p) => p['id'] == l.productId, orElse: () => {});
      c += l.qty * ((prod['cost_price'] as num?)?.toDouble() ?? 0);
    }
    return _safe(c);
  }

  // ── Data ─────────────────────────────────────────────────────────────────
  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { if (mounted) setState(() => _loading = false); return; }
    if (mounted) setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final branches = await client.from('branches')
          .select('id, name, is_virtual, supplier_id').eq('org_id', orgId).eq('is_active', true).order('name');
      final products = await client.from('products')
          .select('id, name, sku, base_uom_id, cost_price').eq('org_id', orgId).eq('is_active', true).limit(5000);
      final suppliers = await client.from('suppliers')
          .select('id, name').eq('org_id', orgId).order('name');
      final list = await client.from('processor_jobwork')
          .select('*').eq('org_id', orgId).order('created_at', ascending: false).limit(200);

      // BOM maps for suggestions — optional, never blocks loading.
      final byInput = <String, Set<String>>{};
      final byFgOh = <String, List<Map<String, dynamic>>>{};
      try {
        final headers = await client.from('bom_headers')
            .select('id, product_id, output_qty').eq('org_id', orgId).eq('status', 'active').limit(2000);
        final fgByBom = <String, String>{};
        final outQtyByBom = <String, double>{};
        for (final h in headers as List) {
          final bid = h['id'] as String?; final fg = h['product_id'] as String?;
          if (bid != null && fg != null) {
            fgByBom[bid] = fg;
            outQtyByBom[bid] = (h['output_qty'] as num?)?.toDouble() ?? 0;
          }
        }
        final ids = fgByBom.keys.toList();
        for (var i = 0; i < ids.length; i += 200) {
          final chunk = ids.sublist(i, (i + 200).clamp(0, ids.length));
          final comps = await client.from('bom_components')
              .select('bom_id, product_id').inFilter('bom_id', chunk);
          for (final c in comps as List) {
            final inPid = c['product_id'] as String?;
            final fg = fgByBom[c['bom_id']];
            if (inPid != null && fg != null && fg != inPid) {
              (byInput[inPid] ??= <String>{}).add(fg);
            }
          }
          // Overhead / labor heads per BOM → per-unit rate for the finished good.
          try {
            final ohs = await client.from('bom_overheads')
                .select('bom_id, description, amount, cost_type').inFilter('bom_id', chunk);
            for (final o in ohs as List) {
              final fg = fgByBom[o['bom_id']];
              final oq = outQtyByBom[o['bom_id']] ?? 0;
              if (fg == null || oq <= 0) continue;
              final amt = (o['amount'] as num?)?.toDouble() ?? 0;
              if (amt == 0) continue;
              final label = (o['description'] as String?)?.trim().isNotEmpty == true
                  ? (o['description'] as String).trim()
                  : ((o['cost_type'] as String?) == 'labor' ? 'Labor' : 'Overhead');
              (byFgOh[fg] ??= []).add({'label': label, 'rate': amt / oq});
            }
          } catch (_) {}
        }
      } catch (_) {}

      if (!mounted) return;
      final all = List<Map<String, dynamic>>.from(branches);
      setState(() {
        _processors = all.where((b) => b['is_virtual'] == true).toList();
        _homes = all.where((b) => b['is_virtual'] != true).toList();
        _products = List<Map<String, dynamic>>.from(products);
        _suppliers = List<Map<String, dynamic>>.from(suppliers);
        _list = List<Map<String, dynamic>>.from(list);
        _outputsByInput
          ..clear()
          ..addAll(byInput);
        _ohSuggestByFg
          ..clear()
          ..addAll(byFgOh);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(friendlyError('Could not load job-work receipts', e), error: true);
    }
  }

  // ── Editor open/close ────────────────────────────────────────────────────
  void _newDoc() {
    _disposeRows();
    final sel = ref.read(selectedBranchProvider)?['id'] as String?;
    final selIsHome = sel != null && _homes.any((b) => b['id'] == sel);
    setState(() {
      _editing = {};
      _procId = _processors.length == 1 ? _processors.first['id'] as String? : null;
      _supplierId = _procId == null
          ? null
          : _processors.firstWhere((p) => p['id'] == _procId, orElse: () => {})['supplier_id'] as String?;
      _homeId = selIsHome ? sel : (_homes.length == 1 ? _homes.first['id'] as String? : null);
      _date = DateTime.now();
      _notesCtrl.text = '';
      _status = 'draft';
      _busy = false;
    });
  }

  Future<void> _openDoc(Map<String, dynamic> h) async {
    setState(() => _busy = true);
    try {
      final client = Supabase.instance.client;
      final lines = await client.from('processor_jobwork_lines').select('*').eq('jobwork_id', h['id']);
      List heads = const [];
      try {
        heads = await client.from('processor_jobwork_overheads')
            .select('*').eq('jobwork_id', h['id']).order('line_order');
      } catch (_) {}
      if (!mounted) return;
      _disposeRows();
      _Line mk(Map<String, dynamic> l) {
        final p = _products.firstWhere((x) => x['id'] == l['product_id'], orElse: () => {});
        return _Line(
          productId: l['product_id'] as String,
          name: (p['name'] as String?) ?? (l['product_id'] as String),
          sku: (p['sku'] as String?) ?? '',
          uomId: l['uom_id'] as String?,
          qty: (l['quantity'] as num?)?.toDouble() ?? 0,
          unitCost: (l['unit_cost'] as num?)?.toDouble() ?? 0,
        );
      }
      for (final l in lines as List) {
        final m = Map<String, dynamic>.from(l as Map);
        if (m['direction'] == 'input') { _inputs.add(mk(m)); } else { _outputs.add(mk(m)); }
      }
      for (final o in heads) {
        final m = Map<String, dynamic>.from(o as Map);
        _heads.add(_Head(
          isFee: m['is_fee'] == true,
          label: (m['label'] as String?) ?? '',
          rate: (m['amount'] as num?)?.toDouble() ?? 0,
        ));
      }
      setState(() {
        _editing = h;
        _procId = h['processor_branch_id'] as String?;
        _homeId = h['home_branch_id'] as String?;
        _supplierId = h['supplier_id'] as String?;
        _date = DateTime.tryParse('${h['jobwork_date']}') ?? DateTime.now();
        _notesCtrl.text = (h['notes'] as String?) ?? '';
        _status = (h['status'] as String?) ?? 'draft';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(friendlyError('Could not open', e), error: true);
    }
  }

  void _closeEditor() {
    _disposeRows();
    setState(() { _editing = null; _busy = false; });
  }

  bool get _isNew => _editing != null && (_editing!['id'] == null);
  bool get _isDraft => _status == 'draft';

  Future<String> _nextVoucher() async {
    final orgId = _orgId!;
    final year = DateTime.now().year;
    final existing = await Supabase.instance.client
        .from('processor_jobwork').select('voucher_number')
        .eq('org_id', orgId).like('voucher_number', 'JW-$year-%');
    int mx = 0;
    for (final r in existing as List) {
      final tail = (r['voucher_number'] as String?)?.split('-').last ?? '';
      final v = int.tryParse(tail) ?? 0;
      if (v > mx) mx = v;
    }
    return 'JW-$year-${(mx + 1).toString().padLeft(4, '0')}';
  }

  /// Writes the draft (header, lines, heads). Returns the id, or null on a
  /// validation/DB failure (already reported). Does NOT touch UI state.
  Future<String?> _writeDraft() async {
    if (_procId == null || _homeId == null) { _snack('Pick the processor and home branch', error: true); return null; }
    if (_inputs.isEmpty) { _snack('Add at least one input line', error: true); return null; }
    if (_outputs.isEmpty) { _snack('Add at least one output line', error: true); return null; }
    if (_inputs.any((l) => l.qty <= 0) || _outputs.any((l) => l.qty <= 0)) {
      _snack('Every line needs a quantity greater than zero', error: true); return null;
    }
    try {
      final client = Supabase.instance.client;
      final payload = {
        'processor_branch_id': _procId,
        'home_branch_id': _homeId,
        'supplier_id': _supplierId ??
            (_processors.firstWhere((p) => p['id'] == _procId, orElse: () => {})['supplier_id']),
        'jobwork_date': DateFormat('yyyy-MM-dd').format(_date),
        'fee_amount': _feeTotal, // auto: fee heads × output qty
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      String id;
      if (_isNew) {
        id = 'jw_${DateTime.now().millisecondsSinceEpoch}';
        final vno = await _nextVoucher();
        await client.from('processor_jobwork').insert({
          'id': id, 'org_id': _orgId, 'voucher_number': vno,
          'status': 'draft', 'created_by': _userId, ...payload,
        });
        _editing = {'id': id, 'voucher_number': vno};
      } else {
        id = _editing!['id'] as String;
        await client.from('processor_jobwork').update(payload).eq('id', id);
      }
      await client.from('processor_jobwork_lines').delete().eq('jobwork_id', id);
      final rows = <Map<String, dynamic>>[];
      void add(List<_Line> src, String dir) {
        for (var i = 0; i < src.length; i++) {
          rows.add({
            'id': 'pjl_${DateTime.now().microsecondsSinceEpoch}_${dir}_$i',
            'jobwork_id': id, 'direction': dir,
            'product_id': src[i].productId, 'uom_id': src[i].uomId,
            'quantity': src[i].qty,
          });
        }
      }
      add(_inputs, 'input');
      add(_outputs, 'output');
      if (rows.isNotEmpty) await client.from('processor_jobwork_lines').insert(rows);
      try {
        await client.from('processor_jobwork_overheads').delete().eq('jobwork_id', id);
        final hr = <Map<String, dynamic>>[];
        for (var i = 0; i < _heads.length; i++) {
          final h = _heads[i];
          if (h.label.isEmpty && h.rate == 0) continue;
          hr.add({
            'id': 'pjoh_${DateTime.now().microsecondsSinceEpoch}_$i',
            'jobwork_id': id,
            'label': h.label.isEmpty ? (h.isFee ? 'Processor fee' : 'Overhead') : h.label,
            'amount': h.rate,
            'is_fee': h.isFee,
            'line_order': i,
          });
        }
        if (hr.isNotEmpty) await client.from('processor_jobwork_overheads').insert(hr);
      } catch (_) {/* overheads table may predate migration 261 */}
      return id;
    } catch (e) {
      _snack(friendlyError('Could not save', e), error: true);
      return null;
    }
  }

  Future<void> _saveDraft() async {
    if (_busy) return;
    setState(() => _busy = true);
    final id = await _writeDraft();
    if (!mounted) return;
    if (id == null) { setState(() => _busy = false); return; }
    final vno = '${_editing?['voucher_number'] ?? ''}';
    _closeEditor();          // never re-render the editor in place after a save
    _snack('Saved $vno'.trim());
    await _load();
  }

  Future<void> _post() async {
    if (_busy) return;
    setState(() => _busy = true);
    final id = await _writeDraft();
    if (!mounted) return;
    if (id == null) { setState(() => _busy = false); return; }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Post job-work receipt?'),
        content: const Text(
            'This consumes the input at the processor, receives the output at the '
            'home branch, and posts the processor fee as a payable. It can be voided but not edited afterwards.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Post')),
        ],
      ),
    );
    if (!mounted) return;
    if (ok != true) { setState(() => _busy = false); return; }

    String resultMsg; bool resultOk;
    try {
      final msg = await Supabase.instance.client
          .rpc('post_processor_jobwork', params: {'p_id': id, 'p_user': _userId});
      resultMsg = '$msg';
      // The RPC returns "… already posted" without actually posting when it
      // finds nothing to do — treat only a real "posted:" result as success.
      resultOk = resultMsg.toLowerCase().contains('posted:');
    } catch (e) {
      resultMsg = friendlyError('Could not post', e);
      resultOk = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    // Always show the outcome in a dialog the user can't miss.
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(resultOk ? 'Posted' : 'Not posted',
            style: TextStyle(color: resultOk ? AppTheme.success : AppTheme.danger)),
        content: SingleChildScrollView(child: Text(resultMsg)),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
    if (!mounted) return;

    if (resultOk) {
      _closeEditor();
      await _load();
      if (!mounted) return;
      final h = _list.firstWhere((r) => r['id'] == id, orElse: () => <String, dynamic>{});
      if (h.isNotEmpty) await _openDoc(h);
    }
    // On failure, stay in the editor so the user can fix the inputs and retry.
  }

  Future<void> _void(Map<String, dynamic> h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Void ${h['voucher_number'] ?? 'receipt'}?'),
        content: const Text('This reverses the stock, cost layers and GL of this job-work receipt.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true), child: const Text('Void')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final msg = await Supabase.instance.client
          .rpc('void_processor_jobwork', params: {'p_id': h['id'], 'p_user': _userId});
      _snack('$msg');
    } catch (e) {
      _snack(friendlyError('Could not void', e), error: true);
    }
    if (!mounted) return;
    _closeEditor();
    await _load();
  }

  // ── Line / head editing ──────────────────────────────────────────────────
  Future<void> _addLine(List<_Line> target) async {
    final p = await pickProduct(context, _products, title: 'Add product');
    if (p == null || p.isEmpty || !mounted) return;
    setState(() => target.add(_Line(
      productId: p['id'] as String, name: '${p['name']}', sku: '${p['sku'] ?? ''}',
      uomId: p['base_uom_id'] as String?, qty: 1,
    )));
  }

  void _removeLine(List<_Line> target, _Line l) {
    setState(() { target.remove(l); });
    l.dispose();
  }

  void _addHead({required bool isFee}) => setState(() => _heads.add(_Head(isFee: isFee)));

  /// Suggest overhead / labor cost heads from the output products' BOMs: each
  /// BOM overhead/labor line, converted to a per-output-unit rate. The processor
  /// fee is external (not in the BOM), so it is never suggested here.
  Future<void> _suggestHeads() async {
    // Collect suggestions across the chosen outputs, summing rates for the same
    // label (so two outputs sharing a "Labor" head don't create duplicates).
    final byLabel = <String, double>{};
    for (final o in _outputs) {
      for (final s in _ohSuggestByFg[o.productId] ?? const <Map<String, dynamic>>[]) {
        final label = (s['label'] as String?) ?? 'Overhead';
        final rate = (s['rate'] as num?)?.toDouble() ?? 0;
        byLabel[label] = (byLabel[label] ?? 0) + rate;
      }
    }
    // Drop labels already present as a head.
    final existing = _heads.map((h) => h.label.toLowerCase()).toSet();
    final candidates = byLabel.entries
        .where((e) => !existing.contains(e.key.toLowerCase()))
        .toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    if (candidates.isEmpty) {
      _snack('No BOM overhead / labor found for these outputs. Add heads manually.', error: true);
      return;
    }
    final sel = <String>{...candidates.map((e) => e.key)};
    final chosen = await showDialog<List<MapEntry<String, double>>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Suggested overhead / labor'),
        content: SizedBox(width: 400, height: 360, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('From the output products\' BOMs, as a rate per output unit. Tick the heads to add; edit rates after.',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Expanded(child: ListView(children: [
            for (final e in candidates)
              CheckboxListTile(
                dense: true,
                value: sel.contains(e.key),
                onChanged: (v) => setS(() => v == true ? sel.add(e.key) : sel.remove(e.key)),
                title: Text(e.key, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text('Rs ${_fmt(e.value)} / unit', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
              ),
          ])),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, candidates.where((e) => sel.contains(e.key)).toList()),
            child: const Text('Add selected'),
          ),
        ],
      )),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    setState(() {
      for (final e in chosen) {
        _heads.add(_Head(isFee: false, label: e.key, rate: e.value));
      }
    });
  }

  void _removeHead(_Head h) {
    setState(() { _heads.remove(h); });
    h.dispose();
  }

  /// Suggest output products: finished goods whose active BOM lists one of the
  /// current inputs as a component. Only the product is proposed (no BOM
  /// materials / overhead heads — those would double-count here).
  Future<void> _suggestOutputs() async {
    final wanted = <String>{};
    for (final l in _inputs) { wanted.addAll(_outputsByInput[l.productId] ?? const <String>{}); }
    final already = _outputs.map((o) => o.productId).toSet();
    final candidates = wanted.where((id) => !already.contains(id))
        .map((id) => _products.firstWhere((p) => p['id'] == id, orElse: () => {}))
        .where((p) => p.isNotEmpty).toList()
      ..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
    if (candidates.isEmpty) {
      _snack('No BOM-based output found for these inputs. Use "Add product" to pick manually.');
      return;
    }
    final sel = <String>{...candidates.map((c) => c['id'] as String)};
    final chosen = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Suggested outputs'),
        content: SizedBox(
          width: 380, height: 360,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Finished goods whose BOM uses your input material(s). Tick the ones to add; set quantities after.',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(children: [
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
            onPressed: () => Navigator.pop(ctx, candidates.where((c) => sel.contains(c['id'])).toList()),
            child: const Text('Add selected'),
          ),
        ],
      )),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    setState(() {
      for (final p in chosen) {
        _outputs.add(_Line(
          productId: p['id'] as String, name: '${p['name']}', sku: '${p['sku'] ?? ''}',
          uomId: p['base_uom_id'] as String?, qty: 1,
        ));
      }
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 700;
    // Excluded from the app-wide SelectionArea: its selection machinery aborted
    // the whole frame here (blank app after save). Native field selection still
    // works; only drag-select of static labels is off on this one screen.
    return SelectionContainer.disabled(
      child: Container(
        color: AppTheme.background,
        padding: EdgeInsets.all(narrow ? 16 : 32),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_editing == null ? _listView() : _editorView()),
      ),
    );
  }

  // ── List ─────────────────────────────────────────────────────────────────
  Widget _listView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _noticeBanner(),
      Row(children: [
        const Expanded(child: Text('Processor Job-work',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
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
                    final amt = (h['total_cost'] as num?)?.toDouble() ?? (h['fee_amount'] as num?)?.toDouble() ?? 0;
                    return ListTile(
                      key: ValueKey('jw_${h['id']}'),
                      onTap: _busy ? null : () => _openDoc(h),
                      title: Text('${h['voucher_number'] ?? '—'}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                          '${_procName(h['processor_branch_id'] as String?)} → ${_homeName(h['home_branch_id'] as String?)}  ·  ${h['jobwork_date'] ?? ''}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('Rs. ${money(_safe(amt))}', style: const TextStyle(fontWeight: FontWeight.w700)),
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
    final label = s.isEmpty ? 'Draft' : s[0].toUpperCase() + s.substring(1);
    final c = s == 'posted' ? AppTheme.success : s == 'void' ? AppTheme.danger : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }

  // ── Editor ───────────────────────────────────────────────────────────────
  Widget _editorView() {
    final editable = _isDraft;
    final title = _isNew ? 'New Job-work Receipt' : '${_editing!['voucher_number'] ?? 'Job-work'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _noticeBanner(),
      Row(children: [
        IconButton(onPressed: _busy ? null : _closeEditor, icon: const Icon(Icons.arrow_back)),
        const SizedBox(width: 4),
        Expanded(
          child: Row(children: [
            Flexible(child: Text(title, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
            if (!_isNew) ...[const SizedBox(width: 12), _statusChip(_status)],
          ]),
        ),
        if (_status == 'posted')
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _void(_editing!),
            icon: const Icon(Icons.block, size: 16, color: AppTheme.danger),
            label: const Text('Void', style: TextStyle(color: AppTheme.danger)),
          ),
        if (editable) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _saveDraft,
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
          _linesCard('Inputs (consumed at processor)', _inputs, editable),
          const SizedBox(height: 16),
          _linesCard('Outputs (received at home)', _outputs, editable,
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
    return _card(child: Wrap(spacing: 20, runSpacing: 14, crossAxisAlignment: WrapCrossAlignment.end, children: [
      _field('Processor', SizedBox(width: 220, child: editable
          ? InkWell(
              onTap: () async {
                final p = await pickProduct(context, _processors, title: 'Select processor');
                if (p == null || p.isEmpty || !mounted) return;
                setState(() { _procId = p['id'] as String?; _supplierId = p['supplier_id'] as String?; });
              },
              child: InputDecorator(
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
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
                if (p != null && mounted) setState(() => _date = p);
              },
              child: InputDecorator(
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                child: Text(DateFormat('d MMM yyyy').format(_date)),
              ),
            )
          : _ro(DateFormat('d MMM yyyy').format(_date)))),
      _field('Processor fee (auto)', SizedBox(width: 160, child: _ro('Rs ${money(_feeTotal)}'))),
      _field('Notes', SizedBox(width: 260, child: editable
          ? TextField(controller: _notesCtrl,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()))
          : _ro(_notesCtrl.text.isEmpty ? '—' : _notesCtrl.text))),
    ]));
  }

  Widget _linesCard(String title, List<_Line> lines, bool editable, {VoidCallback? onSuggest}) {
    return _card(padding: EdgeInsets.zero, child: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          if (editable && onSuggest != null)
            TextButton.icon(onPressed: onSuggest,
                icon: const Icon(Icons.auto_awesome, size: 16), label: const Text('Suggest from inputs')),
          if (editable)
            TextButton.icon(onPressed: () => _addLine(lines),
                icon: const Icon(Icons.add, size: 16), label: const Text('Add product')),
        ]),
      ),
      const Divider(height: 1),
      if (lines.isEmpty)
        const Padding(padding: EdgeInsets.all(18),
            child: Text('No lines yet.', style: TextStyle(color: AppTheme.textSecondary)))
      else
        for (int i = 0; i < lines.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _lineRow(lines, lines[i], editable),
        ],
    ]));
  }

  Widget _lineRow(List<_Line> lines, _Line l, bool editable) {
    return Padding(
      key: ValueKey(l.key),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          if (l.sku.isNotEmpty)
            Text(l.sku, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        const SizedBox(width: 12),
        SizedBox(width: 110, child: editable
            ? TextField(
                controller: l.qtyCtrl,
                decoration: const InputDecoration(labelText: 'Qty', isDense: true, border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                onChanged: (_) => setState(() {}),
              )
            : Text(_fmt(l.qty), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
        if (!editable && l.unitCost > 0) ...[
          const SizedBox(width: 12),
          SizedBox(width: 120, child: Text('@ ${money(l.unitCost)}', textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        ],
        if (editable)
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
            onPressed: () => _removeLine(lines, l),
          ),
      ]),
    );
  }

  Widget _headsCard(bool editable) {
    return _card(padding: EdgeInsets.zero, child: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Row(children: [
          const Expanded(child: Text('Cost heads (processor fee + overhead / labor)',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
          if (editable) ...[
            if (_outputs.isNotEmpty)
              TextButton.icon(onPressed: _suggestHeads,
                  icon: const Icon(Icons.auto_awesome, size: 16), label: const Text('Suggest from BOM')),
            TextButton.icon(onPressed: () => _addHead(isFee: true),
                icon: const Icon(Icons.add, size: 16), label: const Text('Processor fee')),
            TextButton.icon(onPressed: () => _addHead(isFee: false),
                icon: const Icon(Icons.add, size: 16), label: const Text('Overhead / labor')),
          ],
        ]),
      ),
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        child: Text('Each head is a rate per output unit; its total is rate × total output qty (${_fmt(_outQty)}).',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
      ),
      if (_heads.isEmpty)
        const Padding(padding: EdgeInsets.all(18),
            child: Text('No cost heads. Add the processor fee and any internal overhead / labor.',
                style: TextStyle(color: AppTheme.textSecondary)))
      else
        for (int i = 0; i < _heads.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _headRow(_heads[i], editable),
        ],
    ]));
  }

  Widget _headRow(_Head h, bool editable) {
    final lineTotal = _safe(h.rate * _outQty);
    final c = h.isFee ? AppTheme.primary : AppTheme.textSecondary;
    return Padding(
      key: ValueKey(h.key),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
          child: Text(h.isFee ? 'Processor fee' : 'Overhead',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c)),
        ),
        const SizedBox(width: 12),
        Expanded(child: editable
            ? TextField(
                controller: h.labelCtrl,
                decoration: InputDecoration(labelText: 'Head',
                    hintText: h.isFee ? 'e.g. Stitching fee' : 'e.g. Labor, Electricity',
                    isDense: true, border: const OutlineInputBorder()),
              )
            : Text(h.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
        const SizedBox(width: 12),
        SizedBox(width: 120, child: editable
            ? TextField(
                controller: h.rateCtrl,
                decoration: const InputDecoration(labelText: 'Rate / unit', isDense: true,
                    border: OutlineInputBorder(), prefixText: 'Rs '),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                onChanged: (_) => setState(() {}),
              )
            : Text('Rs ${money(h.rate)}', textAlign: TextAlign.right)),
        const SizedBox(width: 12),
        SizedBox(width: 110, child: Text('= Rs ${money(lineTotal)}', textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700))),
        if (editable)
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
            onPressed: () => _removeHead(h),
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
        _sum('Output value', 'Rs. ${money(_safe(inputEst + fee + oh))}', bold: true),
        if (_isDraft)
          const SizedBox(width: 280,
              child: Text('Fee & overhead heads are per output unit × total output qty. Estimate uses product standard cost; posting values inputs at their actual FIFO cost.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
      ]),
    );
  }

  // ── Small helpers ────────────────────────────────────────────────────────
  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) => Container(
        padding: padding,
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: child,
      );

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
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
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
}
