import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

// ============================================================================
// QUOTATION VOUCHER  (Sales module)
// Non-posting document. No GL, no inventory. Exports to SO(Draft) or POS drawer.
// Catalog products only: every line has a real product_id + uom_id.
// ============================================================================

class ErpQuotationScreen extends ConsumerStatefulWidget {
  const ErpQuotationScreen({super.key});
  @override
  ConsumerState<ErpQuotationScreen> createState() => _ErpQuotationScreenState();
}

class _ErpQuotationScreenState extends ConsumerState<ErpQuotationScreen> {
  final _client = Supabase.instance.client;
  String? orgId;
  String? branchId;

  bool _loading = true;
  bool _saving = false;
  String _statusFilter = 'all';
  String _search = '';

  List<Map<String, dynamic>> _list = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _branches = [];

  // Working document (null = list view, non-null = editing/creating)
  Map<String, dynamic>? _doc;              // header
  List<Map<String, dynamic>> _lines = [];  // working lines

  final _notesCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    orgId = ref.read(currentUserProvider)?.orgId;
    branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    await _loadRefs();
    await _loadList();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadRefs() async {
    if (orgId == null) return;
    try {
      final prods = await _client
          .from('products')
          .select('id, name, sku, selling_price, cost_price, base_uom_id, uoms:base_uom_id(name, abbreviation)')
          .eq('org_id', orgId!)
          .eq('is_active', true)
          .order('name');
      final custs = await _client
          .from('customers')
          .select('id, shop_name, phone')
          .eq('org_id', orgId!)
          .order('shop_name');
      final brs = await _client
          .from('branches')
          .select('id, name')
          .eq('org_id', orgId!)
          .eq('is_active', true)
          .order('name');
      if (!mounted) return;
      setState(() {
        _products = List<Map<String, dynamic>>.from(prods);
        _customers = List<Map<String, dynamic>>.from(custs);
        _branches = List<Map<String, dynamic>>.from(brs);
      });
    } catch (_) {}
  }

