import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'product_line_rules.dart';
import 'product_lines_repo.dart';

const _amber = Color(0xFFB45309);
const _amberTint = Color(0xFFFEF3C7);

Widget _chip(String text, {Color fg = AppTheme.primary, Color bg = const Color(0xFFEFF6FF)}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );

// ---------------------------------------------------------------------------------------------
// The lines page: one row per line
// ---------------------------------------------------------------------------------------------

class ProductLinesTable extends StatelessWidget {
  const ProductLinesTable({
    super.key,
    required this.lines,
    required this.skuCounts,
    required this.canEdit,
    required this.onEdit,
    required this.onToggleActive,
    required this.onDelete,
  });

  final List<ProductLine> lines;

  /// line id -> number of SKUs in it
  final Map<String, int> skuCounts;
  final bool canEdit;
  final void Function(ProductLine) onEdit;
  final void Function(ProductLine) onToggleActive;
  final void Function(ProductLine) onDelete;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('No product lines yet.', style: TextStyle(color: AppTheme.textSecondary))),
      );
    }
    return ListView.separated(
      itemCount: lines.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final l = lines[i];
        final n = skuCounts[l.id] ?? 0;
        final groups = l.groups.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return Opacity(
          opacity: l.isActive ? 1 : 0.55,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                flex: 3,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 3),
                  Text('$n SKU${n == 1 ? '' : 's'}${l.isActive ? '' : '  \u00B7  switched off'}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
              Expanded(
                flex: 5,
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  if (l.appliesToAll)
                    _chip('All shops', fg: const Color(0xFF047857), bg: const Color(0xFFECFDF5))
                  else if (groups.isEmpty)
                    _chip('No group ticked: only shops where it is checked', fg: _amber, bg: _amberTint)
                  else
                    for (final g in groups) _chip(g),
                ]),
              ),
              SizedBox(width: 56, child: Text('${l.position}', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
              if (canEdit)
                SizedBox(
                  width: 148,
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    IconButton(icon: const Icon(Icons.edit_outlined, size: 18), tooltip: 'Edit', onPressed: () => onEdit(l)),
                    IconButton(
                      icon: Icon(l.isActive ? Icons.block : Icons.check_circle_outline, size: 18, color: l.isActive ? AppTheme.danger : AppTheme.success),
                      tooltip: l.isActive ? 'Switch off' : 'Switch on',
                      onPressed: () => onToggleActive(l),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline, size: 18, color: n == 0 ? AppTheme.danger : AppTheme.textSecondary),
                      tooltip: n == 0 ? 'Delete' : 'Has SKUs: move them first',
                      onPressed: n == 0 ? () => onDelete(l) : null,
                    ),
                  ]),
                ),
            ]),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Add / edit a line
// ---------------------------------------------------------------------------------------------

class LineEdit {
  const LineEdit({required this.name, required this.position, required this.appliesToAll, required this.isActive, required this.groups});

  final String name;
  final int position;
  final bool appliesToAll;
  final bool isActive;
  final Set<String> groups;
}

/// The add / edit dialog. [allGroups] is the live list of customer groups; groups already ticked but no
/// longer found on any shop are kept in the list so they can still be unticked.
Future<LineEdit?> showLineEditDialog(BuildContext context, {ProductLine? line, required List<String> allGroups}) {
  return showDialog<LineEdit>(
    context: context,
    builder: (_) => LineEditDialog(line: line, allGroups: allGroups),
  );
}

class LineEditDialog extends StatefulWidget {
  const LineEditDialog({super.key, this.line, required this.allGroups});

  final ProductLine? line;
  final List<String> allGroups;

  @override
  State<LineEditDialog> createState() => _LineEditDialogState();
}

