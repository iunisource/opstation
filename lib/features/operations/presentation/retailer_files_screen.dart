// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// The three audiences a shared file can be visible to. Keys match the values
/// stored in shared_files.visible_to (a text[]), so any combination is valid —
/// "all" is simply all three selected rather than a separate sentinel value.
const Map<String, String> _kAudiences = {
  'retailer': 'Retailers',
  'salesperson': 'Salespeople',
  'erpUser': 'ERP Users',
};

/// Admin "Files" area (Operations menu). Admins upload images / PDFs / videos
/// into the private `retailer-files` Storage bucket and record them in
/// `shared_files`; retailers, salespeople and ERP users read these in their
/// respective surfaces, filtered by `visible_to`.
///
/// Set [audience] to make this a read-only consumer view for one role (e.g. the
/// ERP menu's Files screen passes 'erpUser'). Left null it is the admin view:
/// every file, plus upload and delete.
class RetailerFilesScreen extends ConsumerStatefulWidget {
  final String? audience;
  const RetailerFilesScreen({super.key, this.audience});
  @override
  ConsumerState<RetailerFilesScreen> createState() => _RetailerFilesScreenState();
}

class _RetailerFilesScreenState extends ConsumerState<RetailerFilesScreen> {
  static const _bucket = 'retailer-files';
  static const _maxBytes = 50 * 1024 * 1024; // 50 MB

  bool get _readOnly => widget.audience != null;

