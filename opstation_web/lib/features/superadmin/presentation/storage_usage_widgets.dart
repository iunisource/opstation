import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

/// Super Admin: storage used by one org + its support-document retention
/// ("overwrite tenure"). Backed by SQL 350 (org_storage_usage,
/// set_org_docs_retention) and the purge-support-docs edge function.

String fmtBytes(num? b) {
  final v = (b ?? 0).toDouble();
  if (v < 1024) return '${v.toStringAsFixed(0)} B';
  if (v < 1024 * 1024) return '${(v / 1024).toStringAsFixed(1)} KB';
  if (v < 1024 * 1024 * 1024) return '${(v / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(v / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

const _bucketLabels = {
  'si-documents': 'Invoice / DO / return documents',
  'pi-documents': 'Purchase invoice documents',
  'grn-documents': 'GRN documents',
  'jv-documents': 'Journal voucher documents',
  'asset-files': 'Asset photos & files',
  'hr-photos': 'Employee photos & documents',
  'kiosk-punches': 'Attendance kiosk photos',
  'signatures': 'Logos, signatures & stamps',
  'catalog': 'Product & brand images',
  'retailer-files': 'Retailer files',
};

String bucketLabel(String b) => _bucketLabels[b] ?? b;

const _retentionChoices = <int, String>{
  0: 'Keep forever (never overwrite)',
  30: '30 days',
  60: '60 days',
  90: '90 days (3 months)',
  180: '180 days (6 months)',
  365: '1 year',
  730: '2 years',
  1095: '3 years',
  1825: '5 years',
};

Widget _sectionTitle(String t) => Text(t,
    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.6));

Widget _bar(String label, num bytes, num total, {String? sub, Color? color}) {
  final frac = total <= 0 ? 0.0 : (bytes / total).clamp(0, 1).toDouble();
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
        Text(fmtBytes(bytes), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
      if (sub != null) Text(sub, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
      const SizedBox(height: 3),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: frac,
          minHeight: 5,
          backgroundColor: AppTheme.border.withOpacity(0.5),
          valueColor: AlwaysStoppedAnimation(color ?? AppTheme.primary),
        ),
      ),
    ]),
  );
}

Widget _stat(String label, String value, {Color? color}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
      ]),
    );

/// Shown inside Organizations → Edit (org profile).
class OrgStoragePanel extends StatefulWidget {
  final String orgId;
  const OrgStoragePanel({super.key, required this.orgId});
  @override
  State<OrgStoragePanel> createState() => _OrgStoragePanelState();
}