class _LineEditDialogState extends State<LineEditDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.line?.name ?? '');
  late final TextEditingController _pos = TextEditingController(text: '${widget.line?.position ?? 0}');
  late bool _all = widget.line?.appliesToAll ?? false;
  late bool _active = widget.line?.isActive ?? true;
  late final Set<String> _groups = {...?widget.line?.groups};
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _pos.dispose();
    super.dispose();
  }

  List<String> get _shown {
    final keys = {for (final g in widget.allGroups) groupKey(g)};
    return [...widget.allGroups, for (final g in _groups) if (!keys.contains(groupKey(g))) g];
  }

  bool _ticked(String g) => _groups.any((x) => groupKey(x) == groupKey(g));

  void _toggle(String g, bool on) {
    setState(() {
      _groups.removeWhere((x) => groupKey(x) == groupKey(g));
      if (on) _groups.add(g);
    });
  }

  void _save() {
    final n = _name.text.trim();
    if (n.isEmpty) {
      setState(() => _error = 'Give the line a name.');
      return;
    }
    Navigator.of(context).pop(LineEdit(
      name: n,
      position: int.tryParse(_pos.text.trim()) ?? 0,
      appliesToAll: _all,
      isActive: _active,
      groups: _all ? <String>{...?widget.line?.groups, ..._groups} : {..._groups},
    ));
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return AlertDialog(
      title: Text(widget.line == null ? 'Add product line' : 'Edit product line'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'Line name *', hintText: 'e.g. Lights, PVC')),
            const SizedBox(height: 12),
            TextField(
              controller: _pos,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Display order', hintText: 'Lower numbers appear first'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _all,
              onChanged: (v) => setState(() => _all = v),
              title: const Text('Applies to all shops', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Every shop carries this line, including shops with no group, unless it is unchecked on the shop itself.',
                  style: TextStyle(fontSize: 12)),
            ),
            if (widget.line != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Line is on', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Switched off: its SKUs leave the audit grid and the reports.', style: TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 8),
            Text('Shop groups that carry this line', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _all ? AppTheme.textSecondary : null)),
            const SizedBox(height: 6),
            if (_all)
              const Text('Not needed while the line applies to all shops.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
            else if (shown.isEmpty)
              const Text('There are no customer groups yet. Add groups in Settings or on a customer.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
            else
              Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final g in shown)
                      CheckboxListTile(
                        dense: true,
                        value: _ticked(g),
                        onChanged: (v) => _toggle(g, v == true),
                        title: Text(g, style: const TextStyle(fontSize: 13)),
                        subtitle: widget.allGroups.any((x) => groupKey(x) == groupKey(g))
                            ? null
                            : const Text('not on any shop now', style: TextStyle(fontSize: 11, color: _amber)),
                      ),
                  ],
                ),
              ),
            if (!_all && _groups.isEmpty && shown.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('No group ticked: only shops where you check this line on the shop itself will carry it.',
                  style: TextStyle(fontSize: 12, color: _amber)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: Text(widget.line == null ? 'Add' : 'Save')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// On a shop: check / uncheck the lines it carries
// ---------------------------------------------------------------------------------------------

/// The "Product lines" part of the customer dialog. A line starts ticked or not by the shop's group; ticking
/// or unticking it records the shop's own choice ([overrides]); "Use group default" clears them.
class CustomerLinesChecklist extends StatelessWidget {
  const CustomerLinesChecklist({
    super.key,
    required this.rules,
    required this.group,
    required this.overrides,
    required this.onToggle,
    required this.onReset,
  });

  final LineRules rules;
  final String? group;

  /// This shop's own choices so far: line id -> carries.
  final Map<String, bool> overrides;
  final void Function(String lineId, bool carries) onToggle;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final lines = rules.activeLines;
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Product lines', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
        if (overrides.isNotEmpty) TextButton(onPressed: onReset, child: const Text('Use group default', style: TextStyle(fontSize: 12))),
      ]),
      const SizedBox(height: 6),
      Container(
        decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
        child: Column(children: [
          for (final l in lines)
            CheckboxListTile(
              dense: true,
              value: overrides[l.id] ?? rules.defaultCarries(l, group),
              onChanged: (v) => onToggle(l.id, v == true),
              title: Text(l.name, style: const TextStyle(fontSize: 13)),
              subtitle: Text(_why(l), style: const TextStyle(fontSize: 11)),
            ),
        ]),
      ),
      const SizedBox(height: 4),
      const Text('The SKUs of the lines ticked here are the ones audited and reported for this shop.',
          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    ]);
  }

  String _why(ProductLine l) {
    if (overrides.containsKey(l.id)) return 'Set for this shop';
    if (l.appliesToAll) return 'All shops';
    final g = (group ?? '').trim();
    if (rules.defaultCarries(l, group)) return 'From group $g';
    return g.isEmpty ? 'This shop has no group' : 'Not ticked for group $g';
  }
}

