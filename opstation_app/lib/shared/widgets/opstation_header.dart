import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/sound_controller.dart';
import '../../core/theme/theme_controller.dart';
import '../../features/auth/providers/auth_controller.dart';
import 'sync_status_chip.dart';

/// Row of header action buttons shown on role home screens.
/// Mirrors the existing Opstation app: sync status, sound, theme toggle, logout.
class OpstationHeaderActions extends ConsumerWidget {
  const OpstationHeaderActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeControllerProvider);
    final isDark = themeMode == ThemeMode.dark;
    final soundOn = ref.watch(soundControllerProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SyncStatusChip(),
        const SizedBox(width: 4),
        _HeaderIconButton(
          icon: soundOn ? Icons.volume_up_outlined : Icons.volume_off_outlined,
          tooltip: soundOn ? 'Mute sounds' : 'Enable sounds',
          onTap: () => ref.read(soundControllerProvider.notifier).toggle(),
        ),
        _HeaderIconButton(
          icon: isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
          onTap: () => ref.read(themeControllerProvider.notifier).toggle(),
        ),
        _HeaderIconButton(
          icon: Icons.logout,
          tooltip: 'Sign out',
          onTap: () => ref.read(authControllerProvider.notifier).signOut(),
        ),
      ],
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 22),
        onPressed: onTap,
      ),
    );
  }
}