  bool _loading = true;
  List<Map<String, dynamic>> _files = [];
  final _df = DateFormat('d MMM y, h:mm a');

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      var q = Supabase.instance.client
          .from('shared_files')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true);
      // Consumer views (ERP menu, etc.) see only files whose visible_to array
      // contains their role. The admin view passes no audience and sees all.
      final aud = widget.audience;
      if (aud != null) q = q.contains('visible_to', [aud]);
      final rows = await q.order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _files = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (e) {
      _snack('Load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────
  String _typeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return 'pdf';
    if (n.endsWith('.mp4') || n.endsWith('.mov') || n.endsWith('.webm') || n.endsWith('.m4v')) {
      return 'video';
    }
    return 'image';
  }

  String _mimeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.mp4') || n.endsWith('.m4v')) return 'video/mp4';
    if (n.endsWith('.mov')) return 'video/quicktime';
    if (n.endsWith('.webm')) return 'video/webm';
    return 'application/octet-stream';
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'video':
        return Icons.movie_outlined;
      default:
        return Icons.image_outlined;
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ── customer picker (server-side search; no preloading) ────────────────
  Future<Map<String, dynamic>?> _pickCustomer() async {
    final searchCtrl = TextEditingController();
    List<Map<String, dynamic>> results = [];
    bool searching = false;

    Future<void> run(StateSetter setS) async {
      final orgId = _orgId;
      final q = searchCtrl.text.trim();
      if (orgId == null || q.isEmpty) return;
      setS(() => searching = true);
      try {
        final rows = await Supabase.instance.client
            .from('customers')
            .select('id, shop_name, code')
            .eq('org_id', orgId)
            .or('shop_name.ilike.%$q%,code.ilike.%$q%')
            .limit(25);
        setS(() {
          results = List<Map<String, dynamic>>.from(rows);
          searching = false;
        });
      } catch (e) {
        setS(() => searching = false);
        _snack('Search error: $e');
      }
    }

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Choose customer'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: searchCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search by shop name or code',
                    suffixIcon: IconButton(
                        icon: const Icon(Icons.search),
                        onPressed: () => run(setS)),
                  ),
                  onSubmitted: (_) => run(setS),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 320,
                  child: searching
                      ? const Center(child: CircularProgressIndicator())
                      : results.isEmpty
                          ? const Center(
                              child: Text('Type a name or code and search',
                                  style: TextStyle(color: AppTheme.textSecondary)))
                          : ListView.builder(
                              itemCount: results.length,
                              itemBuilder: (_, i) {
                                final c = results[i];
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.store_outlined, size: 18),
                                  title: Text(c['shop_name'] as String? ?? ''),
                                  subtitle: Text(c['code'] as String? ?? ''),
                                  onTap: () => Navigator.pop(ctx, c),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }

  // ── upload dialog ──────────────────────────────────────────────────────
  Future<void> _uploadDialog() async {
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    String audience = 'all';
    // Which ROLES may see this file. Orthogonal to `audience`, which targets
    // WHICH retailer (all vs one specific customer). Overloading `audience`
    // with roles would have destroyed the customer-targeting feature.
    final Set<String> visibleTo = {'retailer'};
    Map<String, dynamic>? customer;
    Uint8List? bytes;
    String? fileName;
    String? fileType;
    bool saving = false;

    void pick(StateSetter setS) {
      final input = html.FileUploadInputElement()
        ..accept = 'image/png,image/jpeg,image/webp,image/gif,application/pdf,video/mp4,video/quicktime,video/webm';
      input.click();
      input.onChange.listen((_) {
        final files = input.files;
        if (files == null || files.isEmpty) return;
        final f = files[0];
        if (f.size > _maxBytes) {
          _snack('File too large — max 50 MB');
          return;
        }
        final reader = html.FileReader();
        reader.readAsArrayBuffer(f);
        reader.onLoad.listen((_) {
          final result = reader.result;
          final data = result is ByteBuffer
              ? result.asUint8List()
              : result as Uint8List;
          setS(() {
            bytes = data;
            fileName = f.name;
            fileType = _typeFor(f.name);
          });
        });
      });
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> save() async {
            final orgId = _orgId;
            if (orgId == null) return;
            if (titleCtrl.text.trim().isEmpty) {
              _snack('Give the file a title');
              return;
            }
            if (bytes == null || fileName == null) {
              _snack('Choose a file to upload');
              return;
            }
            if (audience == 'customer' &&
                visibleTo.contains('retailer') &&
                customer == null) {
              _snack('Pick the customer this file is for');
              return;
            }
            setS(() => saving = true);
            try {
              final client = Supabase.instance.client;
              final safe = fileName!.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
              final path = '$orgId/${DateTime.now().millisecondsSinceEpoch}_$safe';
              await client.storage.from(_bucket).uploadBinary(
                    path,
                    bytes!,
                    fileOptions: FileOptions(contentType: _mimeFor(fileName!), upsert: false),
                  );
              await client.from('shared_files').insert({
                'org_id': orgId,
                'title': titleCtrl.text.trim(),
                'description': descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
                'file_type': fileType,
                'storage_path': path,
                'audience': audience,
                'audience_ref':
                    (audience == 'customer' && visibleTo.contains('retailer'))
                        ? customer!['id']
                        : null,
                'visible_to': visibleTo.toList(),
                'uploaded_by': client.auth.currentUser?.id,
              });
              if (mounted) Navigator.pop(ctx);
              _snack('File uploaded');
              _load();
            } catch (e) {
              setS(() => saving = false);
              _snack('Upload failed: ${e.toString().split('\n').first}');
            }
          }

          return AlertDialog(
            title: const Text('Upload file'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(labelText: 'Title *'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'Description'),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.attach_file, size: 18),
                      label: Text(fileName == null ? 'Choose file' : 'Change file'),
                      onPressed: saving ? null : () => pick(setS),
                    ),
                    if (fileName != null) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Icon(_iconFor(fileType ?? 'image'),
                            size: 16, color: AppTheme.primary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(fileName!,
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                        ),
                        Text('(${fileType})',
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.textSecondary)),
                      ]),
                    ],
                    const SizedBox(height: 16),
                    Row(children: [
                      const Text('Visible to',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setS(() {
                          if (visibleTo.length == 3) {
                            visibleTo
                              ..clear()
                              ..add('retailer');
                          } else {
                            visibleTo
                              ..clear()
                              ..addAll(_kAudiences.keys);
                          }
                        }),
                        child: Text(visibleTo.length == 3 ? 'Clear' : 'Select all',
                            style: const TextStyle(fontSize: 11)),
                      ),
                    ]),
                    const SizedBox(height: 2),
                    Wrap(spacing: 8, children: [
                      for (final e in _kAudiences.entries)
                        FilterChip(
                          label: Text(e.value),
                          selected: visibleTo.contains(e.key),
                          onSelected: (sel) => setS(() {
                            if (sel) {
                              visibleTo.add(e.key);
                            } else {
                              // Never allow an empty set — a file nobody can see
                              // is silently dead. Keep at least one audience.
                              if (visibleTo.length > 1) visibleTo.remove(e.key);
                            }
                            if (!visibleTo.contains('retailer')) {
                              audience = 'all';
                              customer = null;
                            }
                          }),
                        ),
                    ]),
                    // Customer targeting only means anything when retailers can
                    // see the file at all.
                    if (visibleTo.contains('retailer')) ...[
                      const SizedBox(height: 12),
                      const Text('Which retailers',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      const SizedBox(height: 6),
                      Row(children: [
                        ChoiceChip(
                          label: const Text('All retailers'),
                          selected: audience == 'all',
                          onSelected: (_) => setS(() => audience = 'all'),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Specific customer'),
                          selected: audience == 'customer',
                          onSelected: (_) => setS(() => audience = 'customer'),
                        ),
                      ]),
                    ],
                    if (audience == 'customer' && visibleTo.contains('retailer')) ...[
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () async {
                          final c = await _pickCustomer();
                          if (c != null) setS(() => customer = c);
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(labelText: 'Customer'),
                          child: Text(customer == null
                              ? 'Choose a customer'
                              : (customer!['shop_name'] as String? ?? '')),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: saving ? null : () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: saving ? null : save,
                child: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Upload'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _view(Map<String, dynamic> f) async {
    try {
      final url = await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(f['storage_path'] as String, 3600);
      html.window.open(url, '_blank');
    } catch (e) {
      _snack('Could not open file: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove file'),
        content: Text('Remove "${f['title']}"? Retailers will no longer see it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final client = Supabase.instance.client;
      await client.from('shared_files').update({'is_active': false}).eq('id', f['id']);
      try {
        await client.storage.from(_bucket).remove([f['storage_path'] as String]);
      } catch (_) {/* row already hidden; storage cleanup best-effort */}
      _load();
    } catch (e) {
      _snack('Remove failed: ${e.toString().split('\n').first}');
    }
  }

  /// Human label combining both dimensions: which roles see the file, and —
  /// when retailers are among them — whether it is targeted at one customer.
  String _audienceLabel(Map<String, dynamic> f) {
    final raw = f['visible_to'];
    final roles = raw is List ? raw.map((e) => '$e').toList() : <String>['retailer'];
    final names = [
      for (final r in _kAudiences.keys)
        if (roles.contains(r)) _kAudiences[r]!,
    ];
    final who = names.isEmpty ? 'Nobody' : names.join(', ');
    if (roles.contains('retailer') && f['audience'] == 'customer') {
      return '$who (specific customer)';
    }
    return who;
  }

  // ── build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Files',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const SizedBox(width: 12),
            if (!_loading)
              Text('${_files.length} file${_files.length == 1 ? '' : 's'}',
                  style: const TextStyle(color: AppTheme.textSecondary)),
            const Spacer(),
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'),
            const SizedBox(width: 8),
            if (!_readOnly)
              ElevatedButton.icon(
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Upload file'),
                onPressed: _uploadDialog,
              ),
          ]),
          const SizedBox(height: 8),
          Text(
            _readOnly
                ? 'Images, PDFs and videos shared with you.'
                : 'Images, PDFs and videos shared with retailers, salespeople and ERP users.',
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _files.isEmpty
                    ? const Center(
                        child: Text('No files yet — upload one to share with retailers.',
                            style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.separated(
                        itemCount: _files.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final f = _files[i];
                          final type = f['file_type'] as String? ?? 'image';
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.border),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppTheme.primary.withOpacity(0.1),
                                child: Icon(_iconFor(type), color: AppTheme.primary),
                              ),
                              title: Text(f['title'] as String? ?? '',
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text(
                                [
                                  type.toUpperCase(),
                                  _audienceLabel(f),
                                  if (f['created_at'] != null)
                                    _df.format(
                                        DateTime.parse('${f['created_at']}').toLocal()),
                                ].join('  •  '),
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                IconButton(
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                  tooltip: 'View',
                                  onPressed: () => _view(f),
                                ),
                                if (!_readOnly)
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 18),
                                    color: AppTheme.danger,
                                    tooltip: 'Remove',
                                    onPressed: () => _delete(f),
                                  ),
                              ]),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
