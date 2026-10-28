import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';

/// One line on an order being edited.
class EditOrderLine {
  final String productId;
  final String name;
  final String sku;
  final String? uomId;
  final double price;
  double qty;
  EditOrderLine({
    required this.productId,
    required this.name,
    required this.sku,
    required this.uomId,
    required this.price,
    required this.qty,
  });
}

/// Plain-English message for a failed order action.
String fieldOrderErrorText(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('socket') ||
      s.contains('network') ||
      s.contains('connection') ||
      s.contains('timed out') ||
      s.contains('failed host lookup')) {
    return 'No internet connection. Please try again when you are online.';
  }
  if (e is PostgrestException) {
    final m = e.message;
    if (m.toLowerCase().contains('could not find the function') ||
        m.toLowerCase().contains('does not exist')) {
      return 'This option is not available yet. Please ask the office to update the system.';
    }
    if (m.isNotEmpty && !m.contains('_') && m.length < 160) return m;
  }
  return 'Something went wrong. Please try again.';
}

/// Change the products / quantities / note of an order that the office has
/// not reviewed yet. Saves through the `update_field_order` server function,
/// which refuses if the order was approved, rejected or cancelled meanwhile.
class FieldOrderEditScreen extends ConsumerStatefulWidget {
  final String orderId;
  final String customerName;
  final String? notes;
  final List<EditOrderLine> lines;
  const FieldOrderEditScreen({
    super.key,
    required this.orderId,
    required this.customerName,
    required this.notes,
    required this.lines,
  });

  @override
  ConsumerState<FieldOrderEditScreen> createState() =>
      _FieldOrderEditScreenState();
}

class _FieldOrderEditScreenState extends ConsumerState<FieldOrderEditScreen> {
  late final List<EditOrderLine> _lines;
  final Map<String, TextEditingController> _qtyCtrls = {};
  late final TextEditingController _notesCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _lines = [
      for (final l in widget.lines)
        EditOrderLine(
            productId: l.productId,
            name: l.name,
            sku: l.sku,
            uomId: l.uomId,
            price: l.price,
            qty: l.qty)
    ];
    for (final l in _lines) {
      _qtyCtrls[l.productId] = TextEditingController(text: _qtyText(l.qty));
    }
    _notesCtrl = TextEditingController(text: widget.notes ?? '');
  }

  @override
  void dispose() {
    for (final c in _qtyCtrls.values) {
      c.dispose();
    }
    _notesCtrl.dispose();
    super.dispose();
  }

  String _qtyText(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  double get _total =>
      _lines.fold(0.0, (s, l) => s + (l.qty > 0 ? l.qty * l.price : 0));

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  void _setQty(EditOrderLine l, double v) {
    if (v < 0) v = 0;
    setState(() => l.qty = v);
    final c = _qtyCtrls[l.productId];
    if (c != null && c.text != _qtyText(v)) {
      c.text = _qtyText(v);
      c.selection = TextSelection.collapsed(offset: c.text.length);
    }
  }

  void _remove(EditOrderLine l) {
    setState(() => _lines.remove(l));
    _qtyCtrls.remove(l.productId)?.dispose();
  }

  Future<void> _addProduct() async {
    final picked = await showModalBottomSheet<CatalogProductRow>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const CatalogProductPickerSheet(),
    );
    if (picked == null || !mounted) return;
    final existing = _lines.where((l) => l.productId == picked.id);
    if (existing.isNotEmpty) {
      _snack('${picked.name} is already on this order — change its quantity instead.');
      return;
    }
    final line = EditOrderLine(
      productId: picked.id,
      name: picked.name,
      sku: picked.sku ?? '',
      uomId: picked.baseUomId,
      price: picked.sellingPrice,
      qty: 1,
    );
    setState(() => _lines.add(line));
    _qtyCtrls[line.productId] = TextEditingController(text: '1');
  }

  Future<void> _save() async {
    final valid = _lines.where((l) => l.qty > 0).toList();
    if (valid.isEmpty) {
      _snack('Add at least one product with a quantity.');
      return;
    }
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('update_field_order', params: {
        'p_id': widget.orderId,
        'p_items': [
          for (final l in valid)
            {
              'product_id': l.productId,
              'uom_id': l.uomId,
              'quantity': l.qty,
              'price': l.price,
            }
        ],
        'p_notes': _notesCtrl.text.trim(),
      });
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(fieldOrderErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Change order'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimaryLight,
        elevation: 0.5,
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.customerName,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('You can change this order until the office approves it.',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondaryLight)),
          ]),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              if (_lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('No products. Tap "Add product".',
                        style: TextStyle(color: AppColors.textSecondaryLight)),
                  ),
                ),
              for (final l in _lines) _lineCard(l),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _saving ? null : _addProduct,
                icon: const Icon(Icons.add),
                label: const Text('Add product'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _notesCtrl,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(
              16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: AppColors.borderLight)),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondaryLight)),
                    Text('Rs. ${_money(_total)}',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                  ]),
            ),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save changes'),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _lineCard(EditOrderLine l) {
    final ctrl = _qtyCtrls[l.productId]!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.name,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            if (l.sku.isNotEmpty)
              Text(l.sku,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textSecondaryLight)),
            Text('Rs. ${_money(l.price)} each',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondaryLight)),
          ]),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: _saving || l.qty <= 1 ? null : () => _setQty(l, l.qty - 1),
        ),
        SizedBox(
          width: 56,
          child: TextField(
            controller: ctrl,
            enabled: !_saving,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) =>
                setState(() => l.qty = double.tryParse(v.trim()) ?? 0),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline),
          onPressed: _saving ? null : () => _setQty(l, l.qty + 1),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Remove',
          icon: const Icon(Icons.delete_outline, color: AppColors.danger),
          onPressed: _saving ? null : () => _remove(l),
        ),
      ]),
    );
  }

  String _money(double v) {
    final parts = v.abs().toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '${v < 0 ? '-' : ''}$buf.${parts[1]}';
  }
}

