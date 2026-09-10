import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';

/// Admin Settings card: each admin uploads their own signature, and the org
/// uploads one company stamp. Both feed the "Approved By" block on invoice PDFs
/// (via users.signature_url and app_config 'org.stamp_url'). PNG is preserved so
/// stamps/signatures keep transparency.
class SignatureStampSettings extends StatefulWidget {
  final String orgId;
  final String? userId;
  const SignatureStampSettings({super.key, required this.orgId, required this.userId});
  @override
  State<SignatureStampSettings> createState() => _SignatureStampSettingsState();
}

class _SignatureStampSettingsState extends State<SignatureStampSettings> {
  String? _sigUrl;
  String? _stampUrl;
  bool _loading = true;
  bool _busySig = false;
  bool _busyStamp = false;

  @override
  void initState() { super.initState(); _load(); }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _load() async {
    final client = Supabase.instance.client;
    try {
      if (widget.userId != null) {
        final u = await client.from('users').select('signature_url').eq('id', widget.userId!).maybeSingle();
        _sigUrl = u?['signature_url'] as String?;
      }
      final s = await client.from('app_config').select('value').eq('org_id', widget.orgId).eq('key', 'org.stamp_url').maybeSingle();
      _stampUrl = s?['value'] as String?;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  // Downscale + re-encode as PNG (keeps transparency for stamps/signatures).
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

  Future<void> _uploadSignature() async {
    if (widget.userId == null) return;
    setState(() => _busySig = true);
    try {
      final bytes = await _pick();
      if (bytes != null) {
        final client = Supabase.instance.client;
        final path = '${widget.orgId}/sig_${widget.userId}.png';
        await client.storage.from('signatures').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true, contentType: 'image/png'));
        // cache-bust so the new image shows immediately
        final url = '${client.storage.from('signatures').getPublicUrl(path)}?v=${DateTime.now().millisecondsSinceEpoch}';
        await client.from('users').update({'signature_url': url}).eq('id', widget.userId!);
        if (mounted) setState(() => _sigUrl = url);
        _snack('Signature saved');
      }
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    if (mounted) setState(() => _busySig = false);
  }

  Future<void> _uploadStamp() async {
    setState(() => _busyStamp = true);
    try {
      final bytes = await _pick();
      if (bytes != null) {
        final client = Supabase.instance.client;
        final path = '${widget.orgId}/stamp.png';
        await client.storage.from('signatures').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true, contentType: 'image/png'));
        final url = '${client.storage.from('signatures').getPublicUrl(path)}?v=${DateTime.now().millisecondsSinceEpoch}';
        await client.from('app_config').upsert({'key': 'org.stamp_url', 'value': url, 'org_id': widget.orgId}, onConflict: 'key,org_id,branch_id');
        if (mounted) setState(() => _stampUrl = url);
        _snack('Company stamp saved');
      }
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    if (mounted) setState(() => _busyStamp = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Signature & Company Stamp', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text('Your signature and the company stamp print in the Approved By box when you approve an invoice under the review flow.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35)),
        const SizedBox(height: 14),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
        else
          Wrap(spacing: 24, runSpacing: 16, children: [
            _slot('My signature', _sigUrl, _busySig, _uploadSignature),
            _slot('Company stamp', _stampUrl, _busyStamp, _uploadStamp),
          ]),
      ]),
    );
  }

  Widget _slot(String label, String? url, bool busy, VoidCallback onUpload) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Container(
        width: 200, height: 90,
        decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: url == null
            ? const Text('None uploaded', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
            : Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Text('—')),
      ),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        icon: busy ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_outlined, size: 15),
        label: Text(url == null ? 'Upload' : 'Replace', style: const TextStyle(fontSize: 12)),
        onPressed: busy ? null : onUpload),
    ]);
  }
}
