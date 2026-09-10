import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

/// Reusable subscription-tier cards, used on both the signup wizard (to pick a
/// plan) and the Billing screen (to upgrade/switch). Data comes from
/// subscription_plans rows: {id, name, amount, tagline, badge, highlight,
/// features:[...], module_keys:[...]}.
class PlanCards extends StatelessWidget {
  final List<Map<String, dynamic>> plans;
  /// The plan to render as chosen/current (blue outline + check).
  final String? activeId;
  final void Function(Map<String, dynamic> plan) onSelect;
  /// CTA label per plan (e.g. "Select", "Current plan", "Upgrade").
  final String Function(Map<String, dynamic> plan) ctaLabel;
  /// Disable the CTA for a plan (e.g. the current one on Billing).
  final bool Function(Map<String, dynamic> plan) ctaDisabled;

  const PlanCards({
    super.key,
    required this.plans,
    required this.activeId,
    required this.onSelect,
    required this.ctaLabel,
    required this.ctaDisabled,
  });

  String _money(num v) => 'PKR ${v.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 720;
      final cardW = wide ? (c.maxWidth - 2 * 14) / 3 : c.maxWidth;
      return Wrap(
        spacing: 14, runSpacing: 14,
        children: plans.map((p) => SizedBox(width: cardW, child: _card(p))).toList(),
      );
    });
  }

  Widget _card(Map<String, dynamic> p) {
    final id = p['id'] as String;
    final highlight = (p['highlight'] as bool?) ?? false;
    final isActive = id == activeId;
    final badge = p['badge'] as String?;
    final features = ((p['features'] as List?) ?? const []).cast<dynamic>().map((e) => e.toString()).toList();
    final accent = isActive || highlight ? AppTheme.primary : AppTheme.border;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent, width: isActive || highlight ? 2 : 1),
        boxShadow: highlight
            ? [BoxShadow(color: AppTheme.primary.withOpacity(0.12), blurRadius: 18, offset: const Offset(0, 8))]
            : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (badge != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: const BoxDecoration(
              color: AppTheme.primary,
              borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Text(badge, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
          ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p['name'] as String? ?? '',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
            const SizedBox(height: 2),
            Text(p['tagline'] as String? ?? '',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.3)),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text(_money((p['amount'] as num?) ?? 0),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: AppTheme.textPrimary)),
              const SizedBox(width: 4),
              const Text('/mo', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
            const SizedBox(height: 14),
            ...features.map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.check_circle, size: 16, color: AppTheme.success),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f, style: const TextStyle(fontSize: 12.5, height: 1.4, color: AppTheme.textPrimary))),
                  ]),
                )),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: ctaDisabled(p)
                  ? OutlinedButton(
                      onPressed: null,
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)),
                      child: Text(ctaLabel(p)),
                    )
                  : ElevatedButton(
                      onPressed: () => onSelect(p),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        backgroundColor: (highlight || isActive) ? AppTheme.primary : null,
                        foregroundColor: (highlight || isActive) ? Colors.white : null,
                      ),
                      child: Text(ctaLabel(p)),
                    ),
            ),
          ]),
        ),
      ]),
    );
  }
}
