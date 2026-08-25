// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../auth/retailer_auth_controller.dart';
import '../../erp/services/voucher_pdf.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/format/money.dart';

/// Badge counters shared between the tabs (which load the data) and the shell
/// (which paints the badges). Set by the tabs on load / mutation.
final _unreadUpdatesProvider = StateProvider<int>((_) => 0);
final _openComplaintsProvider = StateProvider<int>((_) => 0);

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
  // Whether this retailer may see their account ledger (admin toggle). Loaded
  // once on open; the Ledger tab is appended only when true.
  bool _ledgerEnabled = false;

  static const _baseTabs = [
    (icon: Icons.notifications_outlined, label: 'Updates'),
    (icon: Icons.folder_outlined, label: 'Files'),
    (icon: Icons.receipt_long_outlined, label: 'Invoices'),
    (icon: Icons.report_problem_outlined, label: 'Complaints'),
    (icon: Icons.location_on_outlined, label: 'Location'),
  ];

  List<({IconData icon, String label})> get _tabs => [
        ..._baseTabs,
        if (_ledgerEnabled)
          (icon: Icons.account_balance_wallet_outlined, label: 'Ledger'),
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptPassword());
    _loadLedgerFlag();
  }

  Future<void> _loadLedgerFlag() async {
    try {
      final res =
          await Supabase.instance.client.rpc('retailer_ledger_enabled');
      if (mounted) setState(() => _ledgerEnabled = res == true);
    } catch (_) {
      // RPC not deployed yet / not permitted — keep the tab hidden.
    }
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
                        badge: i == 0
                            ? ref.watch(_unreadUpdatesProvider)
                            : i == 3
                                ? ref.watch(_openComplaintsProvider)
                                : 0,
                        onTap: () => setState(() => _tab = i),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: IndexedStack(
                index: _tab.clamp(0, _tabs.length - 1),
                children: [
                  const _NotificationsTab(),
                  const _FilesTab(),
                  const _OrdersTab(),
                  const _ComplaintsTab(),
                  const _LocationTab(),
                  if (_ledgerEnabled) const _LedgerTab(),
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
  final int badge;
  final VoidCallback onTap;
  const _TabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = 0,
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
          if (badge > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.danger,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('$badge',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
          ],
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
  bool _unreadOnly = false;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _syncBadge() {
    final unread = _items.where((n) => n['read_at'] == null).length;
    ref.read(_unreadUpdatesProvider.notifier).state = unread;
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
      _syncBadge();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) _snack(context, 'Could not load updates');
    }
  }

  Future<void> _markRead(Map<String, dynamic> n) async {
    if (n['read_at'] != null) return;
    try {
      await Supabase.instance.client.rpc('retailer_mark_notification_read',
          params: {'p_notification_id': n['id']});
      if (!mounted) return;
      setState(() => n['read_at'] = DateTime.now().toIso8601String());
      _syncBadge();
    } catch (_) {}
  }

  Future<void> _open(Map<String, dynamic> n) async {
    await _markRead(n);
    final link = n['link_url'] as String?;
    final img = n['image_url'] as String?;
    if (link != null && link.isNotEmpty) {
      html.window.open(link, '_blank');
    } else if (img != null && img.isNotEmpty) {
      html.window.open(img, '_blank');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final visible =
        _unreadOnly ? _items.where((n) => n['read_at'] == null).toList() : _items;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            ChoiceChip(
              label: const Text('All'),
              selected: !_unreadOnly,
              onSelected: (_) => setState(() => _unreadOnly = false),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('Unread'),
              selected: _unreadOnly,
              onSelected: (_) => setState(() => _unreadOnly = true),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ]),
        ),
        Expanded(
          child: visible.isEmpty
              ? _empty(_unreadOnly ? 'No unread updates.' : 'No updates yet.',
                  Icons.notifications_off_outlined)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final n = visible[i];
                    final unread = n['read_at'] == null;
                    final img = n['image_url'] as String?;
                    final link = (n['link_url'] as String?)?.isNotEmpty == true;
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: unread
                                ? AppTheme.primary.withOpacity(0.4)
                                : AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            onTap: () => _open(n),
                            leading: CircleAvatar(
                              backgroundColor:
                                  AppTheme.primary.withOpacity(0.1),
                              child: Icon(
                                  unread
                                      ? Icons.mark_email_unread_outlined
                                      : Icons.mark_email_read_outlined,
                                  color: AppTheme.primary,
                                  size: 20),
                            ),
                            title: Text(n['title'] as String? ?? '',
                                style: TextStyle(
                                    fontWeight: unread
                                        ? FontWeight.w800
                                        : FontWeight.w600)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if ((n['body'] as String?)?.isNotEmpty == true)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(n['body'] as String),
                                  ),
                                const SizedBox(height: 4),
                                Text(
                                  n['created_at'] != null
                                      ? _df.format(
                                          DateTime.parse('${n['created_at']}')
                                              .toLocal())
                                      : '',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textSecondary),
                                ),
                              ],
                            ),
                            trailing: unread
                                ? IconButton(
                                    tooltip: 'Mark read',
                                    icon: const Icon(
                                        Icons.radio_button_unchecked,
                                        size: 18,
                                        color: AppTheme.textSecondary),
                                    onPressed: () => _markRead(n),
                                  )
                                : const Icon(Icons.check_circle,
                                    size: 18, color: Colors.green),
                          ),
                          if (img != null && img.isNotEmpty)
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              child: InkWell(
                                onTap: () {
                                  _markRead(n);
                                  html.window.open(img, '_blank');
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Image.network(img,
                                          width: double.infinity,
                                          height: 160,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const SizedBox()),
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius:
                                              BorderRadius.circular(20),
                                        ),
                                        child: const Icon(Icons.zoom_out_map,
                                            color: Colors.white, size: 18),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (link)
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: Row(children: const [
                                Icon(Icons.open_in_new,
                                    size: 14, color: AppTheme.primary),
                                SizedBox(width: 6),
                                Text('Open link',
                                    style: TextStyle(
                                        color: AppTheme.primary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ]),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
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
// Invoices (read-only list + openable PDF, same renderer as staff)
// ════════════════════════════════════════════════════════════════════
class _OrdersTab extends ConsumerStatefulWidget {
  const _OrdersTab();
  @override
  ConsumerState<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends ConsumerState<_OrdersTab> {
  bool _loading = true;
  String? _openingId;
  List<Map<String, dynamic>> _invoices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_invoices');
      final list = (res as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _invoices =
            list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) _snack(context, 'Could not load invoices');
    }
  }

  Future<void> _openPdf(Map<String, dynamic> inv) async {
    setState(() => _openingId = inv['id'] as String?);
    try {
      final res = await Supabase.instance.client.rpc('retailer_invoice_detail',
          params: {'p_invoice_id': inv['id']});
      final m = Map<String, dynamic>.from(res as Map);
      final header = Map<String, dynamic>.from(m['invoice'] as Map);
      final lines = (m['lines'] as List?) ?? [];
      final orgName = m['org_name'] as String? ?? 'Opstation';

      final vlines = lines.map((e) {
        final l = Map<String, dynamic>.from(e as Map);
        return VoucherLine(
          product: l['product'] as String? ?? '-',
          sku: l['sku'] as String?,
          uom: l['uom'] as String?,
          qty: (l['qty'] as num?)?.toDouble() ?? 0,
          unitPrice: (l['unit_price'] as num?)?.toDouble(),
          discountPct: (l['discount'] as num?)?.toDouble(),
          lineTotal: (l['line_total'] as num?)?.toDouble(),
        );
      }).toList();

      final dateStr = header['voucher_date'] != null
          ? DateFormat('d MMM yyyy')
              .format(DateTime.parse('${header['voucher_date']}'))
          : null;

      await VoucherPdf.printVoucher(
        voucherNumber: header['voucher_number'] as String? ?? '-',
        voucherTypeLabel: 'Sales Invoice',
        orgName: orgName,
        date: dateStr,
        customerOrSupplier: ref.read(currentRetailerProvider)?.name,
        lines: vlines,
        subtotal: (header['subtotal'] as num?)?.toDouble(),
        discountTotal: (header['discount_total'] as num?)?.toDouble(),
        grandTotal: (header['grand_total'] as num?)?.toDouble(),
      );
    } catch (e) {
      if (mounted) _snack(context, 'Could not open invoice');
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_invoices.isEmpty) {
      return _empty('No invoices yet.', Icons.receipt_long_outlined);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _invoices.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final inv = _invoices[i];
          final total = (inv['grand_total'] as num?);
          final opening = _openingId == inv['id'];
          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: ListTile(
              onTap: opening ? null : () => _openPdf(inv),
              leading: CircleAvatar(
                backgroundColor: AppTheme.primary.withOpacity(0.1),
                child: const Icon(Icons.description_outlined,
                    color: AppTheme.primary),
              ),
              title: Text(inv['voucher_number'] as String? ?? 'Invoice',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                [
                  if (total != null) 'Rs ${money(total)}',
                  if (inv['voucher_date'] != null)
                    DateFormat('d MMM yyyy')
                        .format(DateTime.parse('${inv['voucher_date']}')),
                ].join('  •  '),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.picture_as_pdf_outlined,
                      size: 20, color: AppTheme.primary),
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
      final open = _items
          .where((c) => c['status'] == 'open' || c['status'] == 'in_progress')
          .length;
      ref.read(_openComplaintsProvider.notifier).state = open;
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
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width < 600
                        ? MediaQuery.of(context).size.width - 48
                        : 520,
                    height: 260,
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: LatLng(
                            (lat as num).toDouble(), (lng as num).toDouble()),
                        initialZoom: 16,
                        interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.pinchZoom |
                                InteractiveFlag.drag |
                                InteractiveFlag.doubleTapZoom),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'app.opstation.web',
                        ),
                        MarkerLayer(markers: [
                          Marker(
                            point: LatLng((lat).toDouble(), (lng).toDouble()),
                            width: 40,
                            height: 40,
                            child: const Icon(Icons.location_on,
                                color: AppTheme.danger, size: 40),
                          ),
                        ]),
                      ],
                    ),
                  ),
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

// ════════════════════════════════════════════════════════════════════
// Ledger (shown only when the admin enabled it for this retailer)
// ════════════════════════════════════════════════════════════════════
class _LedgerTab extends ConsumerStatefulWidget {
  const _LedgerTab();
  @override
  ConsumerState<_LedgerTab> createState() => _LedgerTabState();
}

class _LedgerTabState extends ConsumerState<_LedgerTab> {
  bool _loading = true;
  bool _allowed = true;
  List<Map<String, dynamic>> _entries = [];
  double _debit = 0, _credit = 0, _balance = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _num(Map m, List<String> keys) {
    for (final k in keys) {
      final val = m[k];
      if (val == null) continue;
      final s = val.toString();
      if (s.isNotEmpty && s != 'null' && DateTime.tryParse(s) != null) return s;
    }
    return '';
  }

  static double _amt(Map m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is num) return v.toDouble();
      if (v is String) {
        final p = double.tryParse(v);
        if (p != null) return p;
      }
    }
    return 0;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_ledger');
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (m['visible'] == false) {
        if (mounted) setState(() { _allowed = false; _loading = false; });
        return;
      }
      final entries = _build(m);
      double d = 0, c = 0, bal = 0;
      for (final e in entries) {
        d += e['debit'] as double;
        c += e['credit'] as double;
        bal += (e['debit'] as double) - (e['credit'] as double);
        e['balance'] = bal;
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _debit = d;
        _credit = c;
        _balance = bal;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      if (mounted) _snack(context, 'Could not load ledger');
    }
  }

  // Same sourcing/netting the staff ledger uses, over the raw rows the RPC
  // returns. Debit = owed by customer, Credit = paid/returned.
  List<Map<String, dynamic>> _build(Map<String, dynamic> m) {
    final out = <Map<String, dynamic>>[];
    List asList(String k) => (m[k] as List?) ?? const [];

    for (final raw in asList('sales_invoices')) {
      final si = Map<String, dynamic>.from(raw as Map);
      if (si['is_voided'] == true) continue;
      final total = _amt(si, const ['total', 'total_amount', 'grand_total', 'net_amount']);
      if (total <= 0) continue;
      out.add({
        'date': _num(si, const ['voucher_date', 'invoice_date', 'si_date', 'date', 'posted_at', 'created_at']),
        'voucher': (si['invoice_number'] ?? si['voucher_number'] ?? si['si_number'] ?? '').toString(),
        'description': (si['remarks'] as String?)?.trim() ?? '',
        'debit': total, 'credit': 0.0, 'type': 'Sales Invoice',
      });
    }

    final pos = [for (final t in asList('pos_transactions')) Map<String, dynamic>.from(t as Map)];
    final posById = {for (final t in pos) if (t['id'] is String) t['id'] as String: t};
    for (final t in pos) {
      final ttype = (t['transaction_type'] as String?) ?? 'sale';
      final raw = _amt(t, const ['total']);
      if (ttype == 'expense' || raw == 0) continue;
      final vno = (t['transaction_number'] as String?)?.isNotEmpty == true
          ? t['transaction_number'] as String
          : 'POS';
      final amt = raw.abs();
      final isReturn = ttype == 'return' || raw < 0;
      final dateStr = (t['transacted_at'] ?? t['created_at'] ?? '').toString();
      if (isReturn) {
        out.add({'date': dateStr, 'voucher': vno, 'description': '', 'debit': 0.0, 'credit': amt, 'type': 'POS Return'});
        double cashRefund = amt;
        Map<String, dynamic>? orig;
        for (final f in const ['reference_transaction_id', 'original_transaction_id', 'parent_transaction_id', 'ref_transaction_id', 'reference_id']) {
          final rid = t[f];
          if (rid is String && posById[rid] != null) { orig = posById[rid]; break; }
        }
        if (orig != null) {
          final ot = _amt(orig, const ['total']);
          final op = orig['amount_paid'] == null ? ot : _amt(orig, const ['amount_paid']);
          cashRefund = (amt - (ot - op)).clamp(0.0, amt).toDouble();
        }
        if (cashRefund > 0) {
          out.add({'date': dateStr, 'voucher': vno, 'description': 'Cash refund', 'debit': cashRefund, 'credit': 0.0, 'type': 'POS Refund (Cash)'});
        }
      } else {
        out.add({'date': dateStr, 'voucher': vno, 'description': '', 'debit': amt, 'credit': 0.0, 'type': 'POS Sale'});
        final paid = (t['amount_paid'] == null ? amt : _amt(t, const ['amount_paid'])).clamp(0.0, amt).toDouble();
        if (paid > 0) {
          out.add({'date': dateStr, 'voucher': vno, 'description': 'Paid at POS', 'debit': 0.0, 'credit': paid, 'type': 'POS Payment'});
        }
      }
    }

    for (final raw in asList('sales_return_invoices')) {
      final sr = Map<String, dynamic>.from(raw as Map);
      if (sr['is_voided'] == true) continue;
      final total = _amt(sr, const ['total', 'total_amount', 'grand_total', 'amount', 'net_amount', 'return_total', 'refund_amount', 'value', 'subtotal']);
      if (total <= 0) continue;
      out.add({
        'date': _num(sr, const ['return_date', 'invoice_date', 'voucher_date', 'sri_date', 'srn_date', 'date', 'posted_at', 'created_at']),
        'voucher': (sr['invoice_number'] ?? sr['return_number'] ?? sr['srn_number'] ?? sr['sri_number'] ?? sr['voucher_number'] ?? sr['return_no'] ?? '').toString(),
        'description': (sr['remarks'] as String?)?.trim() ?? '',
        'debit': 0.0, 'credit': total, 'type': 'Sale Return',
      });
    }

    for (final raw in asList('crv')) {
      final r = Map<String, dynamic>.from(raw as Map);
      out.add({
        'date': (r['date'] ?? '').toString(),
        'voucher': (r['voucher'] ?? '').toString(),
        'description': (r['description'] as String?)?.trim() ?? '',
        'debit': 0.0, 'credit': _amt(r, const ['amount']), 'type': 'Receipt (CRV)',
      });
    }
    for (final raw in asList('cpv')) {
      final r = Map<String, dynamic>.from(raw as Map);
      out.add({
        'date': (r['date'] ?? '').toString(),
        'voucher': (r['voucher'] ?? '').toString(),
        'description': (r['description'] as String?)?.trim() ?? '',
        'debit': _amt(r, const ['amount']), 'credit': 0.0, 'type': 'Payment (CPV)',
      });
    }
    for (final raw in asList('jv')) {
      final r = Map<String, dynamic>.from(raw as Map);
      final ref = (r['reference_type'] as String?) ?? 'jv';
      final opening = ref == 'opening_jv' || ref == 'opening_balance';
      out.add({
        'date': (r['date'] ?? '').toString(),
        'voucher': (r['voucher'] ?? '').toString(),
        'description': (r['description'] as String?)?.trim() ?? '',
        'debit': _amt(r, const ['debit']), 'credit': _amt(r, const ['credit']),
        'type': opening ? 'Opening Balance' : 'Journal (JV)',
      });
    }

    int seq(Map e) => (e['type'] == 'POS Payment' || e['type'] == 'POS Refund (Cash)') ? 1 : 0;
    out.sort((a, b) {
      final d = (a['date'] as String).compareTo(b['date'] as String);
      return d != 0 ? d : seq(a).compareTo(seq(b));
    });
    return out;
  }

  String _fmtDate(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? '-' : DateFormat('d MMM yyyy').format(d.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (!_allowed) {
      return _empty('Ledger is not available for your account.',
          Icons.account_balance_wallet_outlined);
    }
    if (_entries.isEmpty) {
      return _empty('No ledger entries yet.',
          Icons.account_balance_wallet_outlined);
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          Expanded(
            child: Wrap(spacing: 10, runSpacing: 8, children: [
              _stat('Total Debit', _debit, AppTheme.primary),
              _stat('Total Credit', _credit, AppTheme.success),
              _stat('Balance', _balance, _balance >= 0 ? AppTheme.danger : AppTheme.success),
            ]),
          ),
          OutlinedButton.icon(
            onPressed: _printLedger,
            icon: const Icon(Icons.print_outlined, size: 16),
            label: const Text('Print / PDF'),
          ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _entries.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) {
              final e = _entries[i];
              final debit = e['debit'] as double;
              final credit = e['credit'] as double;
              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        [
                          if ((e['voucher'] as String).isNotEmpty) e['voucher'],
                          e['type'],
                        ].join('  •  '),
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          _fmtDate(e['date'] as String),
                          if ((e['description'] as String).isNotEmpty) e['description'],
                        ].join('  •  '),
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 10),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(
                      debit > 0 ? 'Dr ${money(debit)}' : 'Cr ${money(credit)}',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: debit > 0 ? AppTheme.primary : AppTheme.success),
                    ),
                    const SizedBox(height: 2),
                    Text('Bal ${money(e['balance'] as double)}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ]),
                ]),
              );
            },
          ),
        ),
      ),
    ]);
  }

  Widget _stat(String label, double v, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label.toUpperCase(),
              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.4)),
          const SizedBox(height: 2),
          Text('Rs ${money(v)}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c)),
        ]),
      );

  void _printLedger() {
    final name = ref.read(currentRetailerProvider)?.name ?? 'Customer';
    final gen = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    final rows = StringBuffer();
    for (final e in _entries) {
      final debit = e['debit'] as double;
      final credit = e['credit'] as double;
      rows.write('<tr>'
          '<td>${_fmtDate(e['date'] as String)}</td>'
          '<td>${e['voucher']}</td>'
          '<td>${e['description']}</td>'
          '<td>${e['type']}</td>'
          '<td class="num">${debit > 0 ? 'Rs ' + money(debit) : '-'}</td>'
          '<td class="num">${credit > 0 ? 'Rs ' + money(credit) : '-'}</td>'
          '<td class="num">Rs ${money(e['balance'] as double)}</td>'
          '</tr>');
    }
    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>${name}_Ledger</title>'
        '<style>@page{margin:0}'
        '.no-print{margin-bottom:10px}.no-print button{padding:6px 14px;font-size:13px;cursor:pointer}'
        '@media print{.no-print{display:none}}'
        'body{font-family:Arial,sans-serif;padding:16px;font-size:10px;color:#000}'
        '.header{border-bottom:2px solid #000;padding-bottom:8px;margin-bottom:10px}'
        'h1{font-size:18px;margin:0 0 4px 0}.info{font-size:10px;margin:2px 0}'
        'table{width:100%;border-collapse:collapse}'
        'th,td{padding:4px 6px;border-bottom:1px solid #ddd;text-align:left;font-size:9.5px}'
        'th{background:#f5f5f5;font-weight:700;border-bottom:1.5px solid #000}'
        '.num{text-align:right;white-space:nowrap}'
        'tfoot td{font-weight:800;background:#f5f5f5;border-top:2px solid #000}'
        '</style></head><body>'
        '<div class="no-print"><button onclick="window.print()">Print / Save as PDF</button></div>'
        '<div class="header"><h1>Account Ledger</h1>'
        '<div class="info"><strong>Customer:</strong> $name</div>'
        '<div class="info"><strong>Generated:</strong> $gen</div></div>'
        '<table><thead><tr><th>Date</th><th>Voucher</th><th>Description</th><th>Type</th>'
        '<th class="num">Debit</th><th class="num">Credit</th><th class="num">Balance</th></tr></thead>'
        '<tbody>$rows</tbody>'
        '<tfoot><tr><td colspan="4">${_entries.length} entries</td>'
        '<td class="num">Rs ${money(_debit)}</td><td class="num">Rs ${money(_credit)}</td>'
        '<td class="num">Rs ${money(_balance)}</td></tr></tfoot>'
        '</table></body></html>';
    final blob = html.Blob([doc], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 5), () => html.Url.revokeObjectUrl(url));
  }
}