  Future<void> _loadList() async {
    if (orgId == null) return;
    try {
      final rows = await _client
          .from('quotations')
          .select('*, customers(shop_name), branches(name)')
          .eq('org_id', orgId!)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() => _list = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  // ── Line math ──────────────────────────────────────────────────────────────
  double _lineTotal(Map<String, dynamic> l) {
    final qty = (l['quantity'] as num?)?.toDouble() ?? 0;
    final price = (l['unit_price'] as num?)?.toDouble() ?? 0;
    final d = (l['discount'] as num?)?.toDouble() ?? 0;
    final dt = l['discount_type'] as String? ?? 'fixed';
    final gross = qty * price;
    final da = dt == 'percent' ? gross * d.clamp(0, 100) / 100 : d.clamp(0, gross);
    return gross - da;
  }

  double get _docTotal => _lines.fold(0.0, (s, l) => s + _lineTotal(l));

  // ── New / open / edit ────────────────────────────────────────────────────
  void _newDoc() {
    setState(() {
      _doc = {
        'customer_id': null,
        'branch_id': branchId,
        'voucher_date': DateTime.now(),
        'valid_until': null,
        'status': 'draft',
      };
      _lines = [];
      _notesCtrl.clear();
    });
  }

  Future<void> _openDoc(Map<String, dynamic> row) async {
    try {
      final items = await _client
          .from('quotation_items')
          .select('*')
          .eq('quotation_id', row['id'] as String)
          .order('sr_no');
      if (!mounted) return;
      setState(() {
        _doc = {
          'id': row['id'],
          'customer_id': row['customer_id'],
          'branch_id': row['branch_id'],
          'voucher_number': row['voucher_number'],
          'voucher_date': row['voucher_date'] != null ? DateTime.parse(row['voucher_date'] as String) : DateTime.now(),
          'valid_until': row['valid_until'] != null ? DateTime.parse(row['valid_until'] as String) : null,
          'status': row['status'] ?? 'draft',
        };
        _lines = List<Map<String, dynamic>>.from(items).map((it) => {
              'product_id': it['product_id'],
              'item_name': it['item_name'],
              'uom_id': it['uom_id'],
              'quantity': (it['quantity'] as num?)?.toDouble() ?? 1,
              'unit_price': (it['unit_price'] as num?)?.toDouble() ?? 0,
              'discount': (it['discount'] as num?)?.toDouble() ?? 0,
              'discount_type': it['discount_type'] ?? 'fixed',
            }).toList();
        _notesCtrl.text = row['notes'] as String? ?? '';
      });
    } catch (_) {}
  }

  void _closeDoc() => setState(() { _doc = null; _lines = []; });

  void _addLine() {
    setState(() => _lines.add({
          'product_id': null,
          'item_name': null,
          'uom_id': null,
          'quantity': 1.0,
          'unit_price': 0.0,
          'discount': 0.0,
          'discount_type': 'fixed',
        }));
  }

  void _pickProduct(int idx, Map<String, dynamic> p) {
    setState(() {
      _lines[idx]['product_id'] = p['id'];
      _lines[idx]['item_name'] = p['name'];
      _lines[idx]['uom_id'] = p['base_uom_id'];
      _lines[idx]['unit_price'] = (p['selling_price'] as num?)?.toDouble() ?? 0.0;
    });
  }

  // ── Save ─────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (_doc == null || orgId == null) return;
    if (_doc!['branch_id'] == null) { _toast('Select a branch'); return; }
    if (_lines.isEmpty) { _toast('Add at least one line'); return; }
    if (_lines.any((l) => l['product_id'] == null)) { _toast('Every line needs a product'); return; }

    setState(() => _saving = true);
    try {
      final isNew = _doc!['id'] == null;
      String qid = _doc!['id'] as String? ?? 'qt_${DateTime.now().microsecondsSinceEpoch}';
      String? vnum = _doc!['voucher_number'] as String?;

      if (isNew) {
        final y = DateTime.now().year;
        try {
          vnum = await _client.rpc('next_voucher_number', params: {
            'p_org_id': orgId, 'p_branch_id': _doc!['branch_id'], 'p_type': 'QT', 'p_year': y,
          }) as String?;
        } catch (_) { vnum = null; }
      }

      final header = {
        'id': qid,
        'org_id': orgId,
        'branch_id': _doc!['branch_id'],
        'customer_id': _doc!['customer_id'],
        'voucher_number': vnum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(_doc!['voucher_date'] as DateTime),
        'valid_until': _doc!['valid_until'] != null ? DateFormat('yyyy-MM-dd').format(_doc!['valid_until'] as DateTime) : null,
        'status': _doc!['status'] ?? 'draft',
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (isNew) {
        header['created_by'] = ref.read(currentUserProvider)?.id;
        await _client.from('quotations').insert(header);
      } else {
        await _client.from('quotations').update(header).eq('id', qid);
        await _client.from('quotation_items').delete().eq('quotation_id', qid);
      }

      int sr = 1;
      final itemRows = _lines.map((l) => {
            'id': 'qti_${DateTime.now().microsecondsSinceEpoch}_${sr}',
            'quotation_id': qid,
            'org_id': orgId,
            'sr_no': sr++,
            'product_id': l['product_id'],
            'item_name': l['item_name'],
            'uom_id': l['uom_id'],
            'quantity': (l['quantity'] as num?)?.toDouble() ?? 1,
            'unit_price': (l['unit_price'] as num?)?.toDouble() ?? 0,
            'discount': (l['discount'] as num?)?.toDouble() ?? 0,
            'discount_type': l['discount_type'] ?? 'fixed',
            'line_total': _lineTotal(l),
          }).toList();
      await _client.from('quotation_items').insert(itemRows);

      _doc!['id'] = qid;
      _doc!['voucher_number'] = vnum;
      if (!mounted) return;
      _toast('Quotation ${vnum ?? ''} saved');
      await _loadList();
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Save failed: $e');
    }
  }

  // ── Export ─────────────────────────────────────────────────────────────────
  Future<void> _exportDialog() async {
    if (_doc == null) return;
    if (_doc!['id'] == null) { _toast('Save the quotation first'); return; }
    final choice = await showDialog<String>(
      context: context,
      builder: (dctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 4), child: Row(children: [
              const Icon(Icons.ios_share, size: 20, color: AppTheme.primary),
              const SizedBox(width: 8),
              const Text('Export Quotation', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(dctx)),
            ])),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.description_outlined, color: AppTheme.primary),
              title: const Text('Sales Order (Draft)', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Create a draft SO with these lines'),
              onTap: () => Navigator.pop(dctx, 'so'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.point_of_sale, color: AppTheme.primary),
              title: const Text('POS Drawer', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text("Send to the branch's open POS session as a held bill"),
              onTap: () => Navigator.pop(dctx, 'pos'),
            ),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
    if (choice == 'so') await _exportToSO();
    if (choice == 'pos') await _exportToPOS();
  }

  Future<void> _exportToSO() async {
    if (orgId == null || _doc == null) return;
    setState(() => _saving = true);
    try {
      final y = DateTime.now().year;
      String? soVnum;
      try {
        soVnum = await _client.rpc('next_voucher_number', params: {
          'p_org_id': orgId, 'p_branch_id': _doc!['branch_id'], 'p_type': 'SO', 'p_year': y,
        }) as String?;
      } catch (_) { soVnum = null; }

      final soId = 'so_${DateTime.now().microsecondsSinceEpoch}';
      await _client.from('sales_orders').insert({
        'id': soId,
        'org_id': orgId,
        'customer_id': _doc!['customer_id'],
        'branch_id': _doc!['branch_id'],
        'status': 'draft',
        'is_locked': false,
        'source': 'quotation',
        'voucher_number': soVnum,
        'voucher_date': DateFormat('yyyy-MM-dd').format(_doc!['voucher_date'] as DateTime),
        'notes': 'From quotation ${_doc!['voucher_number'] ?? ''}',
        'created_by': ref.read(currentUserProvider)?.id,
        'ordered_at': DateTime.now().toIso8601String(),
      });

      final soItems = _lines.map((l) => {
            'id': 'soi_${DateTime.now().microsecondsSinceEpoch}_${_lines.indexOf(l)}',
            'sales_order_id': soId,
            'product_id': l['product_id'],
            'uom_id': l['uom_id'],
            'quantity': (l['quantity'] as num?)?.toDouble() ?? 1,
            'unit_price': (l['unit_price'] as num?)?.toDouble() ?? 0,
            'discount': (l['discount'] as num?)?.toDouble() ?? 0,
            'qty_delivered': 0,
            'is_foc': false,
          }).toList();
      await _client.from('sales_order_items').insert(soItems);

      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Draft SO ${soVnum ?? ''} created');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('SO export failed: $e');
    }
  }

  Future<void> _exportToPOS() async {
    if (orgId == null || _doc == null) return;
    setState(() => _saving = true);
    try {
      // Find an OPEN POS session for this branch.
      final sessions = await _client
          .from('pos_sessions')
          .select('id, branch_id, status')
          .eq('org_id', orgId!)
          .eq('branch_id', _doc!['branch_id'])
          .eq('status', 'open')
          .order('opened_at', ascending: false)
          .limit(1);
      final list = List<Map<String, dynamic>>.from(sessions);
      if (list.isEmpty) {
        if (!mounted) return;
        setState(() => _saving = false);
        final bname = _branches.firstWhere((b) => b['id'] == _doc!['branch_id'], orElse: () => {'name': 'this branch'})['name'];
        _toast('No open POS session for $bname — open one first');
        return;
      }
      final sessionId = list.first['id'] as String;

      // Build the held-bill items jsonb from the quotation lines.
      final items = _lines.map((l) => {
            'product_id': l['product_id'],
            'name': l['item_name'],
            'uom_id': l['uom_id'],
            'quantity': (l['quantity'] as num?)?.toDouble() ?? 1,
            'unit_price': (l['unit_price'] as num?)?.toDouble() ?? 0,
            'discount': (l['discount'] as num?)?.toDouble() ?? 0,
            'discount_type': l['discount_type'] ?? 'fixed',
          }).toList();

      final custName = _doc!['customer_id'] != null
          ? (_customers.firstWhere((c) => c['id'] == _doc!['customer_id'], orElse: () => {'shop_name': 'Walk-in'})['shop_name'] as String?)
          : 'Walk-in';

      await _client.from('pos_held_bills').insert({
        'id': 'hb_${DateTime.now().microsecondsSinceEpoch}',
        'org_id': orgId,
        'branch_id': _doc!['branch_id'],
        'session_id': sessionId,
        'customer_id': _doc!['customer_id'],
        'customer_name': custName,
        'items': items,
        'order_discount': 0,
        'order_discount_type': 'fixed',
        'payment_method': 'cash',
        'total': _docTotal,
        'held_by': ref.read(currentUserProvider)?.id,
        'held_at': DateTime.now().toIso8601String(),
        'status': 'held',
      });

      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Sent to POS Holds (${_doc!['voucher_number'] ?? ''})');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('POS export failed: $e');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return _doc == null ? _buildList() : _buildEditor();
  }

  Widget _buildList() {
    final q = _search.trim().toLowerCase();
    final rows = _list.where((r) {
      if (_statusFilter != 'all' && (r['status'] ?? 'draft') != _statusFilter) return false;
      if (q.isEmpty) return true;
      final vn = (r['voucher_number'] as String? ?? '').toLowerCase();
      final cn = (r['customers']?['shop_name'] as String? ?? '').toLowerCase();
      return vn.contains(q) || cn.contains(q);
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Quotations', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _newDoc,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Quotation'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
          ),
        ]),
        const SizedBox(height: 4),
        Text('${_list.length} quotations', style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: TextField(
            decoration: InputDecoration(
              hintText: 'Search by number or customer...',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true, filled: true, fillColor: const Color(0xFFF8F9FA),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
            onChanged: (v) => setState(() => _search = v),
          )),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _statusFilter,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(value: 'draft', child: Text('Draft')),
              DropdownMenuItem(value: 'sent', child: Text('Sent')),
              DropdownMenuItem(value: 'converted', child: Text('Converted')),
              DropdownMenuItem(value: 'expired', child: Text('Expired')),
            ],
            onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
          ),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
          child: Row(children: const [
            Expanded(flex: 2, child: Text('Number', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 3, child: Text('Customer', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Valid Until', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: rows.isEmpty
          ? const Center(child: Text('No quotations', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = rows[i];
                final status = r['status'] as String? ?? 'draft';
                return InkWell(
                  onTap: () => _openDoc(r),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(children: [
                      Expanded(flex: 2, child: Text(r['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary))),
                      Expanded(flex: 3, child: Text(r['customers']?['shop_name'] as String? ?? 'Walk-in', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Text(r['branches']?['name'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text(r['voucher_date'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text(r['valid_until'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: _statusChip(status)),
                    ]),
                  ),
                );
              },
            )),
      ]),
    );
  }

  Widget _statusChip(String s) {
    Color c;
    switch (s) {
      case 'converted': c = Colors.green; break;
      case 'sent': c = AppTheme.primary; break;
      case 'expired': c = Colors.red; break;
      default: c = Colors.grey;
    }
    return Align(alignment: Alignment.centerLeft, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(s[0].toUpperCase() + s.substring(1), style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700)),
    ));
  }

  Widget _buildEditor() {
    final isNew = _doc!['id'] == null;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: _closeDoc),
          const SizedBox(width: 4),
          Text(isNew ? 'New Quotation' : (_doc!['voucher_number'] as String? ?? 'Quotation'),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (!isNew) OutlinedButton.icon(
            onPressed: _saving ? null : _exportDialog,
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('Export'),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 18),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
          ),
        ]),
        const SizedBox(height: 16),
        // Header fields
        Wrap(spacing: 16, runSpacing: 12, children: [
          _field('Customer', SizedBox(width: 260, child: DropdownButtonFormField<String?>(
            value: _doc!['customer_id'] as String?,
            isExpanded: true,
            decoration: _dec(),
            hint: const Text('Walk-in / none'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('Walk-in / none')),
              ..._customers.map((c) => DropdownMenuItem<String?>(value: c['id'] as String, child: Text(c['shop_name'] as String? ?? '-', overflow: TextOverflow.ellipsis))),
            ],
            onChanged: (v) => setState(() => _doc!['customer_id'] = v),
          ))),
          _field('Branch', SizedBox(width: 220, child: DropdownButtonFormField<String>(
            value: _doc!['branch_id'] as String?,
            isExpanded: true,
            decoration: _dec(),
            items: _branches.map((b) => DropdownMenuItem<String>(value: b['id'] as String, child: Text(b['name'] as String? ?? '-', overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setState(() => _doc!['branch_id'] = v),
          ))),
          _field('Date', SizedBox(width: 160, child: InkWell(
            onTap: () async {
              final d = await showDatePicker(context: context, initialDate: _doc!['voucher_date'] as DateTime, firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) setState(() => _doc!['voucher_date'] = d);
            },
            child: InputDecorator(decoration: _dec(), child: Text(DateFormat('dd MMM yyyy').format(_doc!['voucher_date'] as DateTime), style: const TextStyle(fontSize: 13))),
          ))),
          _field('Valid Until (optional)', SizedBox(width: 180, child: InkWell(
            onTap: () async {
              final d = await showDatePicker(context: context, initialDate: (_doc!['valid_until'] as DateTime?) ?? DateTime.now().add(const Duration(days: 15)), firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) setState(() => _doc!['valid_until'] = d);
            },
            child: InputDecorator(decoration: _dec(), child: Row(children: [
              Expanded(child: Text(_doc!['valid_until'] != null ? DateFormat('dd MMM yyyy').format(_doc!['valid_until'] as DateTime) : '—', style: const TextStyle(fontSize: 13))),
              if (_doc!['valid_until'] != null) InkWell(onTap: () => setState(() => _doc!['valid_until'] = null), child: const Icon(Icons.clear, size: 14)),
            ])),
          ))),
        ]),
        const SizedBox(height: 20),
        // Lines header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
          child: Row(children: const [
            SizedBox(width: 40, child: Text('Sr#', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 4, child: Text('Item', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 1, child: Text('UoM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Rate', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Discount', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            SizedBox(width: 40),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: ListView.separated(
          itemCount: _lines.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) => _lineRow(i),
        )),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
          TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 18), label: const Text('Add Line')),
          const Spacer(),
          const Text('Total  ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          Text('Rs. ${_docTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          const SizedBox(width: 8),
        ])),
        SizedBox(width: 420, child: TextField(
          controller: _notesCtrl,
          decoration: InputDecoration(labelText: 'Notes (optional)', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          maxLines: 2,
        )),
      ]),
    );
  }

  Widget _lineRow(int i) {
    final l = _lines[i];
    final prod = _products.firstWhere((p) => p['id'] == l['product_id'], orElse: () => {});
    final uomAbbr = prod.isEmpty ? '-' : ((prod['uoms']?['abbreviation'] as String?) ?? (prod['uoms']?['name'] as String?) ?? '-');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        SizedBox(width: 40, child: Text('${i + 1}', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        Expanded(flex: 4, child: InkWell(
          onTap: () => _productPicker(i),
          child: InputDecorator(
            decoration: _dec(),
            child: Text(l['item_name'] as String? ?? '+ Select product',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: l['item_name'] == null ? AppTheme.textSecondary : Colors.black87)),
          ),
        )),
        Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(uomAbbr, style: const TextStyle(fontSize: 13)))),
        Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: TextFormField(
          initialValue: (l['quantity'] as num?)?.toString() ?? '1',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: _dec(),
          style: const TextStyle(fontSize: 13),
          onChanged: (v) => setState(() => l['quantity'] = double.tryParse(v) ?? 0),
        ))),
        Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: TextFormField(
          initialValue: (l['unit_price'] as num?)?.toStringAsFixed(2) ?? '0',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: _dec(),
          style: const TextStyle(fontSize: 13),
          onChanged: (v) => setState(() => l['unit_price'] = double.tryParse(v) ?? 0),
        ))),
        Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Row(children: [
          Expanded(child: TextFormField(
            initialValue: (l['discount'] as num?)?.toString() ?? '0',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _dec(),
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => setState(() => l['discount'] = double.tryParse(v) ?? 0),
          )),
          const SizedBox(width: 4),
          DropdownButton<String>(
            value: l['discount_type'] as String? ?? 'fixed',
            underline: const SizedBox(),
            isDense: true,
            items: const [DropdownMenuItem(value: 'fixed', child: Text('Rs', style: TextStyle(fontSize: 12))), DropdownMenuItem(value: 'percent', child: Text('%', style: TextStyle(fontSize: 12)))],
            onChanged: (v) => setState(() => l['discount_type'] = v),
          ),
        ]))),
        Expanded(flex: 2, child: Text('Rs. ${_lineTotal(l).toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        SizedBox(width: 40, child: IconButton(
          icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() => _lines.removeAt(i)),
        )),
      ]),
    );
  }

  Future<void> _productPicker(int idx) async {
    String q = '';
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setModal) {
        final ql = q.trim().toLowerCase();
        final filtered = ql.isEmpty
            ? _products.take(50).toList()
            : _products.where((p) =>
                (p['name'] as String? ?? '').toLowerCase().contains(ql) ||
                (p['sku'] as String? ?? '').toLowerCase().contains(ql)).take(50).toList();
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(padding: const EdgeInsets.fromLTRB(18, 16, 12, 8), child: Row(children: [
                const Text('Select Product', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(dctx)),
              ])),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(
                autofocus: true,
                decoration: InputDecoration(hintText: 'Search name or SKU...', prefixIcon: const Icon(Icons.search, size: 18), isDense: true, filled: true, fillColor: const Color(0xFFF8F9FA), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none)),
                onChanged: (v) => setModal(() => q = v),
              )),
              const Divider(height: 1),
              Flexible(child: ListView.separated(
                shrinkWrap: true,
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, k) {
                  final p = filtered[k];
                  return ListTile(
                    dense: true,
                    title: Text(p['name'] as String? ?? '-', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text('SKU ${p['sku'] ?? '-'}  ·  Rs. ${(p['selling_price'] as num?)?.toStringAsFixed(2) ?? '0'}', style: const TextStyle(fontSize: 11)),
                    onTap: () => Navigator.pop(dctx, p),
                  );
                },
              )),
            ]),
          ),
        );
      }),
    );
    if (picked != null) _pickProduct(idx, picked);
  }

  Widget _field(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        child,
      ]);

  InputDecoration _dec() => InputDecoration(
        isDense: true,
        filled: true, fillColor: const Color(0xFFF8F9FA),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      );
}
