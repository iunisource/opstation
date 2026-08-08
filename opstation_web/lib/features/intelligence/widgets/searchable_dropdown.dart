import 'package:flutter/material.dart';

/// A dropdown look-alike whose picker opens as a dialog with a search box.
///
/// Options are (id, label) pairs. When [allLabel] is non-null an "All" row
/// (value = null) is shown first. Cancelling the dialog leaves the current
/// selection untouched.
class SearchableDropdown extends StatelessWidget {
  final String label;
  final String? value;
  final List<MapEntry<String?, String>> options;
  final String? allLabel;
  final ValueChanged<String?> onChanged;

  const SearchableDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.allLabel,
  });

  String get _display {
    if (value == null) return allLabel ?? '';
    for (final o in options) {
      if (o.key == value) return o.value;
    }
    return '';
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showDialog<_Pick>(
      context: context,
      builder: (_) => _SearchDialog(
        label: label,
        options: options,
        allLabel: allLabel,
      ),
    );
    if (picked != null) onChanged(picked.id);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          _display,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
      ),
    );
  }
}

class _Pick {
  final String? id;
  const _Pick(this.id);
}

class _SearchDialog extends StatefulWidget {
  final String label;
  final List<MapEntry<String?, String>> options;
  final String? allLabel;

  const _SearchDialog({
    required this.label,
    required this.options,
    this.allLabel,
  });

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _ctrl.text.trim().toLowerCase();
    final matches = q.isEmpty
        ? widget.options
        : widget.options
            .where((o) => o.value.toLowerCase().contains(q))
            .toList();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: widget.label,
                  hintText: 'Search...',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (widget.allLabel != null && q.isEmpty)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.clear_all, size: 18),
                      title: Text(widget.allLabel!,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600)),
                      onTap: () =>
                          Navigator.of(context).pop(const _Pick(null)),
                    ),
                  if (matches.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No matches.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                    )
                  else
                    for (final o in matches)
                      ListTile(
                        dense: true,
                        title: Text(o.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5)),
                        onTap: () =>
                            Navigator.of(context).pop(_Pick(o.key)),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
