import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/auth_controller.dart';

/// Bulk import customers from a CSV or Excel file.
///
/// Expected columns (case-insensitive, in any order):
///   Required: code, shop_name
///   Optional: contact_person, phone, address, latitude, longitude, ntn_gst
///   Optional: latitude, longitude, ntn_gst
///
/// Rows are validated, then upserted: a row whose (code + shop_name + phone)
/// exactly matches an existing customer in the same org UPDATES that customer
/// with the new data; otherwise it is INSERTED as a new customer (in batches of
/// 500). The summary reports how many were inserted vs. updated, so re-runs of
/// the import are safe and never create duplicates on that triple.
class BulkImportCustomersScreen extends ConsumerStatefulWidget {
  const BulkImportCustomersScreen({super.key});

  @override
  ConsumerState<BulkImportCustomersScreen> createState() =>
      _BulkImportCustomersScreenState();
}

class _BulkImportCustomersScreenState
    extends ConsumerState<BulkImportCustomersScreen> {
  static const int _batchSize = 500;

  static const List<String> _requiredCols = [
    'code',
    'shop_name',
  ];

  static const List<String> _optionalCols = [
    'contact_person',
    'phone',
    'address',
    'latitude',
    'longitude',
    'ntn_gst',
  ];

  String? _fileName;
  List<Map<String, String>> _validRows = [];
  List<_ImportError> _parseErrors = [];
  bool _parsing = false;
  bool _importing = false;
  int _imported = 0;
  int _updated = 0;
  int _failed = 0;
  List<_ImportError> _importErrors = [];

  Future<void> _pickFile() async {
    setState(() {
      _parsing = true;
      _validRows = [];
      _parseErrors = [];
      _fileName = null;
      _imported = 0;
      _updated = 0;
      _failed = 0;
      _importErrors = [];
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'xlsx', 'xls'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _parsing = false);
        return;
      }

      final file = result.files.single;
      _fileName = file.name;
      final bytes = file.bytes;
      if (bytes == null) {
        throw 'File could not be read';
      }

      final ext = file.extension?.toLowerCase() ?? '';
      final List<List<String>> rows;
      if (ext == 'csv') {
        rows = _parseCsv(bytes);
      } else if (ext == 'xlsx' || ext == 'xls') {
        rows = _parseExcel(bytes);
      } else {
        throw 'Unsupported file type: .$ext';
      }

      _validateAndStage(rows);
    } catch (e) {
      setState(() {
        _parseErrors = [_ImportError(row: 0, reason: 'Failed to parse: $e')];
      });
    } finally {
      setState(() => _parsing = false);
    }
  }

  List<List<String>> _parseCsv(Uint8List bytes) {
    final text = String.fromCharCodes(bytes);
    final converted = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(text);
    return [
      for (final r in converted) [for (final c in r) c?.toString().trim() ?? '']
    ];
  }

  List<List<String>> _parseExcel(Uint8List bytes) {
    final excel = xl.Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) return const [];
    final sheet = excel.tables.values.first;
    final out = <List<String>>[];
    for (final row in sheet.rows) {
      final cells = [
        for (final c in row) (c?.value?.toString() ?? '').trim(),
      ];
      if (cells.every((c) => c.isEmpty)) continue;
      out.add(cells);
    }
    return out;
  }

  void _validateAndStage(List<List<String>> rows) {
    if (rows.isEmpty) {
      _parseErrors = [_ImportError(row: 0, reason: 'File is empty')];
      _validRows = [];
      return;
    }

    final headerRow = rows.first.map((s) => s.toLowerCase().trim()).toList();
    final missingRequired = _requiredCols.where((c) => !headerRow.contains(c)).toList();
    if (missingRequired.isNotEmpty) {
      _parseErrors = [
        _ImportError(row: 0, reason: 'Missing required columns: ${missingRequired.join(", ")}')
      ];
      _validRows = [];
      return;
    }

    final colIndex = <String, int>{};
    for (final c in [..._requiredCols, ..._optionalCols]) {
      final idx = headerRow.indexOf(c);
      if (idx >= 0) colIndex[c] = idx;
    }

    final valid = <Map<String, String>>[];
    final errors = <_ImportError>[];
    final seenCodes = <String>{};

    for (int i = 1; i < rows.length; i++) {
      final r = rows[i];
      final rowMap = <String, String>{};
      for (final entry in colIndex.entries) {
        rowMap[entry.key] = entry.value < r.length ? r[entry.value].trim() : '';
      }

      final missingFields = _requiredCols
          .where((c) => (rowMap[c] ?? '').isEmpty)
          .toList();
      if (missingFields.isNotEmpty) {
        errors.add(_ImportError(
          row: i + 1,
          reason: 'Missing: ${missingFields.join(", ")}',
        ));
        continue;
      }

      final code = rowMap['code']!;
      if (!seenCodes.add(code)) {
        errors.add(_ImportError(
          row: i + 1,
          reason: 'Duplicate code in file: $code',
        ));
        continue;
      }

      var hadNumberError = false;
      for (final f in ['latitude', 'longitude']) {
        final v = rowMap[f] ?? '';
        if (v.isNotEmpty && double.tryParse(v) == null) {
          errors.add(_ImportError(
            row: i + 1,
            reason: '$f is not a number: "$v"',
          ));
          hadNumberError = true;
          break;
        }
      }
      if (hadNumberError) continue;

      valid.add(rowMap);
    }

    _validRows = valid;
    _parseErrors = errors;
  }

  /// Stable key for duplicate detection on the exact triple. Trimmed only
  /// (exact match per spec: Code AND Name AND Phone). The delimiter \u0001 is a
  /// control char that won't occur in customer data, so fields can't bleed.
  String _dupeKey(String code, String name, String phone) =>
      '${code.trim()}\u0001${name.trim()}\u0001${phone.trim()}';

  Future<void> _runImport() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No org_id — please re-login')),
      );
      return;
    }

    setState(() {
      _importing = true;
      _imported = 0;
      _updated = 0;
      _failed = 0;
      _importErrors = [];
    });

    final client = Supabase.instance.client;
    final now = DateTime.now();
    final baseTs = now.millisecondsSinceEpoch;

    // Pre-fetch existing customers in this org to detect duplicates by the
    // exact triple (code + shop_name + phone). Key uses a delimiter that can't
    // appear inside the trimmed values colliding across fields.
    final Map<String, String> existingIdByKey = {}; // key -> existing customer id
    try {
      final existing = await client
          .from('customers')
          .select('id,code,shop_name,phone')
          .eq('org_id', orgId);
      for (final e in (existing as List)) {
        final k = _dupeKey(
          (e['code'] ?? '').toString(),
          (e['shop_name'] ?? '').toString(),
          (e['phone'] ?? '').toString(),
        );
        existingIdByKey[k] = e['id'] as String;
      }
    } catch (e) {
      // If the pre-fetch fails we fall back to treating everything as new.
    }

    // Split rows into updates (exact code+name+phone match) and inserts.
    final inserts = <Map<String, dynamic>>[];
    final updates = <Map<String, dynamic>>[]; // each carries its existing 'id'
    for (int i = 0; i < _validRows.length; i++) {
      final r = _validRows[i];
      final lat = (r['latitude'] ?? '').isEmpty ? null : double.tryParse(r['latitude']!);
      final lng = (r['longitude'] ?? '').isEmpty ? null : double.tryParse(r['longitude']!);
      final ntn = (r['ntn_gst'] ?? '').isEmpty ? null : r['ntn_gst'];
      final fields = <String, dynamic>{
        'code': r['code'],
        'shop_name': r['shop_name'],
        'contact_person': r['contact_person'] ?? '',
        'phone': r['phone'] ?? '',
        'address': r['address'] ?? '',
        'latitude': lat,
        'longitude': lng,
        'ntn_gst': ntn,
        'org_id': orgId,
        'is_active': true,
        'updated_at': now.toIso8601String(),
      };
      final key = _dupeKey(r['code'] ?? '', r['shop_name'] ?? '', r['phone'] ?? '');
      final existingId = existingIdByKey[key];
      if (existingId != null) {
        updates.add({...fields, 'id': existingId});
      } else {
        inserts.add({...fields, 'id': 'cust_${baseTs}_$i'});
      }
    }

    // INSERT new customers in batches.
    for (int i = 0; i < inserts.length; i += _batchSize) {
      final end = (i + _batchSize < inserts.length) ? i + _batchSize : inserts.length;
      final batch = inserts.sublist(i, end);
      try {
        await client.from('customers').insert(batch);
        setState(() => _imported += batch.length);
      } catch (e) {
        for (int j = i; j < end; j++) {
          _importErrors.add(_ImportError(row: j + 2, reason: e.toString().split('\n').first));
        }
        setState(() => _failed += batch.length);
      }
    }

    // UPDATE existing matches one-by-one (different id per row).
    for (final u in updates) {
      final id = u['id'] as String;
      final patch = {...u}..remove('id');
      try {
        await client.from('customers').update(patch).eq('id', id);
        setState(() => _updated += 1);
      } catch (e) {
        _importErrors.add(_ImportError(row: 0, reason: 'Update failed for ${u['code']}: ${e.toString().split('\n').first}'));
        setState(() => _failed += 1);
      }
    }

    setState(() => _importing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bulk Import Customers'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInstructions(),
            const SizedBox(height: 24),
            _buildFilePicker(),
            const SizedBox(height: 24),
            if (_validRows.isNotEmpty || _parseErrors.isNotEmpty) _buildSummary(),
            if (_importErrors.isNotEmpty) ...[
              const SizedBox(height: 24),
              _buildImportErrorsList(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInstructions() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('File format', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            SizedBox(height: 8),
            Text('Upload a .csv or .xlsx file with these columns (case-insensitive):'),
            SizedBox(height: 8),
            Text('Required:', style: TextStyle(fontWeight: FontWeight.w600)),
            Text('  code, shop_name  (contact_person, phone, address optional)'),
            SizedBox(height: 4),
            Text('Optional:', style: TextStyle(fontWeight: FontWeight.w600)),
            Text('  latitude, longitude, ntn_gst'),
            SizedBox(height: 8),
            Text('First row must be the header. Empty cells in optional columns are fine.',
                style: TextStyle(fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilePicker() {
    return Row(
      children: [
        ElevatedButton.icon(
          onPressed: _parsing || _importing ? null : _pickFile,
          icon: const Icon(Icons.upload_file),
          label: const Text('Pick file'),
        ),
        const SizedBox(width: 16),
        if (_fileName != null) Text(_fileName!, style: const TextStyle(fontStyle: FontStyle.italic)),
        if (_parsing) ...[
          const SizedBox(width: 16),
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ],
    );
  }

  Widget _buildSummary() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green.shade700),
                const SizedBox(width: 8),
                Text('${_validRows.length} valid rows',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ],
            ),
            if (_parseErrors.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.error, color: Colors.red.shade700),
                  const SizedBox(width: 8),
                  Text('${_parseErrors.length} rows with errors (skipped)',
                      style: TextStyle(color: Colors.red.shade700)),
                ],
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in _parseErrors.take(50))
                      Text('Row ${e.row}: ${e.reason}',
                          style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                    if (_parseErrors.length > 50)
                      Text('  …and ${_parseErrors.length - 50} more',
                          style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_importing) ...[
              LinearProgressIndicator(
                value: _validRows.isEmpty ? 0 : (_imported + _failed) / _validRows.length,
              ),
              const SizedBox(height: 8),
              Text('Importing… ${_imported + _updated} / ${_validRows.length}'),
            ] else if (_imported > 0 || _updated > 0 || _failed > 0) ...[
              Text('Imported (new): $_imported',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              if (_updated > 0)
                Text('Updated (existing — matched code + name + phone): $_updated',
                    style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.w700)),
              if (_failed > 0)
                Text('Failed: $_failed',
                    style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700)),
            ] else if (_validRows.isNotEmpty)
              ElevatedButton.icon(
                onPressed: _runImport,
                icon: const Icon(Icons.cloud_upload),
                label: Text('Import ${_validRows.length} customers'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildImportErrorsList() {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Import errors',
                style: TextStyle(fontWeight: FontWeight.w700, color: Colors.red.shade900)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in _importErrors.take(100))
                    Text('Row ${e.row}: ${e.reason}',
                        style: TextStyle(color: Colors.red.shade900, fontSize: 12)),
                  if (_importErrors.length > 100)
                    Text('  …and ${_importErrors.length - 100} more',
                        style: TextStyle(color: Colors.red.shade900, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportError {
  final int row;
  final String reason;
  const _ImportError({required this.row, required this.reason});
}
