import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../search/text_search.dart';
import '../theme/app_theme.dart';

/// A dropdown with a search box: looks like the usual labelled dropdown, but the list that opens
/// has a "Search..." field at the top that narrows the options as you type. Enter picks the first
/// match, Esc or a click outside closes it. [options] is (value, label); a null value is the
/// "All" entry (listed first).
class SearchableDropdown<T> extends StatefulWidget {
  const SearchableDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width = 180,
  });

  final String label;
  final T? value;
  final List<(T?, String)> options;
  final ValueChanged<T?> onChanged;
  final double width;

  @override
  State<SearchableDropdown<T>> createState() => _SearchableDropdownState<T>();
}

class _SearchableDropdownState<T> extends State<SearchableDropdown<T>> {
  final _link = LayerLink();
  OverlayEntry? _entry;

  String get _selectedLabel {
    for (final o in widget.options) {
      if (o.$1 == widget.value) return o.$2;
    }
    return widget.options.isNotEmpty ? widget.options.first.$2 : '';
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  void _pick(T? v) {
    _close();
    widget.onChanged(v);
  }

  void _open() {
    if (_entry != null) return;
    final box = context.findRenderObject() as RenderBox;
    final menuW = box.size.width < 240 ? 240.0 : box.size.width;
    // Keep the list on screen when the field sits near the right edge.
    final left = box.localToGlobal(Offset.zero).dx;
    final screenW = MediaQuery.of(context).size.width;
    final dx = (left + menuW > screenW - 8) ? (screenW - 8 - left - menuW) : 0.0;
    _entry = OverlayEntry(
      builder: (_) => _Menu<T>(
        link: _link,
        offset: Offset(dx, box.size.height + 2),
        width: menuW,
        options: widget.options,
        selected: widget.value,
        onPick: _pick,
        onClose: _close,
      ),
    );
    Overlay.of(context).insert(_entry!);
    setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: SizedBox(
        width: widget.width,
        child: InkWell(
          onTap: _entry != null ? _close : _open,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: widget.label,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: const OutlineInputBorder(),
            ),
            child: Row(children: [
              Expanded(child: Text(_selectedLabel, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
              const Icon(Icons.arrow_drop_down, size: 20, color: AppTheme.textSecondary),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Menu<T> extends StatefulWidget {
  const _Menu({
    required this.link,
    required this.offset,
    required this.width,
    required this.options,
    required this.selected,
    required this.onPick,
    required this.onClose,
  });
  final LayerLink link;
  final Offset offset;
  final double width;
  final List<(T?, String)> options;
  final T? selected;
  final ValueChanged<T?> onPick;
  final VoidCallback onClose;

  @override
  State<_Menu<T>> createState() => _MenuState<T>();
}

class _MenuState<T> extends State<_Menu<T>> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  String _q = '';

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<(T?, String)> get _list =>
      _q.trim().isEmpty ? widget.options : [for (final o in widget.options) if (matchesQuery(o.$2, _q)) o];

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
      child: Stack(children: [
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: widget.onClose)),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          offset: widget.offset,
          child: Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              color: Colors.white,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: widget.width, maxWidth: widget.width, maxHeight: 340),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      autofocus: true,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: 'Search...',
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 16),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _q = v),
                      onSubmitted: (_) {
                        if (list.isNotEmpty) widget.onPick(list.first.$1);
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: list.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: Text('No match', style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)))
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: list.length,
                            itemBuilder: (_, i) {
                              final o = list[i];
                              final sel = o.$1 == widget.selected;
                              return InkWell(
                                onTap: () => widget.onPick(o.$1),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                  child: Row(children: [
                                    Expanded(
                                      child: Text(o.$2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                                              color: sel ? AppTheme.primary : null)),
                                    ),
                                    if (sel) const Icon(Icons.check, size: 15, color: AppTheme.primary),
                                  ]),
                                ),
                              );
                            },
                          ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
