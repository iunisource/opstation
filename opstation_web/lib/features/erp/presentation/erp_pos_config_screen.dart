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
  bool _loading = true, _saving = false;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  static const _keys = ['pos.company_name','pos.footer_note','pos.terms','pos.ntn','pos.contact','pos.logo'];

  @override void initState() { super.initState(); _load(); }
  @override void didChangeDependencies() { super.didChangeDependencies(); }
  @override void dispose() { _companyCtrl.dispose(); _footerCtrl.dispose(); _termsCtrl.dispose(); _ntnCtrl.dispose(); _contactCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final branchId = _branchId;
      var q = Supabase.instance.client.from('app_config').select('key, value').eq('org_id', orgId).inFilter('key', _keys);
      if (branchId != null) q = q.eq('branch_id', branchId); else q = q.filter('branch_id', 'is', null);
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
        final row = <String, dynamic>{'key': e.key, 'value': e.value, 'org_id': orgId};
        if (branchId != null) row['branch_id'] = branchId;
        await Supabase.instance.client.from('app_config').upsert(row, onConflict: branchId != null ? 'key,org_id,branch_id' : 'key,org_id');
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

  @override
  Widget build(BuildContext context) {
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
