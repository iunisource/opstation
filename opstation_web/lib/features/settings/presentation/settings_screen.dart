import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Existing
  final _cutoffCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _groupCtrl = TextEditingController();
  final _voucherFooterCtrl = TextEditingController();
  final _purchaseFooterCtrl = TextEditingController();
  List<String> _categories = [];
  List<String> _groups = [];

  // SMS notifications
  final _smsUrlCtrl = TextEditingController();
  final _smsHeadersCtrl = TextEditingController();
  final _smsBodyCtrl = TextEditingController();
  final _smsApiKeyCtrl = TextEditingController();
  final _smsSenderIdCtrl = TextEditingController();
  final _smsVisitTemplateCtrl = TextEditingController();
  final _smsDeliveryTemplateCtrl = TextEditingController();
  String _smsMethod = 'GET';
  bool _smsEnabled = false;
  bool _smsSaving = false;
  bool _smsObscure = true;

  bool _loading = true;

  static const _defaultVisitTpl =
      'Dear {customer_name}, payment of Rs. {amount} received. Receipt: {receipt_no}. Thank you.';
  static const _defaultDeliveryTpl =
      'Dear {customer_name}, your delivery of Rs. {amount} has been completed. Thank you.';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cutoffCtrl.dispose();
    _categoryCtrl.dispose();
    _groupCtrl.dispose();
    _voucherFooterCtrl.dispose();
    _purchaseFooterCtrl.dispose();
    _smsUrlCtrl.dispose();
    _smsHeadersCtrl.dispose();
    _smsBodyCtrl.dispose();
    _smsApiKeyCtrl.dispose();
    _smsSenderIdCtrl.dispose();
    _smsVisitTemplateCtrl.dispose();
    _smsDeliveryTemplateCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId);
      final cfg = <String, String>{};
      for (final r in rows) {
        cfg[r['key'] as String] = r['value'] as String? ?? '';
      }
      setState(() {
        _cutoffCtrl.text = cfg['org.cutoff_time'] ?? '23:00';
        try {
          _categories = List<String>.from(jsonDecode(cfg['org.categories'] ?? '[]'));
        } catch (_) {}
        try {
          _groups = List<String>.from(jsonDecode(cfg['org.groups'] ?? '[]'));
        } catch (_) {}
        // SMS
        _smsUrlCtrl.text = cfg['org.sms_api_url'] ?? '';
        _smsHeadersCtrl.text = cfg['org.sms_api_headers'] ?? '{}';
        _smsBodyCtrl.text = cfg['org.sms_api_body'] ?? '';
        _smsApiKeyCtrl.text = cfg['org.sms_api_key'] ?? '';
        _smsSenderIdCtrl.text = cfg['org.sms_sender_id'] ?? '';
        _smsVisitTemplateCtrl.text =
            cfg['org.sms_visit_template'] ?? _defaultVisitTpl;
        _smsDeliveryTemplateCtrl.text =
            cfg['org.sms_delivery_template'] ?? _defaultDeliveryTpl;
        _smsMethod = cfg['org.sms_api_method'] ?? 'GET';
        _smsEnabled = cfg['org.sms_enabled'] == 'true';
        _voucherFooterCtrl.text = cfg['org.voucher_footer_note'] ?? '';
        _purchaseFooterCtrl.text = cfg['org.purchase_footer_note'] ?? '';
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _save(String key, String value) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    await Supabase.instance.client
        .from('app_config')
        .upsert({'key': key, 'value': value, 'org_id': orgId});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    }
  }

  Future<void> _saveSmsSettings() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _smsSaving = true);
    try {
      final client = Supabase.instance.client;
      final configs = {
        'org.sms_api_url': _smsUrlCtrl.text.trim(),
        'org.sms_api_method': _smsMethod,
        'org.sms_api_headers': _smsHeadersCtrl.text.trim(),
        'org.sms_api_body': _smsBodyCtrl.text.trim(),
        'org.sms_api_key': _smsApiKeyCtrl.text.trim(),
        'org.sms_sender_id': _smsSenderIdCtrl.text.trim(),
        'org.sms_visit_template': _smsVisitTemplateCtrl.text.trim(),
        'org.sms_delivery_template': _smsDeliveryTemplateCtrl.text.trim(),
        'org.sms_enabled': _smsEnabled.toString(),
      };
      for (final entry in configs.entries) {
        await client.from('app_config').upsert({
          'key': entry.key,
          'value': entry.value,
          'org_id': orgId,
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SMS settings saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _smsSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserProvider)?.role;
    final isMaster = role == WebUserRole.masterAdmin || role == WebUserRole.superAdmin;

    if (_loading) return const Center(child: CircularProgressIndicator());
    return Container(
      color: AppTheme.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Settings',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 32),
          _Section(
              title: 'Cutoff Time',
              child: Row(children: [
                SizedBox(
                    width: 200,
                    child: TextField(
                        controller: _cutoffCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Time (HH:mm)', hintText: '23:00'))),
                const SizedBox(width: 12),
                ElevatedButton(
                    onPressed: () =>
                        _save('org.cutoff_time', _cutoffCtrl.text.trim()),
                    child: const Text('Save')),
              ])),
          const SizedBox(height: 24),
          if (isMaster) ...[
            _Section(
              title: 'Voucher Footer Note',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(
                  'This text appears at the bottom of every voucher PDF (SO, DO, SI, etc). Use it for terms, return policy, or contact info.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _voucherFooterCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Goods once sold will not be taken back. Subject to Lahore jurisdiction.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: () => _save('org.voucher_footer_note', _voucherFooterCtrl.text.trim()),
                    child: const Text('Save'),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 24),
          ],
          _Section(
            title: 'Purchase Voucher Footer Note',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'Appears at the bottom of PO, GRN, and PI PDFs. Leave blank to use the Sales footer note.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _purchaseFooterCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'e.g. Payment terms: Net 30 days. Subject to Lahore jurisdiction.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: () => _save('org.purchase_footer_note', _purchaseFooterCtrl.text.trim()),
                  child: const Text('Save'),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 24),
          _Section(
              title: 'Categories',
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _categories
                            .map((c) => Chip(
                                  label: Text(c),
                                  onDeleted: () {
                                    setState(() => _categories.remove(c));
                                    _save('org.categories', jsonEncode(_categories));
                                  },
                                ))
                            .toList()),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: _categoryCtrl,
                              decoration: const InputDecoration(
                                  labelText: 'New Category'))),
                      const SizedBox(width: 12),
                      ElevatedButton(
                          onPressed: () {
                            final v = _categoryCtrl.text.trim();
                            if (v.isEmpty || _categories.contains(v)) return;
                            setState(() {
                              _categories.add(v);
                              _categories.sort();
                              _categoryCtrl.clear();
                            });
                            _save('org.categories', jsonEncode(_categories));
                          },
                          child: const Text('Add')),
                    ]),
                  ])),
          const SizedBox(height: 24),
          _Section(
              title: 'Groups',
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _groups
                            .map((g) => Chip(
                                  label: Text(g),
                                  onDeleted: () {
                                    setState(() => _groups.remove(g));
                                    _save('org.groups', jsonEncode(_groups));
                                  },
                                ))
                            .toList()),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: _groupCtrl,
                              decoration: const InputDecoration(
                                  labelText: 'New Group'))),
                      const SizedBox(width: 12),
                      ElevatedButton(
                          onPressed: () {
                            final v = _groupCtrl.text.trim();
                            if (v.isEmpty || _groups.contains(v)) return;
                            setState(() {
                              _groups.add(v);
                              _groups.sort();
                              _groupCtrl.clear();
                            });
                            _save('org.groups', jsonEncode(_groups));
                          },
                          child: const Text('Add')),
                    ]),
                  ])),
          const SizedBox(height: 24),
          if (isMaster) _buildSmsSection() else _buildSmsRestricted(),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }

  Widget _buildSmsRestricted() {
    return _Section(
      title: 'SMS Notifications',
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'SMS notification settings are managed by your organization admin.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _buildSmsSection() {
    final inputDecoration = ({
      required String label,
      String? hint,
      IconData? icon,
    }) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon != null ? Icon(icon, size: 18) : null,
        );
    return _Section(
      title: 'SMS Notifications',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Switch(
              value: _smsEnabled,
              onChanged: (v) => setState(() => _smsEnabled = v)),
          const SizedBox(width: 8),
          Text(_smsEnabled ? 'Enabled' : 'Disabled',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Configure your SMS provider. Placeholders in body/query template: {phone}, {message}, {api_key}, {sender_id}.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _smsUrlCtrl,
              decoration: inputDecoration(
                  label: 'API Endpoint URL',
                  hint: 'https://api.example.com/send',
                  icon: Icons.link),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          const Text('Method:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          ChoiceChip(
            label: const Text('GET'),
            selected: _smsMethod == 'GET',
            onSelected: (_) => setState(() => _smsMethod = 'GET'),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('POST'),
            selected: _smsMethod == 'POST',
            onSelected: (_) => setState(() => _smsMethod = 'POST'),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _smsApiKeyCtrl,
              obscureText: _smsObscure,
              decoration: InputDecoration(
                labelText: 'API Key',
                prefixIcon: const Icon(Icons.vpn_key_outlined, size: 18),
                suffixIcon: IconButton(
                  icon: Icon(_smsObscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _smsObscure = !_smsObscure),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _smsSenderIdCtrl,
              decoration: inputDecoration(
                  label: 'Sender ID / Masking',
                  hint: 'e.g. BinAdam',
                  icon: Icons.person_outline),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        TextField(
          controller: _smsHeadersCtrl,
          decoration: inputDecoration(
              label: 'Headers (JSON)', hint: '{}', icon: Icons.code),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _smsBodyCtrl,
          maxLines: 3,
          decoration: inputDecoration(
              label: 'Body / Query params template',
              hint:
                  'hash={api_key}&receivernum={phone}&textmessage={message}',
              icon: Icons.data_object),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 16),
        const Text('Message Templates',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text(
          'Visit: {customer_name}, {amount}, {receipt_no}, {salesperson_name}\nDelivery: {customer_name}, {amount}, {driver_name}',
          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _smsVisitTemplateCtrl,
          maxLines: 2,
          decoration: inputDecoration(
              label: 'Visit collection message',
              icon: Icons.store_outlined),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _smsDeliveryTemplateCtrl,
          maxLines: 2,
          decoration: inputDecoration(
              label: 'Delivery confirmation message',
              icon: Icons.local_shipping_outlined),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton.icon(
            onPressed: _smsSaving ? null : _saveSmsSettings,
            icon: _smsSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(_smsSaving ? 'Saving...' : 'Save SMS Settings'),
          ),
        ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        child,
      ]),
    );
  }
}
