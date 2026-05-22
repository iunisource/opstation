import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../salesperson/models/customer.dart';
import '../data/customer_taxonomy.dart';
import '../providers/customers_controller.dart';
import 'widgets/dropdown_with_custom_field.dart';

/// Form used for both create and edit. If [customerId] is null it creates;
/// otherwise it loads and edits.
class CustomerFormScreen extends ConsumerStatefulWidget {
  final String? customerId;
  const CustomerFormScreen({super.key, this.customerId});

  @override
  ConsumerState<CustomerFormScreen> createState() => _CustomerFormScreenState();
}

class _CustomerFormScreenState extends ConsumerState<CustomerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  String _toInternational(String phone) {
    final digits = phone.trim().replaceAll(RegExp(r'\s+'), '');
    if (digits.startsWith('+')) return digits;
    if (digits.startsWith('0')) return '+92' + digits.substring(1);
    if (digits.startsWith('92')) return '+' + digits;
    return digits;
  }
  final _addressCtrl = TextEditingController();
  final _ntnCtrl = TextEditingController();

  String? _category;
  String? _group;

  bool _hydrated = false;
  Customer? _original;
  bool _submitting = false;

  bool get _isEdit => widget.customerId != null;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _contactCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _ntnCtrl.dispose();
    super.dispose();
  }

  void _hydrate(Customer c) {
    if (_hydrated) return;
    _hydrated = true;
    _original = c;
    _codeCtrl.text = c.code;
    _nameCtrl.text = c.shopName;
    _contactCtrl.text = c.contactPerson;
    _phoneCtrl.text = c.phone;
    _addressCtrl.text = c.address;
    _ntnCtrl.text = c.ntnGst ?? '';
    _category = c.category;
    _group = c.group;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);

    final ctrl = ref.read(customersControllerProvider.notifier);
    final category = (_category == null || _category!.trim().isEmpty)
        ? null
        : _category!.trim();
    final group =
        (_group == null || _group!.trim().isEmpty) ? null : _group!.trim();
    final ntn = _ntnCtrl.text.trim().isEmpty ? null : _ntnCtrl.text.trim();

    try {
      if (_isEdit && _original != null) {
        final updated = _original!.copyWith(
          code: _codeCtrl.text.trim(),
          shopName: _nameCtrl.text.trim(),
          contactPerson: _contactCtrl.text.trim(),
          phone: _toInternational(_phoneCtrl.text),
          address: _addressCtrl.text.trim(),
          category: category,
          clearCategory: category == null,
          group: group,
          clearGroup: group == null,
          ntnGst: ntn,
          clearNtnGst: ntn == null,
        );
        await ctrl.updateCustomer(updated, _original!);
      } else {
        final id = 'cust_${DateTime.now().millisecondsSinceEpoch}';
        final c = Customer(
          id: id,
          code: _codeCtrl.text.trim(),
          shopName: _nameCtrl.text.trim(),
          contactPerson: _contactCtrl.text.trim(),
          phone: _toInternational(_phoneCtrl.text),
          address: _addressCtrl.text.trim(),
          category: category,
          group: group,
          ntnGst: ntn,
        );
        await ctrl.create(c);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isEdit ? 'Customer updated' : 'Customer created')),
      );
      if (mounted) context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(customersControllerProvider);
    final categoriesAsync = ref.watch(customerCategoriesProvider);
    final groupsAsync = ref.watch(customerGroupsProvider);

    if (_isEdit) {
      async.whenData((state) {
        final match = state.all.where((c) => c.id == widget.customerId).toList();
        if (match.isNotEmpty) _hydrate(match.first);
      });
    }

    final categories = categoriesAsync.valueOrNull ?? const <String>[];
    final groups = groupsAsync.valueOrNull ?? const <String>[];

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(_isEdit ? 'Edit customer' : 'New customer',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: _isEdit && !_hydrated
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _field(
                    controller: _nameCtrl,
                    label: 'Shop name *',
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  _field(
                    controller: _codeCtrl,
                    label: 'Code *',
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  _field(
                    controller: _contactCtrl,
                    label: 'Contact person',
                  ),
                  _field(
                    controller: _phoneCtrl,
                    label: 'Phone',
                    keyboardType: TextInputType.phone,
                  ),
                  _field(
                    controller: _addressCtrl,
                    label: 'Address',
                    maxLines: 2,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DropdownWithCustomField(
                      label: 'Category',
                      value: _category,
                      options: categories,
                      onChanged: (v) => setState(() => _category = v),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DropdownWithCustomField(
                      label: 'Group',
                      value: _group,
                      options: groups,
                      onChanged: (v) => setState(() => _group = v),
                    ),
                  ),
                  _field(
                    controller: _ntnCtrl,
                    label: 'NTN / GST#',
                    hint: 'Optional tax identifier',
                  ),
                  const SizedBox(height: 20),
                  if (!_isEdit)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: const [
                          Icon(Icons.info_outline,
                              size: 16, color: AppColors.primary),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "You can set the customer's location after creating the record.",
                              style: TextStyle(
                                color: AppColors.primaryDark,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _submitting ? null : _submit,
                      icon: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check_circle_outline, size: 18),
                      label: Text(_isEdit ? 'Save changes' : 'Create customer'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
        ),
      ),
    );
  }
}
