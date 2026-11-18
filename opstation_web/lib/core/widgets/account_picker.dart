import 'package:flutter/material.dart';
import '../search/text_search.dart';
import '../theme/app_theme.dart';

/// Postable (leaf) accounts only — the same rule the Payment Voucher screen
/// uses. COA design: Group -> L1 -> L2 -> L3 -> L4. Show Level-4 detail
/// accounts; show a Level-3 only when nothing sits beneath it. L1/L2 and any
/// account that has children are hidden, so nothing can post to a parent.
///
/// [coa] must carry `id`, `parent_id` and `level`. Children are counted from
/// every row passed in (active or not), so pass the full set and use
/// [activeOnly] to hide inactive accounts from the list.
List<Map<String, dynamic>> postableAccounts(List<Map<String, dynamic>> coa, {bool activeOnly = true}) {
  final parentIds = <String>{
    for (final a in coa) if (a['parent_id'] != null) a['parent_id'].toString(),
  };
  int lvlOf(Map a) => a['level'] is num ? (a['level'] as num).toInt() : int.tryParse('${a['level']}') ?? 0;
  return coa.where((a) {
    if (activeOnly && a['is_active'] == false) return false;
    if (parentIds.contains(a['id'].toString())) return false;
    return lvlOf(a) >= 3;
  }).toList();
}

String accountLabel(Map a) {
  final code = a['code'];
  final name = a['name'] ?? '';
  return code != null && '$code'.isNotEmpty ? '$code — $name' : '$name';
}

/// Searchable account list in a dialog. Searches code and name, word by word.
/// Returns the picked account map, or null if closed.
Future<Map<String, dynamic>?> showAccountPicker(
  BuildContext context,
  List<Map<String, dynamic>> accounts, {
  String title = 'Select account',
  String? selectedId,
}) {
  final searchCtrl = TextEditingController();
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx2, setS) {
      final q = searchCtrl.text.trim();
      final list = q.isEmpty ? accounts : accounts.where((a) => matchesQuery(accountLabel(a), q)).toList();
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(children: [
                Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search by code or name…', prefixIcon: Icon(Icons.search, size: 20), isDense: true, border: OutlineInputBorder()),
                onChanged: (_) => setS(() {}),
                onSubmitted: (_) { if (list.length == 1) Navigator.pop(ctx, list.first); },
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: list.isEmpty
                  ? const Padding(padding: EdgeInsets.all(24), child: Text('No matching accounts', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final a = list[i];
                        final sel = selectedId != null && a['id'] == selectedId;
                        return ListTile(
                          dense: true,
                          selected: sel,
                          title: Text(accountLabel(a), style: const TextStyle(fontSize: 13)),
                          trailing: sel ? const Icon(Icons.check, size: 18, color: AppTheme.primary) : null,
                          onTap: () => Navigator.pop(ctx, a),
                        );
                      },
                    ),
            ),
          ]),
        ),
      );
    }),
  );
}

/// Tap-to-pick field that opens [showAccountPicker].
class AccountPickerField extends StatelessWidget {
  final List<Map<String, dynamic>> accounts;
  final String? selectedId;
  final String hint;
  final String? label;
  final String title;
  final bool enabled;
  final ValueChanged<Map<String, dynamic>> onPicked;
  final double fontSize;

  const AccountPickerField({
    super.key,
    required this.accounts,
    required this.selectedId,
    required this.onPicked,
    this.hint = 'Select account',
    this.label,
    this.title = 'Select account',
    this.enabled = true,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    final sel = selectedId == null ? null : accounts.cast<Map<String, dynamic>?>().firstWhere((a) => a!['id'] == selectedId, orElse: () => null);
    return InkWell(
      onTap: !enabled
          ? null
          : () async {
              final picked = await showAccountPicker(context, accounts, title: title, selectedId: selectedId);
              if (picked != null) onPicked(picked);
            },
      child: InputDecorator(
        isEmpty: sel == null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          enabled: enabled,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.search, size: 18),
          suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 20),
        ),
        child: Text(sel == null ? '' : accountLabel(sel), style: TextStyle(fontSize: fontSize), overflow: TextOverflow.ellipsis, maxLines: 1),
      ),
    );
  }
}
