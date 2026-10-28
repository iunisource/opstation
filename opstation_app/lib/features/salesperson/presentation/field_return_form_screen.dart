import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/photo_url.dart';
import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import '../../orders/data/field_order_repository.dart';
import '../../orders/services/order_photo_capture_service.dart';
import 'field_order_edit_screen.dart';

/// One product on a return request.
class ReturnLine {
  final String productId;
  final String name;
  final String sku;
  final String? uomId;
  double qty;
  ReturnLine({
    required this.productId,
    required this.name,
    required this.sku,
    required this.uomId,
    required this.qty,
  });
}

/// An existing request being changed (null = new request).
class ReturnDraft {
  final String id;
  final String customerId;
  final String customerName;
  final String? invoiceId;
  final String? invoiceNumber;
  final String? reason;
  final String? note;
  final String? photoPath;
  final List<ReturnLine> lines;
  const ReturnDraft({
    required this.id,
    required this.customerId,
    required this.customerName,
    this.invoiceId,
    this.invoiceNumber,
    this.reason,
    this.note,
    this.photoPath,
    required this.lines,
  });
}

const _kReasons = [
  'Damaged',
  'Expired',
  'Wrong product',
  'Not selling',
  'Quality problem',
  'Other',
];

/// Ask the office for a return: shop → (optional) invoice → products →
/// reason → (optional) photo. Needs internet; the office decides the price.
class FieldReturnFormScreen extends ConsumerStatefulWidget {
  final ReturnDraft? existing;
  const FieldReturnFormScreen({super.key, this.existing});

  @override
  ConsumerState<FieldReturnFormScreen> createState() =>
      _FieldReturnFormScreenState();
}

