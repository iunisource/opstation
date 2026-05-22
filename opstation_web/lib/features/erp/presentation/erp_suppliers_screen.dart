import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpSuppliersScreen extends ConsumerStatefulWidget {
  const ErpSuppliersScreen({super.key});
  @override
  ConsumerState<ErpSuppliersScreen> createState() => _ErpSuppliersScreenState();
}

class _ErpSuppliersScreenState extends ConsumerState<ErpSuppliersScreen> {
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final res = await Supabase.instance.client
          .from('suppliers')
          .select()
          .eq('org_id', orgId)
          .order('name');
      setState(() {
        _suppliers = List<Map<String, dynamic>>.from(res);
        _filtered = _suppliers;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _suppliers.where((s) =>
          q.isEmpty ||
          (s['name'] as String? ?? '').toLowerCase().contains(q) ||
          (s['phone'] as String? ?? '').toLowerCase().contains(q) ||
          (s['email'] as String? ?? '').toLowerCase().contains(q)).toList();
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _toggleActive(Map<String, dynamic> s) async {
    final newVal = !(s['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client
          .from('suppliers')
          .update({'is_active': newVal, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', s['id']);
      _showSnack(newVal ? 'Supplier activated' : 'Supplier deactivated');
      _load();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? supplier) {
    final nameCtrl = TextEditingController(text: supplier?['name'] ?? '');
    final phoneCtrl = TextEditingController(text: supplier?['phone'] ?? '');
    final emailCtrl = TextEditingController(text: supplier?['email'] ?? '');
    final addressCtrl = TextEditingController(text: supplier?['address'] ?? '');
    final termsCtrl = TextEditingController(text: supplier?['payment_terms_days']?.toString() ?? '30');
    final creditCtrl = TextEditingController(text: supplier?['credit_limit']?.toString() ?? '');

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(supplier == null ? 'Add Supplier' : 'Edit Supplier'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Supplier Name *')),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: TextField(controller: phoneCtrl,
                    decoration: const InputDecoration(labelText: 'Phone'),
                    keyboardType: TextInputType.phone)),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: emailCtrl,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress)),
              ]),
              const SizedBox(height: 12),
              TextField(controller: addressCtrl,
                  decoration: const InputDecoration(labelText: 'Address'),
                  maxLines: 2),
              const SizedBox(height: 16),
              const Align(alignment: Alignment.centerLeft,
                  child: Text('Credit Terms', style: TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13,
                      color: AppTheme.textSecondary))),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: termsCtrl,
                    decoration: const InputDecoration(labelText: 'Payment Terms (days)', hintText: '30'),
                    keyboardType: TextInputType.number)),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: creditCtrl,
                    decoration: const InputDecoration(labelText: 'Credit Limit (optional)', hintText: 'Leave blank for no limit'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              ]),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Supplier name is required')));
                return;
              }
              final orgId = ref.read(currentUserProvider)?.orgId;
              final data = {
                'org_id': orgId,
                'name': nameCtrl.text.trim(),
                'phone': phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
                'email': emailCtrl.text.trim().isEmpty ? null : emailCtrl.text.trim(),
                'address': addressCtrl.text.trim().isEmpty ? null : addressCtrl.text.trim(),
                'payment_terms_days': int.tryParse(termsCtrl.text.trim()) ?? 30,
                'credit_limit': creditCtrl.text.trim().isEmpty ? null : double.tryParse(creditCtrl.text.trim()),
                'is_active': true,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              };
              try {
                if (supplier == null) {
                  final id = 'sup_${DateTime.now().millisecondsSinceEpoch}';
                  await Supabase.instance.client.from('suppliers').insert({...data, 'id': id});
                } else {
                  await Supabase.instance.client.from('suppliers').update(data).eq('id', supplier['id']);
                }
                if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
                _showSnack(supplier == null ? 'Supplier added' : 'Supplier updated');
                _load();
              } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
              }
            },
            child: Text(supplier == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Suppliers',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () => _showDialog(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Supplier'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${_filtered.length} suppliers',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search by name, phone or email...',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: const Row(children: [
                      Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Phone', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Email', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('Terms', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Credit Limit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 80),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _filtered.isEmpty
                        ? const Center(child: Text('No suppliers yet.', style: TextStyle(color: AppTheme.textSecondary)))
                        : ListView.separated(
                            itemCount: _filtered.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final s = _filtered[i];
                              final isActive = s['is_active'] as bool? ?? true;
                              return Opacity(
                                opacity: isActive ? 1.0 : 0.5,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  child: Row(children: [
                                    Expanded(flex: 3, child: Text(s['name'] as String? ?? '',
                                        style: const TextStyle(fontWeight: FontWeight.w600))),
                                    Expanded(flex: 2, child: Text(s['phone'] as String? ?? '-',
                                        style: const TextStyle(fontSize: 13))),
                                    Expanded(flex: 2, child: Text(s['email'] as String? ?? '-',
                                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                                    Expanded(flex: 1, child: Text('${s['payment_terms_days'] ?? 30}d',
                                        style: const TextStyle(fontSize: 13))),
                                    Expanded(flex: 2, child: Text(
                                        s['credit_limit'] != null ? s['credit_limit'].toString() : 'No limit',
                                        style: const TextStyle(fontSize: 13))),
                                    SizedBox(width: 80, child: Row(children: [
                                      IconButton(
                                          icon: const Icon(Icons.edit_outlined, size: 18),
                                          onPressed: () => _showDialog(context, s)),
                                      IconButton(
                                        icon: Icon(
                                            isActive ? Icons.block : Icons.check_circle_outline,
                                            size: 18,
                                            color: isActive ? AppTheme.danger : AppTheme.success),
                                        onPressed: () => _toggleActive(s),
                                      ),
                                    ])),
                                  ]),
                                ),
                              );
                            }),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}
