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
  // Other users' signatures (admin uploads on their behalf) — used on the
  // Payment Advice print and anywhere a user's signature is printed.
  List<Map<String, dynamic>> _users = [];
  String? _pickedUserId;
  bool _busyOther = false;

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
      final us = await client.from('users').select('id, name, signature_url')
          .eq('org_id', widget.orgId).or('role.is.null,role.neq.retailer').order('name');
      // Staff only (retailer portal accounts are not users). Includes the
      // signed-in admin — one list, one flow, for everyone's signature.
      _users = [
        for (final u in us as List) Map<String, dynamic>.from(u as Map),
      ];
      _pickedUserId ??= widget.userId;
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

  Future<void> _uploadFor(Map<String, dynamic> u) async {
    setState(() => _busyOther = true);
    try {
      final bytes = await _pick();
      if (bytes != null) {
        final client = Supabase.instance.client;
        final uid = u['id'] as String;
        final path = '${widget.orgId}/sig_$uid.png';
        await client.storage.from('signatures').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true, contentType: 'image/png'));
        final url = '${client.storage.from('signatures').getPublicUrl(path)}?v=${DateTime.now().millisecondsSinceEpoch}';
        final res = await client.from('users').update({'signature_url': url}).eq('id', uid).select('id');
        if ((res as List).isEmpty) {
          throw 'You do not have permission to change this user\'s signature';
        }
        if (mounted) {
          setState(() {
            u['signature_url'] = url;
            if (uid == widget.userId) _sigUrl = url;
          });
        }
        _snack('Signature saved for ${u['name'] ?? 'user'}');
      }
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    if (mounted) setState(() => _busyOther = false);
  }

  Future<void> _removeFor(Map<String, dynamic> u) async {
    setState(() => _busyOther = true);
    try {
      await Supabase.instance.client.from('users').update({'signature_url': null}).eq('id', u['id'] as String);
      if (mounted) {
        setState(() {
          u['signature_url'] = null;
          if (u['id'] == widget.userId) _sigUrl = null;
        });
      }
      _snack('Signature removed');
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    if (mounted) setState(() => _busyOther = false);
  }

  Widget _otherUsers() {
    final picked = _users.where((u) => u['id'] == _pickedUserId).toList();
    final u = picked.isEmpty ? null : picked.first;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('User signatures', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      const Text('Pick a user (you included) and upload their signature. The same signature is used on invoices under the review flow and on the Payment Advice print.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.35)),
      const SizedBox(height: 10),
      SizedBox(
        width: 320,
        child: DropdownButtonFormField<String>(
          value: _pickedUserId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'User', isDense: true, border: OutlineInputBorder()),
          items: [
            for (final x in _users)
              DropdownMenuItem(
                value: x['id'] as String,
                child: Text('${x['name'] ?? x['id']}${x['id'] == widget.userId ? ' (you)' : ''}${x['signature_url'] != null ? '  ✓' : ''}',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _pickedUserId = v),
        ),
      ),
      if (u != null) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.end, children: [
          _slot('Signature — ${u['name'] ?? ''}', u['signature_url'] as String?, _busyOther, () => _uploadFor(u)),
          if (u['signature_url'] != null)
            TextButton.icon(
              onPressed: _busyOther ? null : () => _removeFor(u),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Remove', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            ),
        ]),
      ],
    ]);
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
        const Text('Signatures & Company Stamp', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text('The company stamp prints next to the approver\'s signature.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35)),
        const SizedBox(height: 14),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
        else ...[
          if (_users.isNotEmpty)
            _otherUsers()
          else
            _slot('My signature', _sigUrl, _busySig, _uploadSignature),
          const Divider(height: 28),
          _slot('Company stamp', _stampUrl, _busyStamp, _uploadStamp),
        ],
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
