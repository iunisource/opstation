import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../auth/auth_controller.dart';
import '../intelligence/services/autopilot.dart';
import 'product_line_rules.dart';
import 'product_line_widgets.dart';
import 'product_lines_repo.dart';

/// Product Lines: group the placement-audit SKUs (Lights, PVC, ...) and decide, by customer group, which
/// shops carry which line. Single shops can be set on the customer itself.
class ProductLinesScreen extends ConsumerStatefulWidget {
  const ProductLinesScreen({super.key});

  @override
  ConsumerState<ProductLinesScreen> createState() => _ProductLinesScreenState();
}

class _ProductLinesScreenState extends ConsumerState<ProductLinesScreen> {
  LineRules _rules = LineRules.empty;
  Map<String, int> _counts = {};
  bool _loading = true;
  String? _error;

  // Auto Pilot check
  List<SalesOutsideLine>? _outside;
  Map<String, String> _shopNames = {};
  bool _checking = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  bool _canEdit(WebUserRole? role) => role == WebUserRole.masterAdmin || role == WebUserRole.admin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rules = await ProductLinesRepo.loadForPage(orgId);
      final counts = await ProductLinesRepo.skuCounts(orgId);
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _counts = counts;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _error = (s.contains('product_lines') || s.contains('42P01') || s.contains('line_id'))
            ? 'Product lines are not set up in the database yet. Run product_lines.sql in Supabase, then reload this page.'
            : 'Could not load product lines: ${s.split('\n').first}';
        _loading = false;
      });
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('23505') || s.toLowerCase().contains('duplicate')) return 'A line with this name already exists.';
    if (e is StateError) return e.message;
    return s.split('\n').first;
  }

  Future<void> _addOrEdit([ProductLine? line]) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final groups = await ProductLinesRepo.orgGroups(orgId); // fresh: new groups appear straight away
    if (!mounted) return;
    final r = await showLineEditDialog(context, line: line, allGroups: groups);
    if (r == null) return;
    try {
      await ProductLinesRepo.saveLine(
        id: line?.id,
        orgId: orgId,
        name: r.name,
        position: r.position,
        appliesToAll: r.appliesToAll,
        isActive: r.isActive,
        groups: r.groups,
      );
      _snack(line == null ? 'Line added' : 'Line updated');
      await _load();
    } catch (e) {
      _snack('Failed: ${_friendly(e)}');
    }
  }

  Future<void> _toggle(ProductLine l) async {
    try {
      await ProductLinesRepo.setActive(l.id, !l.isActive);
      await _load();
    } catch (e) {
      _snack('Failed: ${_friendly(e)}');
    }
  }

  Future<void> _delete(ProductLine l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${l.name}?'),
        content: const Text('The line has no SKUs. Its group ticks and any shop checks for it are removed too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ProductLinesRepo.deleteLine(l.id);
      await _load();
    } catch (e) {
      _snack(_friendly(e));
    }
  }

  /// Auto Pilot's invoice rows against what each shop carries.
  Future<void> _checkSales() async {
    final orgId = _orgId;
    if (orgId == null || _checking) return;
    setState(() => _checking = true);
    try {
      final client = Supabase.instance.client;
      final rules = await ProductLinesRepo.loadRules(orgId);
      final auto = await autopilotRows(orgId);
      final groupOf = <String, String?>{};
      final names = <String, String>{};
      for (var from = 0; from < 500000; from += 1000) {
        final rows = List<Map<String, dynamic>>.from(await client
            .from('customers')
            .select('id, shop_name, code, group_name')
            .eq('org_id', orgId)
            .eq('is_active', true)
            .range(from, from + 999));
        for (final c in rows) {
          groupOf['${c['id']}'] = c['group_name'] as String?;
          names['${c['id']}'] = '${c['shop_name'] ?? ''}';
        }
        if (rows.length < 1000) break;
      }
      final prods = List<Map<String, dynamic>>.from(await client.from('intelligence_products').select('id, line_id').eq('org_id', orgId));
      final lineOf = {for (final p in prods) '${p['id']}': p['line_id'] as String?};
      final hits = salesOutsideLines(autoRows: auto, rules: rules, lineOfProduct: lineOf, groupOf: groupOf);
      if (!mounted) return;
      setState(() {
        _outside = hits;
        _shopNames = names;
      });
    } catch (e) {
      _snack('Could not check Auto Pilot sales: ${_friendly(e)}');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _addOutside(SalesOutsideLine h) async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      await ProductLinesRepo.bulkSet(orgId: orgId, customerIds: h.customerIds, choices: {h.line.id: LineChoice.carries});
      setState(() => _outside = [for (final x in _outside ?? const <SalesOutsideLine>[]) if (x.line.id != h.line.id) x]);
      _snack('${h.line.name} added to ${h.customerIds.length} shop${h.customerIds.length == 1 ? '' : 's'}');
    } catch (e) {
      _snack('Failed: ${_friendly(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _canEdit(ref.watch(currentUserProvider)?.role);
    final narrow = MediaQuery.of(context).size.width < 700;
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 16 : 32),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Product Lines', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
            if (canEdit && _error == null)
              ElevatedButton.icon(onPressed: () => _addOrEdit(), icon: const Icon(Icons.add, size: 18), label: const Text('Add line')),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Group your SKUs into lines (Lights, PVC...) and choose which shops carry each line: tick customer groups here, or check and uncheck a line on a single shop. '
            'The Placement Audit grid and every report then show each shop only the SKUs of the lines it carries.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(10)),
              child: Text(_error!, style: const TextStyle(color: Color(0xFF92400E))),
            )
          else ...[
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                  child: Row(children: const [
                    Expanded(flex: 3, child: Text('Line', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    Expanded(flex: 5, child: Text('Carried by', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    SizedBox(width: 56, child: Text('Order', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    SizedBox(width: 148),
                  ]),
                ),
                const Divider(height: 1),
                SizedBox(
                  height: (_rules.lines.length * 78.0).clamp(90.0, 560.0),
                  child: ProductLinesTable(
                    lines: _rules.lines,
                    skuCounts: _counts,
                    canEdit: canEdit,
                    onEdit: _addOrEdit,
                    onToggleActive: _toggle,
                    onDelete: _delete,
                  ),
                ),
              ]),
            ),
            if ((_counts[''] ?? 0) > 0) ...[
              const SizedBox(height: 10),
              Text('${_counts['']} SKU${_counts[''] == 1 ? ' has' : 's have'} no line yet and apply to every shop. Give them a line on the Products screen.',
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFFB45309))),
            ],
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Expanded(child: Text('Auto Pilot sales outside a shop\'s lines', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                  OutlinedButton.icon(
                    onPressed: _checking ? null : _checkSales,
                    icon: _checking
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search, size: 16),
                    label: Text(_checking ? 'Checking...' : 'Check now'),
                  ),
                ]),
                const SizedBox(height: 6),
                const Text(
                  'Auto Pilot follows the same rule: a sale of a SKU the shop does not carry does not show in its reports. This lists shops that bought such a line, so you can add it to them.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                if (_outside != null) ...[
                  const SizedBox(height: 14),
                  OutsideSalesList(hits: _outside!, shopName: (id) => _shopNames[id] ?? id, onAdd: canEdit ? _addOutside : (_) {}),
                ],
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}
