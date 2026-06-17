// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../auth/retailer_auth_controller.dart';
import '../../../core/theme/app_theme.dart';

/// The retailer portal (web). A self-contained shell — NOT inside the staff
/// MainLayout. Tabs read/write only through the retailer_* SECURITY DEFINER
/// RPCs (+ the retailer-file-url Edge Function for private-bucket viewing).
/// Lives at /r.
class RetailerPortalScreen extends ConsumerStatefulWidget {
  const RetailerPortalScreen({super.key});
  @override
  ConsumerState<RetailerPortalScreen> createState() =>
      _RetailerPortalScreenState();
}

class _RetailerPortalScreenState extends ConsumerState<RetailerPortalScreen> {
  int _tab = 0;
  bool _promptedPwd = false;

  static const _tabs = [
    (icon: Icons.notifications_outlined, label: 'Updates'),
    (icon: Icons.folder_outlined, label: 'Files'),
    (icon: Icons.receipt_long_outlined, label: 'Orders'),
    (icon: Icons.report_problem_outlined, label: 'Complaints'),
    (icon: Icons.location_on_outlined, label: 'Location'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptPassword());
  }

  void _maybePromptPassword() {
    if (_promptedPwd) return;
    final r = ref.read(currentRetailerProvider);
    if (r != null && r.mustChangePassword) {
      _promptedPwd = true;
      _showChangePassword(forced: true);
    }
  }

  Future<void> _showChangePassword({bool forced = false}) async {
    final p1 = TextEditingController();
    final p2 = TextEditingController();
    bool saving = false;
    String? error;

    await showDialog(
      context: context,
      barrierDismissible: !forced,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => PopScope(
          canPop: !forced,
          child: AlertDialog(
            title: Text(forced ? 'Set a new password' : 'Change password'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (forced)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                          'For security, please set your own password before continuing.',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textSecondary)),
                    ),
                  TextField(
                    controller: p1,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'New password'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: p2,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'Confirm password'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error!,
                        style: const TextStyle(
                            color: AppTheme.danger, fontSize: 12)),
                  ],
                ],
              ),
            ),
            actions: [
              if (!forced)
                TextButton(
                    onPressed: saving ? null : () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
              ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (p1.text.length < 6) {
                          setS(() => error = 'At least 6 characters.');
                          return;
                        }
                        if (p1.text != p2.text) {
                          setS(() => error = 'Passwords do not match.');
                          return;
                        }
                        setS(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          await ref
                              .read(retailerAuthControllerProvider.notifier)
                              .changePassword(p1.text);
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (e) {
                          setS(() {
                            saving = false;
                            error = e
                                .toString()
                                .replaceFirst('Exception: ', '');
                          });
                        }
                      },
                child: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final retailer = ref.watch(currentRetailerProvider);
    final name = retailer?.name ?? 'Retailer';

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // top bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                border:
                    Border(bottom: BorderSide(color: AppTheme.border, width: 1)),
              ),
              child: Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child:
                      const Icon(Icons.storefront_outlined, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                      const Text('Retailer Portal',
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.account_circle_outlined),
                  onSelected: (v) {
                    if (v == 'password') _showChangePassword();
                    if (v == 'signout') {
                      ref
                          .read(retailerAuthControllerProvider.notifier)
                          .signOut();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'password', child: Text('Change password')),
                    PopupMenuItem(value: 'signout', child: Text('Sign out')),
                  ],
                ),
              ]),
            ),
            // tab selector
            Container(
              color: Colors.white,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (var i = 0; i < _tabs.length; i++)
                      _TabButton(
                        icon: _tabs[i].icon,
                        label: _tabs[i].label,
                        selected: _tab == i,
                        onTap: () => setState(() => _tab = i),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [
                  _NotificationsTab(),
                  _FilesTab(),
                  _OrdersTab(),
                  _ComplaintsTab(),
                  _LocationTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final c = selected ? AppTheme.primary : AppTheme.textSecondary;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                color: selected ? AppTheme.primary : Colors.transparent,
                width: 2.5),
          ),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  color: c,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 14)),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Shared helpers
// ════════════════════════════════════════════════════════════════════
final _df = DateFormat('d MMM y, h:mm a');

void _snack(BuildContext c, String m) {
  ScaffoldMessenger.of(c).showSnackBar(
      SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
}

Widget _empty(String msg, IconData icon) => Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 44, color: AppTheme.textSecondary.withOpacity(0.5)),
        const SizedBox(height: 12),
        Text(msg, style: const TextStyle(color: AppTheme.textSecondary)),
      ]),
    );

