import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';

/// Number of unread notifications (drawer badge). Refreshed when the drawer
/// opens and after the inbox is viewed.
final unreadInboxCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
  try {
    final rows = await Supabase.instance.client
        .from('push_inbox')
        .select('id')
        .filter('read_at', 'is', null)
        .limit(100);
    return (rows as List).length;
  } catch (_) {
    return 0;
  }
});

/// Every push notification this user has received (kept on the server, so it
/// survives reinstalls and phone changes). App reminders made on the phone
/// itself, such as the route inactivity reminder, are not listed.
class NotificationsInboxScreen extends ConsumerStatefulWidget {
  const NotificationsInboxScreen({super.key});
  @override
  ConsumerState<NotificationsInboxScreen> createState() =>
      _NotificationsInboxScreenState();
}

class _NotificationsInboxScreenState
    extends ConsumerState<NotificationsInboxScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = [];
  final Set<String> _expanded = {};

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
    try {
      final res = await Supabase.instance.client
          .from('push_inbox')
          .select('id, title, body, created_at, read_at')
          .order('created_at', ascending: false)
          .limit(300);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(
            (res as List).map((e) => Map<String, dynamic>.from(e as Map)));
        _loading = false;
      });
      // Opening the inbox marks everything as read (dots stay until next open).
      if (_rows.any((r) => r['read_at'] == null)) {
        try {
          await Supabase.instance.client.rpc('mark_push_inbox_read');
        } catch (_) {}
        ref.invalidate(unreadInboxCountProvider);
      }
    } catch (e) {
      if (!mounted) return;
      final s = e.toString().toLowerCase();
      setState(() {
        _loading = false;
        _error = (s.contains('socket') ||
                s.contains('network') ||
                s.contains('connection'))
            ? 'No connection — pull down to try again when online.'
            : 'Could not load notifications.';
      });
    }
  }

  String _when(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final t = DateFormat('h:mm a').format(d);
    if (day == today) return 'Today, $t';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday, $t';
    return '${DateFormat('d MMM yyyy').format(d)}, $t';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimaryLight,
        elevation: 0.5,
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _message(Icons.cloud_off_outlined, _error!);
    if (_rows.isEmpty) {
      return _message(
          Icons.notifications_none_outlined, 'No notifications yet.');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final r = _rows[i];
        final id = (r['id'] ?? '').toString();
        final unread = r['read_at'] == null;
        final title = (r['title'] as String?)?.trim() ?? '';
        final body = (r['body'] as String?)?.trim() ?? '';
        final open = _expanded.contains(id);
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => open ? _expanded.remove(id) : _expanded.add(id)),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: unread ? AppColors.infoLight : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 5, right: 10),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: unread ? AppColors.primary : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title.isEmpty ? 'Notification' : title,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight:
                                  unread ? FontWeight.w800 : FontWeight.w600)),
                      if (body.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(body,
                            maxLines: open ? null : 3,
                            overflow: open ? null : TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondaryLight)),
                      ],
                      const SizedBox(height: 6),
                      Text(_when(r['created_at'] as String?),
                          style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textTertiaryLight)),
                    ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _message(IconData icon, String text) => ListView(
        padding: const EdgeInsets.only(top: 120),
        children: [
          Icon(icon, size: 40, color: AppColors.textTertiaryLight),
          const SizedBox(height: 10),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondaryLight)),
        ],
      );
}
