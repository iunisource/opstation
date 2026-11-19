import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

/// The "Schemes applied" box shown on Sales Orders, Delivery Orders and Sales
/// Invoices. [rows] are scheme_redemptions rows (scheme_name, meta, ...).
/// When [onRemove] is given (Sales Order, while its lines can still be edited)
/// every row gets a remove button.
class SchemesBanner extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row)? onRemove;
  const SchemesBanner({super.key, required this.title, required this.rows, this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.teal.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.teal.withOpacity(0.3))),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.local_offer_outlined, size: 16, color: Colors.teal),
          const SizedBox(width: 6),
          Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.teal)),
        ]),
        const SizedBox(height: 6),
        ...rows.map((r) {
          final name = r['scheme_name'] as String? ?? 'Scheme';
          final desc = ((r['meta'] as Map?)?['description'] as String?)?.trim() ?? '';
          final ft = ((r['meta'] as Map?)?['free_text'] as String?)?.trim() ?? '';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.check_circle, size: 14, color: Colors.teal),
              const SizedBox(width: 6),
              Expanded(
                  child: RichText(
                      text: TextSpan(style: const TextStyle(fontSize: 12.5, color: AppTheme.textPrimary), children: [
                TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w700)),
                if (desc.isNotEmpty) TextSpan(text: '  —  $desc', style: const TextStyle(color: AppTheme.textSecondary)),
                if (ft.isNotEmpty) TextSpan(text: '   ·   Free: $ft', style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.w600)),
              ]))),
              if (onRemove != null)
                InkWell(
                  onTap: () => onRemove!(r),
                  borderRadius: BorderRadius.circular(10),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Tooltip(message: 'Remove this scheme', child: Icon(Icons.close, size: 16, color: AppTheme.danger)),
                  ),
                ),
            ]),
          );
        }),
      ]),
    );
  }
}
