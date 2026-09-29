import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../layout/main_layout.dart' show userBranchesProvider;

/// Empty-list message for branch-scoped voucher screens. When the user can
/// reach more than one branch / location, adds a hint that the documents may
/// simply live under another branch (the list only shows the selected one).
class BranchEmptyHint extends ConsumerWidget {
  final String text;
  final TextStyle? style;
  const BranchEmptyHint(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(userBranchesProvider).valueOrNull ?? const [];
    final base = style ?? const TextStyle(color: Colors.black54);
    if (branches.length < 2) return Text(text, style: base, textAlign: TextAlign.center);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(text, style: base, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(
          'Try other branches/locations if you have access.',
          textAlign: TextAlign.center,
          style: base.copyWith(
            fontSize: ((base.fontSize ?? 13) - 1.5).clamp(10.0, 14.0),
            fontStyle: FontStyle.italic,
          ),
        ),
      ]),
    );
  }
}