// ════════════════════════════════════════════════════════════════════
// Updates / Notifications
// ════════════════════════════════════════════════════════════════════
class _NotificationsTab extends ConsumerStatefulWidget {
  const _NotificationsTab();
  @override
  ConsumerState<_NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends ConsumerState<_NotificationsTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_notifications');
      final list = (res as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _items = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) _snack(context, 'Could not load updates');
    }
  }

  Future<void> _open(Map<String, dynamic> n) async {
    if (n['read_at'] == null) {
      try {
        await Supabase.instance.client.rpc('retailer_mark_notification_read',
            params: {'p_notification_id': n['id']});
        setState(() => n['read_at'] = DateTime.now().toIso8601String());
      } catch (_) {}
    }
    final link = n['link_url'] as String?;
    if (link != null && link.isNotEmpty) html.window.open(link, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return _empty('No updates yet.', Icons.notifications_off_outlined);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final n = _items[i];
          final unread = n['read_at'] == null;
          final img = n['image_url'] as String?;
          final link = (n['link_url'] as String?)?.isNotEmpty == true;
          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: unread ? AppTheme.primary.withOpacity(0.4) : AppTheme.border),
            ),
            child: ListTile(
              onTap: () => _open(n),
              leading: CircleAvatar(
                backgroundColor: AppTheme.primary.withOpacity(0.1),
                child: Icon(
                    unread ? Icons.mark_email_unread_outlined : Icons.email_outlined,
                    color: AppTheme.primary, size: 20),
              ),
              title: Text(n['title'] as String? ?? '',
                  style: TextStyle(
                      fontWeight: unread ? FontWeight.w800 : FontWeight.w600)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if ((n['body'] as String?)?.isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(n['body'] as String),
                    ),
                  if (img != null && img.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(img,
                            height: 140,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox()),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    n['created_at'] != null
                        ? _df.format(DateTime.parse('${n['created_at']}').toLocal())
                        : '',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ],
              ),
              trailing: link
                  ? const Icon(Icons.open_in_new, size: 16, color: AppTheme.textSecondary)
                  : null,
            ),
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Files
// ════════════════════════════════════════════════════════════════════
class _FilesTab extends ConsumerStatefulWidget {
  const _FilesTab();
  @override
  ConsumerState<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<_FilesTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _files = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_files');
      final list = (res as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _files = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) _snack(context, 'Could not load files');
    }
  }

  IconData _iconFor(String? type) {
    switch (type) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'video':
        return Icons.movie_outlined;
      default:
        return Icons.image_outlined;
    }
  }

  Future<void> _view(Map<String, dynamic> f) async {
    try {
      final res = await Supabase.instance.client.functions
          .invoke('retailer-file-url', body: {'fileId': f['id']});
      final url = (res.data is Map) ? res.data['url'] as String? : null;
      if (url == null || url.isEmpty) {
        if (mounted) _snack(context, 'Could not open file');
        return;
      }
      html.window.open(url, '_blank');
    } catch (e) {
      if (mounted) _snack(context, 'Could not open file');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_files.isEmpty) {
      return _empty('No files shared with you yet.', Icons.folder_off_outlined);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _files.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final f = _files[i];
          final type = f['file_type'] as String?;
          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
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
                  (type ?? 'file').toUpperCase(),
                  if (f['created_at'] != null)
                    _df.format(DateTime.parse('${f['created_at']}').toLocal()),
                ].join('  •  '),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.open_in_new, size: 18),
                tooltip: 'Open',
                onPressed: () => _view(f),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Orders (read-only for now)
