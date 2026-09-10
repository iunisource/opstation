// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';

class ErpPosConfigScreen extends ConsumerStatefulWidget {
  const ErpPosConfigScreen({super.key});
  @override ConsumerState<ErpPosConfigScreen> createState() => _ErpPosConfigScreenState();
}

class _ErpPosConfigScreenState extends ConsumerState<ErpPosConfigScreen> {
  final _companyCtrl = TextEditingController();
  final _footerCtrl  = TextEditingController();
  final _termsCtrl   = TextEditingController();
  final _ntnCtrl     = TextEditingController();
  final _contactCtrl = TextEditingController();
  String? _logoDataUri;
  // Payment methods manager
  List<Map<String, dynamic>> _methods = [];
  List<Map<String, dynamic>> _coa = [];
  bool _methodsLoading = true;
  bool _loading = true, _saving = false;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  static const _keys = ['pos.company_name','pos.footer_note','pos.terms','pos.ntn','pos.contact','pos.logo'];

  @override void initState() { super.initState(); _load(); _loadMethods(); }
  @override void didChangeDependencies() { super.didChangeDependencies(); }
  @override void dispose() { _companyCtrl.dispose(); _footerCtrl.dispose(); _termsCtrl.dispose(); _ntnCtrl.dispose(); _contactCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final branchId = _branchId;
      var q = Supabase.instance.client.from('app_config').select('key, value').eq('org_id', orgId).inFilter('key', _keys);
      q = q.eq('branch_id', branchId ?? '');
      final rows = await q;
      final map = <String, String>{for (final r in rows as List) r['key'] as String: r['value'] as String? ?? ''};
      setState(() {
        _companyCtrl.text = map['pos.company_name'] ?? '';
        _footerCtrl.text  = map['pos.footer_note']  ?? '';
        _termsCtrl.text   = map['pos.terms']         ?? '';
        _ntnCtrl.text     = map['pos.ntn']           ?? '';
        _contactCtrl.text = map['pos.contact']       ?? '';
        _logoDataUri      = (map['pos.logo']?.isNotEmpty == true) ? map['pos.logo'] : null;
        _loading = false;
      });
    } catch (e) { _snack('Load error: $e'); setState(() => _loading = false); }
  }

  Future<void> _save() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _saving = true);
    try {
      final configs = {
        'pos.company_name': _companyCtrl.text.trim(), 'pos.footer_note': _footerCtrl.text.trim(),
        'pos.terms': _termsCtrl.text.trim(), 'pos.ntn': _ntnCtrl.text.trim(),
        'pos.contact': _contactCtrl.text.trim(), 'pos.logo': _logoDataUri ?? '',
      };
      for (final e in configs.entries) {
        final branchId = _branchId;
        await Supabase.instance.client.from('app_config').upsert({'key': e.key, 'value': e.value, 'org_id': orgId, 'branch_id': branchId ?? ''}, onConflict: 'key,org_id,branch_id');
      }
      _snack('POS configuration saved');
    } catch (e) { _snack('Save error: $e'); }
    setState(() => _saving = false);
  }

  void _pickLogo() {
    final input = html.FileUploadInputElement()..accept = 'image/png,image/jpeg,image/webp';
    input.click();
    input.onChange.listen((_) {
      if (input.files == null || input.files!.isEmpty) return;
      final file = input.files![0];
      if (file.size > 500000) { _snack('Image too large — max 500 KB'); return; }
      final reader = html.FileReader();
      reader.readAsDataUrl(file);
      reader.onLoad.listen((_) => setState(() => _logoDataUri = reader.result as String));
    });
  }

  void _removeLogo() { setState(() => _logoDataUri = null); }
  void _snack(String msg) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadMethods() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _methodsLoading = true);
    try {
      final m = await Supabase.instance.client.from('pos_payment_methods')
          .select('id, code, label, gl_account_id, is_credit, is_active, sort_order')
          .eq('org_id', orgId).order('sort_order');
      final coa = await Supabase.instance.client.from('chart_of_accounts')
          .select('id, code, name').eq('org_id', orgId).eq('is_active', true).order('code');
      setState(() {
        _methods = List<Map<String, dynamic>>.from(m);
        _coa = List<Map<String, dynamic>>.from(coa);
        _methodsLoading = false;
      });
    } catch (e) { _snack('Methods load error: $e'); setState(() => _methodsLoading = false); }
  }

  String _accountName(String? id) {
    if (id == null) return '—';
    final a = _coa.firstWhere((c) => c['id'] == id, orElse: () => const {});
    return a.isEmpty ? '—' : '${a['code']} — ${a['name']}';
  }

  Future<void> _saveMethod(Map<String, dynamic> m) async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      await Supabase.instance.client.from('pos_payment_methods').upsert({
        'id': m['id'], 'org_id': orgId, 'code': m['code'], 'label': m['label'],
        'gl_account_id': m['gl_account_id'], 'is_credit': m['is_credit'] ?? false,
        'is_active': m['is_active'] ?? true, 'sort_order': m['sort_order'] ?? 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'org_id,code');
    } catch (e) { _snack('Save error: $e'); }
  }

  Future<void> _toggleActive(Map<String, dynamic> m, bool v) async {
    setState(() => m['is_active'] = v);
    await _saveMethod(m);
  }

  // Add or edit a method. Pass null to add.
  void _methodDialog([Map<String, dynamic>? existing]) {
    final labelCtrl = TextEditingController(text: existing?['label'] as String? ?? '');
    String? acct = existing?['gl_account_id'] as String?;
    bool isCredit = existing?['is_credit'] == true;
    final isNew = existing == null;
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
      title: Text(isNew ? 'Add Payment Method' : 'Edit ${existing['label']}'),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: labelCtrl, decoration: const InputDecoration(labelText: 'Name (e.g. Easypaisa)')),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(value: acct, isExpanded: true, decoration: const InputDecoration(labelText: 'Posts to GL account'),
          items: _coa.map((a) => DropdownMenuItem(value: a['id'] as String, child: Text('${a['code']} — ${a['name']}', overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (v) => setLocal(() => acct = v)),
        const SizedBox(height: 6),
        CheckboxListTile(contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading,
          title: const Text('On credit (customer account)', style: TextStyle(fontSize: 13)),
          subtitle: const Text('Amount goes to the customer\'s balance instead of being collected', style: TextStyle(fontSize: 11)),
          value: isCredit, onChanged: (v) => setLocal(() => isCredit = v ?? false)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () async {
          final label = labelCtrl.text.trim();
          if (label.isEmpty || acct == null) { _snack('Enter a name and pick an account'); return; }
          final orgId = _orgId!;
          final code = isNew ? label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_') : existing['code'] as String;
          final id = isNew ? 'ppm_${orgId}_$code' : existing['id'] as String;
          Navigator.pop(ctx);
          await _saveMethod({
            'id': id, 'code': code, 'label': label, 'gl_account_id': acct,
            'is_credit': isCredit, 'is_active': existing?['is_active'] ?? true,
            'sort_order': existing?['sort_order'] ?? _methods.length,
          });
          await _loadMethods();
          _snack(isNew ? 'Added $label' : 'Updated $label');
        }, child: Text(isNew ? 'Add' : 'Save')),
      ],
    )));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<String, dynamic>?>(selectedBranchProvider, (prev, next) {
      if (prev?['id'] != next?['id']) _load();
    });
    if (_loading) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(padding: const EdgeInsets.all(32),
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('POS Configuration', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              SizedBox(height: 4),
              Text('These settings appear on POS receipts. Leave any field blank to hide it.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 4),
                            const SizedBox(height: 4),
                          ])),
            ElevatedButton.icon(icon: const Icon(Icons.save_outlined, size: 18), label: const Text('Save Configuration'), onPressed: _saving ? null : _save, style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14))),
          ]),
          const SizedBox(height: 32),
          _Section(title: 'Receipt Logo', subtitle: 'PNG or JPEG, max 500 KB, shown at top of receipt'),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            GestureDetector(onTap: _pickLogo, child: Container(width: 160, height: 110,
              decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10), border: Border.all(color: _logoDataUri != null ? AppTheme.primary.withOpacity(0.4) : AppTheme.border, width: 1.5)),
              child: _logoDataUri != null
                  ? ClipRRect(borderRadius: BorderRadius.circular(9), child: Image.network(_logoDataUri!, fit: BoxFit.contain))
                  : Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_photo_alternate_outlined, size: 36, color: AppTheme.textSecondary.withOpacity(0.5)), const SizedBox(height: 6), const Text('Click to upload', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))]))),
            const SizedBox(width: 16),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ElevatedButton.icon(icon: const Icon(Icons.upload_outlined, size: 16), label: const Text('Choose Image'), onPressed: _pickLogo),
              const SizedBox(height: 6),
              const Text('Recommended: transparent PNG, ~200x80px', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              if (_logoDataUri != null) ...[const SizedBox(height: 8), TextButton.icon(icon: const Icon(Icons.delete_outline, size: 16), label: const Text('Remove logo'), onPressed: _removeLogo, style: TextButton.styleFrom(foregroundColor: AppTheme.danger))],
            ]),
          ]),
          const SizedBox(height: 28),
          _Section(title: 'Company Name', subtitle: 'Displayed as the receipt heading'),
          const SizedBox(height: 10),
          TextField(controller: _companyCtrl, decoration: const InputDecoration(hintText: 'e.g. Bin Adam Trading Co.', filled: true, fillColor: Colors.white)),
          const SizedBox(height: 24),
          _Section(title: 'NTN', subtitle: 'National Tax Number printed below the company name'),
          const SizedBox(height: 10),
          TextField(controller: _ntnCtrl, decoration: const InputDecoration(hintText: 'e.g. NTN: 1234567-8', filled: true, fillColor: Colors.white)),
          const SizedBox(height: 24),
          _Section(title: 'Contact', subtitle: 'Phone, email or address shown below the company name'),
          const SizedBox(height: 10),
          TextField(controller: _contactCtrl, maxLines: 2, decoration: const InputDecoration(hintText: 'e.g. +92 300 1234567 | info@company.com', filled: true, fillColor: Colors.white)),
          const SizedBox(height: 24),
          _Section(title: 'Footer Note', subtitle: 'Short message printed at the bottom of each receipt'),
          const SizedBox(height: 10),
          TextField(controller: _footerCtrl, maxLines: 2, decoration: const InputDecoration(hintText: 'e.g. Thank you for your business!', filled: true, fillColor: Colors.white)),
          const SizedBox(height: 24),
          _Section(title: 'Terms & Conditions', subtitle: 'Printed in small text at the very bottom of each receipt'),
          const SizedBox(height: 10),
          TextField(controller: _termsCtrl, maxLines: 4, decoration: const InputDecoration(hintText: 'e.g. Goods once sold cannot be returned. All disputes subject to local jurisdiction.', filled: true, fillColor: Colors.white, alignLabelWithHint: true)),
          const SizedBox(height: 36),
          Row(children: [
            const Expanded(child: _Section(title: 'Payment Methods', subtitle: 'Tender types shown at POS checkout, and the account each posts to')),
            OutlinedButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('Add Method'), onPressed: _methodsLoading ? null : () => _methodDialog()),
          ]),
          const SizedBox(height: 12),
          if (_methodsLoading) const Padding(padding: EdgeInsets.all(16), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))))
          else if (_methods.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No payment methods configured yet.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
          else Column(children: _methods.map((m) {
            final active = m['is_active'] == true;
            final isCredit = m['is_credit'] == true;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(m['label'] as String? ?? '', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: active ? AppTheme.textPrimary : AppTheme.textSecondary)),
                    if (isCredit) Container(margin: const EdgeInsets.only(left: 8), padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.12), borderRadius: BorderRadius.circular(4)), child: Text('On credit', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.orange.shade800))),
                  ]),
                  const SizedBox(height: 2),
                  Text(_accountName(m['gl_account_id'] as String?), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                ])),
                Tooltip(message: active ? 'Active at checkout' : 'Hidden at checkout', child: Switch(value: active, onChanged: (v) => _toggleActive(m, v))),
                IconButton(icon: const Icon(Icons.edit_outlined, size: 18), tooltip: 'Edit', onPressed: () => _methodDialog(m)),
              ]),
            );
          }).toList()),
          const SizedBox(height: 8),
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.06), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.withOpacity(0.2))),
            child: const Row(children: [Icon(Icons.lightbulb_outline, size: 16, color: Colors.orange), SizedBox(width: 8), Expanded(child: Text('Turn a method off to hide it at checkout without deleting it. The "Customer Account" credit method is required for on-account and overpayment handling.', style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)))])),
          const SizedBox(height: 28),
          Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.primary.withOpacity(0.2))),
            child: const Row(children: [Icon(Icons.info_outline, size: 18, color: AppTheme.primary), SizedBox(width: 10), Expanded(child: Text('Changes apply to the next receipt printed from any POS session.', style: TextStyle(fontSize: 13, color: AppTheme.primary)))])),
          const SizedBox(height: 28),
          Align(alignment: Alignment.centerRight, child: ElevatedButton.icon(
            icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined, size: 18),
            label: Text(_saving ? 'Saving...' : 'Save Configuration'),
            onPressed: _saving ? null : _save, style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)))),
          const SizedBox(height: 40),
        ]),
      )),
    );
  }
}

class _Section extends StatelessWidget {
  final String title, subtitle;
  const _Section({required this.title, required this.subtitle});
  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    const SizedBox(height: 2),
    Text(subtitle, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
  ]);
}
