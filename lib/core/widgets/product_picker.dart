import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Searchable, scrollable product picker shared by Sales & Purchase order
/// screens (and anywhere a product needs to be chosen from a long list).
///
/// Opens a dialog with a search box (filters on name + SKU) and a scrollable
/// list. Returns the selected product map, or null if dismissed.
/// [products] entries should contain at least 'id' and 'name' (optionally
/// 'sku' and 'base_uom_id' — the caller reads those off the returned map).
///
/// Keyboard: ↑/↓ move the highlighted row, Enter selects it, Esc dismisses.
/// Typing in the search box resets the highlight to the first match.
Future<Map<String, dynamic>?> pickProduct(
  BuildContext context,
  List<Map<String, dynamic>> products, {
  String title = 'Select product',
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => _ProductPickerDialog(products: products, title: title),
  );
}

class _ProductPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> products;
  final String title;
  const _ProductPickerDialog({required this.products, required this.title});
  @override
  State<_ProductPickerDialog> createState() => _ProductPickerDialogState();
}

class _ProductPickerDialogState extends State<_ProductPickerDialog> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollCtrl = ScrollController();
  String _q = '';
  int _highlight = 0;
  static const double _rowExtent = 53; // approx ListTile(dense) + divider

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _q.toLowerCase().trim();
    if (q.isEmpty) return widget.products;
    return widget.products.where((p) {
      final name = (p['name'] as String? ?? '').toLowerCase();
      final sku = (p['sku'] as String? ?? '').toLowerCase();
      return name.contains(q) || sku.contains(q);
    }).toList();
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _highlight = (_highlight + delta).clamp(0, count - 1));
    if (_scrollCtrl.hasClients) {
      final target = _highlight * _rowExtent;
      final vpStart = _scrollCtrl.offset;
      final vpEnd = vpStart + _scrollCtrl.position.viewportDimension;
      if (target < vpStart) {
        _scrollCtrl.animateTo(target, duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
      } else if (target + _rowExtent > vpEnd) {
        _scrollCtrl.animateTo(target + _rowExtent - _scrollCtrl.position.viewportDimension,
            duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
      }
    }
  }

  void _selectHighlighted(List<Map<String, dynamic>> filtered) {
    if (filtered.isEmpty) return;
    final idx = _highlight.clamp(0, filtered.length - 1);
    Navigator.of(context).pop(filtered[idx]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, List<Map<String, dynamic>> filtered) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1, filtered.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1, filtered.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _selectHighlighted(filtered);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    if (_highlight >= filtered.length) _highlight = filtered.isEmpty ? 0 : filtered.length - 1;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(children: [
                Expanded(
                  child: Text(widget.title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Focus(
                onKeyEvent: (node, event) => _onKey(node, event, filtered),
                child: TextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  decoration: InputDecoration(
                    hintText: 'Search name or SKU…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  onChanged: (v) => setState(() { _q = v; _highlight = 0; }),
                  onSubmitted: (_) => _selectHighlighted(filtered),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No products match',
                            style: TextStyle(color: AppTheme.textSecondary)),
                      ),
                    )
                  : Scrollbar(
                      controller: _scrollCtrl,
                      child: ListView.separated(
                        controller: _scrollCtrl,
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final p = filtered[i];
                          final name = p['name'] as String? ?? '-';
                          final sku = p['sku'] as String?;
                          final hl = i == _highlight;
                          return Container(
                            color: hl ? AppTheme.primary.withOpacity(0.08) : null,
                            child: ListTile(
                              dense: true,
                              title: Text(name,
                                  style: TextStyle(fontSize: 13.5,
                                      fontWeight: hl ? FontWeight.w700 : FontWeight.w400)),
                              subtitle: (sku != null && sku.isNotEmpty)
                                  ? Text(sku,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppTheme.textSecondary))
                                  : null,
                              onTap: () => Navigator.of(context).pop(p),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