class _OrgStoragePanelState extends State<OrgStoragePanel> {
  Map<String, dynamic>? _d;
  String? _err;
  bool _loading = true;
  bool _saving = false;
  bool _purging = false;
  int _days = 0; // 0 = keep forever
  bool _custom = false;
  final _customCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _err = null; });
    try {
      final r = await Supabase.instance.client.rpc('org_storage_usage', params: {'p_org': widget.orgId});
      final m = Map<String, dynamic>.from(r as Map);
      if (!mounted) return;
      final days = (m['retention_days'] as num?)?.toInt() ?? 0;
      setState(() {
        _d = m;
        _days = days;
        _custom = !_retentionChoices.containsKey(days);
        if (_custom) _customCtrl.text = '$days';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = e.toString().contains('org_storage_usage')
            ? 'Run SQL 350 in Supabase first.'
            : 'Could not load storage: ${e.toString().split('\n').first}';
      });
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _saveRetention() async {
    var days = _days;
    if (_custom) {
      final c = int.tryParse(_customCtrl.text.trim());
      if (c == null || c < 30) { _snack('Enter at least 30 days.'); return; }
      days = c;
    }
    if (days > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Set document retention?'),
          content: Text(
              'Support documents older than $days days will be permanently deleted for this organization, '
              'every night from now on. This cannot be undone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('set_org_docs_retention', params: {'p_org': widget.orgId, 'p_days': days});
      _snack(days == 0 ? 'Documents will be kept forever' : 'Retention set to $days days');
      await _load();
    } catch (e) {
      _snack('Could not save: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _purgeNow() async {
    final due = (_d?['due_now'] as Map?) ?? const {};
    final n = (due['files'] as num?)?.toInt() ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete old documents now?'),
        content: Text('$n file${n == 1 ? '' : 's'} (${fmtBytes(due['bytes'] as num?)}) older than '
            '${_d?['retention_days']} days will be permanently deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete now'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _purging = true);
    try {
      final res = await Supabase.instance.client.functions
          .invoke('purge-support-docs', body: {'org_id': widget.orgId, 'kind': 'docs'});
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
      final o = (data['orgs'] as Map?)?[widget.orgId] as Map?;
      _snack(o == null ? 'Nothing was due' : 'Deleted ${o['files']} file(s), freed ${fmtBytes(o['bytes'] as num?)}');
      await _load();
    } catch (e) {
      _snack('Purge failed — is the purge-support-docs function deployed? ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (_err != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(child: Text(_err!, style: const TextStyle(fontSize: 12, color: AppTheme.danger))),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    final d = _d!;
    final fileBytes = (d['file_bytes'] as num?) ?? 0;
    final dbBytes = (d['db_bytes'] as num?) ?? 0;
    final total = (d['total_bytes'] as num?) ?? 0;
    final buckets = ((d['buckets'] as List?) ?? const []).cast<Map>();
    final tables = ((d['tables'] as List?) ?? const []).cast<Map>();
    final docs = (d['support_docs'] as Map?) ?? const {};
    final due = d['due_now'] as Map?;
    final last = d['last_purge'] as Map?;
    final oldest = DateTime.tryParse('${docs['oldest'] ?? ''}');
    final lastAt = DateTime.tryParse('${last?['run_at'] ?? ''}');
    final dropdownValue = _custom ? -1 : _days;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: _sectionTitle('STORAGE')),
        IconButton(
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh, size: 16),
          onPressed: _load,
        ),
      ]),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _stat('Total used', fmtBytes(total)),
        _stat('Files', '${fmtBytes(fileBytes)} · ${d['files'] ?? 0}'),
        _stat('Database (est.)', fmtBytes(dbBytes)),
        _stat('Uploaded last 30 days', fmtBytes(d['uploaded_30d'] as num?)),
      ]),
      const SizedBox(height: 12),
      if (buckets.isNotEmpty) ...[
        const Text('Files by type', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (final b in buckets)
          _bar(bucketLabel('${b['bucket']}'), (b['bytes'] as num?) ?? 0, fileBytes,
              sub: '${b['files']} file${b['files'] == 1 ? '' : 's'}'),
      ],
      if (tables.isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Largest data tables (estimate)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            children: [
              for (final t in tables)
                _bar('${t['table']}', (t['bytes'] as num?) ?? 0, dbBytes,
                    sub: '${NumberFormat('#,##0').format(t['rows'] ?? 0)} rows', color: Colors.blueGrey),
            ],
          ),
        ),
      const SizedBox(height: 14),
      _sectionTitle('SUPPORT DOCUMENTS — OVERWRITE TENURE'),
      const SizedBox(height: 4),
      Text(
        'Support documents on invoices, GRNs, JVs, delivery orders and returns: '
        '${docs['files'] ?? 0} file${docs['files'] == 1 ? '' : 's'}, ${fmtBytes(docs['bytes'] as num?)}'
        '${oldest == null ? '' : ' · oldest ${DateFormat('d MMM y').format(oldest.toLocal())}'}.\n'
        'Files older than the period below are deleted automatically every night to free space. '
        'The vouchers themselves are never touched.',
        style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<int>(
        value: dropdownValue,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Delete support documents older than', isDense: true),
        items: [
          for (final e in _retentionChoices.entries) DropdownMenuItem<int>(value: e.key, child: Text(e.value)),
          const DropdownMenuItem<int>(value: -1, child: Text('Custom (days)…')),
        ],
        onChanged: (v) => setState(() {
          _custom = v == -1;
          if (!_custom) _days = v ?? 0;
        }),
      ),
      if (_custom) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _customCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Days (minimum 30)', isDense: true),
        ),
      ],
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ElevatedButton.icon(
          onPressed: _saving ? null : _saveRetention,
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save_outlined, size: 16),
          label: const Text('Save tenure'),
        ),
        if (d['retention_days'] != null && ((due?['files'] as num?) ?? 0) > 0)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
            onPressed: _purging ? null : _purgeNow,
            icon: _purging
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.delete_sweep_outlined, size: 16),
            label: Text('Purge now (${due?['files']} · ${fmtBytes(due?['bytes'] as num?)})'),
          ),
      ]),
      const SizedBox(height: 6),
      Text(
        [
          if (d['retention_days'] == null) 'Currently: kept forever.'
          else 'Currently: ${d['retention_days']} days — ${due?['files'] ?? 0} file(s) due now.',
          if (lastAt != null)
            'Last run ${DateFormat('d MMM y, h:mm a').format(lastAt.toLocal())}: '
                '${last?['files'] ?? 0} file(s), ${fmtBytes(last?['bytes'] as num?)} freed'
                '${(last?['note'] as String?)?.isNotEmpty == true ? ' (${last?['note']})' : ''}.',
        ].join('  '),
        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
      ),
      const SizedBox(height: 18),
      _KioskSection(orgId: widget.orgId),
      const SizedBox(height: 18),
      _AuditSection(orgId: widget.orgId),
    ]);
  }
}

