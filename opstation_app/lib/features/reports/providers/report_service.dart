import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/app_database_provider.dart';
import 'package:printing/printing.dart';

import '../../admin_settings/providers/org_settings_controller.dart';
import '../../auth/models/auth_user.dart';
import '../../salesperson/models/trip.dart';
import '../pdf/report_pdf_builder.dart';
import '../services/coverage_context_builder.dart';
import '../services/report_context_builder.dart';

enum ReportKind { visit, summary }

extension ReportKindX on ReportKind {
  String get title {
    switch (this) {
      case ReportKind.visit:
        return 'Market Visit Report';
      case ReportKind.summary:
        return 'Trip Summary';
    }
  }

  String filename(Trip trip) {
    final slug = trip.routeName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final prefix = this == ReportKind.visit ? 'visit' : 'summary';
    final date = trip.startedAt;
    final ds =
        '${date.year.toString().padLeft(4, '0')}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
    return '${prefix}_${slug}_$ds.pdf';
  }
}

class ReportService {
  final Ref _ref;
  ReportService(this._ref);

  Future<Uint8List> buildBytes({
    required ReportKind kind,
    required Trip trip,
    required AuthUser? actor,
  }) async {
    // Pre-compute addresses + road distances. This can hit the network
    // via OSRM + Nominatim; both have graceful fallbacks baked in.
    final ctx = await _ref.read(reportContextBuilderProvider).build(trip);
    final settings = await _ref.read(orgSettingsProvider.future);
    String orgName = actor?.organizationName ?? '';
    if (orgName.isEmpty && actor?.organizationId != null) {
      try {
        final db = _ref.read(appDatabaseProvider);
        final orgRow = await (db.select(db.orgs)
              ..where((o) => o.id.equals(actor!.organizationId!)))
            .getSingleOrNull();
        orgName = orgRow?.name ?? 'Opstation';
      } catch (_) {
        orgName = 'Opstation';
      }
    }
    if (orgName.isEmpty) orgName = 'Opstation';

    final bytes = switch (kind) {
      ReportKind.visit => await ReportPdfBuilder.buildVisitReport(
          ctx: ctx,
          orgName: orgName,
        ),
      ReportKind.summary => await ReportPdfBuilder.buildTripSummary(
          ctx: ctx,
          orgName: orgName,
        ),
    };
    settings.toString(); // reserved
    return Uint8List.fromList(bytes);
  }

  Future<void> share({
    required ReportKind kind,
    required Trip trip,
    required AuthUser? actor,
  }) async {
    final bytes = await buildBytes(kind: kind, trip: trip, actor: actor);
    try {
      await Printing.sharePdf(bytes: bytes, filename: kind.filename(trip));
    } on PlatformException {
      // Emulator / platform w/o share — swallow. Caller can offer preview.
    }
  }

  Future<void> preview({
    required ReportKind kind,
    required Trip trip,
    required AuthUser? actor,
  }) async {
    await Printing.layoutPdf(
      onLayout: (_) => buildBytes(kind: kind, trip: trip, actor: actor),
      name: kind.filename(trip),
    );
  }

  // ---- Coverage Report ------------------------------------------------

  Future<Uint8List> buildCoverageBytes({
    required DateTime from,
    required DateTime to,
    required AuthUser? actor,
    String? routeIdFilter,
    String? userIdFilter,
  }) async {
    final ctx = await _ref.read(coverageContextBuilderProvider).build(
          from: from,
          to: to,
          routeIdFilter: routeIdFilter,
          userIdFilter: userIdFilter,
        );
    String orgName = actor?.organizationName ?? '';
    if (orgName.isEmpty && actor?.organizationId != null) {
      try {
        final db = _ref.read(appDatabaseProvider);
        final orgRow = await (db.select(db.orgs)
              ..where((o) => o.id.equals(actor!.organizationId!)))
            .getSingleOrNull();
        orgName = orgRow?.name ?? 'Opstation';
      } catch (_) {
        orgName = 'Opstation';
      }
    }
    if (orgName.isEmpty) orgName = 'Opstation';
    final bytes = await ReportPdfBuilder.buildCoverageReport(
      ctx: ctx,
      orgName: orgName,
    );
    return Uint8List.fromList(bytes);
  }

