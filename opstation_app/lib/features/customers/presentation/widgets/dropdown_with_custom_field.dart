import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// A dropdown field with a "None" option at the top and an
/// "Other..." option at the bottom that reveals an inline custom-text
/// field. Keeps data entry friendly while we wait for full admin-managed
/// taxonomy (Slice 5).
class DropdownWithCustomField extends StatefulWidget {
  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final bool allowNone;
  final String noneLabel;

  const DropdownWithCustomField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.allowNone = true,
    this.noneLabel = 'None',
  });

  @override
  State<DropdownWithCustomField> createState() =>
      _DropdownWithCustomFieldState();
}

class _DropdownWithCustomFieldState extends State<DropdownWithCustomField> {
  static const _otherSentinel = '__other__';

  late TextEditingController _customCtrl;
  bool _showingCustom = false;

  @override
  void initState() {
    super.initState();
    _customCtrl = TextEditingController();
    // If current value exists but isn't in options, treat it as a custom.
    if (widget.value != null &&
        widget.value!.isNotEmpty &&
        !widget.options.contains(widget.value)) {
      _showingCustom = true;
      _customCtrl.text = widget.value!;
    }
  }

  @override
  void didUpdateWidget(covariant DropdownWithCustomField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      if (widget.value != null &&
          widget.value!.isNotEmpty &&
          !widget.options.contains(widget.value)) {
        _showingCustom = true;
        _customCtrl.text = widget.value!;
      } else if (widget.value == null) {
        _showingCustom = false;
        _customCtrl.clear();
      }
    }
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // What the dropdown should render as selected:
    String? displayValue;
    if (_showingCustom) {
      displayValue = _otherSentinel;
    } else if (widget.value != null && widget.options.contains(widget.value)) {
      displayValue = widget.value;
    } else {
      displayValue = null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          value: displayValue,
          isExpanded: true,
          decoration: InputDecoration(labelText: widget.label),
          items: [
            if (widget.allowNone)
              DropdownMenuItem<String>(
                value: null,
                child: Text(
                  widget.noneLabel,
                  style: const TextStyle(
                    color: AppColors.textSecondaryLight,
                  ),
                ),
              ),
            for (final opt in widget.options)
              DropdownMenuItem<String>(
                value: opt,
                child: Text(opt),
              ),
            const DropdownMenuItem<String>(
              value: _otherSentinel,
              child: Row(
                children: [
                  Icon(Icons.add, size: 16, color: AppColors.primary),
                  SizedBox(width: 6),
                  Text(
                    'Other...',
                    style: TextStyle(color: AppColors.primary),
                  ),
                ],
              ),
            ),
          ],
          onChanged: (v) {
            if (v == _otherSentinel) {
              setState(() {
                _showingCustom = true;
                _customCtrl.clear();
              });
              widget.onChanged(null);
            } else {
              setState(() {
                _showingCustom = false;
                _customCtrl.clear();
              });
              widget.onChanged(v);
            }
          },
        ),
        if (_showingCustom) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _customCtrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Custom ${widget.label.toLowerCase()}',
              hintText: 'Enter a new value',
              suffixIcon: IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Cancel custom',
                onPressed: () {
                  setState(() {
                    _showingCustom = false;
                    _customCtrl.clear();
                  });
                  widget.onChanged(null);
                },
              ),
            ),
            onChanged: (v) {
              widget.onChanged(v.trim().isEmpty ? null : v.trim());
            },
          ),
        ],
      ],
    );
  }
}
