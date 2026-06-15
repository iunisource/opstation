import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Promoter management — CRUD for sales promoters plus their commission floors.
/// Floors resolve product -> sub_group -> group -> main_group (most specific wins),
/// keyed by the taxonomy NAME stored on products. `effective_floor` is what the
/// commission compute reads; it is derived here from floor_price/discount/tax.
class ErpPromotersScreen extends ConsumerStatefulWidget {
  const ErpPromotersScreen({super.key});
  @override
  ConsumerState<ErpPromotersScreen> createState() => _ErpPromotersScreenState();
}

class _ErpPromotersScreenState extends ConsumerState<ErpPromotersScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _promoters = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _productFloors = [];
  List<Map<String, dynamic>> _categoryFloors = [];
  Map<String, dynamic>? _selected;
  String _search = '';

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── Data ────────────────────────────────────────────────────────────────
  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final res = await Future.wait([
        client.from('sales_promoters').select('*').eq('org_id', orgId).order('name'),
        client
            .from('products')
            .select('id, name, selling_price, product_main_group, product_group, product_sub_group')
            .eq('org_id', orgId)
            .order('name'),
      ]);
      final proms = List<Map<String, dynamic>>.from(res[0] as List);
      setState(() {
        _promoters = proms;
        _products = List<Map<String, dynamic>>.from(res[1] as List);
        if (_selected != null) {
          final id = _selected!['id'];
          final match = proms.where((p) => p['id'] == id).toList();
          _selected = match.isEmpty ? null : match.first;
        }
        _loading = false;
      });
      if (_selected != null) await _loadFloors();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Load error: $e');
      }
    }
  }

  Future<void> _loadFloors() async {
    final p = _selected;
    final orgId = _orgId;
    if (p == null || orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final res = await Future.wait([
        client
            .from('promoter_product_prices')
            .select('*')
            .eq('org_id', orgId)
            .eq('promoter_id', p['id'])
            .order('created_at'),
        client
            .from('promoter_category_prices')
            .select('*')
            .eq('org_id', orgId)
            .eq('promoter_id', p['id'])
            .order('created_at'),
      ]);
      if (!mounted) return;
      setState(() {
        _productFloors = List<Map<String, dynamic>>.from(res[0] as List);
        _categoryFloors = List<Map<String, dynamic>>.from(res[1] as List);
      });
    } catch (e) {
      _snack('Floor load error: $e');
    }
  }

  /// Re-evaluate commissions after a floor change so the GL stays in sync.
  /// Versioned by effective_from, so only sales on/after that date are affected.
  Future<void> _recompute() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      await Supabase.instance.client.rpc('fn_mature_promoter_commission', params: {'p_org_id': orgId});
    } catch (_) {}
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  double _eff(double base, double disc, double tax) =>
      double.parse((base * (1 - disc / 100) * (1 + tax / 100)).toStringAsFixed(2));

  String _productName(String? id) {
    final m = _products.where((p) => p['id'] == id).toList();
    return m.isEmpty ? (id ?? '-') : (m.first['name'] as String? ?? id ?? '-');
  }

  List<String> _taxonomyOptions(String level) {
    final col = level == 'main_group'
        ? 'product_main_group'
        : level == 'sub_group'
            ? 'product_sub_group'
            : 'product_group';
    final set = <String>{};
    for (final p in _products) {
      final v = p[col] as String?;
      if (v != null && v.trim().isNotEmpty) set.add(v);
    }
    final list = set.toList()..sort();
    return list;
  }

  // ── Promoter CRUD ─────────────────────────────────────────────────────────
  Future<void> _editPromoter([Map<String, dynamic>? existing]) async {
    final nameCtrl = TextEditingController(text: existing?['name'] as String? ?? '');
    final phoneCtrl = TextEditingController(text: existing?['phone'] as String? ?? '');
    bool active = (existing?['is_active'] as bool?) ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Add Promoter' : 'Edit Promoter'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name *', hintText: 'Promoter name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone', hintText: 'Optional'),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Active'),
                value: active,
                onChanged: (v) => setLocal(() => active = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(existing == null ? 'Add' : 'Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack('Name is required');
      return;
    }
    final orgId = _orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    final phone = phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim();
    try {
      if (existing == null) {
        final id = 'promo_${DateTime.now().millisecondsSinceEpoch}';
        await client.from('sales_promoters').insert({
          'id': id,
          'org_id': orgId,
          'name': name,
          'phone': phone,
          'is_active': active,
        });
        await _load();
        final m = _promoters.where((p) => p['id'] == id).toList();
        setState(() => _selected = m.isEmpty ? null : m.first);
        if (_selected != null) await _loadFloors();
      } else {
        await client.from('sales_promoters').update({
          'name': name,
          'phone': phone,
          'is_active': active,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', existing['id']);
        await _load();
      }
      _snack(existing == null ? 'Promoter added' : 'Promoter updated');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  // ── Floor dialogs ──────────────────────────────────────────────────────────
  Future<void> _editProductFloor([Map<String, dynamic>? existing]) async {
    final p = _selected;
    if (p == null) return;
    String? productId = existing?['product_id'] as String?;
    final baseCtrl =
        TextEditingController(text: ((existing?['floor_price'] as num?)?.toDouble() ?? 0).toString());
    final discCtrl =
        TextEditingController(text: ((existing?['discount_pct'] as num?)?.toDouble() ?? 0).toString());
    final taxCtrl =
        TextEditingController(text: ((existing?['tax_pct'] as num?)?.toDouble() ?? 0).toString());
    bool active = (existing?['is_active'] as bool?) ?? true;
    DateTime effFrom = existing?['effective_from'] != null
        ? DateTime.parse(existing!['effective_from'] as String)
        : DateTime.now();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setLocal) {
        final base = double.tryParse(baseCtrl.text.trim()) ?? 0;
        final disc = double.tryParse(discCtrl.text.trim()) ?? 0;
        final tax = double.tryParse(taxCtrl.text.trim()) ?? 0;
        final eff = _eff(base, disc, tax);
        return AlertDialog(
          title: Text(existing == null ? 'Add Product Floor' : 'Edit Product Floor'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                DropdownMenu<String>(
                  expandedInsets: EdgeInsets.zero,
                  enableFilter: true,
                  requestFocusOnTap: true,
                  menuHeight: 320,
                  initialSelection: productId,
                  label: const Text('Product *'),
                  hintText: 'Type to search…',
                  dropdownMenuEntries: _products
                      .map((pr) => DropdownMenuEntry<String>(
                            value: pr['id'] as String,
                            label: pr['name'] as String? ?? '-',
                          ))
                      .toList(),
                  onSelected: (v) => setLocal(() {
                    productId = v;
                    // default the floor price to the product's selling price
                    final m = _products.where((p) => p['id'] == v).toList();
                    final sp = m.isEmpty ? 0.0 : ((m.first['selling_price'] as num?)?.toDouble() ?? 0.0);
                    if (v != null) baseCtrl.text = sp == sp.roundToDouble() ? sp.toStringAsFixed(0) : sp.toStringAsFixed(2);
                  }),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: TextField(
                    controller: baseCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(labelText: 'Floor price *', helperText: 'Defaults to selling price'),
                    onChanged: (_) => setLocal(() {}),
                  )),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                    controller: discCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(labelText: 'Discount %'),
                    onChanged: (_) => setLocal(() {}),
                  )),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                    controller: taxCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(labelText: 'Tax %'),
                    onChanged: (_) => setLocal(() {}),
                  )),
                ]),
                const SizedBox(height: 10),
                _effRow(eff),
                const SizedBox(height: 6),
                _effFromRow(effFrom, (d) => setLocal(() => effFrom = d)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Active'),
                  value: active,
                  onChanged: (v) => setLocal(() => active = v),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(existing == null ? 'Add' : 'Save')),
          ],
        );
      }),
    );
    if (ok != true) return;
    if (productId == null) {
      _snack('Select a product');
      return;
    }
    final orgId = _orgId;
    if (orgId == null) return;
    final base = double.tryParse(baseCtrl.text.trim()) ?? 0;
    final disc = double.tryParse(discCtrl.text.trim()) ?? 0;
    final tax = double.tryParse(taxCtrl.text.trim()) ?? 0;
    final row = {
      'org_id': orgId,
      'promoter_id': p['id'],
      'product_id': productId,
      'floor_price': base,
      'discount_pct': disc,
      'tax_pct': tax,
      'effective_floor': _eff(base, disc, tax),
      'effective_from': DateFormat('yyyy-MM-dd').format(effFrom),
      'is_active': active,
    };
    final client = Supabase.instance.client;
    try {
      if (existing == null) {
        await client.from('promoter_product_prices').insert(row);
      } else {
        await client.from('promoter_product_prices').update(row).eq('id', existing['id']);
      }
      await _loadFloors();
      await _recompute();
      _snack('Product floor saved');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  Future<void> _editCategoryFloor([Map<String, dynamic>? existing]) async {
    final p = _selected;
    if (p == null) return;
    String level = (existing?['taxonomy_level'] as String?) ?? 'group';
    String? category = existing?['category_id'] as String?;
    final baseCtrl =
        TextEditingController(text: ((existing?['floor_price'] as num?)?.toDouble() ?? 0).toString());
    final discCtrl =
        TextEditingController(text: ((existing?['discount_pct'] as num?)?.toDouble() ?? 0).toString());
    final taxCtrl =
        TextEditingController(text: ((existing?['tax_pct'] as num?)?.toDouble() ?? 0).toString());
    bool active = (existing?['is_active'] as bool?) ?? true;
    DateTime effFrom = existing?['effective_from'] != null
        ? DateTime.parse(existing!['effective_from'] as String)
        : DateTime.now();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setLocal) {
        final opts = _taxonomyOptions(level);
        if (category != null && !opts.contains(category)) category = null;
        final base = double.tryParse(baseCtrl.text.trim()) ?? 0;
        final disc = double.tryParse(discCtrl.text.trim()) ?? 0;
        final tax = double.tryParse(taxCtrl.text.trim()) ?? 0;
        final eff = _eff(base, disc, tax);
        return AlertDialog(
          title: Text(existing == null ? 'Add Category Floor' : 'Edit Category Floor'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                DropdownButtonFormField<String>(
                  value: level,
                  decoration: const InputDecoration(labelText: 'Taxonomy level *'),
                  items: const [
                    DropdownMenuItem(value: 'main_group', child: Text('Main group', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'group', child: Text('Group', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'sub_group', child: Text('Sub group', style: TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) => setLocal(() {
                    level = v ?? 'group';
                    category = null;
                  }),
                ),
                const SizedBox(height: 8),
                DropdownMenu<String>(
                  key: ValueKey(level),
                  expandedInsets: EdgeInsets.zero,
                  enableFilter: true,
                  requestFocusOnTap: true,
                  menuHeight: 320,
                  initialSelection: category,
                  label: const Text('Category *'),
                  hintText: 'Type to search…',
                  dropdownMenuEntries:
                      opts.map((c) => DropdownMenuEntry<String>(value: c, label: c)).toList(),
                  onSelected: (v) => setLocal(() => category = v),
                ),
                if (opts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('No values found at this level on any product.',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: TextField(
                    controller: discCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(labelText: 'Discount %', helperText: 'Optional'),
                    onChanged: (_) => setLocal(() {}),
                  )),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                    controller: taxCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(labelText: 'Tax %', helperText: 'Optional'),
                    onChanged: (_) => setLocal(() {}),
                  )),
                ]),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.primary.withOpacity(0.25))),
                  child: Text(
                    'Floor = each product\u2019s selling price'
                        '${disc != 0 ? ' \u2212 ${disc.toStringAsFixed(disc == disc.roundToDouble() ? 0 : 2)}%' : ''}'
                        '${tax != 0 ? ' + ${tax.toStringAsFixed(tax == tax.roundToDouble() ? 0 : 2)}% tax' : ''}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 6),
                _effFromRow(effFrom, (d) => setLocal(() => effFrom = d)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Active'),
                  value: active,
                  onChanged: (v) => setLocal(() => active = v),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(existing == null ? 'Add' : 'Save')),
          ],
        );
      }),
    );
    if (ok != true) return;
    if (category == null || category!.isEmpty) {
      _snack('Select a category');
      return;
    }
    final orgId = _orgId;
    if (orgId == null) return;
    final base = double.tryParse(baseCtrl.text.trim()) ?? 0;
    final disc = double.tryParse(discCtrl.text.trim()) ?? 0;
    final tax = double.tryParse(taxCtrl.text.trim()) ?? 0;
    final row = {
      'org_id': orgId,
      'promoter_id': p['id'],
      'taxonomy_level': level,
      'category_id': category,
      'floor_price': 0,
      'discount_pct': disc,
      'tax_pct': tax,
      'effective_floor': 0,
      'effective_from': DateFormat('yyyy-MM-dd').format(effFrom),
      'is_active': active,
    };
    final client = Supabase.instance.client;
    try {
      if (existing == null) {
        await client.from('promoter_category_prices').insert(row);
      } else {
        await client.from('promoter_category_prices').update(row).eq('id', existing['id']);
      }
      await _loadFloors();
      await _recompute();
      _snack('Category floor saved');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  Future<void> _deleteFloor(String table, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete floor?'),
        content: const Text('This removes the floor and re-evaluates commissions.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client.from(table).delete().eq('id', id);
      await _loadFloors();
      await _recompute();
      _snack('Floor deleted');
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  // ── Small shared widgets ────────────────────────────────────────────────
  Widget _effRow(double eff) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: AppTheme.primary.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.primary.withOpacity(0.25))),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Effective floor (used for commission)',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          Text('Rs. ${eff.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primary)),
        ]),
      );

  Widget _effFromRow(DateTime d, ValueChanged<DateTime> onPick) => Row(children: [
        const Text('Effective from', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const Spacer(),
        TextButton.icon(
          icon: const Icon(Icons.calendar_today, size: 14),
          label: Text(DateFormat('dd MMM yyyy').format(d), style: const TextStyle(fontSize: 13)),
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: d,
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (picked != null) onPick(picked);
          },
        ),
      ]);

  // ── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final q = _search.toLowerCase();
    final filtered = q.isEmpty
        ? _promoters
        : _promoters
            .where((p) =>
                (p['name'] as String? ?? '').toLowerCase().contains(q) ||
                (p['phone'] as String? ?? '').toLowerCase().contains(q))
            .toList();

    return Container(
      color: AppTheme.background,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(children: [
            const Text('Promoters',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('Commission floors by product & category',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const Spacer(),
            ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Promoter'),
              onPressed: () => _editPromoter(),
            ),
          ]),
        ),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Left: promoter list
            Container(
              width: 340,
              decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(right: BorderSide(color: AppTheme.border))),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    decoration: const InputDecoration(
                        hintText: 'Search promoters…',
                        prefixIcon: Icon(Icons.search, size: 18),
                        isDense: true),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text('No promoters yet',
                              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final p = filtered[i];
                            final active = (p['is_active'] as bool?) ?? true;
                            final sel = _selected != null && _selected!['id'] == p['id'];
                            return ListTile(
                              dense: true,
                              selected: sel,
                              selectedTileColor: AppTheme.primary.withOpacity(0.06),
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor:
                                    active ? AppTheme.primary.withOpacity(0.12) : Colors.grey.shade200,
                                child: Icon(Icons.badge_outlined,
                                    size: 16, color: active ? AppTheme.primary : Colors.grey),
                              ),
                              title: Text(p['name'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              subtitle: Text(p['phone'] as String? ?? '—',
                                  style: const TextStyle(fontSize: 11)),
                              trailing: active
                                  ? null
                                  : const Text('Inactive',
                                      style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.w700)),
                              onTap: () {
                                setState(() => _selected = p);
                                _loadFloors();
                              },
                            );
                          },
                        ),
                ),
              ]),
            ),
            // Right: detail
            Expanded(child: _selected == null ? _emptyDetail() : _detail()),
          ]),
        ),
      ]),
    );
  }

  Widget _emptyDetail() => const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.badge_outlined, size: 40, color: AppTheme.textSecondary),
          SizedBox(height: 10),
          Text('Select a promoter to manage floors',
              style: TextStyle(color: AppTheme.textSecondary)),
        ]),
      );

  Widget _detail() {
    final p = _selected!;
    final active = (p['is_active'] as bool?) ?? true;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(p['name'] as String? ?? '-',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
                color: (active ? AppTheme.success : Colors.orange).withOpacity(0.12),
                borderRadius: BorderRadius.circular(4)),
            child: Text(active ? 'Active' : 'Inactive',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: active ? AppTheme.success : Colors.orange)),
          ),
          const Spacer(),
          TextButton.icon(
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('Edit'),
              onPressed: () => _editPromoter(p)),
        ]),
        if ((p['phone'] as String?)?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(p['phone'] as String,
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ),
        const SizedBox(height: 20),
        _floorSection(
          title: 'Product floors',
          subtitle: 'Most specific — overrides category floors for that product.',
          onAdd: () => _editProductFloor(),
          rows: _productFloors.map((f) {
            return _floorTile(
              target: _productName(f['product_id'] as String?),
              tag: 'PRODUCT',
              tagColor: AppTheme.primary,
              floorPrice: (f['floor_price'] as num?)?.toDouble() ?? 0,
              eff: (f['effective_floor'] as num?)?.toDouble() ?? 0,
              disc: (f['discount_pct'] as num?)?.toDouble() ?? 0,
              tax: (f['tax_pct'] as num?)?.toDouble() ?? 0,
              effFrom: f['effective_from'] as String?,
              active: (f['is_active'] as bool?) ?? true,
              onEdit: () => _editProductFloor(f),
              onDelete: () => _deleteFloor('promoter_product_prices', f['id'] as String),
            );
          }).toList(),
        ),
        const SizedBox(height: 24),
        _floorSection(
          title: 'Category floors',
          subtitle: 'Resolve sub_group → group → main_group when no product floor exists.',
          onAdd: () => _editCategoryFloor(),
          rows: _categoryFloors.map((f) {
            final lvl = (f['taxonomy_level'] as String? ?? 'group').replaceAll('_', ' ');
            return _floorTile(
              target: '${f['category_id'] ?? '-'}',
              tag: lvl.toUpperCase(),
              tagColor: Colors.purple,
              isCategory: true,
              floorPrice: (f['floor_price'] as num?)?.toDouble() ?? 0,
              eff: (f['effective_floor'] as num?)?.toDouble() ?? 0,
              disc: (f['discount_pct'] as num?)?.toDouble() ?? 0,
              tax: (f['tax_pct'] as num?)?.toDouble() ?? 0,
              effFrom: f['effective_from'] as String?,
              active: (f['is_active'] as bool?) ?? true,
              onEdit: () => _editCategoryFloor(f),
              onDelete: () => _deleteFloor('promoter_category_prices', f['id'] as String),
            );
          }).toList(),
        ),
      ]),
    );
  }

  Widget _floorSection({
    required String title,
    required String subtitle,
    required VoidCallback onAdd,
    required List<Widget> rows,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const Spacer(),
        OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add'),
            onPressed: onAdd),
      ]),
      Text(subtitle, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      const SizedBox(height: 8),
      if (rows.isEmpty)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.border)),
          child: const Text('No floors configured', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        )
      else
        ...rows,
    ]);
  }

  Widget _floorTile({
    required String target,
    required String tag,
    required Color tagColor,
    bool isCategory = false,
    required double floorPrice,
    required double eff,
    required double disc,
    required double tax,
    required String? effFrom,
    required bool active,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    String pct(double v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
    final tail = '${effFrom != null ? '  ·  from $effFrom' : ''}${active ? '' : '  ·  inactive'}';
    final valueText = isCategory
        ? 'Each product price'
            '${disc != 0 ? ' \u2212 ${pct(disc)}%' : ''}'
            '${tax != 0 ? ' + ${pct(tax)}% tax' : ''}$tail'
        : 'Floor Rs. ${eff.toStringAsFixed(2)}'
            '${(disc != 0 || tax != 0) ? '  (base ${floorPrice.toStringAsFixed(2)}${disc != 0 ? ', -${pct(disc)}%' : ''}${tax != 0 ? ', +${pct(tax)}% tax' : ''})' : ''}$tail';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.border)),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: tagColor.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
          child: Text(tag, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: tagColor)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(target,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: active ? null : AppTheme.textSecondary),
                overflow: TextOverflow.ellipsis),
            Text(
                valueText,
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ),
        IconButton(icon: const Icon(Icons.edit, size: 16), onPressed: onEdit, tooltip: 'Edit'),
        IconButton(
            icon: Icon(Icons.delete_outline, size: 16, color: Colors.red.shade400),
            onPressed: onDelete,
            tooltip: 'Delete'),
      ]),
    );
  }
}
