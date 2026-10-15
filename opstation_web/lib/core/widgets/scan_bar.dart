// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Finds a product by what a scanner reads: barcode first, then SKU (exact,
/// case-insensitive). Products need 'barcode' / 'sku' keys.
Map<String, dynamic>? findProductByCode(List<Map<String, dynamic>> products, String code) {
  final c = code.trim().toLowerCase();
  if (c.isEmpty) return null;
  for (final p in products) {
    if ('${p['barcode'] ?? ''}'.trim().toLowerCase() == c) return p;
  }
  for (final p in products) {
    if ('${p['sku'] ?? ''}'.trim().toLowerCase() == c) return p;
  }
  return null;
}

class ScanOutcome {
  final bool ok;
  final String message;
  const ScanOutcome(this.ok, this.message);
}

/// A barcode-scanner input: keeps focus, takes one code per Enter (USB/
/// Bluetooth scanners type the code and press Enter), queues fast scans so
/// none are lost, and shows a green / red result line. An optional "×" box
/// multiplies the next scan (e.g. 12 then scan = 12 pieces).
class ScanBar extends StatefulWidget {
  final Future<ScanOutcome> Function(String code, double qty) onScan;
  final String hint;
  final bool autofocus;
  final bool showQty;
  const ScanBar({super.key, required this.onScan, this.hint = 'Scan barcode (or type code + Enter)',
      this.autofocus = true, this.showQty = true});
  @override
  State<ScanBar> createState() => _ScanBarState();
}

class _ScanBarState extends State<ScanBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _qty = TextEditingController(text: '1');
  final List<(String, double)> _queue = [];
  bool _working = false;
  ScanOutcome? _last;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _focus.requestFocus(); });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _qty.dispose();
    super.dispose();
  }

  void _submit(String v) {
    final code = v.trim();
    _ctrl.clear();
    _focus.requestFocus();
    if (code.isEmpty) return;
    final q = double.tryParse(_qty.text.trim()) ?? 1;
    _queue.add((code, q <= 0 ? 1 : q));
    if (widget.showQty) _qty.text = '1';
    _drain();
  }

  Future<void> _drain() async {
    if (_working) return;
    _working = true;
    while (_queue.isNotEmpty) {
      final (code, q) = _queue.removeAt(0);
      ScanOutcome r;
      try {
        r = await widget.onScan(code, q);
      } catch (e) {
        r = ScanOutcome(false, '$e');
      }
      if (!mounted) return;
      setState(() { _last = r; if (r.ok) _count++; });
      if (!r.ok) SystemSound.play(SystemSoundType.alert);
    }
    _working = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    final color = last == null ? AppTheme.border : (last.ok ? Colors.green : Colors.red);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: last == null ? Colors.white : color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(last == null ? 1 : 0.6), width: last == null ? 1 : 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (widget.showQty) ...[
            SizedBox(width: 70, child: TextField(
              controller: _qty,
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: const InputDecoration(labelText: '×', isDense: true, border: OutlineInputBorder()),
              onSubmitted: (_) => _focus.requestFocus(),
            )),
            const SizedBox(width: 8),
          ],
          Expanded(child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            autofocus: widget.autofocus,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: widget.hint, isDense: true, border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.qr_code_scanner, size: 20),
              suffixIcon: _working
                  ? const Padding(padding: EdgeInsets.all(12),
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
                  : null,
            ),
            onSubmitted: _submit,
          )),
        ]),
        if (last != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(last.ok ? Icons.check_circle : Icons.error_outline, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(child: Text(last.message,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: last.ok ? Colors.green.shade800 : Colors.red.shade700))),
              if (_count > 0) Text('$_count scanned', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ]),
          ),
      ]),
    );
  }
}
