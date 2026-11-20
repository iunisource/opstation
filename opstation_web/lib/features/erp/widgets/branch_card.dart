import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// One branch on a phone: the table's four columns (name, location, status,
/// actions) do not fit 360px — the name and status were squeezed to a few
/// characters. As a card, each gets the room it needs.
class BranchMobileCard extends StatelessWidget {
  const BranchMobileCard({
    super.key,
    required this.name,
    required this.location,
    required this.isActive,
    required this.isProcessor,
    required this.onEdit,
    required this.onToggle,
  });

  final String name;
  final String? location;
  final bool isActive;
  final bool isProcessor;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final loc = (location ?? '').trim();
    final statusColor = isActive ? AppTheme.success : AppTheme.danger;
    return Opacity(
      opacity: isActive ? 1.0 : 0.6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(name.isEmpty ? '—' : name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                if (isProcessor)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: Colors.purple.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                    child: const Text('Processor', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.purple)),
                  ),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: statusColor.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
              child: Text(isActive ? 'Active' : 'Inactive',
                  style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ]),
          if (loc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: Text(loc, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(spacing: 0, children: [
              TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit', style: TextStyle(fontSize: 13)),
              ),
              TextButton.icon(
                onPressed: onToggle,
                icon: Icon(isActive ? Icons.block : Icons.check_circle_outline, size: 16, color: statusColor),
                label: Text(isActive ? 'Deactivate' : 'Activate', style: TextStyle(fontSize: 13, color: statusColor)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
