// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';

/// Per-store "how this store writes its SKUs": bundle separators, where the
/// quantity is written, and what bracket tags like "(S)" mean. Saved on the
/// store (shop_stores.sku_rules) and used for every match and every new order.
/// A test box shows live how sample SKUs are read before saving.
/// Returns true when saved.
Future<bool> showSkuRules(
  BuildContext context, {
  required Map<String, dynamic> store,
  required List<String> samples,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic> body) call,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => _SkuRulesDialog(store: store, samples: samples, call: call),
  );
  return r == true;
}

class _SkuRulesDialog extends StatefulWidget {
  final Map<String, dynamic> store;
  final List<String> samples;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body) call;
  const _SkuRulesDialog({required this.store, required this.samples, required this.call});
  @override
  State<_SkuRulesDialog> createState() => _SkuRulesDialogState();
}

class _SkuRulesDialogState extends State<_SkuRulesDialog> {
  late final TextEditingController _sep;
  late final TextEditingController _test;
  bool _qtyBefore = true, _qtyAfter = true, _qtyBrackets = true, _autoTags = true;
  final List<(TextEditingController, TextEditingController)> _tags = [];
  List<Map<String, dynamic>> _results = [];
  Map<String, String> _names = {};
  bool _testing = false, _saving = false;
  Timer? _debounce;
  void _testSoon() { _debounce?.cancel(); _debounce = Timer(const Duration(milliseconds: 500), _runTest); }
  String? _error;

