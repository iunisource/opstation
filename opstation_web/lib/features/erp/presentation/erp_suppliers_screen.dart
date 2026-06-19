// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

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

  void _showDialog(BuildContext context, Map<String, dynamic>? supplier) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final allBranches = await Supabase.instance.client
        .from('branches').select().eq('org_id', orgId).eq('is_active', true).order('name');
    Set<String> selectedBranches = {};
    if (supplier != null) {
      final existing = await Supabase.instance.client
          .from('supplier_branches').select('branch_id').eq('supplier_id', supplier['id']);
      selectedBranches = (existing as List).map((b) => b['branch_id'] as String).toSet();
    }
    if (!mounted) return;
    final nameCtrl = TextEditingController(text: supplier?['name'] ?? '');
    final phoneCtrl = TextEditingController(text: supplier?['phone'] ?? '');
    final emailCtrl = TextEditingController(text: supplier?['email'] ?? '');
    final addressCtrl = TextEditingController(text: supplier?['address'] ?? '');
    final contactPersonCtrl = TextEditingController(text: supplier?['contact_person'] ?? '');
    final contactNumberCtrl = TextEditingController(text: supplier?['contact_number'] ?? '');
    final ntnCtrl = TextEditingController(text: supplier?['ntn'] ?? '');
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
              Row(children: [
                Expanded(child: TextField(controller: contactPersonCtrl,
                    decoration: const InputDecoration(labelText: 'Contact Person'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: contactNumberCtrl,
                    decoration: const InputDecoration(labelText: 'Contact Number'),
                    keyboardType: TextInputType.phone)),
              ]),
              const SizedBox(height: 12),
              TextField(controller: ntnCtrl,
                  decoration: const InputDecoration(labelText: 'NTN')),
              const SizedBox(height: 12),
              TextField(controller: addressCtrl,
                  decoration: const InputDecoration(labelText: 'Address'),
                  maxLines: 2),
              const SizedBox(height: 16),
              StatefulBuilder(builder: (ctx2, setSB) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Branch Assignment', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary)),
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
                    child: Column(children: (allBranches as List).map((b) => CheckboxListTile(
                      dense: true,
                      title: Text(b['name'] as String, style: const TextStyle(fontSize: 13)),
                      value: selectedBranches.contains(b['id'] as String),
                      onChanged: (v) => setSB(() {
                        if (v == true) selectedBranches.add(b['id'] as String);
                        else selectedBranches.remove(b['id'] as String);
                      }),
                    )).toList()),
                  ),
                ],
              )),
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
                'contact_person': contactPersonCtrl.text.trim().isEmpty ? null : contactPersonCtrl.text.trim(),
                'contact_number': contactNumberCtrl.text.trim().isEmpty ? null : contactNumberCtrl.text.trim(),
                'ntn': ntnCtrl.text.trim().isEmpty ? null : ntnCtrl.text.trim(),
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

  // ─────────────────────────── Bulk import ───────────────────────────
  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static const Map<String, List<String>> _importFields = {
    'name': ['name', 'suppliername', 'supplier'],
    'phone': ['phone', 'phoneno', 'phonenumber'],
    'email': ['email', 'emailaddress'],
    'contact_person': ['contactperson', 'contact'],
    'contact_number': ['contactnumber', 'contactno', 'contactnum'],
    'ntn': ['ntn', 'ntngst', 'gst'],
    'address': ['address'],
    'payment_terms_days': ['paymentterms', 'paymenttermsdays', 'terms'],
    'credit_limit': ['creditlimit', 'credit'],
  };

  List<List<String>> _parseCsv(String input) {
    final rows = <List<String>>[];
    var field = StringBuffer();
    var row = <String>[];
    var inQuotes = false;
    final s = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < s.length && s[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(ch);
        }
      } else {
        if (ch == '"') {
          inQuotes = true;
        } else if (ch == ',') {
          row.add(field.toString());
          field = StringBuffer();
        } else if (ch == '\n') {
          row.add(field.toString());
          field = StringBuffer();
          rows.add(row);
          row = <String>[];
        } else {
          field.write(ch);
        }
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
  }

  void _downloadTemplate() {
    const headers =
        'Name,Phone,Email,Contact Person,Contact Number,NTN,Address,Payment Terms (days),Credit Limit';
    const sample =
        'Acme Traders,03001234567,acme@example.com,Ali Khan,04211112222,1234567-8,"12 Mall Road, Lahore",30,500000';
    final blob = html.Blob(['$headers\n$sample\n'], 'text/csv');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..download = 'suppliers_template.csv'
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  Future<List<List<String>>?> _pickCsv() async {
    final input = html.FileUploadInputElement()..accept = '.csv,text/csv';
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return null;
    final reader = html.FileReader()..readAsText(files.first);
    await reader.onLoad.first;
    return _parseCsv((reader.result as String?) ?? '');
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
        child: Text(text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      );

  Future<void> _bulkImportDialog() async {
    final rawRows = await _pickCsv();
    if (rawRows == null) return;
    if (rawRows.length < 2) {
      _showSnack('CSV has a header but no data rows.');
      return;
    }

    final header = rawRows.first.map((h) => _norm(h)).toList();
    final colIndex = <String, int>{};
    _importFields.forEach((field, aliases) {
      for (var i = 0; i < header.length; i++) {
        if (aliases.contains(header[i])) {
          colIndex[field] = i;
          break;
        }
      }
    });
    if (!colIndex.containsKey('name')) {
      _showSnack('No "Name" column found in the CSV header.');
      return;
    }

    final existingByName = <String, Map<String, dynamic>>{
      for (final s in _suppliers) (s['name'] as String? ?? '').trim().toLowerCase(): s,
    };

    String cell(List<String> r, String f) {
      final idx = colIndex[f];
      if (idx == null || idx >= r.length) return '';
      return r[idx].trim();
    }

    final parsed = <Map<String, dynamic>>[];
    for (final r in rawRows.skip(1)) {
      final name = cell(r, 'name');
      if (name.isEmpty) {
        parsed.add({'status': 'invalid', 'name': '(blank)', 'error': 'missing name'});
        continue;
      }
      final dup = existingByName.containsKey(name.toLowerCase());
      final data = <String, dynamic>{
        'name': name,
        'phone': cell(r, 'phone').isEmpty ? null : cell(r, 'phone'),
        'email': cell(r, 'email').isEmpty ? null : cell(r, 'email'),
        'address': cell(r, 'address').isEmpty ? null : cell(r, 'address'),
        'contact_person':
            cell(r, 'contact_person').isEmpty ? null : cell(r, 'contact_person'),
        'contact_number':
            cell(r, 'contact_number').isEmpty ? null : cell(r, 'contact_number'),
        'ntn': cell(r, 'ntn').isEmpty ? null : cell(r, 'ntn'),
        'payment_terms_days': int.tryParse(cell(r, 'payment_terms_days')) ?? 30,
        'credit_limit':
            cell(r, 'credit_limit').isEmpty ? null : double.tryParse(cell(r, 'credit_limit')),
      };
      parsed.add({'status': dup ? 'dup' : 'new', 'name': name, 'data': data});
    }

    final newCount = parsed.where((p) => p['status'] == 'new').length;
    final dupCount = parsed.where((p) => p['status'] == 'dup').length;
    final invalidCount = parsed.where((p) => p['status'] == 'invalid').length;
    var dupMode = 'skip';
    var importing = false;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: const Text('Bulk Import Suppliers'),
          content: SizedBox(
            width: 560,
            height: 460,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _chip('${parsed.length} rows', AppTheme.textSecondary),
                const SizedBox(width: 8),
                _chip('$newCount new', AppTheme.success),
                const SizedBox(width: 8),
                _chip('$dupCount duplicate', Colors.orange),
                if (invalidCount > 0) ...[
                  const SizedBox(width: 8),
                  _chip('$invalidCount invalid', AppTheme.danger),
                ],
              ]),
              const SizedBox(height: 12),
              if (dupCount > 0) ...[
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Rows whose name already exists:',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
                Row(children: [
                  Expanded(
                    child: RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Skip', style: TextStyle(fontSize: 13)),
                      value: 'skip',
                      groupValue: dupMode,
                      onChanged: (v) => setLocal(() => dupMode = v!),
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Update existing', style: TextStyle(fontSize: 13)),
                      value: 'update',
                      groupValue: dupMode,
                      onChanged: (v) => setLocal(() => dupMode = v!),
                    ),
                  ),
                ]),
              ],
              const Divider(height: 16),
              Expanded(
                child: ListView.builder(
                  itemCount: parsed.length,
                  itemBuilder: (_, i) {
                    final p = parsed[i];
                    final st = p['status'] as String;
                    final color = st == 'new'
                        ? AppTheme.success
                        : st == 'dup'
                            ? Colors.orange
                            : AppTheme.danger;
                    final label = st == 'new'
                        ? 'new'
                        : st == 'dup'
                            ? 'dup'
                            : '${p['error']}';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Expanded(
                            child: Text('${p['name']}',
                                style: const TextStyle(fontSize: 13),
                                maxLines: 1, overflow: TextOverflow.ellipsis)),
                        _chip(label, color),
                      ]),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: _downloadTemplate, child: const Text('Download template')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed:
                  (importing || newCount + (dupMode == 'update' ? dupCount : 0) == 0)
                      ? null
                      : () async {
                          setLocal(() => importing = true);
                          final res = await _runImport(parsed, dupMode, existingByName);
                          if (ctx.mounted) Navigator.pop(ctx);
                          _showSnack(res);
                          _load();
                        },
              child: Text(importing ? 'Importing…' : 'Import'),
            ),
          ],
        );
      }),
    );
  }

  Future<String> _runImport(List<Map<String, dynamic>> parsed, String dupMode,
      Map<String, Map<String, dynamic>> existingByName) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final client = Supabase.instance.client;
    final toInsert = <Map<String, dynamic>>[];
    final toUpdate = <Map<String, dynamic>>[];
    var skipped = 0, invalid = 0;
    var seq = DateTime.now().millisecondsSinceEpoch;
    for (final p in parsed) {
      final st = p['status'] as String;
      if (st == 'invalid') {
        invalid++;
        continue;
      }
      final data = Map<String, dynamic>.from(p['data'] as Map);
      if (st == 'dup') {
        if (dupMode == 'skip') {
          skipped++;
          continue;
        }
        final existing = existingByName[(p['name'] as String).toLowerCase()];
        if (existing != null) {
          toUpdate.add({
            'id': existing['id'],
            'data': {...data, 'updated_at': DateTime.now().toUtc().toIso8601String()},
          });
        }
        continue;
      }
      toInsert.add({
        ...data,
        'id': 'sup_${seq++}',
        'org_id': orgId,
        'is_active': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    }

    var created = 0, updated = 0, failed = 0;
    try {
      for (var i = 0; i < toInsert.length; i += 200) {
        final part = toInsert.sublist(
            i, i + 200 > toInsert.length ? toInsert.length : i + 200);
        await client.from('suppliers').insert(part);
        created += part.length;
      }
      for (final u in toUpdate) {
        try {
          await client.from('suppliers').update(u['data']).eq('id', u['id']);
          updated++;
        } catch (_) {
          failed++;
        }
      }
    } catch (e) {
      return 'Stopped after $created created — $e';
    }

    final bits = <String>['$created created'];
    if (updated > 0) bits.add('$updated updated');
    if (skipped > 0) bits.add('$skipped skipped');
    if (invalid > 0) bits.add('$invalid invalid');
    if (failed > 0) bits.add('$failed failed');
    return 'Import done — ${bits.join(', ')}.';
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
            OutlinedButton.icon(
              onPressed: _bulkImportDialog,
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('Bulk Import'),
            ),
            const SizedBox(width: 8),
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
