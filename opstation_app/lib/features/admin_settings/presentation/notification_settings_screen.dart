import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../models/org_settings.dart';
import '../providers/org_settings_controller.dart';

class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authControllerProvider).valueOrNull?.role;
    final isMasterAdmin = role == UserRole.masterAdmin || role == UserRole.superAdmin;

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Notification Settings',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (isMasterAdmin)
            const _SmsApiSection()
          else
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'SMS notification settings are managed by your organization admin.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondaryLight),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SmsApiSection extends ConsumerStatefulWidget {
  const _SmsApiSection();

  @override
  ConsumerState<_SmsApiSection> createState() => _SmsApiSectionState();
}

class _SmsApiSectionState extends ConsumerState<_SmsApiSection> {
  final _urlCtrl = TextEditingController();
  final _headersCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _senderIdCtrl = TextEditingController();
  final _visitTemplateCtrl = TextEditingController();
  final _deliveryTemplateCtrl = TextEditingController();
  String _method = 'GET';
  bool _enabled = false;
  bool _initialized = false;

  void _initFromSettings(Map<String, String> s) {
    if (_initialized) return;
    _initialized = true;
    _urlCtrl.text = s['org.sms_api_url'] ?? '';
    _headersCtrl.text = s['org.sms_api_headers'] ?? '{}';
    _bodyCtrl.text = s['org.sms_api_body'] ?? '';
    _apiKeyCtrl.text = s['org.sms_api_key'] ?? '';
    _senderIdCtrl.text = s['org.sms_sender_id'] ?? '';
    _visitTemplateCtrl.text = s['org.sms_visit_template'] ?? OrgSettings.defaults.smsVisitTemplate;
    _deliveryTemplateCtrl.text = s['org.sms_delivery_template'] ?? OrgSettings.defaults.smsDeliveryTemplate;
    setState(() {
      _method = s['org.sms_api_method'] ?? 'GET';
      _enabled = s['org.sms_enabled'] == 'true';
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _headersCtrl.dispose();
    _bodyCtrl.dispose();
    _apiKeyCtrl.dispose();
    _senderIdCtrl.dispose();
    _visitTemplateCtrl.dispose();
    _deliveryTemplateCtrl.dispose();
    super.dispose();
  }

  bool _saving = false;

  Future<void> _save() async {
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    if (orgId == null) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final configs = {
        'org.sms_api_url': _urlCtrl.text.trim(),
        'org.sms_api_method': _method,
        'org.sms_api_headers': _headersCtrl.text.trim(),
        'org.sms_api_body': _bodyCtrl.text.trim(),
        'org.sms_api_key': _apiKeyCtrl.text.trim(),
        'org.sms_sender_id': _senderIdCtrl.text.trim(),
        'org.sms_visit_template': _visitTemplateCtrl.text.trim(),
        'org.sms_delivery_template': _deliveryTemplateCtrl.text.trim(),
        'org.sms_enabled': _enabled.toString(),
      };
      for (final entry in configs.entries) {
        await client.from('app_config').upsert({
          'key': entry.key,
          'value': entry.value,
          'org_id': orgId,
        });
      }
      ref.invalidate(smsConfigProvider);
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
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(smsConfigProvider);
    return settingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (settings) {
        _initialized = false;
        _initFromSettings(settings as Map<String, String>);
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.sms_outlined, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('SMS Notifications',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                Switch(
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
              ]),
              const SizedBox(height: 4),
              const Text(
                'Use {phone}, {message}, {api_key}, {sender_id} as placeholders.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Endpoint URL',
                  hintText: 'https://api.example.com/send',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                const Text('Method:', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                ChoiceChip(
                  label: const Text('GET'),
                  selected: _method == 'GET',
                  onSelected: (_) => setState(() => _method = 'GET'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('POST'),
                  selected: _method == 'POST',
                  onSelected: (_) => setState(() => _method = 'POST'),
                ),
              ]),
              const SizedBox(height: 10),
              TextField(
                controller: _apiKeyCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  prefixIcon: Icon(Icons.vpn_key_outlined),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _senderIdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Sender ID / Masking',
                  hintText: 'e.g. BinAdam',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _headersCtrl,
                decoration: const InputDecoration(
                  labelText: 'Headers (JSON)',
                  hintText: '{}',
                  prefixIcon: Icon(Icons.code),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bodyCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Body / Query params template',
                  hintText: 'hash={api_key}&receivernum={phone}&textmessage={message}',
                  prefixIcon: Icon(Icons.data_object),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Message Templates',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text(
                'Visit: {customer_name}, {amount}, {receipt_no}, {salesperson_name}\nDelivery: {customer_name}, {amount}, {driver_name}',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondaryLight),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _visitTemplateCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Visit collection message',
                  prefixIcon: Icon(Icons.store_outlined),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _deliveryTemplateCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Delivery confirmation message',
                  prefixIcon: Icon(Icons.local_shipping_outlined),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Saving...' : 'Save SMS Settings'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}


final smsConfigProvider = FutureProvider<Map<String, String>>((ref) async {
  final orgId = ref.watch(authControllerProvider).valueOrNull?.organizationId;
  if (orgId == null) return {};
  try {
    final client = Supabase.instance.client;
    final rows = await client
        .from('app_config')
        .select('key, value')
        .eq('org_id', orgId)
        .inFilter('key', [
      'org.sms_api_url', 'org.sms_api_method', 'org.sms_api_headers',
      'org.sms_api_body', 'org.sms_api_key', 'org.sms_sender_id',
      'org.sms_visit_template', 'org.sms_delivery_template', 'org.sms_enabled',
    ]);
    final cfg = <String, String>{};
    for (final r in rows) {
      cfg[r['key'] as String] = r['value'] as String? ?? '';
    }
    return cfg;
  } catch (_) { return {}; }
});