/// Search the product catalog saved on the phone.
class CatalogProductPickerSheet extends ConsumerStatefulWidget {
  const CatalogProductPickerSheet({super.key});
  @override
  ConsumerState<CatalogProductPickerSheet> createState() =>
      CatalogProductPickerSheetState();
}

class CatalogProductPickerSheetState extends ConsumerState<CatalogProductPickerSheet> {
  List<CatalogProductRow> _all = [];
  String _q = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    try {
      final db = ref.read(appDatabaseProvider);
      final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
      final q = db.select(db.catalogProducts)
        ..where((p) => p.isActive.equals(true))
        ..orderBy([(p) => OrderingTerm(expression: p.name)]);
      if (orgId != null) q.where((p) => p.orgId.equals(orgId));
      final rows = await q.get();
      if (!mounted) return;
      setState(() {
        _all = rows;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ql = _q.trim().toLowerCase();
    final list = ql.isEmpty
        ? _all
        : _all
            .where((p) =>
                p.name.toLowerCase().contains(ql) ||
                (p.sku ?? '').toLowerCase().contains(ql) ||
                (p.productSubGroup ?? '').toLowerCase().contains(ql))
            .toList();
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(children: [
              const Expanded(
                child: Text('Add product',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search name, code or brand',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                    ? Center(
                        child: Text('No products found.',
                            style: TextStyle(
                                color: AppColors.textSecondaryLight)))
                    : ListView.separated(
                        itemCount: list.length > 200 ? 200 : list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final p = list[i];
                          final sub = [
                            if ((p.productSubGroup ?? '').isNotEmpty)
                              p.productSubGroup!,
                            if ((p.sku ?? '').isNotEmpty) p.sku!,
                          ].join(' · ');
                          return ListTile(
                            title: Text(p.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: sub.isEmpty ? null : Text(sub),
                            trailing: Text(
                                'Rs. ${p.sellingPrice.toStringAsFixed(0)}'),
                            onTap: () => Navigator.pop(context, p),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}
