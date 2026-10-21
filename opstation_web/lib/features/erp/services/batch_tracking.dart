import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/printing/label_printer.dart';
import '../../../core/theme/app_theme.dart';

/// Batch & warranty tracking (Admin Settings → Inventory & Products,
/// org.batch_tracking). Everything here does nothing while the setting is OFF
/// and never stops a GRN or a production post if something goes wrong.
class BatchTracking {
  static SupabaseClient get _db => Supabase.instance.client;

  static Future<bool> isOn(String? orgId) async {
    if (orgId == null) return false;
    try {
      final r = await _db.from('app_config').select('value')
          .eq('org_id', orgId).eq('key', 'org.batch_tracking').limit(1).maybeSingle();
      return (r?['value'] as String?) == 'true';
    } catch (_) {
      return false;
    }
  }

  /// product id → 'batch' | 'serial' for the tracked ones among [ids].
  static Future<Map<String, Map<String, dynamic>>> trackedProducts(List<String> ids) async {
    final out = <String, Map<String, dynamic>>{};
    final clean = ids.toSet().where((e) => e.isNotEmpty).toList();
    if (clean.isEmpty) return out;
    try {
      for (var i = 0; i < clean.length; i += 200) {
        final rows = await _db.from('products')
            .select('id, name, sku, batch_tracking, warranty_months, units_per_carton')
            .inFilter('id', clean.sublist(i, (i + 200).clamp(0, clean.length)));
        for (final r in rows as List) {
          final t = '${r['batch_tracking'] ?? 'none'}';
          if (t == 'batch' || t == 'serial') out[r['id'] as String] = Map<String, dynamic>.from(r);
        }
      }
    } catch (_) {}
    return out;
  }