String _lastRunLine(Map? last, {String unit = 'file(s)', String verb = 'freed'}) {
  final at = DateTime.tryParse('${last?['run_at'] ?? ''}');
  if (at == null) return '';
  final note = (last?['note'] as String?) ?? '';
  return 'Last run ${DateFormat('d MMM y, h:mm a').format(at.toLocal())}: '
      '${last?['files'] ?? 0} $unit, ${fmtBytes(last?['bytes'] as num?)} $verb'
      '${note.isNotEmpty ? ' ($note)' : ''}.';
}

Future<bool> _confirm(BuildContext context, String title, String body, String action, {bool danger = true}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          style: danger ? ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Attendance kiosk punch photos — kept 40 days by default (SQL 351).
class _KioskSection extends StatefulWidget {
  final String orgId;
  const _KioskSection({required this.orgId});
  @override
  State<_KioskSection> createState() => _KioskSectionState();
}

class _KioskSectionState extends State<_KioskSection> {
  static const _choices = <int, String>{
    0: 'Keep forever',
    14: '14 days',
    30: '30 days',
    40: '40 days (default)',
    60: '60 days',
    90: '90 days',
    180: '180 days',
    365: '1 year',
  };
  Map<String, dynamic>? _d;
  String? _err;
  int _days = 40;
  bool _custom = false;
  final _customCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _load() async {
    try {
      final r = await Supabase.instance.client.rpc('org_kiosk_usage', params: {'p_org': widget.orgId});
      final m = Map<String, dynamic>.from(r as Map);
      if (!mounted) return;
      setState(() {
        _d = m;
        _err = null;
        final d = (m['retention_days'] as num?)?.toInt() ?? 40;
        _days = d;
        _custom = !_choices.containsKey(d);
        if (_custom) _customCtrl.text = '$d';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _err = e.toString().contains('org_kiosk_usage')
            ? 'Run SQL 351 in Supabase first.'
            : e.toString().split('\n').first);
      }
    }
  }

  Future<void> _save() async {
    var days = _days;
    if (_custom) {
      final c = int.tryParse(_customCtrl.text.trim());
      if (c == null || c < 7) { _snack('Enter at least 7 days.'); return; }
      days = c;
    }
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.rpc('set_org_kiosk_retention',
          params: {'p_org': widget.orgId, 'p_days': days == 40 ? null : days});
      _snack(days == 0 ? 'Kiosk photos will be kept forever' : 'Kiosk photos kept $days days');
      await _load();
    } catch (e) {
      _snack('Could not save: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeNow() async {
    final n = _d?['due_files'] ?? 0;
    if (!await _confirm(context, 'Delete old kiosk photos now?',
        '$n photo(s) older than ${_d?['retention_days']} days will be permanently deleted. '
        'Attendance times stay; only the photo is removed.', 'Delete now')) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.functions
          .invoke('purge-support-docs', body: {'org_id': widget.orgId, 'kind': 'kiosk'});
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
      final o = (data['kiosk'] as Map?)?[widget.orgId] as Map?;
      _snack(o == null ? 'Nothing was due' : 'Deleted ${o['files']} photo(s), freed ${fmtBytes(o['bytes'] as num?)}');
      await _load();
    } catch (e) {
      _snack('Purge failed — is the purge-support-docs function deployed? ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) return Text('Kiosk photos: $_err', style: const TextStyle(fontSize: 12, color: AppTheme.danger));
    final d = _d;
    if (d == null) return const SizedBox(height: 24);
    final oldest = DateTime.tryParse('${d['oldest'] ?? ''}');
    final due = (d['due_files'] as num?) ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('ATTENDANCE KIOSK PHOTOS — OVERWRITE TENURE'),
      const SizedBox(height: 4),
      Text(
        '${d['files'] ?? 0} photo(s), ${fmtBytes(d['bytes'] as num?)}'
        '${oldest == null ? '' : ' · oldest ${DateFormat('d MMM y').format(oldest.toLocal())}'}. '
        'Older photos are deleted every night; the attendance record stays.',
        style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<int>(
        value: _custom ? -1 : _days,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Delete kiosk photos older than', isDense: true),
        items: [
          for (final e in _choices.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
          const DropdownMenuItem(value: -1, child: Text('Custom (days)…')),
        ],
        onChanged: (v) => setState(() {
          _custom = v == -1;
          if (!_custom) _days = v ?? 40;
        }),
      ),
      if (_custom) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _customCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Days (minimum 7)', isDense: true),
        ),
      ],
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 6, children: [
        ElevatedButton.icon(
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_outlined, size: 16),
          label: const Text('Save'),
        ),
        if (due > 0)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
            onPressed: _busy ? null : _purgeNow,
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            label: Text('Purge now ($due · ${fmtBytes(d['due_bytes'] as num?)})'),
          ),
      ]),
      const SizedBox(height: 6),
      Text(
        [
          (d['retention_days'] as num? ?? 40) == 0
              ? 'Currently: kept forever.'
              : 'Currently: ${d['retention_days']} days${d['is_default'] == true ? ' (default)' : ''} — $due due now.',
          _lastRunLine(d['last_purge'] as Map?, unit: 'photo(s)'),
        ].where((e) => e.isNotEmpty).join('  '),
        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
      ),
    ]);
  }
}

