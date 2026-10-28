import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/pdf/pdf_output.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../services/quotation_design.dart';

// ============================================================================
// QUOTATION BRANDS — the business's brands, each with its own details, logo
// and a generated quotation design. Managed by admins from the Quotation page.
// ============================================================================

Future<List<Map<String, dynamic>>> loadQuotationBrands(String orgId, {bool activeOnly = true}) async {
  try {
    var q = Supabase.instance.client.from('quotation_brands').select().eq('org_id', orgId);
    if (activeOnly) q = q.eq('is_active', true);
    final rows = await q.order('name');
    return List<Map<String, dynamic>>.from(rows as List);
  } catch (_) {
    return [];
  }
}

String describeDesign(QuoteDesign d) {
  const head = {
    'band': 'Colour banner header', 'split': 'Classic header', 'centered': 'Centred header',
    'minimal': 'Minimal header', 'sidebar': 'Side-bar header', 'boxed': 'Boxed header', 'stripe': 'Top-stripe header',
  };
  const tbl = {'grid': 'grid table', 'striped': 'striped table', 'lines': 'lined table', 'minimal': 'open table', 'boxed': 'boxed table'};
  return [
    head[d.s('header', 'split')] ?? 'Classic header',
    'logo ${d.s('logo', 'left')}',
    tbl[d.s('table', 'grid')] ?? 'table',
    d.s('font', 'helvetica') == 'times' ? 'serif font' : 'sans font',
    'totals ${d.s('totals', 'right')}',
  ].join(' · ');
}

Future<void> showBrandManager(BuildContext context, String orgId) =>
    showDialog(context: context, builder: (_) => _BrandManager(orgId: orgId));

class _BrandManager extends StatefulWidget {
  final String orgId;
  const _BrandManager({required this.orgId});
  @override
  State<_BrandManager> createState() => _BrandManagerState();
}

