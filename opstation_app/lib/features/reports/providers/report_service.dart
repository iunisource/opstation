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
}

final reportServiceProvider = Provider<ReportService>((ref) {
  return ReportService(ref);
});
