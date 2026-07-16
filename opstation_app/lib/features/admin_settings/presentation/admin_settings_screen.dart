import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/sms_debug_screen.dart';
import '../../../core/theme/app_colors.dart';
import '../models/org_settings.dart';
import '../providers/org_settings_controller.dart';

/// Admin-only settings screen.
///
/// Sections:
///   • Cut-off time
///   • Geofence radius / accuracy warning threshold
///   • Visit score bands
///   • Category taxonomy (CRUD)
///   • Group taxonomy (CRUD)
class AdminSettingsScreen extends ConsumerWidget {
  const AdminSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(orgSettingsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Settings',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (settings) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _CutoffSection(settings: settings),
            const SizedBox(height: 16),
            _GeofenceSection(settings: settings),
            const SizedBox(height: 16),
            _ScoreBandsSection(settings: settings),
            const SizedBox(height: 16),
            _TaxonomySection(
              title: 'Categories',
              items: settings.categories,
              onAdd: (name) => ref
                  .read(orgSettingsProvider.notifier)
                  .addCategory(name),
              onRemove: (name) => ref
                  .read(orgSettingsProvider.notifier)
                  .removeCategory(name),
              onRename: (oldN, newN) => ref
                  .read(orgSettingsProvider.notifier)
                  .renameCategory(oldN, newN),
            ),
            const SizedBox(height: 16),
            _TaxonomySection(
              title: 'Groups',
              items: settings.groups,
              onAdd: (name) =>
                  ref.read(orgSettingsProvider.notifier).addGroup(name),
              onRemove: (name) =>
                  ref.read(orgSettingsProvider.notifier).removeGroup(name),
              onRename: (oldN, newN) => ref
                  .read(orgSettingsProvider.notifier)
                  .renameGroup(oldN, newN),
            ),
            const SizedBox(height: 16),
            // SMS API config has been moved to the dedicated "Notification
            // templates" screen so masterAdmin only sees it once. The
            // _SmsApiSection class below remains in this file so we can
            // restore it instantly if needed — flip the false to a real
            // role check (matching the original commented logic) and the
            // section reappears.
            Builder(builder: (_) {
              const showHere = false;
              if (showHere) {
                return _SmsApiSection(settings: settings);
              }
              return const SizedBox.shrink();
            }),
            const SizedBox(height: 16),
            // Diagnostics: view the on-device log of the last SMS attempts —
            // sent, skipped (with reason), gateway rejection (with the
            // provider's response), or error. No Sentry/network needed.
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppColors.borderLight),
              ),
              child: ListTile(
                leading: const Icon(Icons.sms_outlined),
                title: const Text('SMS Debug'),
                subtitle: const Text('View the last SMS send attempts'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SmsDebugScreen(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}


// ---- SMS API ----------------------------------------------------------

class _SmsApiSection extends ConsumerStatefulWidget {
  final OrgSettings settings;
  const _SmsApiSection({required this.settings});

  @override
  ConsumerState<_SmsApiSection> createState() => _SmsApiSectionState();
}

class _SmsApiSectionState extends ConsumerState<_SmsApiSection> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _headersCtrl;
  late final TextEditingController _bodyCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _senderIdCtrl;
  late final TextEditingController _visitTemplateCtrl;
  late final TextEditingController _deliveryTemplateCtrl;
  late String _method;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _urlCtrl = TextEditingController(text: s.smsApiUrl);
    _headersCtrl = TextEditingController(text: s.smsApiHeaders);
    _bodyCtrl = TextEditingController(text: s.smsApiBody);
    _apiKeyCtrl = TextEditingController(text: s.smsApiKey);
    _senderIdCtrl = TextEditingController(text: s.smsSenderId);
    _visitTemplateCtrl = TextEditingController(text: s.smsVisitTemplate);
    _deliveryTemplateCtrl = TextEditingController(text: s.smsDeliveryTemplate);
    _method = s.smsApiMethod;
    _enabled = s.smsEnabled;
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

  Future<void> _save() async {
    await ref.read(orgSettingsProvider.notifier).setSmsConfig(
      apiUrl: _urlCtrl.text.trim(),
      apiMethod: _method,
      apiHeaders: _headersCtrl.text.trim(),
      apiBody: _bodyCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      senderId: _senderIdCtrl.text.trim(),
      visitTemplate: _visitTemplateCtrl.text.trim(),
      deliveryTemplate: _deliveryTemplateCtrl.text.trim(),
      enabled: _enabled,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SMS settings saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
          Row(
            children: [
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
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Configure your SMS provider. Use {phone}, {message}, {api_key}, {sender_id} as placeholders.',
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
          Row(
            children: [
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
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _apiKeyCtrl,
            decoration: const InputDecoration(
              labelText: 'API Key',
              prefixIcon: Icon(Icons.vpn_key_outlined),
            ),
            obscureText: true,
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
              hintText: '{"Authorization": "Bearer ..."}',
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
            'Placeholders: {customer_name}, {amount}, {receipt_no}',
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
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save SMS Settings'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Cut-off ----------------------------------------------------------

class _CutoffSection extends ConsumerWidget {
  final OrgSettings settings;
  const _CutoffSection({required this.settings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _SettingsCard(
      icon: Icons.access_time,
      title: 'Daily cut-off',
      subtitle:
          'Active trips auto-close at this time. Visit counts and leaderboards reset after cut-off.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.schedule,
                    color: AppColors.primary, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CURRENT',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: AppColors.primaryDark,
                        ),
                      ),
                      Text(
                        settings.cutoffTime,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final parts = settings.cutoffTime.split(':');
                    final h = int.tryParse(parts.first) ?? 23;
                    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(hour: h, minute: m),
                    );
                    if (picked != null) {
                      final hh = picked.hour.toString().padLeft(2, '0');
                      final mm = picked.minute.toString().padLeft(2, '0');
                      await ref
                          .read(orgSettingsProvider.notifier)
                          .setCutoffTime('$hh:$mm');
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Cut-off set to $hh:$mm')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Change'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Geofence ---------------------------------------------------------

class _GeofenceSection extends ConsumerStatefulWidget {
  final OrgSettings settings;
  const _GeofenceSection({required this.settings});

  @override
  ConsumerState<_GeofenceSection> createState() => _GeofenceSectionState();
}

class _GeofenceSectionState extends ConsumerState<_GeofenceSection> {
  late double _radius;
  late double _warn;

  @override
  void initState() {
    super.initState();
    _radius = widget.settings.geofenceRadiusMeters.toDouble();
    _warn = widget.settings.accuracyWarnMeters.toDouble();
  }

  @override
  void didUpdateWidget(covariant _GeofenceSection old) {
    super.didUpdateWidget(old);
    // Reflect updates from elsewhere.
    _radius = widget.settings.geofenceRadiusMeters.toDouble();
    _warn = widget.settings.accuracyWarnMeters.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.gps_fixed,
      title: 'GPS & geofencing',
      subtitle:
          'Visits within the radius are Verified; outside are marked Outside.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SliderRow(
            label: 'Geofence radius',
            value: _radius,
            min: 25,
            max: 500,
            divisions: 19,
            valueLabel: '${_radius.round()} m',
            onChanged: (v) => setState(() => _radius = v),
            onChangeEnd: (v) async {
              await ref
                  .read(orgSettingsProvider.notifier)
                  .setGeofenceRadius(v.round());
            },
          ),
          const SizedBox(height: 8),
          _SliderRow(
            label: 'Accuracy warning',
            value: _warn,
            min: 10,
            max: 200,
            divisions: 19,
            valueLabel: '±${_warn.round()} m',
            onChanged: (v) => setState(() => _warn = v),
            onChangeEnd: (v) async {
              await ref
                  .read(orgSettingsProvider.notifier)
                  .setAccuracyWarn(v.round());
            },
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.warningLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: const [
                Icon(Icons.info_outline,
                    size: 14, color: AppColors.warningDark),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Changes take effect at the next cut-off.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.warningDark,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Score bands ------------------------------------------------------

class _ScoreBandsSection extends ConsumerStatefulWidget {
  final OrgSettings settings;
  const _ScoreBandsSection({required this.settings});

  @override
  ConsumerState<_ScoreBandsSection> createState() => _ScoreBandsSectionState();
}

class _ScoreBandsSectionState extends ConsumerState<_ScoreBandsSection> {
  late RangeValues _range;

  @override
  void initState() {
    super.initState();
    _range = RangeValues(
      widget.settings.scoreBadMax.toDouble(),
      widget.settings.scoreOkMax.toDouble(),
    );
  }

  @override
  void didUpdateWidget(covariant _ScoreBandsSection old) {
    super.didUpdateWidget(old);
    _range = RangeValues(
      widget.settings.scoreBadMax.toDouble(),
      widget.settings.scoreOkMax.toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.bar_chart,
      title: 'Visit score bands',
      subtitle:
          'Thresholds (percent) for Poor / Okay / Good bands on salesperson performance.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RangeSlider(
            values: _range,
            min: 10,
            max: 90,
            divisions: 80,
            labels: RangeLabels(
              '${_range.start.round()}%',
              '${_range.end.round()}%',
            ),
            onChanged: (v) => setState(() => _range = v),
            onChangeEnd: (v) async {
              await ref.read(orgSettingsProvider.notifier).setScoreBands(
                    badMax: v.start.round(),
                    okMax: v.end.round(),
                  );
            },
          ),
          Row(
            children: [
              Expanded(
                child: _BandLabel(
                  color: AppColors.danger,
                  label: 'Poor',
                  range: '< ${_range.start.round()}%',
                ),
              ),
              Expanded(
                child: _BandLabel(
                  color: AppColors.warningDark,
                  label: 'Okay',
                  range: '${_range.start.round()}–${_range.end.round()}%',
                ),
              ),
              Expanded(
                child: _BandLabel(
                  color: AppColors.success,
                  label: 'Good',
                  range: '> ${_range.end.round()}%',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BandLabel extends StatelessWidget {
  final Color color;
  final String label;
  final String range;
  const _BandLabel({
    required this.color,
    required this.label,
    required this.range,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 2),
          child: Text(
            range,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondaryLight,
            ),
          ),
        ),
      ],
    );
  }
}

// ---- Taxonomy CRUD ----------------------------------------------------

class _TaxonomySection extends StatefulWidget {
  final String title;
  final List<String> items;
  final Future<void> Function(String) onAdd;
  final Future<void> Function(String) onRemove;
  final Future<void> Function(String, String) onRename;

  const _TaxonomySection({
    required this.title,
    required this.items,
    required this.onAdd,
    required this.onRemove,
    required this.onRename,
  });

  @override
  State<_TaxonomySection> createState() => _TaxonomySectionState();
}

class _TaxonomySectionState extends State<_TaxonomySection> {
  final _newCtrl = TextEditingController();

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _promptRename(String oldName) async {
    final ctrl = TextEditingController(text: oldName);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Rename ${widget.title.toLowerCase().substring(0, widget.title.length - 1)}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'New name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != oldName) {
      await widget.onRename(oldName, newName);
    }
  }

  Future<void> _confirmRemove(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove item?'),
        content: Text(
          'Remove "$name"? Customers already assigned to this value will keep it, but it won\'t appear in the dropdown anymore.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.onRemove(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.label_outline,
      title: widget.title,
      subtitle: 'Appears in the edit-customer dropdown.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No entries yet. Add one below.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryLight,
                ),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in widget.items)
                  _TaxonomyChip(
                    label: item,
                    onEdit: () => _promptRename(item),
                    onDelete: () => _confirmRemove(item),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newCtrl,
                  decoration: InputDecoration(
                    hintText: 'Add new ${widget.title.toLowerCase()}',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final v = _newCtrl.text.trim();
    if (v.isEmpty) return;
    await widget.onAdd(v);
    _newCtrl.clear();
  }
}

class _TaxonomyChip extends StatelessWidget {
  final String label;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _TaxonomyChip({
    required this.label,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: AppColors.borderLight,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(999),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.edit, size: 14),
            ),
          ),
          InkWell(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(999),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 14, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Shared ----------------------------------------------------------

class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child:
                    Icon(icon, color: AppColors.primary, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondaryLight,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}