/// Audit-log archive (SQL 352): old audit rows → compressed files.
class _AuditSection extends StatefulWidget {
  final String orgId;
  const _AuditSection({required this.orgId});
  @override
  State<_AuditSection> createState() => _AuditSectionState();
}

class _AuditSectionState extends State<_AuditSection> {
  static const _choices = <int, String>{
    0: 'Off — keep everything live',
    12: 'Older than 1 year',
    24: 'Older than 2 years (recommended)',
    36: 'Older than 3 years',
    60: 'Older than 5 years',
  };
  Map<String, dynamic>? _d;
  String? _err;
  int _months = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _load() async {
    try {
      final r = await Supabase.instance.client.rpc('org_audit_usage', params: {'p_org': widget.orgId});
      final m = Map<String, dynamic>.from(r as Map);
      if (!mounted) return;
      setState(() {
        _d = m;
        _err = null;
        final v = (m['months'] as num?)?.toInt() ?? 0;
        _months = _choices.containsKey(v) ? v : 24;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _err = e.toString().contains('org_audit_usage')
            ? 'Run SQL 352 in Supabase first.'
            : e.toString().split('\n').first);
      }
    }
  }

  Future<void> _save() async {
    if (_months > 0 &&
        !await _confirm(
            context,
            'Archive audit history?',
            'Every night, audit-log rows older than ${_months ~/ 12} year(s) will be moved out of the live '
                'tables into compressed files you can download here. They will no longer show on screens '
                'such as a voucher\'s history.',
            'Confirm',
            danger: false)) return;
    setState(() => _busy = true);
    try {
      await Supabase.instance.client
          .rpc('set_org_audit_archive', params: {'p_org': widget.orgId, 'p_months': _months});
      _snack(_months == 0 ? 'Audit archiving is off' : 'Audit history older than ${_months ~/ 12} year(s) will be archived');
      await _load();
    } catch (e) {
      _snack('Could not save: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _archiveNow() async {
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.functions
          .invoke('purge-support-docs', body: {'org_id': widget.orgId, 'kind': 'audit'});
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
      final o = (data['audit'] as Map?)?[widget.orgId] as Map?;
      final errs = (data['auditErrors'] as List?) ?? const [];
      _snack(o != null
          ? 'Archived ${o['rows']} row(s) into ${o['files']} file(s) (${fmtBytes(o['bytes'] as num?)})'
          : (errs.isNotEmpty ? 'Archive failed: ${errs.first}' : 'Nothing was due'));
      await _load();
    } catch (e) {
      _snack('Archive failed — is the purge-support-docs function deployed? ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(String path) async {
    try {
      final url = await Supabase.instance.client.storage.from('audit-archive').createSignedUrl(path, 600);
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
    } catch (e) {
      _snack('Could not open file: ${e.toString().split('\n').first}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) return Text('Audit archive: $_err', style: const TextStyle(fontSize: 12, color: AppTheme.danger));
    final d = _d;
    if (d == null) return const SizedBox(height: 24);
    final tables = ((d['tables'] as List?) ?? const []).cast<Map>();
    final files = ((d['files'] as List?) ?? const []).cast<Map>();
    final due = tables.fold<num>(0, (s, t) => s + ((t['due'] as num?) ?? 0));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('AUDIT HISTORY ARCHIVE'),
      const SizedBox(height: 4),
      const Text(
        'Old audit-log rows (who changed what, when) can be moved out of the live database into compressed '
        'files. Nothing is lost — every file can be downloaded below. Business records are never archived.',
        style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
      ),
      const SizedBox(height: 6),
      for (final t in tables)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            '${t['table']}: ${NumberFormat('#,##0').format(t['rows'] ?? 0)} rows'
            '${DateTime.tryParse('${t['oldest'] ?? ''}') == null ? '' : ' · oldest ${DateFormat('d MMM y').format(DateTime.parse('${t['oldest']}').toLocal())}'}'
            '${((t['due'] as num?) ?? 0) > 0 ? ' · ${t['due']} due' : ''}',
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
      const SizedBox(height: 8),
      DropdownButtonFormField<int>(
        value: _months,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Archive audit history', isDense: true),
        items: [for (final e in _choices.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) => setState(() => _months = v ?? 0),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 6, children: [
        ElevatedButton.icon(
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_outlined, size: 16),
          label: const Text('Save'),
        ),
        if (d['months'] != null && due > 0)
          OutlinedButton.icon(
            onPressed: _busy ? null : _archiveNow,
            icon: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.archive_outlined, size: 16),
            label: Text('Archive now ($due rows)'),
          ),
      ]),
      const SizedBox(height: 6),
      Text(
        [
          d['months'] == null ? 'Currently: off.' : 'Currently: older than ${(d['months'] as num) ~/ 12} year(s).',
          _lastRunLine(d['last_run'] as Map?, unit: 'row(s)', verb: 'archived (compressed)'),
        ].where((e) => e.isNotEmpty).join('  '),
        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
      ),
      if (files.isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text('Archive files (${files.length})', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            children: [
              for (final f in files)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.inventory_2_outlined, size: 18),
                  title: Text('${f['table']} · ${NumberFormat('#,##0').format(f['rows'] ?? 0)} rows',
                      style: const TextStyle(fontSize: 12)),
                  subtitle: Text(
                    '${_d8(f['from'])} → ${_d8(f['to'])} · ${fmtBytes(f['bytes'] as num?)}',
                    style: const TextStyle(fontSize: 10.5),
                  ),
                  trailing: IconButton(
                    tooltip: 'Download (.json.gz)',
                    icon: const Icon(Icons.download_outlined, size: 18),
                    onPressed: () => _download('${f['path']}'),
                  ),
                ),
            ],
          ),
        ),
    ]);
  }

