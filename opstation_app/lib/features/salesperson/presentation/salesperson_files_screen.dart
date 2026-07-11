import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';

/// Files shared with salespeople.
///
/// Read-only consumer of `shared_files`. Admins upload from the web panel
/// (Operations → Files) and choose which audiences may see each file; this
/// screen shows only those whose `visible_to` array contains 'salesperson'.
///
/// The storage bucket is private, so a file is opened via a short-lived signed
/// URL minted on tap rather than a stored public link. Online-only by design:
/// nothing is cached to disk. If salespeople need these in dead zones, that is
/// a deliberate follow-up (local cache + invalidation), not an accident.
class SalespersonFilesScreen extends ConsumerStatefulWidget {
  const SalespersonFilesScreen({super.key});

  @override
  ConsumerState<SalespersonFilesScreen> createState() =>
      _SalespersonFilesScreenState();
}

class _SalespersonFilesScreenState
    extends ConsumerState<SalespersonFilesScreen> {
  static const _bucket = 'retailer-files';

  final _df = DateFormat('d MMM yyyy');

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _files = [];
  String? _openingId; // file currently minting a signed URL

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final user = ref.read(authControllerProvider).valueOrNull;
    final orgId = user?.organizationId;
    if (orgId == null) {
      setState(() {
        _loading = false;
        _error = 'Not signed in.';
      });
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('shared_files')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .contains('visible_to', ['salesperson'])
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _files = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().split('\n').first;
      });
    }
  }

  /// Mint a signed URL and hand it to the system viewer/browser. The bucket is
  /// private, so the URL is time-limited (1 hour) and not shareable long-term.
  Future<void> _open(Map<String, dynamic> f) async {
    final path = f['storage_path'] as String?;
    final id = f['id'] as String?;
    if (path == null || path.isEmpty) {
      _snack('This file has no stored path.');
      return;
    }
    setState(() => _openingId = id);
    try {
      final url = await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(path, 3600);
      final uri = Uri.parse(url);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) _snack('Could not open the file.');
    } catch (e) {
      _snack('Could not open: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  IconData _iconFor(String? type) {
    final t = (type ?? '').toLowerCase();
    if (t.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (t.contains('video')) return Icons.videocam_outlined;
    if (t.contains('image')) return Icons.image_outlined;
    return Icons.insert_drive_file_outlined;
  }

  Color _colorFor(String? type) {
    final t = (type ?? '').toLowerCase();
    if (t.contains('pdf')) return Colors.red.shade600;
    if (t.contains('video')) return Colors.purple.shade500;
    if (t.contains('image')) return Colors.blue.shade600;
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Icon(Icons.cloud_off_outlined,
              size: 40, color: AppColors.textSecondaryLight),
          const SizedBox(height: 12),
          Center(
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondaryLight),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton(
              onPressed: _load,
              child: const Text('Try again'),
            ),
          ),
        ],
      );
    }
    if (_files.isEmpty) {
      // Must stay scrollable so pull-to-refresh still works when empty.
      return ListView(
        children: [
          const SizedBox(height: 120),
          Icon(Icons.folder_open_outlined,
              size: 44, color: AppColors.textSecondaryLight),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'No files shared with you yet.',
              style: TextStyle(color: AppColors.textSecondaryLight),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              'Pull down to refresh.',
              style: TextStyle(
                  fontSize: 12, color: AppColors.textSecondaryLight),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _files.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (_, i) {
        final f = _files[i];
        final type = f['file_type'] as String?;
        final desc = (f['description'] as String?)?.trim();
        final created = f['created_at'] != null
            ? _df.format(DateTime.parse('${f['created_at']}').toLocal())
            : null;
        final opening = _openingId != null && _openingId == f['id'];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: _colorFor(type).withValues(alpha: 0.12),
            child: Icon(_iconFor(type), color: _colorFor(type), size: 20),
          ),
          title: Text(
            (f['title'] as String?)?.trim().isNotEmpty == true
                ? f['title'] as String
                : 'Untitled',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (desc != null && desc.isNotEmpty)
                Text(
                  desc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.textSecondaryLight),
                ),
              const SizedBox(height: 2),
              Text(
                [
                  if (type != null && type.isNotEmpty) type.toUpperCase(),
                  if (created != null) created,
                ].join('  •  '),
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondaryLight),
              ),
            ],
          ),
          isThreeLine: desc != null && desc.isNotEmpty,
          trailing: opening
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.open_in_new, size: 18),
          onTap: opening ? null : () => _open(f),
        );
      },
    );
  }
}