class _BrandManagerState extends State<_BrandManager> {
  List<Map<String, dynamic>> _brands = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await loadQuotationBrands(widget.orgId, activeOnly: false);
    if (mounted) setState(() { _brands = b; _loading = false; });
  }

  Future<void> _edit([Map<String, dynamic>? b]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _BrandEditor(orgId: widget.orgId, brand: b));
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        const Expanded(child: Text('Quotation brands')),
        FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add, size: 18), label: const Text('Add brand')),
      ]),
      content: SizedBox(
        width: 560,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _brands.isEmpty
                ? const Center(
                    child: Text('No brands yet. Add a brand to quote under its own name, logo and design.',
                        textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: _brands.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final b = _brands[i];
                      final d = QuoteDesign(Map<String, dynamic>.from((b['design'] as Map?) ?? const {}));
                      final active = b['is_active'] != false;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Color(d.i('accent', QuoteDesign.palette.first)),
                          child: Text('${b['name']}'.isEmpty ? '?' : '${b['name']}'[0].toUpperCase(),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                        ),
                        title: Text('${b['name']}${active ? '' : '  (hidden)'}',
                            style: TextStyle(fontWeight: FontWeight.w600, color: active ? null : AppTheme.textSecondary)),
                        subtitle: Text(describeDesign(d), style: const TextStyle(fontSize: 12)),
                        trailing: const Icon(Icons.edit_outlined, size: 18),
                        onTap: () => _edit(b),
                      );
                    },
                  ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

class _BrandEditor extends StatefulWidget {
  final String orgId;
  final Map<String, dynamic>? brand;
  const _BrandEditor({required this.orgId, this.brand});
  @override
  State<_BrandEditor> createState() => _BrandEditorState();
}

class _BrandEditorState extends State<_BrandEditor> {
  late final _name = TextEditingController(text: '${widget.brand?['name'] ?? ''}');
  late final _tagline = TextEditingController(text: '${widget.brand?['tagline'] ?? ''}');
  late final _phone = TextEditingController(text: '${widget.brand?['phone'] ?? ''}');
  late final _email = TextEditingController(text: '${widget.brand?['email'] ?? ''}');
  late final _address = TextEditingController(text: '${widget.brand?['address'] ?? ''}');
  late final _website = TextEditingController(text: '${widget.brand?['website'] ?? ''}');
  late final _tax = TextEditingController(text: '${widget.brand?['tax_no'] ?? ''}');
  late final _footer = TextEditingController(text: '${widget.brand?['footer'] ?? ''}');
  late final _prefix = TextEditingController(text: '${widget.brand?['number_prefix'] ?? ''}');
  late bool _numYear = widget.brand?['number_year'] != false;
  late int _numDigits = (widget.brand?['number_digits'] as num?)?.toInt() ?? 4;
  late String _numSep = (widget.brand?['number_sep'] as String?) ?? '-';
  String? _logo; // data: URI
  late QuoteDesign _design;
  final List<QuoteDesign> _history = [];
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _logo = widget.brand?['logo_data'] as String?;
    _active = widget.brand?['is_active'] != false;
    final d = widget.brand?['design'];
    _design = (d is Map && d.isNotEmpty) ? QuoteDesign(Map<String, dynamic>.from(d)) : QuoteDesign.generate();
  }

  @override
  void dispose() {
    for (final c in [_name, _tagline, _phone, _email, _address, _website, _tax, _footer, _prefix]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  QuoteBrand get _brandNow => QuoteBrand(
        name: _name.text.trim().isEmpty ? 'Brand name' : _name.text.trim(),
        tagline: _tagline.text, phone: _phone.text, email: _email.text, address: _address.text,
        website: _website.text, taxNo: _tax.text, footer: _footer.text,
        logo: QuoteBrand.logoFromData(_logo),
      );

  Future<void> _pickLogo() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg'], withData: true);
    final f = res?.files.single;
    if (f?.bytes == null) return;
    if (f!.bytes!.length > 300 * 1024) {
      _snack('Logo is too large — please use an image under 300 KB.');
      return;
    }
    final ext = (f.extension ?? 'png').toLowerCase();
    setState(() => _logo = 'data:image/${ext == 'jpg' ? 'jpeg' : ext};base64,${base64Encode(f.bytes!)}');
  }

  // Prefix typed by the user, else the first 3 letters of the brand name.
  String get _prefixNow {
    final t = _prefix.text.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (t.isNotEmpty) return t;
    final n = _name.text.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    return n.isEmpty ? 'QB' : n.substring(0, n.length < 3 ? n.length : 3);
  }

  String get _numberExample =>
      '$_prefixNow$_numSep${_numYear ? '${DateTime.now().year}$_numSep' : ''}${'1'.padLeft(_numDigits, '0')}';

  void _generate() => setState(() {
        _history.add(_design);
        _design = QuoteDesign.generate(avoid: _design);
      });

  void _previous() {
    if (_history.isEmpty) return;
    setState(() => _design = _history.removeLast());
  }

  Future<void> _preview() async {
    try {
      final bytes = await buildBrandQuotationPdf(_design, _brandNow, QuoteData.sample());
      await showPdf(bytes, 'quotation-preview.pdf');
    } catch (e) {
      _snack(friendlyError('Could not show the preview', e));
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Enter the brand name');
      return;
    }
    setState(() => _saving = true);
    final row = {
      'org_id': widget.orgId,
      'name': _name.text.trim(),
      'tagline': _tagline.text.trim().isEmpty ? null : _tagline.text.trim(),
      'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      'email': _email.text.trim().isEmpty ? null : _email.text.trim(),
      'address': _address.text.trim().isEmpty ? null : _address.text.trim(),
      'website': _website.text.trim().isEmpty ? null : _website.text.trim(),
      'tax_no': _tax.text.trim().isEmpty ? null : _tax.text.trim(),
      'footer': _footer.text.trim().isEmpty ? null : _footer.text.trim(),
      'logo_data': _logo,
      'design': _design.p,
      'number_prefix': _prefixNow,
      'number_year': _numYear,
      'number_digits': _numDigits,
      'number_sep': _numSep,
      'is_active': _active,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final c = Supabase.instance.client;
      if (widget.brand == null) {
        await c.from('quotation_brands').insert(row);
      } else {
        await c.from('quotation_brands').update(row).eq('id', widget.brand!['id'] as String);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack(friendlyError('Could not save the brand', e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _dec(String l, {String? hint}) =>
      InputDecoration(labelText: l, hintText: hint, isDense: true, border: const OutlineInputBorder());

  @override
  Widget build(BuildContext context) {
    final logoBytes = QuoteBrand.logoFromData(_logo);
    final accent = Color(_design.i('accent', QuoteDesign.palette.first));
    return AlertDialog(
      title: Text(widget.brand == null ? 'Add brand' : 'Edit brand'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 10, runSpacing: 10, children: [
              SizedBox(width: 290, child: TextField(controller: _name, decoration: _dec('Brand name *'), onChanged: (_) => setState(() {}))),
              SizedBox(width: 290, child: TextField(controller: _tagline, decoration: _dec('Tagline', hint: 'e.g. Quality lighting since 1998'))),
              SizedBox(width: 290, child: TextField(controller: _phone, decoration: _dec('Phone'))),
              SizedBox(width: 290, child: TextField(controller: _email, decoration: _dec('Email'))),
              SizedBox(width: 590, child: TextField(controller: _address, decoration: _dec('Address'))),
              SizedBox(width: 290, child: TextField(controller: _website, decoration: _dec('Website'))),
              SizedBox(width: 290, child: TextField(controller: _tax, decoration: _dec('NTN / STRN'))),
              SizedBox(width: 590, child: TextField(controller: _footer, decoration: _dec('Footer line', hint: 'e.g. Thank you for your business'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Container(
                width: 64, height: 48,
                decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
                child: logoBytes == null
                    ? const Icon(Icons.image_outlined, color: AppTheme.textSecondary)
                    : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(logoBytes, fit: BoxFit.contain)),
              ),
              const SizedBox(width: 10),
              OutlinedButton(onPressed: _pickLogo, child: Text(logoBytes == null ? 'Add logo' : 'Change logo')),
              if (logoBytes != null) TextButton(onPressed: () => setState(() => _logo = null), child: const Text('Remove')),
              const Spacer(),
              const Text('Show on quotations'),
              Switch(value: _active, onChanged: (v) => setState(() => _active = v)),
            ]),
            const Divider(height: 26),
            const Text('Quote number', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 130, child: TextField(
                controller: _prefix,
                textCapitalization: TextCapitalization.characters,
                decoration: _dec('Prefix', hint: _prefixNow),
                onChanged: (_) => setState(() {}),
              )),
              SizedBox(width: 110, child: DropdownButtonFormField<String>(
                value: _numSep,
                isDense: true,
                decoration: _dec('Separator'),
                items: const [
                  DropdownMenuItem(value: '-', child: Text('-  dash')),
                  DropdownMenuItem(value: '/', child: Text('/  slash')),
                  DropdownMenuItem(value: '.', child: Text('.  dot')),
                ],
                onChanged: (v) => setState(() => _numSep = v ?? '-'),
              )),
              SizedBox(width: 110, child: DropdownButtonFormField<int>(
                value: _numDigits,
                isDense: true,
                decoration: _dec('Digits'),
                items: [for (final d in [3, 4, 5, 6]) DropdownMenuItem(value: d, child: Text('$d'))],
                onChanged: (v) => setState(() => _numDigits = v ?? 4),
              )),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(value: _numYear, onChanged: (v) => setState(() => _numYear = v)),
                const Text('Include year'),
              ]),
            ]),
            const SizedBox(height: 6),
            Text('Example: $_numberExample  ·  this brand keeps its own series',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const Divider(height: 26),
            const Text('Quotation design', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.07),
                border: Border.all(color: accent.withValues(alpha: 0.35)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Container(width: 18, height: 18, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
                const SizedBox(width: 10),
                Expanded(child: Text(describeDesign(_design), style: const TextStyle(fontSize: 13))),
              ]),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(onPressed: _generate, icon: const Icon(Icons.auto_awesome, size: 18), label: const Text('Generate new design')),
              OutlinedButton.icon(onPressed: _history.isEmpty ? null : _previous, icon: const Icon(Icons.undo, size: 18), label: const Text('Previous')),
              OutlinedButton.icon(onPressed: _preview, icon: const Icon(Icons.visibility_outlined, size: 18), label: const Text('Preview')),
            ]),
            const SizedBox(height: 6),
            const Text('Each press makes a new layout, colours and fonts. Preview shows it with sample items. '
                'The design is kept for this brand until you generate a new one.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save brand')),
      ],
    );
  }
}
