import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Looks like a dropdown; opens a searchable list of salespersons.
/// [users] = [{id, name}]. [value] null = "All salespersons".
class SalespersonPicker extends StatelessWidget {
  final List<Map<String, dynamic>> users;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String allLabel;
  const SalespersonPicker({
    super.key,
    required this.users,
    required this.value,
    required this.onChanged,
    this.allLabel = 'All salespersons',
  });

  String _name(Map<String, dynamic> u) => '${u['name'] ?? ''}';

  @override
  Widget build(BuildContext context) {
    final sel = users.where((u) => '${u['id']}' == value).toList();
    final label = sel.isEmpty ? allLabel : _name(sel.first);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final picked = await showDialog<_Pick>(
          context: context,
          builder: (_) => _PickerDialog(users: users, value: value, allLabel: allLabel),
        );
        if (picked != null && picked.id != value) onChanged(picked.id);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }
}

class _Pick {
  final String? id;
  const _Pick(this.id);
}

class _PickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> users;
  final String? value;
  final String allLabel;
  const _PickerDialog({required this.users, required this.value, required this.allLabel});
  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = widget.users.where((u) => q.isEmpty || '${u['name'] ?? ''}'.toLowerCase().contains(q)).toList();
    Widget tile(String? id, String text) => ListTile(
          dense: true,
          title: Text(text),
          selected: id == widget.value,
          trailing: id == widget.value ? const Icon(Icons.check, size: 18) : null,
          onTap: () => Navigator.pop(context, _Pick(id)),
        );
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 520),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search salesperson',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v),
              onSubmitted: (_) {
                if (list.length == 1) Navigator.pop(context, _Pick('${list.first['id']}'));
              },
            ),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              if (q.isEmpty) tile(null, widget.allLabel),
              for (final u in list) tile('${u['id']}', '${u['name'] ?? ''}'),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('No match', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)),
                ),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
