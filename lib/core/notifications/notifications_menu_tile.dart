import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../../features/auth/auth_controller.dart';
import 'push_service.dart';

/// Compact notifications toggle for the top-right user menu, so ANY user
/// (including non-admin approvers) can enable push on their device.
class NotificationsMenuTile extends ConsumerStatefulWidget {
  const NotificationsMenuTile({super.key});
  @override
  ConsumerState<NotificationsMenuTile> createState() => _NotificationsMenuTileState();
}

class _NotificationsMenuTileState extends ConsumerState<NotificationsMenuTile> {
  bool _enabled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    bool on = false;
    try {
      on = await PushService.isEnabled()
          .timeout(const Duration(seconds: 4), onTimeout: () => false);
    } catch (_) {}
    if (mounted) setState(() => _enabled = on);
  }

  Future<void> _toggle(bool want) async {
    setState(() => _busy = true);
    final u = ref.read(currentUserProvider);
    try {
      if (want) {
        final err = await PushService
            .enable(orgId: u?.orgId ?? '', userId: u?.id ?? '')
            .timeout(const Duration(seconds: 15),
                onTimeout: () => 'Timed out — try again.');
        if (err != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(err), behavior: SnackBarBehavior.floating));
        }
      } else {
        await PushService.disable().timeout(const Duration(seconds: 15),
            onTimeout: () {});
      }
    } catch (_) {}
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final supported = PushService.isSupported;
    return Row(children: [
      const Icon(Icons.notifications_active_outlined,
          size: 15, color: AppTheme.sidebarText),
      const SizedBox(width: 8),
      const Expanded(
        child: Text('Notifications',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
      ),
      if (_busy)
        const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
      else
        Transform.scale(
          scale: 0.72,
          child: Switch(
            value: _enabled,
            onChanged: supported ? (v) => _toggle(v) : null,
          ),
        ),
    ]);
  }
}