class _FieldReturnFormScreenState extends ConsumerState<FieldReturnFormScreen> {
  late final String _requestId;
  String? _customerId;
  String? _customerName;
  List<Map<String, dynamic>> _invoices = [];
  bool _invoicesLoading = false;
  String? _invoiceId;
  final List<ReturnLine> _lines = [];
  final Map<String, TextEditingController> _qtyCtrls = {};
  String? _reason;
  final _noteCtrl = TextEditingController();
  String? _photoPath;
  bool _photoBusy = false;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _requestId = e?.id ?? 'fr_${DateTime.now().microsecondsSinceEpoch}';
    if (e != null) {
      _customerId = e.customerId;
      _customerName = e.customerName;
      _invoiceId = e.invoiceId;
      _reason = e.reason;
      _noteCtrl.text = e.note ?? '';
      _photoPath = e.photoPath;
      for (final l in e.lines) {
        _addLine(ReturnLine(
            productId: l.productId,
            name: l.name,
            sku: l.sku,
            uomId: l.uomId,
            qty: l.qty));
      }
      _loadInvoices();
    }
  }

  @override
  void dispose() {
    for (final c in _qtyCtrls.values) {
      c.dispose();
    }
    _noteCtrl.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  String _qtyText(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  void _addLine(ReturnLine l) {
    _lines.add(l);
    _qtyCtrls[l.productId] = TextEditingController(text: _qtyText(l.qty));
  }

  void _removeLine(ReturnLine l) {
    setState(() => _lines.remove(l));
    _qtyCtrls.remove(l.productId)?.dispose();
  }

  void _setQty(ReturnLine l, double v) {
    if (v < 0) v = 0;
    setState(() => l.qty = v);
    final c = _qtyCtrls[l.productId];
    if (c != null && c.text != _qtyText(v)) {
      c.text = _qtyText(v);
      c.selection = TextSelection.collapsed(offset: c.text.length);
    }
  }

  // ── Shop ───────────────────────────────────────────────────────────────
  Future<void> _pickShop() async {
    final picked = await showModalBottomSheet<CustomersData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const _ShopPickerSheet(),
    );
    if (picked == null || !mounted) return;
    if (picked.id == _customerId) return;
    setState(() {
      _customerId = picked.id;
      _customerName = picked.shopName;
      _invoiceId = null;
      _invoices = [];
    });
    _loadInvoices();
  }

  Future<void> _loadInvoices() async {
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    final cid = _customerId;
    if (orgId == null || cid == null) return;
    setState(() => _invoicesLoading = true);
    try {
      final res = await Supabase.instance.client.rpc('customer_recent_invoices',
          params: {'p_org': orgId, 'p_customer': cid});
      if (!mounted || cid != _customerId) return;
      setState(() {
        _invoices = [
          if (res is List)
            for (final r in res) Map<String, dynamic>.from(r as Map)
        ];
        _invoicesLoading = false;
        if (_invoiceId != null && !_invoices.any((i) => i['id'] == _invoiceId)) {
          _invoiceId = null;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _invoicesLoading = false);
    }
  }

  Map<String, dynamic>? get _invoice {
    for (final i in _invoices) {
      if (i['id'] == _invoiceId) return i;
    }
    return null;
  }

  // ── Products ───────────────────────────────────────────────────────────
  Future<void> _addFromCatalog() async {
    final picked = await showModalBottomSheet<CatalogProductRow>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const CatalogProductPickerSheet(),
    );
    if (picked == null || !mounted) return;
    if (_lines.any((l) => l.productId == picked.id)) {
      _snack('${picked.name} is already on the list — change its quantity instead.');
      return;
    }
    setState(() => _addLine(ReturnLine(
        productId: picked.id,
        name: picked.name,
        sku: picked.sku ?? '',
        uomId: picked.baseUomId,
        qty: 1)));
  }

  Future<void> _addFromInvoice() async {
    final inv = _invoice;
    if (inv == null) return;
    final items = [
      for (final it in (inv['items'] as List? ?? const []))
        Map<String, dynamic>.from(it as Map)
    ];
    if (items.isEmpty) {
      _snack('This invoice has no products to pick from.');
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text('Products on ${inv['number'] ?? 'this invoice'}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final it in items)
                ListTile(
                  title: Text((it['name'] ?? 'Product').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      'Invoiced: ${_qtyText((it['quantity'] as num?)?.toDouble() ?? 0)}'),
                  trailing: _lines.any((l) => l.productId == it['product_id'])
                      ? const Icon(Icons.check, color: AppColors.success)
                      : null,
                  onTap: () => Navigator.pop(ctx, it),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    final pid = (picked['product_id'] ?? '').toString();
    if (pid.isEmpty) return;
    if (_lines.any((l) => l.productId == pid)) {
      _snack('Already on the list — change its quantity instead.');
      return;
    }
    setState(() => _addLine(ReturnLine(
        productId: pid,
        name: (picked['name'] ?? 'Product').toString(),
        sku: (picked['sku'] ?? '').toString(),
        uomId: picked['uom_id']?.toString(),
        qty: 1)));
  }

  // ── Photo ──────────────────────────────────────────────────────────────
  Future<void> _takePhoto(OrderPhotoSource source) async {
    setState(() => _photoBusy = true);
    try {
      final path = await ref
          .read(orderPhotoCaptureServiceProvider)
          .capture(orderId: 'return_$_requestId', source: source);
      if (path != null && mounted) setState(() => _photoPath = path);
    } catch (e) {
      _snack(fieldOrderErrorText(e));
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  // ── Send ───────────────────────────────────────────────────────────────
  Future<void> _send() async {
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    if (_customerId == null) {
      _snack('Choose the shop first.');
      return;
    }
    final valid = _lines.where((l) => l.qty > 0).toList();
    if (valid.isEmpty) {
      _snack('Add at least one product with a quantity.');
      return;
    }
    if (_reason == null) {
      _snack('Choose a reason for the return.');
      return;
    }
    if (_reason == 'Other' && _noteCtrl.text.trim().isEmpty) {
      _snack('Please write a short note explaining the reason.');
      return;
    }
    setState(() => _saving = true);
    final items = [
      for (final l in valid)
        {'product_id': l.productId, 'uom_id': l.uomId, 'quantity': l.qty}
    ];
    try {
      final client = Supabase.instance.client;
      if (_isEdit) {
        await client.rpc('update_field_return', params: {
          'p_id': _requestId,
          'p_items': items,
          'p_reason': _reason,
          'p_note': _noteCtrl.text.trim(),
          'p_invoice_id': _invoiceId,
          'p_photo_path': _photoPath,
        });
      } else {
        await client.rpc('submit_field_return', params: {
          'p_org': orgId,
          'p_customer': _customerId,
          'p_items': items,
          'p_reason': _reason,
          'p_note': _noteCtrl.text.trim(),
          'p_invoice_id': _invoiceId,
          'p_photo_path': _photoPath,
          'p_id': _requestId,
        });
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(fieldOrderErrorText(e));
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: Text(_isEdit ? 'Change return request' : 'New return request'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimaryLight,
        elevation: 0.5,
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _section('Shop', [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.storefront_outlined,
                    color: AppColors.primary),
                title: Text(_customerName ?? 'Choose shop',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _customerName == null
                            ? AppColors.textSecondaryLight
                            : AppColors.textPrimaryLight)),
                trailing: _isEdit ? null : const Icon(Icons.chevron_right),
                onTap: _isEdit ? null : _pickShop,
              ),
            ]),
            if (_customerId != null)
              _section('Invoice (optional)', [
                if (_invoicesLoading)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: LinearProgressIndicator(),
                  )
                else if (_invoices.isEmpty)
                  Text('No recent invoices found for this shop.',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textSecondaryLight))
                else
                  DropdownButtonFormField<String?>(
                    value: _invoiceId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        isDense: true, border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('Not linked to an invoice')),
                      for (final i in _invoices)
                        DropdownMenuItem<String?>(
                          value: i['id'] as String?,
                          child: Text(
                              '${i['number'] ?? ''}  ·  ${_shortDate(i['date'])}',
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _invoiceId = v),
                  ),
              ]),
            _section('Products to return', [
              if (_lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('No products yet.',
                      style: TextStyle(color: AppColors.textSecondaryLight)),
                ),
              for (final l in _lines) _lineRow(l),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (_invoice != null)
                  OutlinedButton.icon(
                    onPressed: _addFromInvoice,
                    icon: const Icon(Icons.receipt_outlined, size: 18),
                    label: const Text('From invoice'),
                  ),
                OutlinedButton.icon(
                  onPressed: _addFromCatalog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add product'),
                ),
              ]),
            ]),
            _section('Reason', [
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final r in _kReasons)
                  ChoiceChip(
                    label: Text(r),
                    selected: _reason == r,
                    onSelected: (_) => setState(() => _reason = r),
                  ),
              ]),
              const SizedBox(height: 10),
              TextField(
                controller: _noteCtrl,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText:
                      _reason == 'Other' ? 'Note (required)' : 'Note (optional)',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ]),
            _section('Photo (optional)', [
              if (_photoPath != null)
                Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(PhotoUrl.build(_photoPath!),
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                            height: 60,
                            alignment: Alignment.center,
                            child: const Text('Photo added'))),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Material(
                      color: Colors.white,
                      shape: const CircleBorder(),
                      child: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _photoPath = null),
                      ),
                    ),
                  ),
                ])
              else if (_photoBusy)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: LinearProgressIndicator(),
                )
              else
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: () => _takePhoto(OrderPhotoSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: const Text('Camera'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _takePhoto(OrderPhotoSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('Gallery'),
                  ),
                ]),
            ]),
            const SizedBox(height: 8),
            Text(
                'The office decides the return price. The delivery driver will bring the goods back.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondaryLight)),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ElevatedButton(
            onPressed: _saving || _photoBusy ? null : _send,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(_isEdit ? 'Save changes' : 'Send to office'),
          ),
        ),
      ),
    );
  }

  String _shortDate(dynamic v) {
    final d = DateTime.tryParse((v ?? '').toString());
    if (d == null) return '';
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }

  Widget _section(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: AppColors.textTertiaryLight)),
          const SizedBox(height: 8),
          ...children,
        ]),
      );

  Widget _lineRow(ReturnLine l) {
    final ctrl = _qtyCtrls[l.productId]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
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
          ]),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: l.qty <= 1 ? null : () => _setQty(l, l.qty - 1),
        ),
        SizedBox(
          width: 54,
          child: TextField(
            controller: ctrl,
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
          onPressed: () => _setQty(l, l.qty + 1),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.delete_outline, color: AppColors.danger),
          onPressed: () => _removeLine(l),
        ),
      ]),
    );
  }
}

/// Search the shops saved on the phone.
class _ShopPickerSheet extends ConsumerStatefulWidget {
  const _ShopPickerSheet();
  @override
  ConsumerState<_ShopPickerSheet> createState() => _ShopPickerSheetState();
}

class _ShopPickerSheetState extends ConsumerState<_ShopPickerSheet> {
  List<CustomersData> _rows = [];
  bool _loading = true;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String q) async {
    final my = ++_seq;
    try {
      final rows =
          await ref.read(fieldOrderRepositoryProvider).searchCustomers(q);
      if (!mounted || my != _seq) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                child: Text('Choose shop',
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
                hintText: 'Search shop name or code',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: _search,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(
                        child: Text('No shops found.',
                            style: TextStyle(
                                color: AppColors.textSecondaryLight)))
                    : ListView.separated(
                        itemCount: _rows.length > 200 ? 200 : _rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final c = _rows[i];
                          return ListTile(
                            title: Text(c.shopName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                                [c.code, c.address]
                                    .where((s) => s.trim().isNotEmpty)
                                    .join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            onTap: () => Navigator.pop(context, c),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}
