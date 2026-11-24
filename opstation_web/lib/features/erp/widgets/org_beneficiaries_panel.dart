import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';

/// Admin Settings: the supplier's bank / beneficiary accounts that retailers
/// see when they press "Pay" in the retailer portal. Any number can be added.
class OrgBeneficiariesPanel extends StatefulWidget {
  final String orgId;
  const OrgBeneficiariesPanel({super.key, required this.orgId});
  @override
  State<OrgBeneficiariesPanel> createState() => _OrgBeneficiariesPanelState();
}

class _OrgBeneficiariesPanelState extends State<OrgBeneficiariesPanel> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = [];

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.orgId.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final r = await _db.rpc('org_beneficiaries_list',
          params: {'p_org': widget.orgId});
      if (!mounted) return;
      setState(() {
        _rows = [
          for (final e in (r as List? ?? const []))
            Map<String, dynamic>.from(e as Map)
        ];
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Run SQL 461 first.';
        });
      }
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    String v(String k) => (row?[k] as String?) ?? '';
    final bank = TextEditingController(text: v('bank_name'));
    final title = TextEditingController(text: v('account_title'));
    final acct = TextEditingController(text: v('account_number'));
    final iban = TextEditingController(text: v('iban'));
    final branch = TextEditingController(text: v('branch'));
    final note = TextEditingController(text: v('note'));
    Widget f(String label, TextEditingController c, {int lines = 1}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: c,
            maxLines: lines,
            decoration: InputDecoration(
                labelText: label,
                isDense: true,
                border: const OutlineInputBorder()),
          ),
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(row == null ? 'Add beneficiary' : 'Edit beneficiary'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              f('Bank name *', bank),
              f('Account title *', title),
              f('Account number', acct),
              f('IBAN', iban),
              f('Branch', branch),
              f('Note (shown to retailer)', note, lines: 2),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _db.rpc('org_beneficiary_save', params: {
        'p_org': widget.orgId,
        'p_id': row?['id'],
        'p_bank': bank.text,
        'p_title': title.text,
        'p_acct': acct.text,
        'p_iban': iban.text,
        'p_branch': branch.text,
        'p_note': note.text,
      });
      await _load();
    } catch (e) {
      _snack('Could not save: ${'$e'.replaceAll('Exception: ', '')}');
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove beneficiary?'),
        content: Text('${row['bank_name']} · ${row['account_title']}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _db.rpc('org_beneficiary_delete',
          params: {'p_org': widget.orgId, 'p_id': row['id']});
      await _load();
    } catch (_) {
      _snack('Could not remove');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('Payment beneficiaries',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          if (_error == null)
            OutlinedButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add')),
        ]),
        const SizedBox(height: 4),
        const Text(
            'Bank accounts retailers can pay into. They see these when they press Pay in the retailer portal. Add as many as you need.',
            style: TextStyle(
                fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35)),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Text(_error!, style: const TextStyle(color: AppTheme.danger))
        else if (_rows.isEmpty)
          const Text('No beneficiaries yet.',
              style: TextStyle(color: AppTheme.textSecondary))
        else
          for (final r in _rows)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border)),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${r['bank_name']}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 13.5)),
                        Text('${r['account_title']}',
                            style: const TextStyle(fontSize: 12.5)),
                        if ((r['account_number'] ?? '').toString().isNotEmpty)
                          Text('A/C ${r['account_number']}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary)),
                        if ((r['iban'] ?? '').toString().isNotEmpty)
                          Text('IBAN ${r['iban']}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary)),
                      ]),
                ),
                IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _edit(r)),
                IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _delete(r)),
              ]),
            ),
      ]),
    );
  }
}