// ---------------------------------------------------------------------------------------------
// Many shops at once
// ---------------------------------------------------------------------------------------------

String choiceLabel(LineChoice c) {
  switch (c) {
    case LineChoice.keep:
      return 'Leave as it is';
    case LineChoice.carries:
      return 'Carries this line';
    case LineChoice.notCarries:
      return 'Does not carry it';
    case LineChoice.groupDefault:
      return 'Use the group default';
  }
}

/// Asks what to do for each line with the [count] chosen shops. Returns null when cancelled, and only the
/// lines that are to change.
Future<Map<String, LineChoice>?> showBulkLinesDialog(BuildContext context, {required List<ProductLine> lines, required int count}) {
  return showDialog<Map<String, LineChoice>>(
    context: context,
    builder: (_) => BulkLinesDialog(lines: lines, count: count),
  );
}

class BulkLinesDialog extends StatefulWidget {
  const BulkLinesDialog({super.key, required this.lines, required this.count});

  final List<ProductLine> lines;
  final int count;

  @override
  State<BulkLinesDialog> createState() => _BulkLinesDialogState();
}

class _BulkLinesDialogState extends State<BulkLinesDialog> {
  late final Map<String, LineChoice> _choice = {for (final l in widget.lines) l.id: LineChoice.keep};

  bool get _anyChange => _choice.values.any((c) => c != LineChoice.keep);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Product lines for ${widget.count} shop${widget.count == 1 ? '' : 's'}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Choose what happens to each line for the selected shops. Lines left as they are are not touched.',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            for (final l in widget.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  Expanded(child: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                  SizedBox(
                    width: 210,
                    child: DropdownButtonFormField<LineChoice>(
                      value: _choice[l.id],
                      isExpanded: true,
                      decoration: const InputDecoration(isDense: true),
                      items: [for (final c in LineChoice.values) DropdownMenuItem(value: c, child: Text(choiceLabel(c), style: const TextStyle(fontSize: 13)))],
                      onChanged: (v) => setState(() => _choice[l.id] = v ?? LineChoice.keep),
                    ),
                  ),
                ]),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _anyChange ? () => Navigator.of(context).pop({for (final e in _choice.entries) if (e.value != LineChoice.keep) e.key: e.value}) : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Auto Pilot: shops that bought a line they do not carry
// ---------------------------------------------------------------------------------------------

class OutsideSalesList extends StatelessWidget {
  const OutsideSalesList({super.key, required this.hits, required this.shopName, required this.onAdd});

  final List<SalesOutsideLine> hits;
  final String Function(String customerId) shopName;
  final void Function(SalesOutsideLine) onAdd;

  @override
  Widget build(BuildContext context) {
    if (hits.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('No shop has bought a line it does not carry.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final h in hits)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${h.line.name}: ${h.customerIds.length} shop${h.customerIds.length == 1 ? '' : 's'} bought it but do not carry it',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                const SizedBox(height: 3),
                Text(
                  [for (final id in h.customerIds.take(6)) shopName(id)].join(', ') + (h.customerIds.length > 6 ? ' and ${h.customerIds.length - 6} more' : ''),
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            OutlinedButton(onPressed: () => onAdd(h), child: const Text('Add line to these shops')),
          ]),
        ),
    ]);
  }
}
