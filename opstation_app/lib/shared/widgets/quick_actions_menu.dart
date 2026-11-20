import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// One entry of the Quick Actions menu.
class QuickActionItem {
  const QuickActionItem({
    required this.id,
    required this.label,
    required this.hint,
    required this.icon,
    required this.bg,
    required this.fg,
  });

  /// What [showQuickActionsMenu] returns when this entry is tapped.
  final String id;
  final String label;
  final String hint;
  final IconData icon;
  final Color bg;
  final Color fg;
}

/// The floating "Quick Actions" button (bolt), the same as on the salesperson's home.
class QuickActionsButton extends StatelessWidget {
  const QuickActionsButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      heroTag: 'quick_actions',
      onPressed: onPressed,
      icon: const Icon(Icons.bolt, size: 20),
      label: const Text('Quick Actions', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
      extendedPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}

/// Fans the [items] out above the button over a dimmed screen; tap outside to close.
/// Returns the tapped item's id, or null when closed.
Future<String?> showQuickActionsMenu(BuildContext context, List<QuickActionItem> items) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withOpacity(0.45),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, __) => SafeArea(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final it in items) ...[
              QuickActionTile(item: it, onTap: () => Navigator.of(ctx).pop(it.id)),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 4),
            SizedBox(
              width: 46,
              height: 46,
              child: FloatingActionButton(
                heroTag: 'qa_close',
                elevation: 3,
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Icon(Icons.close),
              ),
            ),
          ]),
        ),
      ),
    ),
    transitionBuilder: (ctx, a, __, child) => FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.05), end: Offset.zero).animate(a),
        child: child,
      ),
    ),
  );
}

class QuickActionTile extends StatelessWidget {
  const QuickActionTile({super.key, required this.item, required this.onTap});

  final QuickActionItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(item.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              Text(item.hint, style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondaryLight)),
            ]),
          ),
          const SizedBox(width: 10),
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: item.bg,
              shape: BoxShape.circle,
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
            ),
            child: Icon(item.icon, color: item.fg, size: 22),
          ),
        ]),
      ),
    );
  }
}
