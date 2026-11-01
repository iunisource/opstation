import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';

/// Super admin → Enquiries: "Talk to our team" requests from the website
/// (SQL 437). Each one is also emailed when it arrives.
class EnquiriesScreen extends StatefulWidget {
  const EnquiriesScreen({super.key});
  @override
  State<EnquiriesScreen> createState() => _EnquiriesScreenState();
}

class _EnquiriesScreenState extends State<EnquiriesScreen> {
  bool _loading = true;
  String _filter = 'new';
  String _search = '';
  List<Map<String, dynamic>> _rows = [];

  static const _statuses = {'new': 'New', 'contacted': 'Contacted', 'closed': 'Closed'};

  SupabaseClient get _c => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await _c.from('sales_enquiries').select('*').order('created_at', ascending: false).limit(1000);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(friendlyError('Could not load enquiries', e));
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _setStatus(Map<String, dynamic> r, String status) async {
    final old = r['status'];
    setState(() => r['status'] = status);
    try {
      await _c.from('sales_enquiries').update({'status': status}).eq('id', r['id'] as String);
    } catch (e) {
      if (!mounted) return;
      setState(() => r['status'] = old);
      _snack(friendlyError('Could not update', e));
    }
  }

  Future<void> _editNotes(Map<String, dynamic> r) async {
    final ctrl = TextEditingController(text: (r['notes'] as String?) ?? '');
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Notes · ${r['name']}'),
        content: SizedBox(
          width: 420,
          child: TextField(controller: ctrl, maxLines: 5, autofocus: true,
              decoration: const InputDecoration(hintText: 'Call outcome, follow-up date…', border: OutlineInputBorder())),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (saved == null) return;
    final old = r['notes'];
    setState(() => r['notes'] = saved.isEmpty ? null : saved);
    try {
      await _c.from('sales_enquiries').update({'notes': saved.isEmpty ? null : saved}).eq('id', r['id'] as String);
    } catch (e) {
      if (!mounted) return;
      setState(() => r['notes'] = old);
      _snack(friendlyError('Could not save notes', e));
    }
  }

  String _digits(String phone) {
    var d = phone.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('00')) d = d.substring(2);
    if (d.startsWith('0')) d = '92${d.substring(1)}'; // local Pakistani number
    return d;
  }

  Future<void> _open(Uri u) async {
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {
      _snack('Could not open');
    }
  }

  List<Map<String, dynamic>> get _visible {
    final q = _search.trim().toLowerCase();
    return _rows.where((r) {
      if (_filter != 'all' && r['status'] != _filter) return false;
      if (q.isEmpty) return true;
      return [r['name'], r['phone'], r['business_name'], r['industry'], r['notes']]
          .any((v) => (v ?? '').toString().toLowerCase().contains(q));
    }).toList();
  }

  int _count(String s) => s == 'all' ? _rows.length : _rows.where((r) => r['status'] == s).length;

  @override
  Widget build(BuildContext context) {
    final list = _visible;
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Enquiries', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
            const Text('Call-back requests from the website', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final e in {'new': 'New', 'contacted': 'Contacted', 'closed': 'Closed', 'all': 'All'}.entries)
              ChoiceChip(
                label: Text('${e.value} (${_count(e.key)})'),
                selected: _filter == e.key,
                onSelected: (_) => setState(() => _filter = e.key),
              ),
            SizedBox(
              width: 260,
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: const InputDecoration(
                  isDense: true, prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search name, number, business',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
          ]),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? const Center(child: Text('No enquiries here yet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _card(list[i]),
                      ),
                    ),
        ),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final phone = (r['phone'] as String?) ?? '';
    final when = DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal();
    final status = (r['status'] as String?) ?? 'new';
    final biz = (r['business_name'] as String?)?.trim();
    final ind = (r['industry'] as String?)?.trim();
    final notes = (r['notes'] as String?)?.trim();
    final color = switch (status) { 'new' => AppTheme.primary, 'contacted' => Colors.orange.shade700, _ => Colors.green.shade700 };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: status == 'new' ? AppTheme.primary.withOpacity(0.35) : AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((r['name'] as String?) ?? '', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              Text([if (biz != null && biz.isNotEmpty) biz, if (ind != null && ind.isNotEmpty) ind].join(' · ').ifEmpty('No business details'),
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(6)),
            child: Text(_statuses[status] ?? status, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: phone));
              _snack('Number copied');
            },
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.phone_outlined, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Text(phone, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            ]),
          ),
          OutlinedButton.icon(
            onPressed: () => _open(Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}')),
            icon: const Icon(Icons.call, size: 16), label: const Text('Call'),
          ),
          OutlinedButton.icon(
            onPressed: () => _open(Uri.parse('https://wa.me/${_digits(phone)}')),
            icon: const Icon(Icons.chat_outlined, size: 16), label: const Text('WhatsApp'),
          ),
          if (when != null)
            Text(DateFormat('d MMM yyyy, h:mm a').format(when), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
        if (notes != null && notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(notes, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final s in _statuses.entries)
            if (s.key != status)
              TextButton(onPressed: () => _setStatus(r, s.key), child: Text('Mark ${s.value.toLowerCase()}')),
          TextButton.icon(
            onPressed: () => _editNotes(r),
            icon: const Icon(Icons.edit_note, size: 18),
            label: Text(notes == null || notes.isEmpty ? 'Add notes' : 'Edit notes'),
          ),
        ]),
      ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
