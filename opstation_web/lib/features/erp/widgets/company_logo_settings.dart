import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';

/// Admin Settings card: upload one company logo and choose which voucher PDFs
/// print it in the header.
///
/// Storage: bucket `signatures`, path `${orgId}/logo.png`.
/// Config (app_config):
///   org.show_logo_on_vouchers  master on/off ('true' | 'false')
///   org.logo_url               public URL of the uploaded logo
///   org.logo_voucher_types     comma-separated voucher-type keys to print on
///
/// The keys below MUST match VoucherPdf._voucherKey().
class CompanyLogoSettings extends StatefulWidget {
  final String orgId;
  const CompanyLogoSettings({super.key, required this.orgId});
  @override
  State<CompanyLogoSettings> createState() => _CompanyLogoSettingsState();
}

// (key, label) — key must match VoucherPdf._voucherKey().
const List<List<String>> _voucherTypes = [
  ['quotation', 'Quotation'],
  ['so', 'Sales Order'],
  ['do', 'Delivery Order'],
  ['si', 'Sales Invoice'],
  ['sri', 'Sales Return Invoice'],
  ['po', 'Purchase Order'],
  ['grn', 'Goods Receipt Note (GRN)'],
  ['pi', 'Purchase Invoice'],
  ['pri', 'Purchase Return Invoice'],
  ['stock_transfer', 'Stock Transfer'],
];

class _CompanyLogoSettingsState extends State<CompanyLogoSettings> {
  String? _logoUrl;
  bool _enabled = false;
  Set<String> _selected = {};
  bool _loading = true;
  bool _busyLogo = false;
  bool _busySave = false;

