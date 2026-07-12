import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';

final retailerNotificationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await Supabase.instance.client.rpc('retailer_my_notifications');
  if (res is! List) return [];
  return [for (final r in res) Map<String, dynamic>.from(r as Map)];
});

/// Updates live behind the header bell rather than occupying a nav tab: nobody
/// opens the app to browse announcements. Opening the sheet marks each unread
/// item read, which is why the shell invalidates the unread count on dismiss.
class RetailerNotificationsSheet extends ConsumerWidget {
  const RetailerNotificationsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = T.of(context);
    final async = ref.watch(retailerNotificationsProvider);
    final df = DateFormat('d MMM yyyy, h:mm a');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(t.updates,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => Center(
                child: Text(t.somethingWentWrong,
                    style: TextStyle(color: AppColors.textSecondaryLight))),
            data: (rows) {
              if (rows.isEmpty) {
                return Center(
                    child: Text(t.noUpdates,
                        style:
                            TextStyle(color: AppColors.textSecondaryLight)));
              }
              return ListView.separated(
                controller: scroll,
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final n = rows[i];
                  final unread = n['read_at'] == null;
                  final link = n['link_url'] as String?;
                  return ListTile(
                    leading: Icon(
                      unread ? Icons.mark_email_unread : Icons.drafts_outlined,
                      color: unread
                          ? AppColors.primary
                          : AppColors.textSecondaryLight,
                    ),
                    title: Text('${n['title'] ?? ''}',
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight:
                                unread ? FontWeight.w800 : FontWeight.w600)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ('${n['body'] ?? ''}'.trim().isNotEmpty)
                          Text('${n['body']}',
                              style: const TextStyle(fontSize: 12.5)),
                        if (n['created_at'] != null)
                          Text(
                              df.format(
                                  DateTime.parse('${n['created_at']}').toLocal()),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textSecondaryLight)),
                      ],
                    ),
                    isThreeLine: '${n['body'] ?? ''}'.trim().isNotEmpty,
                    trailing: (link != null && link.isNotEmpty)
                        ? const Icon(Icons.open_in_new, size: 17)
                        : null,
                    onTap: () async {
                      if (unread) {
                        try {
                          await Supabase.instance.client.rpc(
                              'retailer_mark_notification_read',
                              params: {'p_notification_id': n['id']});
                          ref.invalidate(retailerNotificationsProvider);
                        } catch (_) {}
                      }
                      if (link != null && link.isNotEmpty) {
                        await launchUrl(Uri.parse(link),
                            mode: LaunchMode.externalApplication);
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