  String _coverageFilename(DateTime from, DateTime to) {
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    return 'coverage_${ymd(from)}_${ymd(to)}.pdf';
  }

  Future<void> shareCoverage({
    required DateTime from,
    required DateTime to,
    required AuthUser? actor,
    String? routeIdFilter,
    String? userIdFilter,
  }) async {
    final bytes = await buildCoverageBytes(
      from: from,
      to: to,
      actor: actor,
      routeIdFilter: routeIdFilter,
      userIdFilter: userIdFilter,
    );
    try {
      await Printing.sharePdf(
        bytes: bytes,
        filename: _coverageFilename(from, to),
      );
    } on PlatformException {
      // swallow
    }
  }

  Future<void> previewCoverage({
    required DateTime from,
    required DateTime to,
    required AuthUser? actor,
    String? routeIdFilter,
    String? userIdFilter,
  }) async {
    await Printing.layoutPdf(
      onLayout: (_) => buildCoverageBytes(
        from: from,
        to: to,
        actor: actor,
        routeIdFilter: routeIdFilter,
        userIdFilter: userIdFilter,
      ),
      name: _coverageFilename(from, to),
    );
  }

  // ---- Combined Trip Summary (multi-date reimbursement) ---------------

  /// Build the combined, distance-only reimbursement summary. [trips] must
  /// already be filtered to the chosen range/salesperson; [userNames] maps a
  /// userId to a display name. Distances are computed per trip (same figures
  /// as the single-trip Trip Summary) and aggregated by (salesperson, date).
  Future<Uint8List> buildCombinedSummaryBytes({
    required List<Trip> trips,
    required Map<String, String> userNames,
    required bool showSalesperson,
    required String periodLabel,
    required String salespersonLabel,
    required AuthUser? actor,
  }) async {
    final builder = _ref.read(reportContextBuilderProvider);
    final ctxs = await Future.wait(trips.map((t) => builder.build(t)));

    bool usedGoogle = false;
    final acc = <String, _CombinedAcc>{};
    for (var i = 0; i < trips.length; i++) {
      final t = trips[i];
      final ctx = ctxs[i];
      usedGoogle = usedGoogle || ctx.usedGoogle;
      final d = DateTime(t.startedAt.year, t.startedAt.month, t.startedAt.day);
      final key = '${t.userId}|${d.toIso8601String()}';
      final a = acc.putIfAbsent(
        key,
        () => _CombinedAcc(
          date: d,
          salesperson: userNames[t.userId] ?? t.userName,
        ),
      );
      a.km += ctx.totalDistanceKm;
      if (t.routeName.trim().isNotEmpty) a.routes.add(t.routeName.trim());
    }

    final rows = acc.values
        .map((a) => CombinedSummaryRow(
              date: a.date,
              salesperson: a.salesperson,
              routes: a.routes.join(', '),
              km: a.km,
            ))
        .toList()
      ..sort((x, y) {
        final s = x.salesperson.compareTo(y.salesperson);
        return s != 0 ? s : x.date.compareTo(y.date);
      });

    final grand = rows.fold<double>(0, (s, r) => s + r.km);

    String orgName = actor?.organizationName ?? '';
    if (orgName.isEmpty && actor?.organizationId != null) {
      try {
        final db = _ref.read(appDatabaseProvider);
        final orgRow = await (db.select(db.orgs)
              ..where((o) => o.id.equals(actor!.organizationId!)))
            .getSingleOrNull();
        orgName = orgRow?.name ?? 'Opstation';
      } catch (_) {
        orgName = 'Opstation';
      }
    }
    if (orgName.isEmpty) orgName = 'Opstation';

    final bytes = await ReportPdfBuilder.buildCombinedTripSummary(
      orgName: orgName,
      periodLabel: periodLabel,
      salespersonLabel: salespersonLabel,
      showSalesperson: showSalesperson,
      rows: rows,
      grandTotalKm: grand,
      usedGoogle: usedGoogle,
    );
    return Uint8List.fromList(bytes);
  }
}

/// Per-(salesperson, date) accumulator for the combined summary.
class _CombinedAcc {
  final DateTime date;
  final String salesperson;
  final Set<String> routes = {};
  double km = 0;
  _CombinedAcc({required this.date, required this.salesperson});
}

final reportServiceProvider = Provider<ReportService>((ref) {
  return ReportService(ref);
});