  @override
  void initState() { super.initState(); _load(); }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _load() async {
    final client = Supabase.instance.client;
    try {
      final rows = await client.from('app_config').select('key,value')
          .eq('org_id', widget.orgId)
          .inFilter('key', ['org.show_logo_on_vouchers', 'org.logo_url', 'org.logo_voucher_types']);
      final cfg = {for (final r in rows as List) r['key'] as String: r['value'] as String?};
      _logoUrl = cfg['org.logo_url'];
      _enabled = cfg['org.show_logo_on_vouchers'] == 'true';
      if (cfg.containsKey('org.logo_voucher_types')) {
        _selected = (cfg['org.logo_voucher_types'] ?? '')
            .split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
      } else {
        // Never narrowed => default to all types selected.
        _selected = _voucherTypes.map((t) => t[0]).toSet();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setConfig(String key, String value) async {
    await Supabase.instance.client.from('app_config').upsert(
      {'key': key, 'value': value, 'org_id': widget.orgId},
      onConflict: 'key,org_id,branch_id');
  }

  // Downscale + re-encode as PNG (keeps transparency).
  Future<Uint8List> _toPng(html.File file) async {
    final objUrl = html.Url.createObjectUrlFromBlob(file);
    final img = html.ImageElement()..src = objUrl;
    await img.onLoad.first;
    var w = img.naturalWidth ?? 0, h = img.naturalHeight ?? 0;
    if (w == 0 || h == 0) { html.Url.revokeObjectUrl(objUrl); throw 'Could not read image'; }
    const maxDim = 600;
    if (w > maxDim || h > maxDim) {
      if (w >= h) { h = (h * maxDim / w).round(); w = maxDim; } else { w = (w * maxDim / h).round(); h = maxDim; }
    }
    final canvas = html.CanvasElement(width: w, height: h);
    canvas.context2D.drawImageScaled(img, 0, 0, w, h);
    html.Url.revokeObjectUrl(objUrl);
    return base64Decode(canvas.toDataUrl('image/png').split(',').last);
  }

  Future<Uint8List?> _pick() async {
    final input = html.FileUploadInputElement()..accept = 'image/*';
    input.style.display = 'none';
    html.document.body?.append(input);
    input.click();
    await input.onChange.first;
    final files = input.files;
    input.remove();
    if (files == null || files.isEmpty) return null;
    return _toPng(files.first);
  }

  Future<void> _uploadLogo() async {
    setState(() => _busyLogo = true);
    try {
      final bytes = await _pick();
      if (bytes != null) {
        final client = Supabase.instance.client;
        final path = '${widget.orgId}/logo.png';
        await client.storage.from('signatures').uploadBinary(
            path, bytes, fileOptions: const FileOptions(upsert: true, contentType: 'image/png'));
        final url = '${client.storage.from('signatures').getPublicUrl(path)}?v=${DateTime.now().millisecondsSinceEpoch}';
        await _setConfig('org.logo_url', url);
        if (mounted) setState(() => _logoUrl = url);
        _snack('Company logo saved');
      }
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    if (mounted) setState(() => _busyLogo = false);
  }

  Future<void> _removeLogo() async {
    setState(() => _busyLogo = true);
    try {
      await _setConfig('org.logo_url', '');
      if (mounted) setState(() => _logoUrl = null);
      _snack('Company logo removed');
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    if (mounted) setState(() => _busyLogo = false);
  }

  Future<void> _toggleEnabled(bool v) async {
    setState(() { _enabled = v; _busySave = true; });
    try {
      await _setConfig('org.show_logo_on_vouchers', v ? 'true' : 'false');
      // Persist the current selection too, so the type list is explicit.
      await _setConfig('org.logo_voucher_types', _selected.join(','));
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    if (mounted) setState(() => _busySave = false);
  }

  Future<void> _saveTypes() async {
    setState(() => _busySave = true);
    try {
      await _setConfig('org.logo_voucher_types', _selected.join(','));
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    if (mounted) setState(() => _busySave = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Company Logo on Vouchers', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text('Upload your company logo and choose which voucher prints show it in the header. When the switch is off, no logo prints anywhere.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35)),
        const SizedBox(height: 14),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
        else ...[
          Wrap(spacing: 24, runSpacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
            // Logo preview + upload
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Company logo', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Container(
                width: 200, height: 90,
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                child: _logoUrl == null || _logoUrl!.isEmpty
                    ? const Text('None uploaded', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
                    : Image.network(_logoUrl!, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Text('—')),
              ),
              const SizedBox(height: 6),
              Row(children: [
                OutlinedButton.icon(
                  icon: _busyLogo ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_outlined, size: 15),
                  label: Text(_logoUrl == null || _logoUrl!.isEmpty ? 'Upload' : 'Replace', style: const TextStyle(fontSize: 12)),
                  onPressed: _busyLogo ? null : _uploadLogo),
                if (_logoUrl != null && _logoUrl!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  TextButton(onPressed: _busyLogo ? null : _removeLogo, child: const Text('Remove', style: TextStyle(fontSize: 12, color: AppTheme.danger))),
                ],
              ]),
            ]),
            // Master switch
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Show logo on vouchers', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Switch(value: _enabled, onChanged: _busySave ? null : _toggleEnabled),
            ]),
          ]),
          if (_enabled) ...[
            const SizedBox(height: 8),
            if (_logoUrl == null || _logoUrl!.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.orange.withOpacity(0.08), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.35))),
                child: const Row(children: [
                  Icon(Icons.info_outline, size: 15, color: Colors.orange), SizedBox(width: 8),
                  Expanded(child: Text('Upload a logo above for it to appear on the selected vouchers.', style: TextStyle(fontSize: 12, color: Colors.orange))),
                ]),
              ),
            const SizedBox(height: 12),
            const Text('Print the logo on these vouchers:', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(children: [
              TextButton(onPressed: _busySave ? null : () { setState(() => _selected = _voucherTypes.map((t) => t[0]).toSet()); _saveTypes(); },
                  child: const Text('Select all', style: TextStyle(fontSize: 12))),
              TextButton(onPressed: _busySave ? null : () { setState(() => _selected = {}); _saveTypes(); },
                  child: const Text('Clear all', style: TextStyle(fontSize: 12))),
            ]),
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth >= 560 ? 2 : 1;
              final rowW = (c.maxWidth - (cols - 1) * 12) / cols;
              return Wrap(spacing: 12, runSpacing: 4, children: _voucherTypes.map((t) {
                final key = t[0]; final label = t[1];
                return SizedBox(width: rowW, child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selected.contains(key),
                  title: Text(label, style: const TextStyle(fontSize: 13)),
                  onChanged: _busySave ? null : (v) {
                    setState(() { if (v == true) { _selected.add(key); } else { _selected.remove(key); } });
                    _saveTypes();
                  },
                ));
              }).toList());
            }),
          ],
        ],
      ]),
    );
  }
}
