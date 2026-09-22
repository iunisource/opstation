import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';

/// Opens the product lifecycle timeline: every recorded BOM save for [productId],
/// newest first, with a diff of what changed versus the previous version.
Future<void> showProductLifecycle(
  BuildContext context, {
  required String orgId,
  required String productId,
  required String title,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _ProductLifecycleDialog(orgId: orgId, productId: productId, title: title),
  );
}

class _ProductLifecycleDialog extends StatefulWidget {
  final String orgId, productId, title;
  const _ProductLifecycleDialog({required this.orgId, required this.productId, required this.title});
  @override
  State<_ProductLifecycleDialog> createState() => _ProductLifecycleDialogState();
}

class _ProductLifecycleDialogState extends State<_ProductLifecycleDialog> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _events = []; // newest first

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .from('product_lifecycle')
          .select('id, code, event_type, snapshot, changed_at, changed_by_name')
          .eq('org_id', widget.orgId)
          .eq('product_id', widget.productId)
          .order('changed_at', ascending: false)
          .limit(300);
      if (!mounted) return;
      setState(() { _events = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── diff helpers ──────────────────────────────────────────────────────────
  Map<String, num> _lineMap(dynamic list, String key) {
    final m = <String, num>{};
    if (list is List) {
      for (final e in list) {
        if (e is Map) {
          final name = '${e[key] ?? ''}';
          final qty = (e['qty'] as num?) ?? 0;
          m[name] = (m[name] ?? 0) + qty;
        }
      }
    }
    return m;
  }

  List<_Change> _diff(Map<String, dynamic> cur, Map<String, dynamic>? prev) {
    final out = <_Change>[];
    final cs = (cur['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};
    if (prev == null) {
      out.add(const _Change(_ChangeKind.info, 'Initial version recorded'));
      return out;
    }
    final ps = (prev['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};

    num? cq = cs['output_qty'] as num?, pq = ps['output_qty'] as num?;
    if (cq != pq) out.add(_Change(_ChangeKind.changed, 'Output qty: ${_n(pq)} → ${_n(cq)}'));

    final cst = '${cs['status'] ?? ''}', pst = '${ps['status'] ?? ''}';
    if (cst != pst && (cst.isNotEmpty || pst.isNotEmpty)) {
      out.add(_Change(_ChangeKind.changed, 'Status: ${pst.isEmpty ? '—' : pst} → ${cst.isEmpty ? '—' : cst}'));
    }
    final cn = '${cs['name'] ?? ''}', pn = '${ps['name'] ?? ''}';
    if (cn != pn && (cn.isNotEmpty || pn.isNotEmpty)) {
      out.add(_Change(_ChangeKind.changed, 'Name: ${pn.isEmpty ? '—' : pn} → ${cn.isEmpty ? '—' : cn}'));
    }

    _diffLines(out, 'Component', _lineMap(ps['components'], 'product'), _lineMap(cs['components'], 'product'));
    _diffLines(out, 'Waste', _lineMap(ps['waste'], 'product'), _lineMap(cs['waste'], 'product'));
    _diffLines(out, 'Cost', _lineMap(ps['overheads'], 'name'), _lineMap(cs['overheads'], 'name'));

    if (out.isEmpty) out.add(const _Change(_ChangeKind.info, 'Saved with no detected changes'));
    return out;
  }

  void _diffLines(List<_Change> out, String label, Map<String, num> prev, Map<String, num> cur) {
    for (final e in cur.entries) {
      if (!prev.containsKey(e.key)) {
        out.add(_Change(_ChangeKind.added, '$label added: ${e.key} (${_n(e.value)})'));
      } else if (prev[e.key] != e.value) {
        out.add(_Change(_ChangeKind.changed, '$label ${e.key}: ${_n(prev[e.key])} → ${_n(e.value)}'));
      }
    }
    for (final e in prev.entries) {
      if (!cur.containsKey(e.key)) {
        out.add(_Change(_ChangeKind.removed, '$label removed: ${e.key} (${_n(e.value)})'));
      }
    }
  }

  String _n(num? v) {
    if (v == null) return '—';
    final d = v.toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(children: [
              const Icon(Icons.timeline, size: 20, color: AppTheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Product lifecycle', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                Text(widget.title, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ])),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          const Divider(height: 1),
          Flexible(child: _body()),
        ]),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()));
    if (_error != null) {
      return Padding(padding: const EdgeInsets.all(24),
          child: Text("Couldn't load lifecycle: $_error", style: const TextStyle(color: AppTheme.danger)));
    }
    if (_events.isEmpty) {
      return const Padding(padding: EdgeInsets.all(32),
          child: Center(child: Text(
              'No lifecycle recorded yet.\nChanges are tracked from the next time this BOM is saved.',
              textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary))));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: _events.length,
      itemBuilder: (_, i) {
        final ev = _events[i];
        final prev = i + 1 < _events.length ? _events[i + 1] : null; // older
        final changes = _diff(ev, prev);
        return _eventCard(ev, changes, isLatest: i == 0);
      },
    );
  }

  Widget _eventCard(Map<String, dynamic> ev, List<_Change> changes, {required bool isLatest}) {
    final at = DateTime.tryParse('${ev['changed_at']}')?.toLocal();
    final who = (ev['changed_by_name'] as String?) ?? '';
    final type = '${ev['event_type'] ?? 'updated'}';
    final isCreated = type == 'created';
    final snap = (ev['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: isLatest ? AppTheme.primary.withOpacity(0.5) : AppTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: (isCreated ? AppTheme.success : AppTheme.primary).withOpacity(0.08),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: (isCreated ? AppTheme.success : AppTheme.primary).withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(isCreated ? 'Created' : 'Updated',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                      color: isCreated ? AppTheme.success : AppTheme.primary)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(
              at != null ? DateFormat('d MMM y · h:mm a').format(at) : '',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            )),
            if (who.isNotEmpty)
              Text('by $who', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            if (isLatest) ...[
              const SizedBox(width: 8),
              const Text('current', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final c in changes) _changeRow(c)]),
        ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            title: const Text('Full recipe at this point', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            children: [_snapshotView(snap)],
          ),
        ),
      ]),
    );
  }

  Widget _changeRow(_Change c) {
    IconData icon; Color color;
    switch (c.kind) {
      case _ChangeKind.added: icon = Icons.add_circle_outline; color = AppTheme.success; break;
      case _ChangeKind.removed: icon = Icons.remove_circle_outline; color = AppTheme.danger; break;
      case _ChangeKind.changed: icon = Icons.swap_horiz; color = AppTheme.primary; break;
      case _ChangeKind.info: icon = Icons.info_outline; color = AppTheme.textSecondary; break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(c.text, style: const TextStyle(fontSize: 13))),
      ]),
    );
  }

  Widget _snapshotView(Map<String, dynamic> s) {
    Widget section(String label, List<Widget> rows) {
      if (rows.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        ...rows,
      ]);
    }
    Widget kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(fontSize: 12))),
          Text(v, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]));
    final comps = (s['components'] as List?) ?? const [];
    final waste = (s['waste'] as List?) ?? const [];
    final ohs = (s['overheads'] as List?) ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      kv('Output qty', _n(s['output_qty'] as num?)),
      section('Components', [
        for (final e in comps)
          if (e is Map) kv('${e['product'] ?? ''}', _n(e['qty'] as num?)),
      ]),
      section('Waste', [
        for (final e in waste)
          if (e is Map) kv('${e['product'] ?? ''}', _n(e['qty'] as num?)),
      ]),
      section('Labor / Overheads', [
        for (final e in ohs)
          if (e is Map)
            kv('${e['name'] ?? ''}  (${e['type'] ?? ''})',
                'Rs. ${money((e['amount'] as num?)?.toDouble() ?? 0)}'),
      ]),
    ]);
  }
}

enum _ChangeKind { added, removed, changed, info }

class _Change {
  final _ChangeKind kind;
  final String text;
  const _Change(this.kind, this.text);
}
