import 'package:opstation_web/core/utils/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/widgets/product_picker.dart';
import '../../auth/auth_controller.dart';

/// Field Returns queue. A salesperson asks for a return from the app (shop,
/// products, reason, optional invoice and photo). The office checks it here,
/// may adjust products / quantities, then Approves — which creates a draft
/// Sales Return Note (saved when the goods arrive, then credited through a
/// Sales Return Invoice) — or Rejects.
class ErpFieldReturnsScreen extends ConsumerStatefulWidget {
  const ErpFieldReturnsScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpFieldReturnsScreen> createState() => _ErpFieldReturnsScreenState();
}

class _ErpFieldReturnsScreenState extends ConsumerState<ErpFieldReturnsScreen> {
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _currentBranchId => ref.read(selectedBranchProvider)?['id'] as String?;

  String _filter = 'submitted';
  bool _loading = true, _saving = false;
  List<Map<String, dynamic>> _rows = [];
  final Map<String, String> _custNames = {};
  final Map<String, String> _userNames = {};
  final Map<String, String> _srnNumbers = {};
  final Map<String, Map<String, dynamic>> _products = {};
  List<Map<String, dynamic>> _branches = [];

  Map<String, dynamic>? _selected;
  List<Map<String, dynamic>> _lines = [];   // {product_id, uom_id, quantity, ctrl}
  String? _branchId;
  RealtimeChannel? _channel;
  String? _focusDone;

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _loadBranches();
    _load().then((_) => _openFocus());
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant ErpFieldReturnsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusId != oldWidget.focusId) _openFocus();
  }

  @override
  void dispose() {
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    _disposeLineCtrls();
    super.dispose();
  }

  void _disposeLineCtrls() {
    for (final l in _lines) {
      (l['ctrl'] as TextEditingController?)?.dispose();
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  void _subscribe() {
    final orgId = _orgId; if (orgId == null) return;
    _channel = Supabase.instance.client
        .channel('field_returns_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'field_returns',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'org_id', value: orgId),
          callback: (payload) => _onChanged(payload.newRecord),
        )
        .subscribe();
  }

  Future<void> _onChanged(Map<String, dynamic> row) async {
    if (!mounted) return;
    ref.invalidate(fieldReturnPendingCountProvider);
    final sel = _selected;
    if (sel != null && row.isNotEmpty && sel['id'] == row['id'] && !_saving) {
      if (row['status'] == 'cancelled' && sel['status'] != 'cancelled') {
        setState(() => _selected = null);
        _snack('The salesperson cancelled this return request.');
      } else if (((row['edit_count'] as num?) ?? 0) != ((sel['edit_count'] as num?) ?? 0)) {
        await _open(Map<String, dynamic>.from(row));
        _snack('The salesperson just changed this request. Showing the latest version.');
      }
    }
    _load();
  }

  Future<void> _loadProducts() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final p = await Supabase.instance.client.from('products')
          .select('id, name, sku, base_uom_id')
          .eq('org_id', orgId).eq('is_active', true).order('name').limit(10000);
      for (final r in p as List) {
        _products[r['id'] as String] = Map<String, dynamic>.from(r as Map);
      }
    } catch (_) {}
  }

  Future<void> _loadBranches() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final b = await Supabase.instance.client.from('branches')
          .select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
      if (mounted) setState(() => _branches = List<Map<String, dynamic>>.from(b));
    } catch (_) {}
  }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final rows = List<Map<String, dynamic>>.from(await client.from('field_returns')
          .select('*').eq('org_id', orgId).eq('status', _filter)
          .order('created_at', ascending: false).limit(500));
      final custIds = rows.map((o) => o['customer_id'] as String?).whereType<String>().toSet().toList();
      final userIds = {
        ...rows.map((o) => o['salesperson_id'] as String?).whereType<String>(),
        ...rows.map((o) => o['reviewed_by'] as String?).whereType<String>(),
      }.toList();
      final srnIds = rows.map((o) => o['srn_id'] as String?).whereType<String>().toSet().toList();
      if (custIds.isNotEmpty) {
        final cs = await client.from('customers').select('id, shop_name').inFilter('id', custIds);
        for (final c in cs as List) { _custNames[c['id'] as String] = (c['shop_name'] as String?) ?? '—'; }
      }
      if (userIds.isNotEmpty) {
        final us = await client.from('users').select('id, name').inFilter('id', userIds);
        for (final u in us as List) { _userNames[u['id'] as String] = (u['name'] as String?) ?? '—'; }
      }
      if (srnIds.isNotEmpty) {
        final ss = await client.from('sales_returns').select('id, voucher_number').inFilter('id', srnIds);
        for (final s in ss as List) { _srnNumbers[s['id'] as String] = (s['voucher_number'] as String?) ?? ''; }
      }
      if (!mounted) return;
      setState(() { _rows = rows; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(friendlyError('Could not load return requests', e));
    }
  }

  Future<void> _openFocus() async {
    final id = widget.focusId;
    if (id == null || id.isEmpty || id == _focusDone || !mounted) return;
    _focusDone = id;
    Map<String, dynamic>? o;
    for (final x in _rows) { if (x['id'] == id) { o = x; break; } }
    if (o == null) {
      try {
        final row = await Supabase.instance.client.from('field_returns').select('*').eq('id', id).maybeSingle();
        if (row != null) {
          o = Map<String, dynamic>.from(row);
          final st = o['status'] as String?;
          if (st != null && st != _filter) { setState(() => _filter = st); await _load(); }
        }
      } catch (_) {}
    }
    if (o != null && mounted) await _open(o);
  }

  Future<void> _open(Map<String, dynamic> o) async {
    _disposeLineCtrls();
    setState(() {
      _selected = o; _lines = [];
      _branchId = (o['branch_id'] as String?) ?? _currentBranchId;
    });
    try {
      final items = await Supabase.instance.client.from('field_return_items')
          .select('*').eq('return_id', o['id'] as String);
      if (!mounted) return;
      setState(() {
        _lines = (items as List).map((r) {
          final q = (r['quantity'] as num?)?.toDouble() ?? 0;
          return <String, dynamic>{
            'product_id': r['product_id'], 'uom_id': r['uom_id'], 'quantity': q,
            'ctrl': TextEditingController(text: _qtyText(q)),
          };
        }).toList();
      });
    } catch (e) { _snack(friendlyError('Could not load the products', e)); }
  }

  String _qtyText(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Future<void> _addLine() async {
    final list = _products.values.toList();
    final p = await pickProduct(context, list, title: 'Add product');
    if (p == null || p.isEmpty) return;
    if (_lines.any((l) => l['product_id'] == p['id'])) { _snack('That product is already on this request'); return; }
    setState(() => _lines.add({
      'product_id': p['id'], 'uom_id': p['base_uom_id'], 'quantity': 1.0,
      'ctrl': TextEditingController(text: '1'),
    }));
  }

  Future<void> _approve() async {
    final o = _selected; if (o == null) return;
    final items = _lines.where((l) => (l['quantity'] as double) > 0).toList();
    if (items.isEmpty) { _snack('Add at least one product with a quantity'); return; }
    if (_branchId == null) { _snack('Choose the branch the goods will come back to'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Approve return?'),
      content: Text('This creates a draft Sales Return Note for ${_custNames[o['customer_id']] ?? 'this shop'} '
          'with ${items.length} product(s).\n\nSave the note when the goods arrive — that is when stock comes back. '
          'Then make the Sales Return Invoice to credit the customer.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approve')),
      ]));
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final fresh = await client.from('field_returns').select('status, edit_count').eq('id', o['id'] as String).maybeSingle();
      if (fresh == null || fresh['status'] != 'submitted') {
        if (!mounted) return;
        setState(() { _saving = false; _selected = null; });
        _snack(fresh?['status'] == 'cancelled' ? 'The salesperson cancelled this request, so it was not approved.' : 'This request was already handled.');
        _load();
        return;
      }
      if (((fresh['edit_count'] as num?) ?? 0) != ((o['edit_count'] as num?) ?? 0)) {
        if (!mounted) return;
        setState(() => _saving = false);
        final row = await client.from('field_returns').select('*').eq('id', o['id'] as String).maybeSingle();
        if (row != null) await _open(Map<String, dynamic>.from(row));
        _snack('The salesperson just changed this request. Please check it again, then approve.');
        return;
      }
      final srnId = await client.rpc('approve_field_return', params: {
        'p_id': o['id'], 'p_branch': _branchId,
        'p_items': [for (final l in items) {'product_id': l['product_id'], 'uom_id': l['uom_id'], 'quantity': l['quantity']}],
      });
      String srnNo = '';
      try {
        final s = await client.from('sales_returns').select('voucher_number').eq('id', srnId as String).maybeSingle();
        srnNo = (s?['voucher_number'] as String?) ?? '';
      } catch (_) {}
      if (!mounted) return;
      setState(() { _saving = false; _selected = null; });
      ref.invalidate(fieldReturnPendingCountProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Approved — ${srnNo.isEmpty ? 'Sales Return Note' : srnNo} created as a draft. Save it when the goods arrive.'),
        action: SnackBarAction(label: 'Open', onPressed: () => context.go('/erp/sales-returns')),
        duration: const Duration(seconds: 6),
      ));
      _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(friendlyError('Approve failed', e));
    }
  }

  Future<void> _reject() async {
    final o = _selected; if (o == null) return;
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Reject return request?'),
      content: TextField(controller: reasonCtrl, autofocus: true, maxLines: 3,
        decoration: const InputDecoration(hintText: 'Reason (the salesperson will see this)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
          onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
      ]));
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('reject_field_return', params: {'p_id': o['id'], 'p_reason': reason});
      if (!mounted) return;
      setState(() { _saving = false; _selected = null; });
      _snack('Return request rejected');
      ref.invalidate(fieldReturnPendingCountProvider);
      _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(friendlyError('Reject failed', e));
    }
  }

  String _photoUrl(String path) {
    if (path.startsWith('http')) return path;
    return Supabase.instance.client.storage.from('opstation-photos').getPublicUrl(path);
  }

  String _dt(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    return d == null ? '' : DateFormat('d MMM yyyy, HH:mm').format(d);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Field Returns', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      const Text('Return requests sent by salespeople. Check and adjust, then approve to create a draft Sales Return Note.',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final f in const ['submitted', 'approved', 'rejected', 'cancelled'])
          ChoiceChip(
            label: Text(f == 'submitted' ? 'Received' : '${f[0].toUpperCase()}${f.substring(1)}'),
            selected: _filter == f,
            onSelected: (_) { setState(() { _filter = f; _selected = null; }); _load(); }),
      ]),
      const SizedBox(height: 14),
      Expanded(child: LayoutBuilder(builder: (ctx, c) {
        final wide = c.maxWidth >= 820;
        if (!wide) {
          return _selected == null ? _list() : Column(children: [
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(
              onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.arrow_back, size: 16), label: const Text('Back to list'))),
            Expanded(child: _panel()),
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 340, child: _list()),
          const SizedBox(width: 16),
          Expanded(child: _panel()),
        ]);
      })),
    ]));
  }

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return Center(child: Text(_filter == 'submitted' ? 'No return requests waiting' : 'Nothing here',
          style: const TextStyle(color: AppTheme.textSecondary)));
    }
    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final o = _rows[i];
        final sel = _selected?['id'] == o['id'];
        return InkWell(onTap: () => _open(o), borderRadius: BorderRadius.circular(10), child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: sel ? AppTheme.primary.withOpacity(0.06) : Colors.white,
            borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? AppTheme.primary.withOpacity(0.4) : AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(_custNames[o['customer_id']] ?? 'Shop', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
              if ((o['photo_path'] as String?)?.isNotEmpty == true) const Icon(Icons.photo_camera_outlined, size: 15, color: AppTheme.textSecondary),
            ]),
            const SizedBox(height: 2),
            Text('By ${_userNames[o['salesperson_id']] ?? '—'}  ·  ${_dt(o['created_at'] as String?)}',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            if ((o['reason'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 3),
              Text(o['reason'] as String, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ],
            if (o['srn_id'] != null && (_srnNumbers[o['srn_id']] ?? '').isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(_srnNumbers[o['srn_id']]!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary)),
            ],
            if (((o['edit_count'] as num?) ?? 0) > 0 && o['status'] == 'submitted') ...[
              const SizedBox(height: 3),
              const Text('Changed by salesperson', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.warning)),
            ],
          ]),
        ));
      },
    );
  }

  Widget _info(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary))),
      Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
    ]),
  );

  Widget _panel() {
    final o = _selected;
    final box = BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border));
    if (o == null) {
      return Container(decoration: box, child: const Center(child: Text('Select a request to review', style: TextStyle(color: AppTheme.textSecondary))));
    }
    final editable = o['status'] == 'submitted';
    final photo = (o['photo_path'] as String?) ?? '';
    return Container(
      decoration: box,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(_custNames[o['customer_id']] ?? 'Shop', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          _info('Salesperson', _userNames[o['salesperson_id']] ?? '—'),
          _info('Sent on', _dt(o['created_at'] as String?)),
          if ((o['invoice_number'] as String?)?.isNotEmpty == true) _info('Invoice', o['invoice_number'] as String),
          _info('Reason', (o['reason'] as String?)?.isNotEmpty == true ? o['reason'] as String : '—'),
          if ((o['note'] as String?)?.isNotEmpty == true) _info('Note', o['note'] as String),
          if (((o['edit_count'] as num?) ?? 0) > 0) _info('Changed', 'by the salesperson · ${_dt(o['edited_at'] as String?)}'),
          if (o['status'] == 'approved') ...[
            _info('Approved by', '${_userNames[o['reviewed_by']] ?? '—'} · ${_dt(o['reviewed_at'] as String?)}'),
            if ((_srnNumbers[o['srn_id']] ?? '').isNotEmpty) _info('Return note', _srnNumbers[o['srn_id']]!),
          ],
          if (o['status'] == 'rejected') ...[
            _info('Rejected by', '${_userNames[o['reviewed_by']] ?? '—'} · ${_dt(o['reviewed_at'] as String?)}'),
            if ((o['reject_reason'] as String?)?.isNotEmpty == true) _info('Why', o['reject_reason'] as String),
          ],
          if (o['status'] == 'cancelled') _info('Cancelled', 'by the salesperson · ${_dt(o['cancelled_at'] as String?)}'),
          if (photo.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => showDialog(context: context, builder: (_) => Dialog(child: InteractiveViewer(child: Image.network(_photoUrl(photo))))),
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(_photoUrl(photo),
                height: 160, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Text('Photo could not be shown', style: TextStyle(color: AppTheme.textSecondary)))),
            ),
          ],
          const SizedBox(height: 14),
          Row(children: [
            const Expanded(child: Text('Products to return', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
            if (editable) OutlinedButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('Add product'), onPressed: _saving ? null : _addLine),
          ]),
          const SizedBox(height: 6),
          if (_lines.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No products', style: TextStyle(color: AppTheme.textSecondary))),
          for (final l in _lines) Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((_products[l['product_id']]?['name'] as String?) ?? 'Product', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                if ((_products[l['product_id']]?['sku'] as String?)?.isNotEmpty == true)
                  Text(_products[l['product_id']]!['sku'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ])),
              SizedBox(width: 90, child: editable
                ? TextField(
                    controller: l['ctrl'] as TextEditingController,
                    textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(isDense: true, labelText: 'Qty'),
                    onChanged: (v) => l['quantity'] = double.tryParse(v.trim()) ?? 0,
                  )
                : Text(_qtyText(l['quantity'] as double), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
              if (editable) IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.delete_outline, color: AppTheme.danger, size: 20),
                onPressed: _saving ? null : () => setState(() {
                  (l['ctrl'] as TextEditingController?)?.dispose();
                  _lines.remove(l);
                }),
              ),
            ]),
          ),
        ])),
        if (editable) ...[
          const Divider(height: 1),
          Padding(padding: const EdgeInsets.all(12), child: Row(children: [
            if (_branches.isNotEmpty) SizedBox(width: 200, child: DropdownButtonFormField<String>(
              value: _branches.any((b) => b['id'] == _branchId) ? _branchId : null,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true, labelText: 'Goods come back to', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
              items: _branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) => setState(() => _branchId = v),
            )),
            const Spacer(),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
              onPressed: _saving ? null : _reject, child: const Text('Reject')),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _saving ? null : _approve,
              child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Approve')),
          ])),
        ],
      ]),
    );
  }
}
