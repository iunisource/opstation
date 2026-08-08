import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';

/// Reusable "Support Documents" panel for invoice vouchers (SI / PI / PRI).
///
/// - Images are compressed client-side (canvas, max 1400px, JPEG 0.82); PDFs
///   pass through. Files are stored as <org_id>/<VoucherNumber>_<n>.<ext> in the
///   per-type bucket and registered in `voucher_documents`.
/// - Images render as a tappable grid (tap = full-screen zoom); every file also
///   has an open-in-new-tab button. Attach from file or straight from camera.
class VoucherDocsPanel extends StatefulWidget {
  final String voucherType;   // 'SI' | 'PI' | 'PRI'
  final String voucherId;
  final String voucherNumber; // used for the stored filename
  final String bucket;
  final String orgId;
  final String? userId;
  final bool canWrite;

  const VoucherDocsPanel({
    super.key,
    required this.voucherType,
    required this.voucherId,
    required this.voucherNumber,
    required this.bucket,
    required this.orgId,
    required this.userId,
    required this.canWrite,
  });

  @override
  State<VoucherDocsPanel> createState() => _VoucherDocsPanelState();
}

class _VoucherDocsPanelState extends State<VoucherDocsPanel> {
  List<Map<String, dynamic>> _docs = [];
  bool _loading = true;
  bool _uploading = false;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void didUpdateWidget(covariant VoucherDocsPanel old) {
    super.didUpdateWidget(old);
    if (old.voucherId != widget.voucherId) _load();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('voucher_documents')
          .select()
          .eq('voucher_type', widget.voucherType)
          .eq('voucher_id', widget.voucherId)
          .order('doc_no', ascending: true);
      if (mounted) setState(() { _docs = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _docs = []; _loading = false; });
    }
  }

  int _nextDocNo() {
    var maxNo = 0;
    for (final d in _docs) { final n = (d['doc_no'] as num?)?.toInt() ?? 0; maxNo = math.max(maxNo, n); }
    return maxNo + 1;
  }

  Future<Uint8List> _compressImage(html.File file) async {
    final objUrl = html.Url.createObjectUrlFromBlob(file);
    final img = html.ImageElement()..src = objUrl;
    await img.onLoad.first;
    var w = img.naturalWidth ?? 0, h = img.naturalHeight ?? 0;
    if (w == 0 || h == 0) { html.Url.revokeObjectUrl(objUrl); throw 'Could not read image dimensions'; }
    const maxDim = 1400;
    if (w > maxDim || h > maxDim) {
      if (w >= h) { h = (h * maxDim / w).round(); w = maxDim; }
      else { w = (w * maxDim / h).round(); h = maxDim; }
    }
    final canvas = html.CanvasElement(width: w, height: h);
    canvas.context2D.drawImageScaled(img, 0, 0, w, h);
    html.Url.revokeObjectUrl(objUrl);
    final dataUrl = canvas.toDataUrl('image/jpeg', 0.82);
    return base64Decode(dataUrl.split(',').last);
  }

  Future<void> _upload({bool camera = false}) async {
    if (!widget.canWrite) { _snack('This voucher is locked — documents cannot be changed'); return; }
    final input = html.FileUploadInputElement()..accept = camera ? 'image/*' : 'image/*,application/pdf';
    if (camera) input.setAttribute('capture', 'environment'); // opens the camera on mobile
    input.style.display = 'none';
    html.document.body?.append(input);
    input.click();
    await input.onChange.first;
    final files = input.files;
    input.remove();
    if (files == null || files.isEmpty) return;
    final file = files.first;
    setState(() => _uploading = true);
    try {
      Uint8List bytes; String ct; String ext;
      if (file.type.startsWith('image/')) {
        bytes = await _compressImage(file); ct = 'image/jpeg'; ext = 'jpg';
      } else {
        final r = html.FileReader();
        r.readAsArrayBuffer(file);
        await r.onLoadEnd.first;
        final res = r.result;
        bytes = res is Uint8List ? res : (res as ByteBuffer).asUint8List();
        ct = file.type.isNotEmpty ? file.type : 'application/octet-stream';
        ext = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : 'bin';
      }
      if (bytes.isEmpty) { _snack('Selected file is empty'); setState(() => _uploading = false); return; }
      final docNo = _nextDocNo();
      final fname = '${widget.voucherNumber}_$docNo.$ext';
      final path = '${widget.orgId}/$fname';
      final client = Supabase.instance.client;
      await client.storage.from(widget.bucket).uploadBinary(
        path, bytes, fileOptions: FileOptions(upsert: true, contentType: ct));
      final url = client.storage.from(widget.bucket).getPublicUrl(path);
      final ts = DateTime.now().millisecondsSinceEpoch;
      await client.from('voucher_documents').insert({
        'id': 'vdoc_$ts',
        'org_id': widget.orgId,
        'voucher_type': widget.voucherType,
        'voucher_id': widget.voucherId,
        'bucket': widget.bucket,
        'path': path,
        'url': url,
        'name': fname,
        'doc_no': docNo,
        'file_type': ct,
        'size_bytes': bytes.length,
        'uploaded_by': widget.userId,
      });
      await _load();
      _snack('Document uploaded');
    } catch (e) {
      _snack('Upload failed: $e');
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _delete(Map<String, dynamic> d) async {
    if (!widget.canWrite) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Remove document?'),
      content: Text('Remove "${d['name'] ?? 'document'}"?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Remove')),
      ],
    ));
    if (ok != true) return;
    try {
      final client = Supabase.instance.client;
      try { await client.storage.from(d['bucket'] as String? ?? widget.bucket).remove([d['path'] as String]); } catch (_) {}
      await client.from('voucher_documents').delete().eq('id', d['id'] as String);
      await _load();
    } catch (e) { _snack('Remove failed: $e'); }
  }

  void _openNewTab(String? url) { if (url != null) html.window.open(url, '_blank'); }

  void _zoom(Map<String, dynamic> d) {
    final url = d['url'] as String?;
    if (url == null) return;
    showDialog(context: context, builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Colors.black,
      child: Stack(children: [
        SizedBox(
          width: double.infinity, height: MediaQuery.of(ctx).size.height * 0.85,
          child: InteractiveViewer(
            minScale: 0.5, maxScale: 5,
            child: Center(child: Image.network(url, fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 48)))),
          ),
        ),
        Positioned(top: 6, right: 6, child: Row(children: [
          IconButton(icon: const Icon(Icons.open_in_new, color: Colors.white), tooltip: 'Open in new tab', onPressed: () => _openNewTab(url)),
          IconButton(icon: const Icon(Icons.close, color: Colors.white), tooltip: 'Close', onPressed: () => Navigator.pop(ctx)),
        ])),
        Positioned(bottom: 8, left: 0, right: 0, child: Center(child: Text(d['name'] as String? ?? '',
          style: const TextStyle(color: Colors.white70, fontSize: 12)))),
      ]),
    ));
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  bool _isImage(Map<String, dynamic> d) => (d['file_type'] as String? ?? '').startsWith('image/');

  @override
  Widget build(BuildContext context) {
    final images = _docs.where(_isImage).toList();
    final files = _docs.where((d) => !_isImage(d)).toList();
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
          child: Row(children: [
            const Icon(Icons.attach_file, size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            const Expanded(child: Text('Support Documents', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
            if (_docs.isNotEmpty)
              Padding(padding: const EdgeInsets.only(right: 8), child: Text('${_docs.length}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            if (widget.canWrite) ...[
              _miniBtn(Icons.upload_file_outlined, 'Attach', _uploading ? null : () => _upload()),
              const SizedBox(width: 6),
              _miniBtn(Icons.photo_camera_outlined, 'Camera', _uploading ? null : () => _upload(camera: true)),
            ],
          ]),
        ),
        if (_loading)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))))
        else if (_docs.isEmpty)
          Padding(padding: const EdgeInsets.all(14), child: Text(
            widget.canWrite ? 'No documents yet. Use Attach for images/PDFs or Camera to capture a photo (images are compressed automatically).'
                            : 'No documents attached.',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)))
        else ...[
          if (images.isNotEmpty)
            Padding(padding: EdgeInsets.fromLTRB(12, 12, 12, files.isEmpty ? 12 : 4),
              child: Wrap(spacing: 8, runSpacing: 8, children: [for (final d in images) _thumb(d)])),
          for (final d in files) _fileRow(d),
        ],
      ]),
    );
  }

  Widget _miniBtn(IconData icon, String label, VoidCallback? onTap) => ElevatedButton.icon(
    icon: (_uploading && onTap == null)
        ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        : Icon(icon, size: 14),
    label: Text(label, style: const TextStyle(fontSize: 11.5)),
    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    onPressed: onTap,
  );

  Widget _thumb(Map<String, dynamic> d) {
    final url = d['url'] as String? ?? '';
    return SizedBox(width: 92, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Stack(children: [
        InkWell(
          onTap: () => _zoom(d),
          child: Container(
            width: 92, height: 92,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border), color: AppTheme.background),
            clipBehavior: Clip.antiAlias,
            child: Image.network(url, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image, size: 20, color: AppTheme.textSecondary)),
              loadingBuilder: (c, w, p) => p == null ? w : const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))),
          ),
        ),
        Positioned(top: 2, right: 2, child: Row(children: [
          _iconChip(Icons.open_in_new, () => _openNewTab(url)),
          if (widget.canWrite) ...[const SizedBox(width: 2), _iconChip(Icons.close, () => _delete(d))],
        ])),
      ]),
      const SizedBox(height: 2),
      Text(d['name'] as String? ?? '', style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
    ]));
  }

  Widget _iconChip(IconData icon, VoidCallback onTap) => InkWell(onTap: onTap, child: Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
    child: Icon(icon, size: 13, color: Colors.white)));

  Widget _fileRow(Map<String, dynamic> d) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border.withOpacity(0.5)))),
    child: Row(children: [
      const Icon(Icons.picture_as_pdf_outlined, size: 18, color: AppTheme.textSecondary),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(d['name'] as String? ?? 'document', style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis),
        Text(_fmtSize((d['size_bytes'] as num?)?.toInt() ?? 0), style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ])),
      IconButton(icon: const Icon(Icons.open_in_new, size: 16, color: AppTheme.primary), tooltip: 'Open', onPressed: () => _openNewTab(d['url'] as String?)),
      if (widget.canWrite)
        IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.danger), tooltip: 'Remove', onPressed: () => _delete(d)),
    ]),
  );
}
