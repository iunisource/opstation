import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Searchable, scrollable product picker shared by Sales & Purchase order
/// screens (and anywhere a product needs to be chosen from a long list).
///
/// Opens a dialog with a search box (filters on name + SKU) and a scrollable
/// list. Returns the selected product map, or null if dismissed.
/// [products] entries should contain at least 'id' and 'name' (optionally
/// 'sku' and 'base_uom_id' — the caller reads those off the returned map).
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
  String _q = '';

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase().trim();
    final filtered = q.isEmpty
        ? widget.products
        : widget.products.where((p) {
            final name = (p['name'] as String? ?? '').toLowerCase();
            final sku = (p['sku'] as String? ?? '').toLowerCase();
            return name.contains(q) || sku.contains(q);
          }).toList();

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
                onChanged: (v) => setState(() => _q = v),
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
                      child: ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final p = filtered[i];
                          final name = p['name'] as String? ?? '-';
                          final sku = p['sku'] as String?;
                          return ListTile(
                            dense: true,
                            title: Text(name,
                                style: const TextStyle(fontSize: 13.5)),
                            subtitle: (sku != null && sku.isNotEmpty)
                                ? Text(sku,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textSecondary))
                                : null,
                            onTap: () => Navigator.of(context).pop(p),
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
