import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/money.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';

/// Financials → Duplicate References (SQL 406).
///
/// Every "reference number already used" warning raised on a CRV / CPV lands
/// here with the vouchers it matched and what the user chose. Pending events are
/// reviewed and supervised; supervised events move to the archive (filter by
/// voucher type and date). With org.dupref_supervise_flow ON only admins and the
/// chosen supervisors can supervise, and a pending counter shows in the menu;
/// with it OFF anyone who can open this page can supervise.
class ErpDuplicateRefsScreen extends ConsumerStatefulWidget {
  const ErpDuplicateRefsScreen({super.key});
  @override
  ConsumerState<ErpDuplicateRefsScreen> createState() => _State();
}

class _State extends ConsumerState<ErpDuplicateRefsScreen> {
  SupabaseClient get _db => Supabase.instance.client;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  final _dtf = DateFormat('d MMM yyyy, h:mm a');
  final _df = DateFormat('d MMM yyyy');

  int _tab = 0; // 0 pending · 1 archive
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _pending = [];
  List<Map<String, dynamic>> _archive = [];
  final Set<String> _selected = {};
  bool _busy = false;

  bool _flowOn = false;
  bool _canSupervise = false;

  // archive filters
  String _type = 'all'; // all | CRV | CPV
  DateTimeRange _range = DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 30)), end: DateTime.now());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final org = _orgId;
    if (org == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final cfg = await _db.from('app_config').select('key, value').eq('org_id', org)
          .inFilter('key', ['org.dupref_supervise_flow', 'org.dupref_supervisor_users']);
      final m = {for (final r in cfg as List) '${r['key']}': '${r['value'] ?? ''}'};
      final user = ref.read(currentUserProvider);
      final isAdmin = user?.role == WebUserRole.admin || user?.role == WebUserRole.masterAdmin ||
          user?.role == WebUserRole.superAdmin;
      final list = (m['org.dupref_supervisor_users'] ?? '').split(',').map((e) => e.trim()).toSet();
      _flowOn = m['org.dupref_supervise_flow'] == 'true';
      _canSupervise = !_flowOn || isAdmin || (user != null && list.contains(user.id));

      final pending = await _db.from('duplicate_ref_events').select().eq('org_id', org)
          .filter('supervised_at', 'is', null).order('raised_at', ascending: false).limit(500);
      var q = _db.from('duplicate_ref_events').select().eq('org_id', org)
          .not('supervised_at', 'is', null)
          .gte('raised_at', DateTime(_range.start.year, _range.start.month, _range.start.day).toUtc().toIso8601String())
          .lt('raised_at', DateTime(_range.end.year, _range.end.month, _range.end.day + 1).toUtc().toIso8601String());
      if (_type != 'all') q = q.eq('voucher_type', _type);
      final archive = await q.order('raised_at', ascending: false).limit(1000);
      if (!mounted) return;
      setState(() {
        _pending = List<Map<String, dynamic>>.from(pending as List);
        _archive = List<Map<String, dynamic>>.from(archive as List);
        _selected.removeWhere((id) => !_pending.any((e) => e['id'] == id));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = friendlyError('Could not load duplicate references', e); });
    }
  }

  Future<void> _supervise(List<String> ids) async {
    if (ids.isEmpty || _busy) return;
    final note = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(ids.length == 1 ? 'Supervise this entry?' : 'Supervise ${ids.length} entries?'),
      content: SizedBox(width: 420, child: TextField(controller: note, maxLines: 2,
          decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. Checked — failed transfer resent'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supervise')),
      ],
    ));
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _db.rpc('dup_ref_event_supervise', params: {'p_ids': ids, 'p_note': note.text.trim()});
      _selected.removeAll(ids);
      ref.invalidate(dupRefPendingProvider);
      _snack(ids.length == 1 ? 'Supervised — moved to the archive' : '${ids.length} entries supervised');
      await _load();
    } catch (e) {
      _snack(friendlyError('That did not save', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  void _openVoucher(String? type, String? number) {
    if (number == null || number.isEmpty) return;
    final path = type == 'CPV' ? '/erp/payment-vouchers' : '/erp/receipt-vouchers';
    context.go('$path?id=${Uri.encodeComponent(number)}');
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now(),
        initialDateRange: _range);
    if (r != null) { setState(() => _range = r); _load(); }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mobile = context.isMobile;
    final list = _tab == 0 ? _pending : _archive;
    return Container(
      color: AppTheme.background,
      padding: context.pagePadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
          const Text('Duplicate References', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, size: 20)),
        ]),
        const Text('Receipt, slip and transaction numbers flagged as already used on Receipt and Payment Vouchers.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _tabChip(0, 'To review', _pending.length),
          _tabChip(1, 'Archive', null),
          if (_tab == 0 && _canSupervise && _pending.isNotEmpty) ...[
            TextButton(
              onPressed: () => setState(() {
                if (_selected.length == _pending.length) { _selected.clear(); } else { _selected.addAll(_pending.map((e) => e['id'] as String)); }
              }),
              child: Text(_selected.length == _pending.length ? 'Clear selection' : 'Select all'),
            ),
            if (_selected.isNotEmpty)
              ElevatedButton.icon(
                onPressed: _busy ? null : () => _supervise(_selected.toList()),
                icon: const Icon(Icons.verified_outlined, size: 16),
                label: Text('Supervise ${_selected.length}'),
              ),
          ],
        ]),
        if (_tab == 0 && !_canSupervise)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Only the chosen supervisors can supervise these.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
        if (_tab == 1) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final t in const ['all', 'CRV', 'CPV'])
              ChoiceChip(
                label: Text(t == 'all' ? 'All' : t == 'CRV' ? 'Receipt (CRV)' : 'Payment (CPV)'),
                selected: _type == t,
                onSelected: (_) { setState(() => _type = t); _load(); },
              ),
            OutlinedButton.icon(
              onPressed: _pickRange,
              icon: const Icon(Icons.date_range, size: 16),
              label: Text('${_df.format(_range.start)} – ${_df.format(_range.end)}'),
            ),
          ]),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                  : list.isEmpty
                      ? Center(child: Text(_tab == 0 ? 'Nothing to review.' : 'No supervised entries in this range.',
                          style: const TextStyle(color: AppTheme.textSecondary)))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (_, i) => _card(list[i], mobile),
                          ),
                        ),
        ),
      ]),
    );
  }

  Widget _tabChip(int i, String label, int? count) => ChoiceChip(
        selected: _tab == i,
        onSelected: (_) => setState(() => _tab = i),
        label: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label),
          if (count != null && count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: AppTheme.danger, borderRadius: BorderRadius.circular(10)),
              child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ],
        ]),
      );

  Widget _pill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      );

  Widget _card(Map<String, dynamic> e, bool mobile) {
    final id = e['id'] as String;
    final type = '${e['voucher_type'] ?? ''}';
    final number = e['voucher_number'] as String?;
    final outcome = '${e['outcome'] ?? 'shown'}';
    final refs = ((e['refs'] as List?) ?? const []).map((x) => '$x').toList();
    final matches = ((e['matches'] as List?) ?? const []).cast<Map>();
    final raisedAt = DateTime.tryParse('${e['raised_at']}')?.toLocal();
    final supAt = DateTime.tryParse('${e['supervised_at'] ?? ''}')?.toLocal();
    final pending = supAt == null;
    final sel = _selected.contains(id);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sel ? AppTheme.primary : AppTheme.border, width: sel ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (pending && _canSupervise)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: SizedBox(width: 28, height: 28, child: Checkbox(
                value: sel,
                onChanged: (v) => setState(() => v == true ? _selected.add(id) : _selected.remove(id)),
              )),
            ),
          Expanded(child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _pill(type, type == 'CPV' ? Colors.deepOrange : Colors.teal),
            if (number != null && number.isNotEmpty)
              InkWell(
                onTap: () => _openVoucher(type, number),
                child: Text(number, style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primary,
                    decoration: TextDecoration.underline, decorationColor: Color(0x552F6FED))),
              )
            else
              const Text('Not saved', style: TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
            _pill(outcome == 'saved_anyway' ? 'Saved anyway' : outcome == 'went_back' ? 'Went back to review' : 'Warning shown',
                outcome == 'saved_anyway' ? Colors.orange.shade800 : AppTheme.textSecondary),
          ])),
          if (pending && _canSupervise && !mobile)
            TextButton.icon(
              onPressed: _busy ? null : () => _supervise([id]),
              icon: const Icon(Icons.verified_outlined, size: 16),
              label: const Text('Supervise'),
            ),
        ]),
        const SizedBox(height: 6),
        Text('Reference${refs.length == 1 ? '' : 's'}: ${refs.join(', ')}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        Text('By ${e['raised_by_name'] ?? 'Someone'}${raisedAt == null ? '' : ' · ${_dtf.format(raisedAt)}'}',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        if (matches.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Already used in', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          for (final m in matches)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.05), borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.25))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  InkWell(
                    onTap: () => _openVoucher('${m['type']}', m['number'] as String?),
                    child: Text('${m['number'] ?? m['type']}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                        color: AppTheme.primary, decoration: TextDecoration.underline, decorationColor: Color(0x552F6FED))),
                  ),
                  if (m['date'] != null && DateTime.tryParse('${m['date']}') != null)
                    Text(_df.format(DateTime.parse('${m['date']}')), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                  Text('${m['status'] ?? ''}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  Text('Rs ${money((m['amount'] as num?) ?? 0)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ]),
                if ('${m['account'] ?? ''}'.isNotEmpty) Text('${m['account']}', style: const TextStyle(fontSize: 12)),
                Text('${m['description'] ?? ''}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
              ]),
            ),
        ],
        if (pending && _canSupervise && mobile) ...[
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _supervise([id]),
            icon: const Icon(Icons.verified_outlined, size: 16),
            label: const Text('Supervise'),
          )),
        ],
        if (!pending) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.verified, size: 15, color: AppTheme.success),
            const SizedBox(width: 6),
            Expanded(child: Text(
              'Supervised by ${e['supervised_by_name'] ?? 'someone'} · ${_dtf.format(supAt)}'
              '${(e['supervise_note'] ?? '').toString().isNotEmpty ? ' — ${e['supervise_note']}' : ''}',
              style: const TextStyle(fontSize: 12, color: AppTheme.success),
            )),
          ]),
        ],
      ]),
    );
  }
}
