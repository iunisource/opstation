import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/product_picker.dart';
import '../../auth/auth_controller.dart';
import '../../../core/pdf/pdf_output.dart';
import 'erp_npl_pdf.dart';

double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;
final _df = DateFormat('d MMM yyyy');
String _fmtDate(dynamic v) {
  if (v == null) return '—';
  try {
    return _df.format(DateTime.parse('$v'));
  } catch (_) {
    return '$v';
  }
}

/// New Product Launch (NPL): a focused tracker for introducing one product.
/// A launch = product + dates + target outlets (+ optional qty / value targets).
/// Results come from non-void sales invoices of that product, inside the launch
/// dates, for the target outlets: outlets covered, quantity / value, repeats.
/// Off by default per org (Admin Settings -> New Product Launch).
class ErpNplScreen extends ConsumerStatefulWidget {
  const ErpNplScreen({super.key});
  @override
  ConsumerState<ErpNplScreen> createState() => _ErpNplScreenState();
}

class _ErpNplScreenState extends ConsumerState<ErpNplScreen> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  bool _enabled = true;
  String? _error;
  List<Map<String, dynamic>> _launches = [];

  // detail
  String? _openId;
  bool _detailLoading = false;
  Map<String, dynamic>? _detail;
  List<Map<String, dynamic>> _outlets = [];
  List<Map<String, dynamic>> _schemes = [];
  String _filter = 'all'; // all | none | once | repeat

  String get _orgId => ref.read(currentUserProvider)?.orgId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  String _err(Object e) {
    final m = '$e';
    if (m.contains('PGRST202') || m.contains('Could not find')) {
      return 'Run SQL 464 first, then reload.';
    }
    if (m.contains('not allowed')) return 'Not allowed for your user.';
    final mm = RegExp(r'message: ([^,}]+)').firstMatch(m);
    if (mm != null && (m.contains('cannot') || m.contains('required') || m.contains('void'))) return mm.group(1)!.trim();
    return 'Could not load: $m';
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final cfg = await _db
          .from('app_config')
          .select('value')
          .eq('org_id', _orgId)
          .eq('key', 'org.npl_enabled')
          .maybeSingle();
      final on = (cfg?['value'] as String?) == 'true';
      if (!on) {
        if (mounted) setState(() { _enabled = false; _loading = false; });
        return;
      }
      final r = await _db.rpc('npl_launch_list', params: {'p_org': _orgId});
      if (!mounted) return;
      setState(() {
        _enabled = true;
        _launches = [for (final e in (r as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = _err(e); });
    }
  }

  Future<void> _open(String id) async {
    setState(() { _openId = id; _detailLoading = true; _filter = 'all'; });
    try {
      final r = await _db.rpc('npl_launch_detail', params: {'p_org': _orgId, 'p_id': id});
      final m = Map<String, dynamic>.from(r as Map);
      if (!mounted) return;
      setState(() {
        _detail = Map<String, dynamic>.from(m['launch'] as Map);
        _outlets = [for (final e in (m['outlets'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
        _schemes = [for (final e in (m['schemes'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
        _detailLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _detailLoading = false; _openId = null; });
      _snack(_err(e));
    }
  }

  void _back() {
    setState(() { _openId = null; _detail = null; });
    _load();
  }

  Future<void> _setStatus(String status) async {
    final l = _detail;
    if (l == null) return;
    try {
      await _db.rpc('npl_launch_status', params: {'p_org': _orgId, 'p_id': l['id'], 'p_status': status});
      await _open('${l['id']}');
    } catch (e) {
      _snack('Could not update: ${_err(e)}');
    }
  }

  Future<void> _delete() async {
    final l = _detail;
    if (l == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this launch?'),
        content: Text('"${l['name']}" has no sales yet, so it can be deleted. Its outlet list will be removed. Invoices are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _db.rpc('npl_launch_delete', params: {'p_org': _orgId, 'p_id': l['id']});
      _back();
    } catch (e) {
      _snack(_err(e));
    }
  }

  Future<void> _void() async {
    final l = _detail;
    if (l == null) return;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Void this launch?'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('"${l['name']}" already has sales, so it cannot be deleted. Voiding keeps all figures and the history, '
                  'but the launch can no longer be edited or reopened.',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: reason,
                maxLines: 2,
                onChanged: (_) => setS(() {}),
                decoration: const InputDecoration(labelText: 'Reason *', isDense: true, border: OutlineInputBorder()),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: reason.text.trim().isEmpty ? null : () => Navigator.pop(ctx, true),
              child: const Text('Void launch'),
            ),
          ],
        ),
      ),
    );
    final r = reason.text.trim();
    reason.dispose();
    if (ok != true) return;
    try {
      await _db.rpc('npl_launch_void', params: {'p_org': _orgId, 'p_id': l['id'], 'p_reason': r});
      await _open('${l['id']}');
    } catch (e) {
      _snack(_err(e));
    }
  }

  Future<void> _history() async {
    final l = _detail;
    if (l == null) return;
    List<Map<String, dynamic>> ev = [];
    String? err;
    try {
      final r = await _db.rpc('npl_launch_events', params: {'p_org': _orgId, 'p_id': l['id']});
      ev = [for (final e in (r as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    } catch (e) {
      err = _err(e);
    }
    if (!mounted) return;
    final tf = DateFormat('d MMM yyyy, HH:mm');
    IconData ic(String a) => switch (a) {
          'created' => Icons.rocket_launch_outlined,
          'edited' => Icons.edit_outlined,
          'closed' => Icons.lock_outline,
          'reopened' => Icons.lock_open_outlined,
          'voided' => Icons.block,
          _ => Icons.history,
        };
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('History: ${l['name']}'),
        content: SizedBox(
          width: 520,
          height: 440,
          child: err != null
              ? Text(err, style: const TextStyle(color: AppTheme.danger))
              : ev.isEmpty
                  ? const Center(child: Text('No history recorded yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView(children: [
                      for (final e in ev)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Icon(ic('${e['action']}'), size: 18, color: AppTheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(
                                    '${'${e['action']}'[0].toUpperCase()}${'${e['action']}'.substring(1)} by ${e['by'] ?? 'Unknown'}',
                                    style: const TextStyle(fontWeight: FontWeight.w700)),
                                Text(
                                    (DateTime.tryParse('${e['at']}') != null) ? tf.format(DateTime.parse('${e['at']}').toLocal()) : '${e['at']}',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                if ((e['detail'] as String?)?.isNotEmpty == true)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text('${e['detail']}', style: const TextStyle(fontSize: 13)),
                                  ),
                              ]),
                            ),
                          ]),
                        ),
                    ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _print() async {
    final l = _detail;
    if (l == null) return;
    try {
      final user = ref.read(currentUserProvider);
      final label = switch (_filter) {
        'none' => 'Not yet ordered',
        'once' => 'Ordered once',
        'repeat' => 'Repeat',
        _ => 'All outlets',
      };
      final shown = _outlets.where((o) {
        final n = _d(o['orders']);
        return switch (_filter) { 'none' => n == 0, 'once' => n == 1, 'repeat' => n >= 2, _ => true };
      }).toList();
      final bytes = await NplPdf.build(
        launch: l,
        outlets: shown,
        schemes: _schemes,
        viewLabel: label,
        orgName: user?.orgName ?? '',
        preparedBy: user?.name ?? '',
      );
      await showPdf(bytes, 'NPL - ${l['name']}');
    } catch (e) {
      _snack('Could not create the PDF: $e');
    }
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _LaunchDialog(orgId: _orgId, existing: existing),
    );
    if (saved != true) return;
    if (_openId != null) {
      await _open(_openId!);
    } else {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_enabled
              ? _notEnabled()
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                  : _openId != null
                      ? _detailView()
                      : _listView(),
    );
  }

  Widget _notEnabled() => Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.border)),
          child: const Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.rocket_launch_outlined, size: 36, color: AppTheme.textSecondary),
            SizedBox(height: 12),
            Text('New Product Launch is switched off',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            SizedBox(height: 6),
            Text('An admin can turn it on under Admin Settings → New Product Launch (NPL).',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary)),
          ]),
        ),
      );

  // ───────────────────────── list ─────────────────────────
  Widget _listView() {
    return ListView(padding: const EdgeInsets.all(24), children: [
      Row(children: [
        const Icon(Icons.rocket_launch_outlined, color: AppTheme.primary),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('New Product Launch (NPL)',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        ),
        ElevatedButton.icon(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New launch'),
        ),
      ]),
      const SizedBox(height: 4),
      const Text('Track how a new product is taking off: outlets covered, quantity and value sold, and repeat orders.',
          style: TextStyle(color: AppTheme.textSecondary)),
      const SizedBox(height: 18),
      if (_launches.isEmpty)
        Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.border)),
          child: const Center(
              child: Text('No launches yet. Press "New launch" to start one.',
                  style: TextStyle(color: AppTheme.textSecondary))),
        )
      else
        for (final l in _launches) _launchCard(l),
    ]);
  }

  Widget _statusChip(String s) {
    final active = s == 'active';
    final isVoid = s == 'void';
    final c = isVoid ? AppTheme.danger : active ? AppTheme.success : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(isVoid ? 'Void' : active ? 'Active' : 'Closed',
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _launchCard(Map<String, dynamic> l) {
    final outlets = _d(l['outlets']);
    final covered = _d(l['covered']);
    final tq = _d(l['target_qty']);
    final tv = _d(l['target_value']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _open('${l['id']}'),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${l['name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text('${l['product_name'] ?? '—'}  •  ${_fmtDate(l['start_date'])} → ${l['end_date'] == null ? 'open' : _fmtDate(l['end_date'])}',
                      style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                ]),
              ),
              _statusChip('${l['status']}'),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 28, runSpacing: 10, children: [
              _MiniStat('Outlets covered', '${covered.toInt()} / ${outlets.toInt()}',
                  outlets > 0 ? covered / outlets : null),
              _MiniStat('Repeat outlets', '${_d(l['repeat']).toInt()}', null),
              _MiniStat('Quantity', tq > 0 ? '${money(_d(l['qty']))} / ${money(tq)}' : money(_d(l['qty'])),
                  tq > 0 ? _d(l['qty']) / tq : null),
              _MiniStat('Value', tv > 0 ? 'Rs ${money(_d(l['value']))} / ${money(tv)}' : 'Rs ${money(_d(l['value']))}',
                  tv > 0 ? _d(l['value']) / tv : null),
            ]),
          ]),
        ),
      ),
    );
  }

  // ───────────────────────── detail ─────────────────────────
  Widget _detailView() {
    final l = _detail;
    if (_detailLoading || l == null) return const Center(child: CircularProgressIndicator());
    final total = _outlets.length;
    final covered = _outlets.where((o) => _d(o['orders']) > 0).length;
    final repeat = _outlets.where((o) => _d(o['orders']) >= 2).length;
    final qty = _outlets.fold<double>(0, (a, o) => a + _d(o['qty']));
    final value = _outlets.fold<double>(0, (a, o) => a + _d(o['value']));
    final tq = _d(l['target_qty']);
    final tv = _d(l['target_value']);
    final isVoid = '${l['status']}' == 'void';
    final hasSales = l['has_sales'] == true || covered > 0;

    List<Map<String, dynamic>> shown = _outlets.where((o) {
      final n = _d(o['orders']);
      switch (_filter) {
        case 'none':
          return n == 0;
        case 'once':
          return n == 1;
        case 'repeat':
          return n >= 2;
        default:
          return true;
      }
    }).toList();

    Widget kpi(String title, String big, String sub, double? pct) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(big, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              if (pct != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                      value: pct.clamp(0.0, 1.0), minHeight: 7, backgroundColor: AppTheme.border),
                ),
              ],
            ]),
          ),
        );

    Widget chip(String key, String label) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label),
            selected: _filter == key,
            onSelected: (_) => setState(() => _filter = key),
          ),
        );

    return ListView(padding: const EdgeInsets.all(24), children: [
      Row(children: [
        IconButton(onPressed: _back, icon: const Icon(Icons.arrow_back)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                  child: Text('${l['name']}',
                      style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
              const SizedBox(width: 10),
              _statusChip('${l['status']}'),
            ]),
            Text('${l['product_name'] ?? '—'}  •  ${_fmtDate(l['start_date'])} → ${l['end_date'] == null ? 'open' : _fmtDate(l['end_date'])}',
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          ]),
        ),
        IconButton(tooltip: 'History', onPressed: _history, icon: const Icon(Icons.history)),
        IconButton(tooltip: 'Print / PDF', onPressed: _print, icon: const Icon(Icons.print_outlined)),
        if (!isVoid) ...[
          const SizedBox(width: 4),
          OutlinedButton.icon(
              onPressed: () => _edit(l), icon: const Icon(Icons.edit_outlined, size: 17), label: const Text('Edit')),
          const SizedBox(width: 8),
          OutlinedButton(
              onPressed: () => _setStatus('${l['status']}' == 'active' ? 'closed' : 'active'),
              child: Text('${l['status']}' == 'active' ? 'Close launch' : 'Reopen')),
          const SizedBox(width: 8),
          if (hasSales)
            OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
                onPressed: _void,
                icon: const Icon(Icons.block, size: 17),
                label: const Text('Void'))
          else
            IconButton(tooltip: 'Delete (only while there are no sales)', onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ]),
      if (isVoid)
        Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: AppTheme.danger.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.danger.withOpacity(0.3))),
          child: Text(
              'Voided ${(DateTime.tryParse('${l['voided_at']}') != null) ? DateFormat('d MMM yyyy, HH:mm').format(DateTime.parse('${l['voided_at']}').toLocal()) : ''}'
              ' by ${l['voided_by'] ?? 'Unknown'}. Reason: ${l['void_reason'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.danger)),
        ),
      if ((l['notes'] as String?)?.isNotEmpty == true)
        Padding(
          padding: const EdgeInsets.only(left: 48, top: 4),
          child: Text('${l['notes']}', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ),
      const SizedBox(height: 16),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        kpi('Outlets covered', '$covered / $total',
            total > 0 ? '${(covered * 100 / total).toStringAsFixed(0)}% of target outlets' : 'No target outlets',
            total > 0 ? covered / total : null),
        const SizedBox(width: 12),
        kpi('Repeat outlets', '$repeat',
            covered > 0 ? '${(repeat * 100 / covered).toStringAsFixed(0)}% of covered outlets reordered' : 'Ordered 2+ times',
            covered > 0 ? repeat / covered : null),
        const SizedBox(width: 12),
        kpi('Quantity sold', money(qty), tq > 0 ? 'Target ${money(tq)}' : 'No target set', tq > 0 ? qty / tq : null),
        const SizedBox(width: 12),
        kpi('Value sold', 'Rs ${money(value)}', tv > 0 ? 'Target Rs ${money(tv)}' : 'No target set', tv > 0 ? value / tv : null),
      ]),
      if (_schemes.isNotEmpty) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Launch schemes',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final s in _schemes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                  Text('Applied ${_d(s['times']).toInt()}x', style: const TextStyle(color: AppTheme.textSecondary)),
                  const SizedBox(width: 18),
                  Text('Free qty ${money(_d(s['free_qty']))}'),
                  const SizedBox(width: 18),
                  Text('Discount Rs ${money(_d(s['discount']))}'),
                ]),
              ),
            const SizedBox(height: 2),
            const Text('Counted from the scheme log between the launch dates (voided / cancelled vouchers excluded).',
                style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ]),
        ),
      ],
      const SizedBox(height: 20),
      Row(children: [
        chip('all', 'All ($total)'),
        chip('none', 'Not yet ordered (${total - covered})'),
        chip('once', 'Ordered once (${covered - repeat})'),
        chip('repeat', 'Repeat ($repeat)'),
        const Spacer(),
        TextButton.icon(
          onPressed: () {
            final names = _outlets
                .where((o) => _d(o['orders']) == 0)
                .map((o) => '${o['shop_name'] ?? ''}')
                .join('\n');
            Clipboard.setData(ClipboardData(text: names));
            _snack('Copied ${total - covered} outlet names');
          },
          icon: const Icon(Icons.copy_outlined, size: 16),
          label: const Text('Copy not-yet-ordered list'),
        ),
      ]),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.border)),
        child: shown.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: Text('No outlets in this view.', style: TextStyle(color: AppTheme.textSecondary))))
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 900),
                  child: DataTable(
                    headingTextStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                    dataTextStyle: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    columns: const [
                      DataColumn(label: Text('Outlet')),
                      DataColumn(label: Text('Code')),
                      DataColumn(label: Text('Group')),
                      DataColumn(label: Text('Orders'), numeric: true),
                      DataColumn(label: Text('Qty'), numeric: true),
                      DataColumn(label: Text('Value (Rs)'), numeric: true),
                      DataColumn(label: Text('First order')),
                      DataColumn(label: Text('Last order')),
                      DataColumn(label: Text('Status')),
                    ],
                    rows: [
                      for (final o in shown)
                        DataRow(cells: [
                          DataCell(Text('${o['shop_name'] ?? '—'}')),
                          DataCell(Text('${o['code'] ?? ''}')),
                          DataCell(Text('${o['group_name'] ?? ''}')),
                          DataCell(Text('${_d(o['orders']).toInt()}')),
                          DataCell(Text(money(_d(o['qty'])))),
                          DataCell(Text(money(_d(o['value'])))),
                          DataCell(Text(_fmtDate(o['first_date']))),
                          DataCell(Text(_fmtDate(o['last_date']))),
                          DataCell(_outletStatus(_d(o['orders']).toInt())),
                        ]),
                    ],
                  ),
                ),
              ),
      ),
    ]);
  }

  Widget _outletStatus(int n) {
    final (String, Color) s = n == 0
        ? ('Not yet', AppTheme.textSecondary)
        : n == 1
            ? ('Ordered', AppTheme.primary)
            : ('Repeat', AppTheme.success);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: s.$2.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(s.$1, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: s.$2)),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label, value;
  final double? pct;
  const _MiniStat(this.label, this.value, this.pct);
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 190,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
          if (pct != null) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                  value: pct!.clamp(0.0, 1.0), minHeight: 6, backgroundColor: AppTheme.border),
            ),
          ],
        ]),
      );
}