// ════════════════════════════════════════════════════════════════════
class _OrdersTab extends ConsumerStatefulWidget {
  const _OrdersTab();
  @override
  ConsumerState<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends ConsumerState<_OrdersTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _orders = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_orders');
      final list = (res as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _orders = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) _snack(context, 'Could not load orders');
    }
  }

  String _orderNo(Map<String, dynamic> o) {
    for (final k in ['order_number', 'number', 'voucher_number', 'id']) {
      final v = o[k];
      if (v != null && '$v'.isNotEmpty) return '$v';
    }
    return '—';
  }

  String? _total(Map<String, dynamic> o) {
    for (final k in ['total', 'grand_total', 'net_total', 'total_amount', 'amount']) {
      final v = o[k];
      if (v != null) return '$v';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_orders.isEmpty) {
      return _empty('No orders yet.', Icons.receipt_long_outlined);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _orders.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final o = _orders[i];
          final status = o['status'] as String? ?? '';
          final total = _total(o);
          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.primary.withOpacity(0.1),
                child: const Icon(Icons.receipt_long_outlined,
                    color: AppTheme.primary),
              ),
              title: Text('Order ${_orderNo(o)}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                [
                  if (status.isNotEmpty) status,
                  if (o['created_at'] != null)
                    _df.format(DateTime.parse('${o['created_at']}').toLocal()),
                ].join('  •  '),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: total == null
                  ? null
                  : Text(total,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Complaints
// ════════════════════════════════════════════════════════════════════
class _ComplaintsTab extends ConsumerStatefulWidget {
  const _ComplaintsTab();
  @override
  ConsumerState<_ComplaintsTab> createState() => _ComplaintsTabState();
}

class _ComplaintsTabState extends ConsumerState<_ComplaintsTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_complaints');
      final list = (res as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _items = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) _snack(context, 'Could not load complaints');
    }
  }

  Future<void> _logDialog() async {
    final subject = TextEditingController();
    final desc = TextEditingController();
    bool saving = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Raise a complaint'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: subject,
                decoration: const InputDecoration(labelText: 'Subject *'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: desc,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Details'),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (subject.text.trim().isEmpty) {
                        _snack(ctx, 'Subject is required');
                        return;
                      }
                      setS(() => saving = true);
                      try {
                        await Supabase.instance.client.rpc(
                          'retailer_log_complaint',
                          params: {
                            'p_subject': subject.text.trim(),
                            'p_description': desc.text.trim(),
                          },
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                        _load();
                      } catch (e) {
                        setS(() => saving = false);
                        _snack(ctx, 'Could not submit');
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Submit'),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'resolved':
      case 'closed':
        return Colors.green;
      case 'in_progress':
        return Colors.orange;
      default:
        return AppTheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _logDialog,
        backgroundColor: AppTheme.primary,
        icon: const Icon(Icons.add),
        label: const Text('Raise complaint'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? _empty('No complaints raised.', Icons.check_circle_outline)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final c = _items[i];
                      final status = c['status'] as String? ?? 'open';
                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: ListTile(
                          title: Text(c['subject'] as String? ?? '',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if ((c['description'] as String?)?.isNotEmpty ==
                                  true)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(c['description'] as String),
                                ),
                              const SizedBox(height: 4),
                              Text(
                                c['created_at'] != null
                                    ? _df.format(DateTime.parse(
                                            '${c['created_at']}')
                                        .toLocal())
                                    : '',
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: _statusColor(status).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              status.replaceAll('_', ' '),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: _statusColor(status)),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Location
// ════════════════════════════════════════════════════════════════════
class _LocationTab extends ConsumerStatefulWidget {
  const _LocationTab();
  @override
  ConsumerState<_LocationTab> createState() => _LocationTabState();
}

class _LocationTabState extends ConsumerState<_LocationTab> {
  bool _loading = true;
  bool _sharing = false;
  Map<String, dynamic>? _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_profile');
      final list = (res as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _profile = list.isNotEmpty
            ? Map<String, dynamic>.from(list.first as Map)
            : null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final pos = await html.window.navigator.geolocation.getCurrentPosition(
        enableHighAccuracy: true,
        timeout: const Duration(seconds: 15),
      );
      final lat = pos.coords?.latitude?.toDouble();
      final lng = pos.coords?.longitude?.toDouble();
      if (lat == null || lng == null) throw Exception('No coordinates');
      await Supabase.instance.client.rpc('retailer_update_location',
          params: {'p_lat': lat, 'p_lng': lng});
      if (mounted) _snack(context, 'Location shared');
      await _load();
    } catch (e) {
      if (mounted) {
        _snack(context, 'Could not get location — check browser permission');
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final allowed =
        (_profile?['location_capture_allowed'] as bool?) ?? false;
    final lat = _profile?['latitude'];
    final lng = _profile?['longitude'];
    final updated = _profile?['location_updated_at'];

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on_outlined,
                size: 56, color: AppTheme.primary.withOpacity(0.7)),
            const SizedBox(height: 16),
            if (!allowed) ...[
              const Text('Location sharing is turned off',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 8),
              const Text(
                'Your supplier hasn’t enabled location sharing for your shop.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ] else ...[
              const Text('Share your shop location',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 8),
              const Text(
                'This helps your supplier route deliveries to you accurately.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              if (lat != null && lng != null) ...[
                const SizedBox(height: 16),
                Text('Current pin: $lat, $lng',
                    style: const TextStyle(fontSize: 12)),
                if (updated != null)
                  Text(
                    'Updated ${_df.format(DateTime.parse('$updated').toLocal())}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary),
                  ),
              ],
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _sharing ? null : _share,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 14),
                ),
                icon: _sharing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.my_location),
                label: Text(lat == null
                    ? 'Share my location'
                    : 'Update my location'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