  static String _d8(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '—' : DateFormat('d MMM y').format(d.toLocal());
  }
}

/// Super Admin → Organizations → "Server usage".
Future<void> showServerOverview(BuildContext context) {
  return showDialog(
    context: context,
    builder: (ctx) {
      final w = MediaQuery.of(ctx).size.width;
      return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text('Server usage'),
        content: SizedBox(width: w < 640 ? w : 600, child: const _ServerOverview()),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      );
    },
  );
}

class _ServerOverview extends StatefulWidget {
  const _ServerOverview();
  @override
  State<_ServerOverview> createState() => _ServerOverviewState();
}

class _ServerOverviewState extends State<_ServerOverview> {
  late Future<Map<String, dynamic>> _f = _get();

  Future<Map<String, dynamic>> _get() async {
    final r = await Supabase.instance.client.rpc('platform_storage_overview');
    return Map<String, dynamic>.from(r as Map);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _f,
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Row(children: [
            Expanded(
              child: Text(
                snap.error.toString().contains('platform_storage_overview')
                    ? 'Run SQL 350 in Supabase first.'
                    : 'Could not load: ${snap.error.toString().split('\n').first}',
                style: const TextStyle(color: AppTheme.danger, fontSize: 12),
              ),
            ),
            TextButton(onPressed: () => setState(() => _f = _get()), child: const Text('Retry')),
          ]);
        }
        final d = snap.data!;
        final db = (d['db_bytes'] as num?) ?? 0;
        final files = (d['file_bytes'] as num?) ?? 0;
        final buckets = ((d['buckets'] as List?) ?? const []).cast<Map>();
        final orgs = ((d['orgs'] as List?) ?? const []).cast<Map>();
        final monthly = ((d['monthly'] as List?) ?? const []).cast<Map>();
        final tables = ((d['largest_tables'] as List?) ?? const []).cast<Map>();
        final maxMonth = monthly.fold<num>(0, (m, e) => ((e['bytes'] as num?) ?? 0) > m ? (e['bytes'] as num) : m);
        return SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              _stat('Total', fmtBytes(db + files)),
              _stat('Database', fmtBytes(db)),
              _stat('File storage', '${fmtBytes(files)} · ${NumberFormat('#,##0').format(d['files'] ?? 0)}'),
              _stat('Uploaded 7 days', fmtBytes(d['uploaded_7d'] as num?)),
              _stat('Uploaded 30 days', fmtBytes(d['uploaded_30d'] as num?)),
            ]),
            const SizedBox(height: 16),
            _sectionTitle('UPLOAD TRAFFIC BY MONTH'),
            const SizedBox(height: 6),
            for (final m in monthly)
              _bar(DateFormat('MMM y').format(DateTime.parse('${m['month']}-01')), (m['bytes'] as num?) ?? 0, maxMonth,
                  sub: '${m['files']} file(s)', color: Colors.teal),
            const SizedBox(height: 12),
            _sectionTitle('BY ORGANIZATION (FILES)'),
            const SizedBox(height: 6),
            for (final o in orgs)
              _bar('${o['name']}', (o['bytes'] as num?) ?? 0, files, sub: '${o['files']} file(s)'),
            const SizedBox(height: 12),
            _sectionTitle('BY FILE TYPE'),
            const SizedBox(height: 6),
            for (final b in buckets)
              _bar(bucketLabel('${b['bucket']}'), (b['bytes'] as num?) ?? 0, files, sub: '${b['files']} file(s)'),
            const SizedBox(height: 12),
            _sectionTitle('LARGEST DATABASE TABLES'),
            const SizedBox(height: 6),
            for (final t in tables) _bar('${t['table']}', (t['bytes'] as num?) ?? 0, db, color: Colors.blueGrey),
            const SizedBox(height: 10),
            const Text(
              'Download bandwidth (egress) is metered by Supabase outside the database, so it is not shown here — '
              'see Supabase Dashboard → Organization → Usage. Upload traffic above is measured from the stored files.',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
          ]),
        );
      },
    );
  }
}