  @override
  void initState() {
    super.initState();
    final r = Map<String, dynamic>.from((widget.store['sku_rules'] as Map?) ?? const {});
    _sep = TextEditingController(text: '${r['separators'] ?? '+,;&|'}');
    _qtyBefore = r['qty_before'] != false;
    _qtyAfter = r['qty_after'] != false;
    _qtyBrackets = r['qty_brackets'] != false;
    _autoTags = r['auto_tags'] != false;
    for (final t in (r['tags'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(t as Map);
      _tags.add((TextEditingController(text: '${m['tag'] ?? ''}'), TextEditingController(text: '${m['word'] ?? ''}')));
    }
    _test = TextEditingController(text: widget.samples.take(6).join('\n'));
    _runTest();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sep.dispose();
    _test.dispose();
    for (final t in _tags) { t.$1.dispose(); t.$2.dispose(); }
    super.dispose();
  }

  Map<String, dynamic> get _rules => {
        'separators': _sep.text.replaceAll(RegExp(r'\s'), ''),
        'qty_before': _qtyBefore,
        'qty_after': _qtyAfter,
        'qty_brackets': _qtyBrackets,
        'auto_tags': _autoTags,
        'tags': [
          for (final t in _tags)
            if (t.$1.text.trim().isNotEmpty && t.$2.text.trim().isNotEmpty)
              {'tag': t.$1.text.trim(), 'word': t.$2.text.trim()},
        ],
      };

  Future<void> _runTest() async {
    final skus = _test.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).take(20).toList();
    if (skus.isEmpty) { setState(() => _results = []); return; }
    setState(() { _testing = true; _error = null; });
    try {
      final r = await widget.call({'action': 'test_sku', 'store_id': widget.store['id'], 'rules': _rules, 'skus': skus});
      if (!mounted) return;
      setState(() {
        _results = [for (final x in (r['results'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
        _names = {for (final e in ((r['names'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
        _testing = false;
      });
    } catch (e) {
      if (mounted) setState(() { _testing = false; _error = '$e'; });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('shop_stores').update({'sku_rules': _rules}).eq('id', widget.store['id']);
      widget.store['sku_rules'] = _rules;
      if (mounted) Navigator.of(context, rootNavigator: true).pop(true);
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = 'Could not save: $e'; });
    }
  }

  Widget _check(String label, String eg, bool v, ValueChanged<bool> on) => CheckboxListTile(
        dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
        value: v, onChanged: (x) { setState(() => on(x ?? false)); _testSoon(); },
        title: Text(label, style: const TextStyle(fontSize: 13)),
        subtitle: Text(eg, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
      );

  String _q(dynamic v) {
    final d = v is num ? v.toDouble() : (double.tryParse('$v') ?? 1);
    return d % 1 == 0 ? '${d.toInt()}' : '$d';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('SKU rules · ${widget.store['name'] ?? ''}'),
      content: SizedBox(
        width: 860, height: 560,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── rules ──
          Expanded(child: ListView(children: [
            const Text('Tell Opstation how this store writes its SKUs. Applies to matching and to every new order.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            const Text('Bundle', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            TextField(
              controller: _sep,
              decoration: const InputDecoration(
                labelText: 'Characters that join products in one SKU', hintText: '+,;&|',
                helperText: 'e.g. "A + B" = 2 products. Leave empty if the store has no bundles.',
                isDense: true, border: OutlineInputBorder()),
              onChanged: (_) => _testSoon(),
            ),
            const SizedBox(height: 14),
            const Text('Quantity is written as', style: TextStyle(fontWeight: FontWeight.w700)),
            _check('Before the code', '3x CODE', _qtyBefore, (v) => _qtyBefore = v),
            _check('After the code', 'CODE x3', _qtyAfter, (v) => _qtyAfter = v),
            _check('A number in brackets', 'CODE (3) · CODE (3 pcs)', _qtyBrackets, (v) => _qtyBrackets = v),
            const SizedBox(height: 10),
            const Text('Bracket tags', style: TextStyle(fontWeight: FontWeight.w700)),
            const Text('A tag after the code picks a version of the product, e.g. (S) → name contains "special".',
                style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            for (var i = 0; i < _tags.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  SizedBox(width: 80, child: TextField(controller: _tags[i].$1,
                      decoration: const InputDecoration(labelText: 'Tag', hintText: 'S', isDense: true, border: OutlineInputBorder()),
                      onChanged: (_) => _testSoon())),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('→ name contains')),
                  Expanded(child: TextField(controller: _tags[i].$2,
                      decoration: const InputDecoration(hintText: 'special', isDense: true, border: OutlineInputBorder()),
                      onChanged: (_) => _testSoon())),
                  IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () {
                    setState(() => _tags.removeAt(i));
                    _testSoon();
                  }),
                ]),
              ),
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(
              icon: const Icon(Icons.add, size: 16), label: const Text('Add tag'),
              onPressed: () => setState(() => _tags.add((TextEditingController(), TextEditingController()))),
            )),
            _check('Guess other tags', 'An unknown (X) picks the product with a word starting with X',
                _autoTags, (v) => _autoTags = v),
          ])),
          const VerticalDivider(width: 28),
          // ── live test ──
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Try it', style: TextStyle(fontWeight: FontWeight.w700))),
              if (_testing) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              TextButton(onPressed: _testing ? null : _runTest, child: const Text('Test')),
            ]),
            TextField(
              controller: _test, minLines: 3, maxLines: 5,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(hintText: 'One SKU per line', isDense: true, border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Expanded(child: ListView(children: [
              for (final r in _results) ...[
                Text('${r['sku']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                if ((r['parts'] as List? ?? const []).isEmpty)
                  const Text('  nothing recognised', style: TextStyle(fontSize: 12, color: Colors.red)),
                for (final p in (r['parts'] as List? ?? const []))
                  Builder(builder: (_) {
                    final m = Map<String, dynamic>.from(p as Map);
                    final pid = m['product_id'] as String?;
                    final choices = (m['choices'] as List? ?? const []).length;
                    return Padding(
                      padding: const EdgeInsets.only(left: 8, top: 2),
                      child: Text.rich(TextSpan(style: const TextStyle(fontSize: 12), children: [
                        TextSpan(text: '${_q(m['qty'])} × ', style: const TextStyle(fontWeight: FontWeight.w800)),
                        TextSpan(text: '${m['code']}  →  ', style: const TextStyle(color: AppTheme.textSecondary)),
                        TextSpan(
                          text: pid != null ? (_names[pid] ?? 'product') : (choices > 1 ? '$choices possible — pick in the list' : 'no product found'),
                          style: TextStyle(color: pid != null ? Colors.green.shade800 : (choices > 1 ? Colors.orange.shade800 : Colors.red)),
                        ),
                      ])),
                    );
                  }),
                const Divider(height: 14),
              ],
            ])),
            if (_error != null) Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12)),
          ])),
        ]),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Save rules'),
        ),
      ],
    );
  }
}
