import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'responsive.dart';

/// One column of an [AdaptiveTable].
///
/// [width] is the fixed desktop width; null means Expanded. On mobile the width
/// is ignored entirely — the column becomes a labelled line in a card, which is
/// the only way to show 7 columns on a 380px screen without the header text
/// wrapping to one letter per line.
class AdaptiveColumn<T> {
  final String label;
  final double? width;
  final Widget Function(T row) cell;

  /// Show this column on mobile? Some columns (a row index, a spacer) are noise
  /// on a phone. Defaults to true.
  final bool showOnMobile;

  /// Promote to the card's title line on mobile, rather than a labelled field.
  /// Typically the voucher number or the name.
  final bool isTitle;

  /// Promote to the card's trailing line — typically the amount.
  final bool isTrailing;

  final TextAlign align;

  const AdaptiveColumn({
    required this.label,
    required this.cell,
    this.width,
    this.showOnMobile = true,
    this.isTitle = false,
    this.isTrailing = false,
    this.align = TextAlign.left,
  });
}

/// A data table that degrades honestly on a phone.
///
/// Desktop: a real table with fixed column widths.
/// Mobile:  one card per row. Title and trailing get their own line; everything
///          else becomes a "Label: value" pair. Nothing is truncated to a sliver
///          and no header wraps vertically.
class AdaptiveTable<T> extends StatelessWidget {
  final List<AdaptiveColumn<T>> columns;
  final List<T> rows;
  final void Function(T row)? onRowTap;
  final Widget? empty;
  final Widget? footer;

  /// Zebra striping on desktop. Off on mobile — cards already separate rows.
  final bool striped;

  const AdaptiveTable({
    super.key,
    required this.columns,
    required this.rows,
    this.onRowTap,
    this.empty,
    this.footer,
    this.striped = true,
  });

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return empty ??
          const Center(
            child: Text('Nothing to show.',
                style: TextStyle(color: AppTheme.textSecondary)),
          );
    }
    return context.isMobile ? _mobile(context) : _desktop(context);
  }

  // ── Desktop ───────────────────────────────────────────────────────────────
  Widget _desktop(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
          ),
          child: Row(children: [
            for (final c in columns)
              c.width == null
                  ? Expanded(child: _header(c))
                  : SizedBox(width: c.width, child: _header(c)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: AppTheme.border),
            itemBuilder: (_, i) {
              final row = rows[i];
              final content = Container(
                color: striped && i.isOdd ? Colors.grey.shade50 : null,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                child: Row(children: [
                  for (final c in columns)
                    c.width == null
                        ? Expanded(child: c.cell(row))
                        : SizedBox(width: c.width, child: c.cell(row)),
                ]),
              );
              return onRowTap == null
                  ? content
                  : InkWell(onTap: () => onRowTap!(row), child: content);
            },
          ),
        ),
        if (footer != null) footer!,
      ]),
    );
  }

  Widget _header(AdaptiveColumn<T> c) => Text(
        c.label,
        textAlign: c.align,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 11,
          color: AppTheme.textSecondary,
        ),
      );

  // ── Mobile ────────────────────────────────────────────────────────────────
  Widget _mobile(BuildContext context) {
    final visible = columns.where((c) => c.showOnMobile).toList();
    final title = visible.where((c) => c.isTitle).toList();
    final trailing = visible.where((c) => c.isTrailing).toList();
    final fields = visible
        .where((c) => !c.isTitle && !c.isTrailing)
        .toList();

    return Column(children: [
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final row = rows[i];
            final card = Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty || trailing.isNotEmpty)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final c in title) Flexible(child: c.cell(row)),
                        const Spacer(),
                        for (final c in trailing) c.cell(row),
                      ],
                    ),
                  if ((title.isNotEmpty || trailing.isNotEmpty) &&
                      fields.isNotEmpty)
                    const SizedBox(height: 8),
                  for (final c in fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 84,
                            child: Text(
                              c.label,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ),
                          Expanded(
                            child: DefaultTextStyle.merge(
                              style: const TextStyle(fontSize: 12.5),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: c.cell(row),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
            return onRowTap == null
                ? card
                : InkWell(
                    onTap: () => onRowTap!(row),
                    borderRadius: BorderRadius.circular(12),
                    child: card,
                  );
          },
        ),
      ),
      if (footer != null) footer!,
    ]);
  }
}