  /// Open batches of a product with stock left, oldest first (same branch first).
  static Future<List<Map<String, dynamic>>> openBatches(String orgId, String productId, {String? branchId}) async {
    try {
      final rows = await _db.from('stock_batches')
          .select('id, batch_no, source_number, branch_id, supplier_id, received_on, warranty_until, qty_in, qty_used')
          .eq('org_id', orgId).eq('product_id', productId).eq('status', 'open')
          .order('received_on', ascending: true).order('created_at', ascending: true).limit(1000);
      final list = List<Map<String, dynamic>>.from(rows as List).where((b) => remaining(b) > 0).toList();
      await attachSuppliers(list);
      if (branchId != null) {
        // stable: same branch first, then oldest
        final mine = list.where((b) => b['branch_id'] == branchId).toList();
        final other = list.where((b) => b['branch_id'] != branchId).toList();
        return [...mine, ...other];
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  /// Adds 'supplier_name' to rows that have a supplier_id.
  static Future<void> attachSuppliers(List<Map<String, dynamic>> rows) async {
    final ids = rows.map((r) => r['supplier_id']).whereType<String>().toSet().toList();
    if (ids.isEmpty) return;
    try {
      final names = <String, String>{};
      for (var i = 0; i < ids.length; i += 200) {
        final s = await _db.from('suppliers').select('id, name').inFilter('id', ids.sublist(i, (i + 200).clamp(0, ids.length)));
        for (final r in s as List) { names[r['id'] as String] = '${r['name'] ?? ''}'; }
      }
      for (final r in rows) { final n = names[r['supplier_id']]; if (n != null) r['supplier_name'] = n; }
    } catch (_) {}
  }

  static double remaining(Map b) =>
      ((b['qty_in'] as num?)?.toDouble() ?? 0) - ((b['qty_used'] as num?)?.toDouble() ?? 0);

  static String qty(num? v) {
    final d = (v ?? 0).toDouble();
    return d % 1 == 0 ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
  }

  static String date(Object? v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '-' : DateFormat('d MMM y').format(d);
  }

  /// Records the component batches used and makes serials / cartons (or a
  /// batch) for the finished product. Returns null if off or on any problem.
  static Future<Map<String, dynamic>?> afterProduction({
    required String sourceType, // 'job_run' | 'production'
    required String sourceId,
    required String sourceNumber,
    required String? productId,
    required double qty,
    required String? branchId,
    DateTime? date,
    Map<String, String> picks = const {},
    List<Map<String, dynamic>> fallback = const [],
  }) async {
    if (productId == null) return null;
    try {
      final r = await _db.rpc('bt_after_production', params: {
        'p_source_type': sourceType,
        'p_source_id': sourceId,
        'p_source_number': sourceNumber,
        'p_product': productId,
        'p_qty': qty,
        'p_branch': branchId,
        'p_date': DateFormat('yyyy-MM-dd').format(date ?? DateTime.now()),
        'p_picks': picks,
        'p_fallback': fallback,
      });
      if (r is Map && r['on'] == true) return Map<String, dynamic>.from(r);
    } catch (_) {}
    return null;
  }

  /// Serials and cartons already made by one production (for reprints).
  static Future<Map<String, dynamic>?> madeBy(String sourceType, String sourceId) async {
    try {
      final s = await _db.from('product_serials').select('serial, carton_id')
          .eq('source_type', sourceType).eq('source_id', sourceId).neq('status', 'void').order('serial').limit(20000);
      final serials = List<Map<String, dynamic>>.from(s as List);
      if (serials.isEmpty) return null;
      final c = await _db.from('product_cartons').select('id, carton_no, qty')
          .eq('source_type', sourceType).eq('source_id', sourceId).neq('status', 'void').order('carton_no');
      final cartons = <Map<String, dynamic>>[];
      for (final ct in c as List) {
        final mine = serials.where((x) => x['carton_id'] == ct['id']).map((x) => '${x['serial']}').toList();
        cartons.add({'carton': ct['carton_no'], 'qty': ct['qty'],
          'first': mine.isEmpty ? null : mine.first, 'last': mine.isEmpty ? null : mine.last});
      }
      return {'tracking': 'serial', 'serials': serials.map((x) => {'serial': x['serial']}).toList(), 'cartons': cartons};
    } catch (_) {
      return null;
    }
  }

  /// Unit labels (one per serial) then carton labels. True if anything to print.
  static Future<bool> printSerialLabels(BuildContext context, Map<String, dynamic>? made, {
    required String productName,
    DateTime? date,
    String batch = '',
    bool ask = false,
  }) async {
    final serials = ((made?['serials'] as List?) ?? const []).map((e) => '${(e as Map)['serial']}').toList();
    if (serials.isEmpty) return false;
    final d = DateFormat('dd/MM/yyyy').format(date ?? DateTime.now());
    if (!context.mounted) return true;
    await showLabelPrintDialog(context,
      title: ask ? 'Print ${serials.length} serial label${serials.length == 1 ? '' : 's'}?' : 'Serial labels · ${serials.length}',
      allowQtyEdit: false,
      items: [for (final s in serials)
        LabelData(name: productName, code: s, codeText: s, batch: batch.isEmpty ? null : batch, date: d)],
      defaultCopies: 1,
    );
    final cartons = ((made?['cartons'] as List?) ?? const []).cast<Map>();
    if (cartons.isEmpty || !context.mounted) return true;
    await showLabelPrintDialog(context,
      title: 'Print ${cartons.length} carton label${cartons.length == 1 ? '' : 's'}?',
      allowQtyEdit: false,
      items: [for (final c in cartons)
        LabelData(
          name: productName,
          code: '${c['carton']}',
          codeText: '${c['carton']}',
          batch: c['first'] == null ? null : (c['first'] == c['last'] ? '${c['first']}' : '${c['first']} to ${c['last']}'),
          qty: '${c['qty']} pcs',
          date: d,
        )],
      defaultCopies: 1,
    );
    return true;
  }

  /// Searchable list of a product's open batches (type a GRN or batch number).
  static Future<Map<String, dynamic>?> pickBatch(BuildContext context, {
    required String orgId,
    required String productId,
    required String productName,
    String? branchId,
  }) async {
    final all = await openBatches(orgId, productId, branchId: branchId);
    if (!context.mounted) return null;
    if (all.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No batches with stock left for $productName.'), behavior: SnackBarBehavior.floating));
      return null;
    }
    final searchCtrl = TextEditingController();
    return showDialog<Map<String, dynamic>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final q = searchCtrl.text.trim().toLowerCase();
      final list = q.isEmpty ? all : all.where((b) =>
          '${b['batch_no']} ${b['source_number'] ?? ''} ${b['supplier_name'] ?? ''}'.toLowerCase().contains(q)).toList();
      return AlertDialog(
        title: Text('Batch for $productName'),
        content: SizedBox(width: 480, height: 420, child: Column(children: [
          TextField(controller: searchCtrl, autofocus: true,
            decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Type a GRN or batch number', border: OutlineInputBorder()),
            onChanged: (_) => setS(() {})),
          const SizedBox(height: 8),
          Expanded(child: list.isEmpty
            ? const Center(child: Text('No match', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final b = list[i];
                  final first = i == 0 && q.isEmpty;
                  final sup = b['supplier_name'];
                  return ListTile(
                    dense: true,
                    title: Text('${b['batch_no']}${b['source_number'] != null && b['source_number'] != b['batch_no'] ? '  ·  ${b['source_number']}' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      'Received ${date(b['received_on'])}',
                      if (sup != null) '$sup',
                      if (b['warranty_until'] != null) 'Warranty till ${date(b['warranty_until'])}',
                      if (branchId != null && b['branch_id'] != branchId) 'other branch',
                    ].join('  ·  '), style: const TextStyle(fontSize: 11)),
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('${qty(remaining(b))} left', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      if (first) const Text('oldest', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                    ]),
                    onTap: () => Navigator.pop(ctx, b),
                  );
                })),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      );
    }));
  }
}

/// "Component batches" box for the produce / post dialogs: each tracked
/// component shows the batch it will use — oldest first unless picked by hand.
/// Writes the hand-picked ones into [picks] (component product id → batch id).
class ComponentBatchPicker extends StatefulWidget {
  const ComponentBatchPicker({
    super.key,
    required this.orgId,
    required this.branchId,
    required this.components, // product id → name
    required this.picks,
  });
  final String orgId;
  final String? branchId;
  final Map<String, String> components;
  final Map<String, String> picks;

  @override
  State<ComponentBatchPicker> createState() => _ComponentBatchPickerState();
}

class _ComponentBatchPickerState extends State<ComponentBatchPicker> {
  bool _loading = true;
  Map<String, Map<String, dynamic>> _tracked = {};
  final Map<String, Map<String, dynamic>?> _oldest = {};
  final Map<String, Map<String, dynamic>> _picked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await BatchTracking.trackedProducts(widget.components.keys.toList());
    for (final pid in t.keys) {
      final l = await BatchTracking.openBatches(widget.orgId, pid, branchId: widget.branchId);
      _oldest[pid] = l.isEmpty ? null : l.first;
    }
    if (mounted) setState(() { _tracked = t; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 6),
          child: LinearProgressIndicator(minHeight: 2));
    }
    if (_tracked.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.04),
          borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.primary.withOpacity(0.2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.qr_code_2_outlined, size: 15, color: AppTheme.primary),
          SizedBox(width: 6),
          Text('Component batches', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 2),
        const Text('Oldest batch is used first. Tap Change to use another.',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        for (final pid in _tracked.keys) _row(pid),
      ]),
    );
  }

  Widget _row(String pid) {
    final name = widget.components[pid] ?? '${_tracked[pid]?['name'] ?? ''}';
    final picked = _picked[pid];
    final oldest = _oldest[pid];
    final b = picked ?? oldest;
    final label = b == null
        ? 'No batch on record — taken from older stock'
        : '${b['batch_no']}  ·  ${BatchTracking.qty(BatchTracking.remaining(b))} left${picked == null ? '  (oldest)' : ''}';
    return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
        Text(label, style: TextStyle(fontSize: 11, color: picked != null ? AppTheme.primary : AppTheme.textSecondary)),
      ])),
      if (picked != null)
        IconButton(tooltip: 'Back to oldest first', visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 16),
          onPressed: () => setState(() { _picked.remove(pid); widget.picks.remove(pid); })),
      if (oldest != null)
        TextButton(
          onPressed: () async {
            final r = await BatchTracking.pickBatch(context, orgId: widget.orgId, productId: pid,
                productName: name, branchId: widget.branchId);
            if (r != null && mounted) setState(() { _picked[pid] = r; widget.picks[pid] = r['id'] as String; });
          },
          child: const Text('Change', style: TextStyle(fontSize: 12))),
    ]));
  }
}

