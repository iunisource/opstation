import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/auth_controller.dart';

/// Bulk import routes from a CSV or Excel file.
///
/// Expected columns (case-insensitive, in any order):
///   route_name, customer_code, position
///
/// Each row represents one stop in a route. Rows are grouped by
/// route_name, sorted by position, and inserted as:
///   1. One row per unique route_name into `sales_routes`
///   2. One row per source row into `route_stops`, referencing the new
///      sales_routes.id and the existing customers.id matched on code.
///
/// Customer codes that don't exist in Supabase (for the current org)
/// are reported as errors and their rows skipped. Customers must be
/// imported first.
class BulkImportRoutesScreen extends ConsumerStatefulWidget {
  const BulkImportRoutesScreen({super.key});

  @override
  ConsumerState<BulkImportRoutesScreen> createState() =>
      _BulkImportRoutesScreenState();
}

class _BulkImportRoutesScreenState extends ConsumerState<BulkImportRoutesScreen> {
  static const List<String> _requiredCols = [
    'route_name',
    'customer_code',
    'position',
  ];

  String? _fileName;
  // Grouped by route name → ordered list of (customer_code, position)
  Map<String, List<_RouteStop>> _grouped = {};
  List<_ImportError> _parseErrors = [];
  bool _parsing = false;
  bool _importing = false;
  int _routesImported = 0;
  int _stopsImported = 0;
  int _routesFailed = 0;
  List<_ImportError> _importErrors = [];

  Future<void> _pickFile() async {
    setState(() {
      _parsing = true;
      _grouped = {};
      _parseErrors = [];
      _fileName = null;
      _routesImported = 0;
      _stopsImported = 0;
      _routesFailed = 0;
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
      _grouped = {};
      return;
    }

    final headerRow = rows.first.map((s) => s.toLowerCase().trim()).toList();
    final missingRequired = _requiredCols.where((c) => !headerRow.contains(c)).toList();
    if (missingRequired.isNotEmpty) {
      _parseErrors = [
        _ImportError(row: 0, reason: 'Missing required columns: ${missingRequired.join(", ")}')
      ];
      _grouped = {};
      return;
    }

    final colIndex = <String, int>{};
    for (final c in _requiredCols) {
      colIndex[c] = headerRow.indexOf(c);
    }

    final grouped = <String, List<_RouteStop>>{};
    final errors = <_ImportError>[];

    for (int i = 1; i < rows.length; i++) {
      final r = rows[i];
      final routeName = (colIndex['route_name']! < r.length ? r[colIndex['route_name']!] : '').trim();
      final code = (colIndex['customer_code']! < r.length ? r[colIndex['customer_code']!] : '').trim();
      final posStr = (colIndex['position']! < r.length ? r[colIndex['position']!] : '').trim();

      if (routeName.isEmpty || code.isEmpty || posStr.isEmpty) {
        errors.add(_ImportError(row: i + 1, reason: 'Missing route_name, customer_code, or position'));
        continue;
      }
      final pos = int.tryParse(posStr);
      if (pos == null) {
        errors.add(_ImportError(row: i + 1, reason: 'position is not an integer: "$posStr"'));
        continue;
      }

      grouped.putIfAbsent(routeName, () => []).add(_RouteStop(
            customerCode: code,
            position: pos,
            sourceRow: i + 1,
          ));
    }

    // Sort each route's stops by position
    for (final stops in grouped.values) {
      stops.sort((a, b) => a.position.compareTo(b.position));
    }

    _grouped = grouped;
    _parseErrors = errors;
  }

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
      _routesImported = 0;
      _stopsImported = 0;
      _routesFailed = 0;
      _importErrors = [];
    });

    final client = Supabase.instance.client;

    // Step 1: load all customers for this org so we can map code → id
    final Map<String, String> codeToId = {};
    try {
      const pageSize = 1000;
      var offset = 0;
      while (true) {
        final page = await client
            .from('customers')
            .select('id, code')
            .eq('org_id', orgId)
            .range(offset, offset + pageSize - 1);
        for (final r in page) {
          codeToId[r['code'] as String] = r['id'] as String;
        }
        if (page.length < pageSize) break;
        offset += pageSize;
      }
    } catch (e) {
      setState(() {
        _importing = false;
        _importErrors.add(_ImportError(row: 0, reason: 'Failed to load customers: $e'));
      });
      return;
    }

    // Step 2: for each grouped route, create the route + stops
    final now = DateTime.now();
    int routeIdx = 0;
    for (final entry in _grouped.entries) {
      final routeName = entry.key;
      final stops = entry.value;

      // Verify every customer code exists
      final missing = stops.where((s) => !codeToId.containsKey(s.customerCode)).toList();
      if (missing.isNotEmpty) {
        for (final m in missing) {
          _importErrors.add(_ImportError(
            row: m.sourceRow,
            reason: 'Unknown customer_code "${m.customerCode}" — import customers first',
          ));
        }
        setState(() => _routesFailed += 1);
        continue;
      }

      final routeId = 'route_${now.millisecondsSinceEpoch}_$routeIdx';
      routeIdx++;

      try {
        // Insert the route
        await client.from('sales_routes').insert({
          'id': routeId,
          'name': routeName,
          'kind': 'recurring',
          'is_active': true,
          'org_id': orgId,
          'created_at': now.toIso8601String(),
        });

        // Insert all stops in one batch
        final stopPayload = [
          for (final s in stops)
            {
              'route_id': routeId,
              'customer_id': codeToId[s.customerCode],
              'position': s.position,
            }
        ];
        await client.from('route_stops').insert(stopPayload);

        setState(() {
          _routesImported += 1;
          _stopsImported += stops.length;
        });
      } catch (e) {
        _importErrors.add(_ImportError(
          row: stops.first.sourceRow,
          reason: 'Failed to import route "$routeName": ${e.toString().split('\n').first}',
        ));
        setState(() => _routesFailed += 1);
      }
    }

    setState(() => _importing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bulk Import Routes'),
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
            if (_grouped.isNotEmpty || _parseErrors.isNotEmpty) _buildSummary(),
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
            Text('  route_name, customer_code, position'),
            SizedBox(height: 8),
            Text('Each row represents one stop in a route.', style: TextStyle(fontStyle: FontStyle.italic)),
            SizedBox(height: 4),
            Text('Customers must be imported first; their codes are matched against the customers table.',
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
    final totalRoutes = _grouped.length;
    final totalStops = _grouped.values.fold<int>(0, (s, list) => s + list.length);
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
                Text('$totalRoutes routes / $totalStops stops',
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
                value: totalRoutes == 0 ? 0 : (_routesImported + _routesFailed) / totalRoutes,
              ),
              const SizedBox(height: 8),
              Text('Importing… $_routesImported / $totalRoutes routes ($_stopsImported stops)'),
            ] else if (_routesImported > 0 || _routesFailed > 0) ...[
              Text('Routes imported: $_routesImported',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('Stops imported: $_stopsImported',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              if (_routesFailed > 0)
                Text('Routes failed: $_routesFailed',
                    style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700)),
            ] else if (totalRoutes > 0)
              ElevatedButton.icon(
                onPressed: _runImport,
                icon: const Icon(Icons.cloud_upload),
                label: Text('Import $totalRoutes routes'),
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

class _RouteStop {
  final String customerCode;
  final int position;
  final int sourceRow;
  const _RouteStop({
    required this.customerCode,
    required this.position,
    required this.sourceRow,
  });
}

class _ImportError {
  final int row;
  final String reason;
  const _ImportError({required this.row, required this.reason});
}
