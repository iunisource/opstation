// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Admin "Notifications" composer (Operations menu). Sends a push + saves a
/// drawer entry to any combination of user groups (roles) or a specific
/// customer. Recipients are resolved at send time and fanned out into
/// `notification_recipients` (which backs each user's drawer + read-state);
/// the existing push Edge Function is then invoked to deliver.
class NotificationsComposerScreen extends ConsumerStatefulWidget {
  const NotificationsComposerScreen({super.key});
  @override
  ConsumerState<NotificationsComposerScreen> createState() =>
      _NotificationsComposerScreenState();
}

class _NotificationsComposerScreenState
    extends ConsumerState<NotificationsComposerScreen> {
  // Batch push Edge Function (deploy send-notification-batch alongside your
  // existing send-notification). Reuses users.fcm_token + your FCM auth.
  static const _pushFunction = 'send-notification-batch';
  // Public bucket reused for notification images (URL must be directly usable
  // by push + drawer); 'opstation-photos' is already public in this project.
  static const _imageBucket = 'opstation-photos';
  static const _maxImageBytes = 5 * 1024 * 1024; // 5 MB

  bool _loading = true;
  List<Map<String, dynamic>> _recent = [];
  List<String> _roles = [];
  final _df = DateFormat('d MMM y, h:mm a');
  DateTime? _from;
  DateTime? _to;

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
      final client = Supabase.instance.client;
      final recent = await client
          .from('notifications')
          .select()
          .eq('org_id', orgId)
          .order('created_at', ascending: false)
          .limit(50);
      final userRows =
          await client.from('users').select('role').eq('org_id', orgId);
      final roles = <String>{};
      for (final r in userRows as List) {
        final role = (r['role'] as String?)?.trim();
        if (role != null && role.isNotEmpty) roles.add(role);
      }
      if (!mounted) return;
      setState(() {
        _recent = List<Map<String, dynamic>>.from(recent);
        _roles = roles.toList()..sort();
        _loading = false;
      });
    } catch (e) {
      _snack('Load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  String _mimeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.gif')) return 'image/gif';
    return 'application/octet-stream';
  }

  Future<Map<String, dynamic>?> _pickCustomer() async {
    final searchCtrl = TextEditingController();
    List<Map<String, dynamic>> results = [];
    bool searching = false;
    Timer? debounce;

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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search by shop name or code',
                  suffixIcon: IconButton(
                      icon: const Icon(Icons.search), onPressed: () => run(setS)),
                ),
                onChanged: (_) {
                  debounce?.cancel();
                  debounce = Timer(const Duration(milliseconds: 350), () => run(setS));
                },
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
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }

  // ── compose + send ─────────────────────────────────────────────────────
  Future<void> _composeDialog() async {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final linkCtrl = TextEditingController();
    String audience = 'all';
    final Set<String> selectedRoles = {};
    Map<String, dynamic>? customer;
    Uint8List? imageBytes;
    String? imageName;
    bool sending = false;

    void pickImage(StateSetter setS) {
      final input = html.FileUploadInputElement()
        ..accept = 'image/png,image/jpeg,image/webp,image/gif';
      input.click();
      input.onChange.listen((_) {
        final files = input.files;
        if (files == null || files.isEmpty) return;
        final f = files[0];
        if (f.size > _maxImageBytes) {
          _snack('Image too large — max 5 MB');
          return;
        }
        final reader = html.FileReader();
        reader.readAsArrayBuffer(f);
        reader.onLoad.listen((_) {
          final result = reader.result;
          final data =
              result is ByteBuffer ? result.asUint8List() : result as Uint8List;
          setS(() {
            imageBytes = data;
            imageName = f.name;
          });
        });
      });
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> send() async {
            final orgId = _orgId;
            if (orgId == null) return;
            final title = titleCtrl.text.trim();
            if (title.isEmpty) {
              _snack('Give the notification a title');
              return;
            }
            if (audience == 'roles' && selectedRoles.isEmpty) {
              _snack('Pick at least one group');
              return;
            }
            if (audience == 'customer' && customer == null) {
              _snack('Pick the customer');
              return;
            }
            setS(() => sending = true);
            try {
              final client = Supabase.instance.client;

              // optional image -> public bucket
              String? imageUrl;
              if (imageBytes != null && imageName != null) {
                final safe = imageName!.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
                final path =
                    'notifications/$orgId/${DateTime.now().millisecondsSinceEpoch}_$safe';
                await client.storage.from(_imageBucket).uploadBinary(
                      path,
                      imageBytes!,
                      fileOptions:
                          FileOptions(contentType: _mimeFor(imageName!), upsert: false),
                    );
                imageUrl = client.storage.from(_imageBucket).getPublicUrl(path);
              }

              final link = linkCtrl.text.trim();

              // 1) notification row
              final inserted = await client
                  .from('notifications')
                  .insert({
                    'org_id': orgId,
                    'title': title,
                    'body': bodyCtrl.text.trim().isEmpty ? null : bodyCtrl.text.trim(),
                    'audience': audience,
                    'audience_ref': audience == 'customer' ? customer!['id'] : null,
                    'audience_roles':
                        audience == 'roles' ? selectedRoles.toList() : null,
                    'image_url': imageUrl,
                    'link_url': link.isEmpty ? null : link,
                    'created_by': client.auth.currentUser?.id,
                  })
                  .select('id')
                  .single();
              final notifId = inserted['id'] as String;

              // 2) resolve recipients
              var q = client.from('users').select('id').eq('org_id', orgId);
              if (audience == 'roles') {
                q = q.inFilter('role', selectedRoles.toList());
              } else if (audience == 'customer') {
                q = q.eq('customer_id', customer!['id']);
              }
              final recips = await q;
              final ids = [
                for (final r in recips as List) r['id'] as String,
              ];

              // 3) fan out drawer rows
              if (ids.isNotEmpty) {
                await client.from('notification_recipients').insert([
                  for (final uid in ids)
                    {'notification_id': notifId, 'recipient_user_id': uid},
                ]);
              }

              // 4) hand off to push (best-effort; drawer already populated)
              try {
                final data = <String, String>{'notification_id': notifId};
                if (imageUrl != null) data['image_url'] = imageUrl;
                if (link.isNotEmpty) data['link_url'] = link;
                await client.functions.invoke(_pushFunction, body: {
                  'recipient_user_ids': ids,
                  'title': title,
                  'body': bodyCtrl.text.trim(),
                  'data': data,
                });
              } catch (_) {/* push delivery is best-effort */}

              if (mounted) Navigator.pop(ctx);
              _snack('Sent to ${ids.length} recipient${ids.length == 1 ? '' : 's'}');
              _load();
            } catch (e) {
              setS(() => sending = false);
              _snack('Send failed: ${e.toString().split('\n').first}');
            }
          }

          return AlertDialog(
            title: const Text('New notification'),
            content: SizedBox(
              width: 500,
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
                      controller: bodyCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Message'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: linkCtrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                          labelText: 'Link (optional)',
                          hintText: 'https://…',
                          prefixIcon: Icon(Icons.link, size: 18)),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.image_outlined, size: 18),
                        label: Text(imageName == null ? 'Add image' : 'Change image'),
                        onPressed: sending ? null : () => pickImage(setS),
                      ),
                      const SizedBox(width: 10),
                      if (imageName != null)
                        Expanded(
                          child: Text(imageName!,
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                        ),
                    ]),
                    const Divider(height: 28),
                    const Text('Send to',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, children: [
                      ChoiceChip(
                        label: const Text('All users'),
                        selected: audience == 'all',
                        onSelected: (_) => setS(() => audience = 'all'),
                      ),
                      ChoiceChip(
                        label: const Text('Groups'),
                        selected: audience == 'roles',
                        onSelected: (_) => setS(() => audience = 'roles'),
                      ),
                      ChoiceChip(
                        label: const Text('Specific customer'),
                        selected: audience == 'customer',
                        onSelected: (_) => setS(() => audience = 'customer'),
                      ),
                    ]),
                    if (audience == 'roles') ...[
                      const SizedBox(height: 12),
                      if (_roles.isEmpty)
                        const Text('No user groups found.',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final role in _roles)
                              FilterChip(
                                label: Text(role),
                                selected: selectedRoles.contains(role),
                                onSelected: (s) => setS(() {
                                  if (s) {
                                    selectedRoles.add(role);
                                  } else {
                                    selectedRoles.remove(role);
                                  }
                                }),
                              ),
                          ],
                        ),
                    ],
                    if (audience == 'customer') ...[
                      const SizedBox(height: 12),
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
                  onPressed: sending ? null : () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: sending ? null : send,
                child: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Send'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _audienceLabel(Map<String, dynamic> n) {
    switch (n['audience']) {
      case 'roles':
        final r = (n['audience_roles'] as List?)?.cast<String>() ?? [];
        return r.isEmpty ? 'Groups' : r.join(', ');
      case 'customer':
        return 'Specific customer';
      default:
        return 'All users';
    }
  }

  List<Map<String, dynamic>> get _filteredRecent {
    if (_from == null && _to == null) return _recent;
    return _recent.where((n) {
      final ts = DateTime.tryParse('${n['created_at']}');
      if (ts == null) return false;
      final d = ts.toLocal();
      if (_from != null &&
          d.isBefore(DateTime(_from!.year, _from!.month, _from!.day))) {
        return false;
      }
      if (_to != null &&
          d.isAfter(DateTime(_to!.year, _to!.month, _to!.day, 23, 59, 59))) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<void> _pickRange(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2023),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => isFrom ? _from = picked : _to = picked);
  }

  void _openDetail(Map<String, dynamic> n) {
    final img = n['image_url'] as String?;
    final link = n['link_url'] as String?;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n['title'] as String? ?? 'Notification'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    _audienceLabel(n),
                    if (n['created_at'] != null)
                      _df.format(
                          DateTime.parse('${n['created_at']}').toLocal()),
                  ].join('  •  '),
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 12),
                if ((n['body'] as String?)?.isNotEmpty == true)
                  Text(n['body'] as String),
                if (img != null && img.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(img,
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Open image'),
                      onPressed: () => html.window.open(img, '_blank'),
                    ),
                  ),
                ],
                if (link != null && link.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.link, size: 16),
                      label: Text(link, overflow: TextOverflow.ellipsis),
                      onPressed: () => html.window.open(link, '_blank'),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _dateChip(String label, DateTime? value, VoidCallback onTap) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.calendar_today_outlined, size: 15),
      label: Text(value == null
          ? label
          : '$label: ${DateFormat('d MMM y').format(value)}'),
      onPressed: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Notifications',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.campaign_outlined, size: 18),
              label: const Text('New notification'),
              onPressed: _composeDialog,
            ),
          ]),
          const SizedBox(height: 8),
          const Text(
              'Push a message to any group of app users; it is also saved in their notification drawer.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Row(children: [
            _dateChip('From', _from, () => _pickRange(true)),
            const SizedBox(width: 8),
            _dateChip('To', _to, () => _pickRange(false)),
            if (_from != null || _to != null) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('Clear'),
                onPressed: () => setState(() {
                  _from = null;
                  _to = null;
                }),
              ),
            ],
            const Spacer(),
            Text('${_filteredRecent.length} shown',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filteredRecent.isEmpty
                    ? const Center(
                        child: Text('No notifications sent yet.',
                            style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.separated(
                        itemCount: _filteredRecent.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final n = _filteredRecent[i];
                          final hasImg =
                              (n['image_url'] as String?)?.isNotEmpty == true;
                          final hasLink =
                              (n['link_url'] as String?)?.isNotEmpty == true;
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.border),
                            ),
                            child: ListTile(
                              onTap: () => _openDetail(n),
                              leading: CircleAvatar(
                                backgroundColor: AppTheme.primary.withOpacity(0.1),
                                child: const Icon(Icons.campaign_outlined,
                                    color: AppTheme.primary),
                              ),
                              title: Text(n['title'] as String? ?? '',
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if ((n['body'] as String?)?.isNotEmpty == true)
                                    Text(n['body'] as String,
                                        maxLines: 2, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 2),
                                  Text(
                                    [
                                      _audienceLabel(n),
                                      if (n['created_at'] != null)
                                        _df.format(
                                            DateTime.parse('${n['created_at']}')
                                                .toLocal()),
                                    ].join('  •  '),
                                    style: const TextStyle(
                                        fontSize: 12, color: AppTheme.textSecondary),
                                  ),
                                ],
                              ),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                if (hasImg)
                                  const Icon(Icons.image_outlined,
                                      size: 18, color: AppTheme.textSecondary),
                                if (hasLink)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 6),
                                    child: Icon(Icons.link,
                                        size: 18, color: AppTheme.textSecondary),
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
