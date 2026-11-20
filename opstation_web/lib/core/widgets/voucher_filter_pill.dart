import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A small status pill with the number of vouchers behind it, as on the PO, GRN and
/// PI lists. [urgent] draws the pill in red while something is waiting (count > 0).
class VoucherFilterPill extends StatelessWidget {
  const VoucherFilterPill({
    super.key,
    required this.label,
    required this.value,
    required this.current,
    required this.onTap,
    this.count,
    this.urgent = false,
  });

  final String label, value, current;
  final int? count;
  final bool urgent;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final active = value == current;
    final hot = urgent && (count ?? 0) > 0;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary : AppTheme.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? AppTheme.primary : (hot ? const Color(0xFFDC2626) : AppTheme.border)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)),
          if (count != null) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: active ? Colors.white.withOpacity(0.25) : (hot ? const Color(0xFFDC2626) : AppTheme.border.withOpacity(0.7)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('$count',
                  style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: active || hot ? Colors.white : AppTheme.textSecondary)),
            ),
          ],
        ]),
      ),
    );
  }
}
