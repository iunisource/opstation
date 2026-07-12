import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';

/// `retailer_my_files()` already gates on visible_to containing 'retailer' AND
/// on the audience/audience_ref customer targeting — so this screen does no
/// filtering of its own. A file the retailer is not entitled to never arrives,
/// rather than arriving and refusing to open.
final retailerFilesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await Supabase.instance.client.rpc('retailer_my_files');
  if (res is! List) return [];
  return [for (final r in res) Map<String, dynamic>.from(r as Map)];
});

class RetailerFilesScreen extends ConsumerStatefulWidget {
  const RetailerFilesScreen({super.key});

  @override
  ConsumerState<RetailerFilesScreen> createState() =>
      _RetailerFilesScreenState();
}

class _RetailerFilesScreenState extends ConsumerState<RetailerFilesScreen> {
  static const _bucket = 'retailer-files';
  String? _opening;

  Future<void> _open(Map<String, dynamic> f, T t) async {
    final path = f['storage_path'] as String?;
    if (path == null || path.isEmpty) return;
    setState(() => _opening = f['id'] as String?);
    try {
      final url = await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(path, 3600);
      final ok =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.couldNotOpen)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.couldNotOpen)));
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  IconData _icon(String? type) {
    final s = (type ?? '').toLowerCase();
    if (s.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (s.contains('video')) return Icons.videocam_outlined;
    if (s.contains('image')) return Icons.image_outlined;
    return Icons.insert_drive_file_outlined;
  }

  Color _color(String? type) {
    final s = (type ?? '').toLowerCase();
    if (s.contains('pdf')) return Colors.red.shade600;
    if (s.contains('video')) return Colors.purple.shade500;
    if (s.contains('image')) return Colors.blue.shade600;
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final async = ref.watch(retailerFilesProvider);
    final df = DateFormat('d MMM yyyy');

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(retailerFilesProvider),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ListView(children: [
          const SizedBox(height: 140),
          Center(child: Text(t.somethingWentWrong,
              style: TextStyle(color: AppColors.textSecondaryLight))),
        ]),
        data: (rows) {
          if (rows.isEmpty) {
            return ListView(children: [
              const SizedBox(height: 130),
              Center(child: Column(children: [
                Icon(Icons.folder_open_outlined,
                    size: 40, color: AppColors.textSecondaryLight),
                const SizedBox(height: 10),
                Text(t.noFiles,
                    style: TextStyle(color: AppColors.textSecondaryLight)),
              ])),
            ]);
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 70),
            itemBuilder: (_, i) {
              final f = rows[i];
              final type = f['file_type'] as String?;
              final created = f['created_at'];
              final busy = _opening != null && _opening == f['id'];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: _color(type).withValues(alpha: 0.12),
                  child: Icon(_icon(type), color: _color(type), size: 20),
                ),
                title: Text('${f['title'] ?? ''}',
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  [
                    if (type != null && type.isNotEmpty) type.toUpperCase(),
                    if (created != null)
                      df.format(DateTime.parse('$created').toLocal()),
                  ].join('  •  '),
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.textSecondaryLight),
                ),
                trailing: busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.open_in_new, size: 18),
                onTap: busy ? null : () => _open(f, t),
              );
            },
          );
        },
      ),
    );
  }
}
