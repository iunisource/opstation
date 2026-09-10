import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/notifications/push_service.dart';

/// Admin Settings card: enable/disable browser push notifications on THIS device.
class PushNotificationSettings extends ConsumerStatefulWidget {
  final String orgId;
  final String? userId;
  const PushNotificationSettings({super.key, required this.orgId, this.userId});

  @override
  ConsumerState<PushNotificationSettings> createState() =>
      _PushNotificationSettingsState();
}

class _PushNotificationSettingsState
    extends ConsumerState<PushNotificationSettings> {
  bool _enabled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    // Best-effort; never block the UI on it (timeout guards a slow/odd browser).
    bool on = false;
    try {
      on = await PushService.isEnabled()
          .timeout(const Duration(seconds: 4), onTimeout: () => false);
    } catch (_) {}
    if (mounted) setState(() => _enabled = on);
  }

  Future<void> _toggle(bool want) async {
    setState(() => _busy = true);
    if (want) {
      final err = await PushService.enable(
          orgId: widget.orgId, userId: widget.userId ?? '');
      if (err != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(err), behavior: SnackBarBehavior.floating));
      }
    } else {
      await PushService.disable();
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final supported = PushService.isSupported;
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.notifications_active_outlined,
                      size: 18, color: AppTheme.primary),
                  const SizedBox(width: 8),
                  const Text('Notifications (this device)',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 4),
                Text(
                  supported
                      ? 'Get a notification when something needs your attention (invoices to review, new POs, transfers to approve) — even when the app is in the background. Turn this on for each device/browser you use. On iPhone, first add Opstation to your Home Screen.'
                      : 'This browser does not support notifications. Try Chrome/Edge on desktop, or install Opstation to your Home Screen on mobile.',
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
                ),
                if (_loaded && supported && !_enabled &&
                    PushService.permission == 'denied') ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Notifications are blocked in this browser. Allow them in the site settings, then turn this on.',
                    style: TextStyle(fontSize: 12, color: AppTheme.danger),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (_busy)
            const SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Switch(
              value: _enabled,
              onChanged: supported ? (v) => _toggle(v) : null,
            ),
        ],
      ),
    );
  }
}
