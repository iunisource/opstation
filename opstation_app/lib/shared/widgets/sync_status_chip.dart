import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/sync_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../features/auth/providers/auth_controller.dart';

/// Small status pill showing sync + connectivity state.
/// Tap opens a panel with more detail and a manual retry.
class SyncStatusChip extends ConsumerWidget {
  const SyncStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncControllerProvider);
    final (icon, color, label) = _styleFor(status);

    return InkWell(
      onTap: () => _showDetails(context, ref),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            if (status.pendingCount > 0 || status.rejectedCount > 0) ...[
              const SizedBox(width: 4),
              Text(
                _badgeCount(status),
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _badgeCount(SyncStatus s) {
    if (s.rejectedCount > 0) return '!';
    return s.pendingCount.toString();
  }

  (IconData, Color, String) _styleFor(SyncStatus s) {
    switch (s.state) {
      case SyncState.synced:
        return (Icons.cloud_done_outlined, AppColors.success, 'Synced');
      case SyncState.syncing:
        return (Icons.cloud_sync_outlined, AppColors.primary, 'Syncing');
      case SyncState.error:
        return (Icons.cloud_off_outlined, AppColors.danger, 'Error');
      case SyncState.offline:
        return (Icons.cloud_off_outlined, AppColors.warningDark, 'Offline');
    }
  }

  void _showDetails(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (_) => Consumer(
        builder: (context, ref, __) {
          final s = ref.watch(syncControllerProvider);
          final (icon, color, label) = _styleFor(s);
          return AlertDialog(
            title: Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Pending', s.pendingCount.toString()),
                _row('Rejected', s.rejectedCount.toString()),
                _row(
                  'Last synced',
                  s.lastSyncedAt == null
                      ? '—'
                      : TimeOfDay.fromDateTime(s.lastSyncedAt!).format(context),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  final user = ref.read(authControllerProvider).valueOrNull;
                  ref.read(syncControllerProvider.notifier).refreshNow(
                        orgId: ref.read(orgIdProvider),
                        userId: user?.id,
                      );
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry now'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              k,
              style: const TextStyle(
                color: AppColors.textSecondaryLight,
                fontSize: 13,
              ),
            ),
          ),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
