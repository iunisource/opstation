import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../../features/auth/auth_controller.dart';

/// Top-bar notification bell: unread badge + dropdown of this user's received
/// notifications (from notifications + notification_recipients). Click one to
/// open its linked screen and mark it read; "Mark all read" clears the badge.
class NotificationBell extends ConsumerStatefulWidget {
  const NotificationBell({super.key});
  @override
  ConsumerState<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends ConsumerState<NotificationBell> {
  List<Map<String, dynamic>> _items = [];
  int _unread = 0;
  bool _loading = false;
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  String? get _uid => ref.read(currentUserProvider)?.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadUnread());
  }

  @override
  void dispose() {
    _overlay?.remove();
    _overlay = null;
    super.dispose();
  }

  Future<void> _loadUnread() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final res = await Supabase.instance.client
          .from('notification_recipients')
          .select('notification_id')
          .eq('recipient_user_id', uid)
          .filter('read_at', 'is', null);
      if (mounted) setState(() => _unread = (res as List).length);
      _overlay?.markNeedsBuild();
    } catch (_) {}
  }

  Future<void> _loadList() async {
    final uid = _uid;
    if (uid == null) return;
    setState(() => _loading = true);
    _overlay?.markNeedsBuild();
    try {
      // Two-step (no embedded join) — robust against FK/RLS embed quirks:
      // 1) my recipient rows, 2) the matching notifications, merged client-side.
      final recips = await Supabase.instance.client
          .from('notification_recipients')
          .select('notification_id, read_at')
          .eq('recipient_user_id', uid);
      final recipList = List<Map<String, dynamic>>.from(recips as List);
      final readBy = <String, dynamic>{
        for (final r in recipList) (r['notification_id'] as String): r['read_at']
      };
      final ids = readBy.keys.toList();
      List<Map<String, dynamic>> notifs = [];
      if (ids.isNotEmpty) {
        final rows = await Supabase.instance.client
            .from('notifications')
            .select('id, title, body, link_url, created_at')
            .inFilter('id', ids)
            .order('created_at', ascending: false)
            .limit(50);
        notifs = List<Map<String, dynamic>>.from(rows);
        // Attach each notification's read_at for this user.
        for (final n in notifs) {
          n['read_at'] = readBy[n['id'] as String];
        }
      }
      if (mounted) {
        setState(() {
          _items = notifs;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    _overlay?.markNeedsBuild();
  }

  bool _isUnread(Map<String, dynamic> n) => n['read_at'] == null;

  void _markLocalRead(Map<String, dynamic> n) {
    n['read_at'] = DateTime.now().toUtc().toIso8601String();
  }

  Future<void> _markRead(Map<String, dynamic> n) async {
    final uid = _uid;
    if (uid == null || !_isUnread(n)) return;
    try {
      await Supabase.instance.client
          .from('notification_recipients')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('notification_id', n['id'])
          .eq('recipient_user_id', uid);
      _markLocalRead(n);
      if (mounted) setState(() => _unread = (_unread - 1).clamp(0, 99999));
      _overlay?.markNeedsBuild();
    } catch (_) {}
  }

  Future<void> _markAllRead() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await Supabase.instance.client
          .from('notification_recipients')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('recipient_user_id', uid)
          .filter('read_at', 'is', null);
      for (final n in _items) {
        _markLocalRead(n);
      }
      if (mounted) setState(() => _unread = 0);
      _overlay?.markNeedsBuild();
    } catch (_) {}
  }

  void _open(Map<String, dynamic> n) {
    _markRead(n);
    _removeOverlay();
    final link = (n['link_url'] as String?) ?? '';
    // Trigger links are internal app routes (e.g. /erp/purchase). External http
    // links are left alone (the push itself handles those).
    if (link.isNotEmpty && !link.startsWith('http')) {
      try {
        context.go(link);
      } catch (_) {}
    }
  }

  String _ago(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso);
    if (d == null) return '';
    final diff = DateTime.now().difference(d.toLocal());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('d MMM').format(d.toLocal());
  }

  void _toggleOverlay() {
    if (_overlay != null) {
      _removeOverlay();
      return;
    }
    _loadList();
    _loadUnread();
    _overlay = OverlayEntry(
      builder: (ctx) => Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _removeOverlay,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, 8),
          child: _panel(),
        ),
      ]),
    );
    Overlay.of(context).insert(_overlay!);
    setState(() {});
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
    if (mounted) setState(() {});
  }

  Widget _panel() {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 380,
        constraints: const BoxConstraints(maxHeight: 460),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Row(children: [
              const Expanded(
                  child: Text('Notifications',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14))),
              if (_unread > 0)
                TextButton(
                    onPressed: _markAllRead,
                    child: const Text('Mark all read', style: TextStyle(fontSize: 12))),
            ]),
          ),
          const Divider(height: 1),
          Flexible(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                : _items.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(28),
                        child: Text('No notifications yet',
                            style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final n = _items[i];
                          final unread = _isUnread(n);
                          return InkWell(
                            onTap: () => _open(n),
                            child: Container(
                              color: unread ? AppTheme.primary.withOpacity(0.05) : Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: Container(
                                    width: 8, height: 8,
                                    decoration: BoxDecoration(
                                        color: unread ? AppTheme.primary : Colors.transparent,
                                        shape: BoxShape.circle),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text((n['title'] as String?) ?? '',
                                        style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: unread ? FontWeight.w700 : FontWeight.w600)),
                                    if (((n['body'] as String?) ?? '').isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(n['body'] as String,
                                            maxLines: 2, overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                      ),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 3),
                                      child: Text(_ago(n['created_at'] as String?),
                                          style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
                                    ),
                                  ]),
                                ),
                              ]),
                            ),
                          );
                        }),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: Stack(clipBehavior: Clip.none, children: [
        IconButton(
          tooltip: 'Notifications',
          icon: Icon(_overlay != null ? Icons.notifications : Icons.notifications_none,
              color: Colors.white70, size: 20),
          onPressed: _toggleOverlay,
        ),
        if (_unread > 0)
          Positioned(
            right: 6, top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              constraints: const BoxConstraints(minWidth: 16),
              decoration: BoxDecoration(color: AppTheme.danger, borderRadius: BorderRadius.circular(9)),
              child: Text(_unread > 99 ? '99+' : '$_unread',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
            ),
          ),
      ]),
    );
  }
}