/// Serial scan at dispatch (Delivery Order, POS) — Admin Settings → Batch &
/// warranty tracking → "Scan serials at dispatch": off | optional | mandatory.
class DispatchSerials {
  static SupabaseClient get _db => Supabase.instance.client;

  /// 'off' | 'optional' | 'mandatory'. Off whenever batch tracking is off.
  static Future<String> mode(String? orgId) async {
    if (!await BatchTracking.isOn(orgId)) return 'off';
    try {
      final r = await _db.from('app_config').select('value')
          .eq('org_id', orgId!).eq('key', 'org.bt_dispatch_scan').limit(1).maybeSingle();
      final v = '${r?['value'] ?? ''}';
      return const ['off', 'optional', 'mandatory'].contains(v) ? v : 'optional';
    } catch (_) {
      return 'optional';
    }
  }

  /// Scan dialog. [lines]: product id → (name, qty). Only Serial products are
  /// asked for. Returns product id → serials, {} when nothing to scan / skipped,
  /// or null when the user cancelled (stop the save).
  /// For a return, pass [returnFromDocId]: serials must have been sold on it.
  static Future<Map<String, List<String>>?> scan(BuildContext context, {
    required String orgId,
    required Map<String, (String, double)> lines,
    required String mode,
    String title = 'Scan serial numbers',
    String? returnFromDocId,
  }) async {
    if (mode == 'off' || lines.isEmpty) return {};
    final tracked = await BatchTracking.trackedProducts(lines.keys.toList());
    final serialLines = <String, (String, int)>{
      for (final e in lines.entries)
        if (tracked[e.key]?['batch_tracking'] == 'serial' && e.value.$2 >= 1) e.key: (e.value.$1, e.value.$2.floor()),
    };
    if (serialLines.isEmpty || !context.mounted) return {};
    final picked = <String, List<String>>{for (final k in serialLines.keys) k: <String>[]};
    final ctrl = TextEditingController();
    final focus = FocusNode();
    String? msg;
    bool busy = false;
    final isReturn = returnFromDocId != null;
    final mandatory = mode == 'mandatory' && !isReturn;

    Future<void> add(String raw, void Function(void Function()) setS) async {
      final code = raw.trim();
      if (code.isEmpty) return;
      setS(() { busy = true; msg = null; });
      try {
        var rows = List<Map<String, dynamic>>.from(await _db.from('product_serials')
            .select('serial, product_id, status, sold_doc_id')
            .eq('org_id', orgId).ilike('serial', code).limit(1) as List);
        if (rows.isEmpty) {
          final ct = await _db.from('product_cartons').select('id').eq('org_id', orgId).ilike('carton_no', code).limit(1).maybeSingle();
          if (ct != null) {
            rows = List<Map<String, dynamic>>.from(await _db.from('product_serials')
                .select('serial, product_id, status, sold_doc_id').eq('carton_id', ct['id']).order('serial') as List);
          }
        }
        if (rows.isEmpty) { msg = '$code was not found.'; return; }
        int added = 0; final skipped = <String>[];
        for (final r in rows) {
          final pid = '${r['product_id']}';
          final s = '${r['serial']}';
          final line = serialLines[pid];
          if (line == null) { skipped.add('$s is not on this ${isReturn ? 'return' : 'order'}'); continue; }
          if (isReturn ? (r['status'] != 'dispatched' || r['sold_doc_id'] != returnFromDocId) : r['status'] != 'in_stock') {
            skipped.add(isReturn ? '$s was not sold on this receipt' : '$s is not in stock'); continue;
          }
          final list = picked[pid]!;
          if (list.any((x) => x.toUpperCase() == s.toUpperCase())) { skipped.add('$s already scanned'); continue; }
          if (list.length >= line.$2) { skipped.add('${line.$1}: all ${line.$2} already scanned'); continue; }
          list.add(s); added++;
        }
        if (skipped.isNotEmpty) msg = skipped.length > 3 ? '${skipped.take(3).join(' · ')} …' : skipped.join(' · ');
        if (added > 1 && skipped.isEmpty) msg = 'Carton: $added units added';
      } catch (_) {
        msg = 'Could not check that code. Please try again.';
      } finally {
        ctrl.clear();
        setS(() => busy = false);
        focus.requestFocus();
      }
    }

    final res = await showDialog<Map<String, List<String>>>(context: context, barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final total = serialLines.values.fold<int>(0, (s, l) => s + l.$2);
      final done = picked.values.fold<int>(0, (s, l) => s + l.length);
      final complete = serialLines.entries.every((e) => picked[e.key]!.length >= e.value.$2);
      return AlertDialog(
        title: Text(title),
        content: SizedBox(width: 520, child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isReturn
              ? 'Scan the units coming back so they return to stock. You can skip this.'
              : mandatory
                  ? 'Scan every unit (or a carton label) before saving.'
                  : 'Scan the units (or a carton label) going out. You can skip this.',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(controller: ctrl, focusNode: focus, autofocus: true, enabled: !busy,
              textInputAction: TextInputAction.done,
              onSubmitted: (v) => add(v, setS),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.qr_code_scanner, size: 18), hintText: 'Scan or type a serial or carton number'))),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: busy ? null : () => add(ctrl.text, setS), child: const Text('Add')),
          ]),
          if (msg != null) Padding(padding: const EdgeInsets.only(top: 6),
              child: Text(msg!, style: TextStyle(fontSize: 11.5,
                  color: msg!.startsWith('Carton:') ? AppTheme.success : AppTheme.danger))),
          const SizedBox(height: 12),
          Text('$done of $total scanned', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final e in serialLines.entries) Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(
                color: picked[e.key]!.length >= e.value.$2 ? AppTheme.success.withOpacity(0.5) : AppTheme.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(e.value.$1, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
                Text('${picked[e.key]!.length} / ${e.value.$2}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: picked[e.key]!.length >= e.value.$2 ? AppTheme.success : AppTheme.textSecondary)),
              ]),
              if (picked[e.key]!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 5, runSpacing: 5, children: [
                  for (final s in picked[e.key]!) InputChip(visualDensity: VisualDensity.compact,
                      label: Text(s, style: const TextStyle(fontSize: 11)),
                      onDeleted: () => setS(() => picked[e.key]!.remove(s))),
                ]),
              ],
            ]),
          ),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (!mandatory) TextButton(onPressed: () => Navigator.pop(ctx, <String, List<String>>{}), child: const Text('Skip')),
          ElevatedButton(
            onPressed: (mandatory && !complete) || busy ? null : () => Navigator.pop(ctx, picked),
            child: Text(mandatory && !complete ? '${total - done} left' : 'Continue')),
        ],
      );
    }));
    // Not disposed here: the dialog may still be animating out.
    return res;
  }

  static List<String> flat(Map<String, List<String>>? m) =>
      [for (final l in (m ?? const <String, List<String>>{}).values) ...l];

  /// Records the sale on the serials. Returns the count, or null on failure.
  static Future<int?> markSold({
    required String orgId,
    required String docType, // 'do' | 'pos'
    required String docId,
    required String docNumber,
    String? customerId,
    String? customerName,
    DateTime? date,
    required List<String> serials,
  }) async {
    if (serials.isEmpty) return 0;
    try {
      final r = await _db.rpc('bt_dispatch_serials', params: {
        'p_org': orgId, 'p_doc_type': docType, 'p_doc_id': docId, 'p_doc_number': docNumber,
        'p_customer': customerId, 'p_customer_name': customerName,
        'p_date': DateFormat('yyyy-MM-dd').format(date ?? DateTime.now()),
        'p_serials': serials,
      });
      return (r as num?)?.toInt() ?? 0;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> markReturned({required String orgId, String? docId, required List<String> serials}) async {
    if (serials.isEmpty) return 0;
    try {
      final r = await _db.rpc('bt_return_serials', params: {'p_org': orgId, 'p_doc_id': docId, 'p_serials': serials});
      return (r as num?)?.toInt() ?? 0;
    } catch (_) {
      return null;
    }
  }

  /// Serials sold on one document.
  static Future<List<Map<String, dynamic>>> soldOn(String docType, String docId) async {
    try {
      final r = await _db.from('product_serials').select('serial, product_id')
          .eq('sold_doc_type', docType).eq('sold_doc_id', docId).order('serial');
      return List<Map<String, dynamic>>.from(r as List);
    } catch (_) {
      return [];
    }
  }
}