// ───────────────────────── create / edit dialog ─────────────────────────
class _LaunchDialog extends StatefulWidget {
  final String orgId;
  final Map<String, dynamic>? existing;
  const _LaunchDialog({required this.orgId, this.existing});
  @override
  State<_LaunchDialog> createState() => _LaunchDialogState();
}

class _LaunchDialogState extends State<_LaunchDialog> {
  final _db = Supabase.instance.client;
  final _name = TextEditingController();
  final _tq = TextEditingController();
  final _tv = TextEditingController();
  final _notes = TextEditingController();
  bool _loading = true, _saving = false;

  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _customers = []; // id, group_name
  List<Map<String, dynamic>> _routes = [];
  List<Map<String, dynamic>> _schemeList = [];
  final Set<String> _schemeIds = {};
  Map<String, dynamic>? _product;
  DateTime _start = DateTime.now();
  DateTime? _end;
  final Set<String> _groups = {};
  final Set<String> _routeIds = {};
  bool _all = false;
  Set<String> _routeCustomers = {};

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = '${e['name'] ?? ''}';
      _tq.text = _d(e['target_qty']) > 0 ? '${_d(e['target_qty'])}'.replaceAll(RegExp(r'\.0$'), '') : '';
      _tv.text = _d(e['target_value']) > 0 ? '${_d(e['target_value'])}'.replaceAll(RegExp(r'\.0$'), '') : '';
      _notes.text = '${e['notes'] ?? ''}';
      _start = DateTime.tryParse('${e['start_date']}') ?? DateTime.now();
      _end = e['end_date'] == null ? null : DateTime.tryParse('${e['end_date']}');
      for (final s in (e['scheme_ids'] as List? ?? const [])) {
        _schemeIds.add('$s');
      }
    }
    _init();
  }

  @override
  void dispose() {
    _name.dispose();
    _tq.dispose();
    _tv.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final p = await _db
          .from('products')
          .select('id, name, sku')
          .eq('org_id', widget.orgId)
          .eq('is_active', true)
          .order('name')
          .limit(10000);
      final custs = <Map<String, dynamic>>[];
      for (var from = 0;; from += 1000) {
        final page = await _db
            .from('customers')
            .select('id, group_name, is_active')
            .eq('org_id', widget.orgId)
            .range(from, from + 999);
        custs.addAll(List<Map<String, dynamic>>.from(page as List));
        if ((page as List).length < 1000) break;
      }
      final r = await _db.from('sales_routes').select('id, name').eq('org_id', widget.orgId).order('name');
      List<Map<String, dynamic>> sch = [];
      try {
        final sr = await _db.from('schemes').select('id, name, is_active').eq('org_id', widget.orgId).order('name');
        sch = List<Map<String, dynamic>>.from(sr as List);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _schemeList = sch;
        _products = List<Map<String, dynamic>>.from(p as List);
        _customers = custs;
        _routes = List<Map<String, dynamic>>.from(r as List);
        if (_editing) {
          for (final x in _products) {
            if (x['id'] == widget.existing!['product_id']) _product = x;
          }
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<String> get _groupNames {
    final s = <String>{};
    for (final c in _customers) {
      final g = (c['group_name'] as String?)?.trim();
      if (g != null && g.isNotEmpty) s.add(g);
    }
    return s.toList()..sort();
  }

  Future<void> _loadRouteCustomers() async {
    if (_routeIds.isEmpty) {
      setState(() => _routeCustomers = {});
      return;
    }
    try {
      final rows = await _db.from('route_stops').select('customer_id').inFilter('route_id', _routeIds.toList());
      setState(() => _routeCustomers = {for (final r in rows as List) '${r['customer_id']}'});
    } catch (_) {}
  }

  /// null = keep the current outlets (edit with nothing re-selected).
  Set<String>? get _resolved {
    if (!_all && _groups.isEmpty && _routeIds.isEmpty) return null;
    final ids = <String>{};
    for (final c in _customers) {
      if (c['is_active'] == false) continue;
      final g = (c['group_name'] as String?)?.trim() ?? '';
      if (_all || _groups.contains(g)) ids.add('${c['id']}');
    }
    ids.addAll(_routeCustomers);
    return ids;
  }

  Future<void> _pickMulti(String title, List<MapEntry<String, String>> options, Set<String> selected,
      VoidCallback after) async {
    final working = {...selected};
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        String q = '';
        return StatefulBuilder(builder: (ctx, setS) {
          final shown = options.where((o) => o.value.toLowerCase().contains(q.toLowerCase())).toList();
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 380,
              height: 420,
              child: Column(children: [
                TextField(
                  decoration: const InputDecoration(hintText: 'Search', prefixIcon: Icon(Icons.search), isDense: true),
                  onChanged: (v) => setS(() => q = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(children: [
                    for (final o in shown)
                      CheckboxListTile(
                        dense: true,
                        value: working.contains(o.key),
                        title: Text(o.value),
                        onChanged: (v) => setS(() => v == true ? working.add(o.key) : working.remove(o.key)),
                      ),
                  ]),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  selected
                    ..clear()
                    ..addAll(working);
                  Navigator.pop(ctx);
                },
                child: const Text('Done'),
              ),
            ],
          );
        });
      },
    );
    after();
  }

  Future<void> _pickDate(bool isStart) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isStart ? _start : (_end ?? _start),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() => isStart ? _start = d : _end = d);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _product == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Give the launch a name and pick a product')));
      return;
    }
    final resolved = _resolved;
    if (!_editing && (resolved == null || resolved.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Pick target outlets: a customer group, a route, or all customers')));
      return;
    }
    setState(() => _saving = true);
    String f(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
    try {
      await _db.rpc('npl_launch_save', params: {
        'p_org': widget.orgId,
        'p_id': widget.existing?['id'],
        'p_name': _name.text,
        'p_product': _product!['id'],
        'p_start': f(_start),
        'p_end': _end == null ? null : f(_end!),
        'p_target_qty': double.tryParse(_tq.text.replaceAll(',', '').trim()),
        'p_target_value': double.tryParse(_tv.text.replaceAll(',', '').trim()),
        'p_notes': _notes.text,
        'p_customers': resolved?.toList(),
        'p_schemes': _schemeIds.toList(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: ${'$e'.replaceAll('Exception: ', '')}')));
      }
    }
  }

  Widget _field(String label, TextEditingController c, {int lines = 1, bool number = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          maxLines: lines,
          keyboardType: number ? TextInputType.number : null,
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final resolved = _resolved;
    return AlertDialog(
      title: Text(_editing ? 'Edit launch' : 'New product launch'),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const SizedBox(height: 140, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _field('Launch name *', _name),
                  InkWell(
                    onTap: () async {
                      final p = await pickProduct(context, _products, title: 'Select launch product');
                      if (p != null) setState(() => _product = p);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                          labelText: 'Product *', isDense: true, border: OutlineInputBorder()),
                      child: Row(children: [
                        Expanded(child: Text(_product == null ? 'Select product' : '${_product!['name']}')),
                        const Icon(Icons.arrow_drop_down),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                          onPressed: () => _pickDate(true), child: Text('Start: ${_fmtDate(_start.toIso8601String())}')),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                          onPressed: () => _pickDate(false),
                          child: Text(_end == null ? 'End: open' : 'End: ${_fmtDate(_end!.toIso8601String())}')),
                    ),
                    if (_end != null)
                      IconButton(
                          tooltip: 'Clear end date',
                          onPressed: () => setState(() => _end = null),
                          icon: const Icon(Icons.close, size: 18)),
                  ]),
                  const SizedBox(height: 12),
                  const Text('Launch scheme(s)', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('Optional. Pick the existing scheme(s) running for this launch; their free quantity and discounts are shown on the launch.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.local_offer_outlined, size: 17),
                    label: Text(_schemeIds.isEmpty ? 'Select schemes' : 'Schemes (${_schemeIds.length})'),
                    onPressed: () => _pickMulti(
                        'Schemes',
                        [for (final s in _schemeList) MapEntry('${s['id']}', '${s['name']}${s['is_active'] == false ? ' (inactive)' : ''}')],
                        _schemeIds,
                        () => setState(() {})),
                  ),
                  if (_schemeIds.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                          [for (final s in _schemeList) if (_schemeIds.contains('${s['id']}')) '${s['name']}'].join(', '),
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _field('Target quantity (optional)', _tq, number: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _field('Target value Rs (optional)', _tv, number: true)),
                  ]),
                  const Text('Target outlets', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                      _editing
                          ? 'Leave all unselected to keep the current outlet list. Selecting anything replaces it.'
                          : 'Choose who the launch is aimed at. Groups, routes and "all" combine.',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.groups_2_outlined, size: 17),
                      label: Text(_groups.isEmpty ? 'Customer groups' : 'Groups (${_groups.length})'),
                      onPressed: () => _pickMulti(
                          'Customer groups', [for (final g in _groupNames) MapEntry(g, g)], _groups, () => setState(() {})),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.alt_route, size: 17),
                      label: Text(_routeIds.isEmpty ? 'Routes' : 'Routes (${_routeIds.length})'),
                      onPressed: () => _pickMulti(
                          'Routes',
                          [for (final r in _routes) MapEntry('${r['id']}', '${r['name']}')],
                          _routeIds,
                          _loadRouteCustomers),
                    ),
                    FilterChip(
                      label: const Text('All active customers'),
                      selected: _all,
                      onSelected: (v) => setState(() => _all = v),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    resolved == null
                        ? (_editing ? 'Keeping current outlets.' : '0 outlets selected.')
                        : '${resolved.length} outlet${resolved.length == 1 ? '' : 's'} selected.',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  _field('Notes (optional)', _notes, lines: 2),
                ]),
              ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: (_saving || _loading) ? null : _save,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}
