import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/initial_avatar.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/models/customer.dart';
import '../../salesperson/models/trip.dart';
import '../data/customer_repository.dart';
import '../models/audit_entry.dart';
import '../providers/customers_controller.dart';

/// Detail screen shown when a customer row is tapped.
///
/// Read-only by default; edit buttons appear for Admin / Master Admin / Surveyor.
/// Activate/deactivate is Admin-only.
class CustomerDetailScreen extends ConsumerWidget {
  final String customerId;
  const CustomerDetailScreen({super.key, required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canEdit = canEditCustomers(user?.role);
    final canManage = canManageCustomers(user?.role);

    final async = ref.watch(customersControllerProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Customer',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () => context.push('/customers/$customerId/edit'),
            ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (state) {
          final customer = state.all.firstWhere(
            (c) => c.id == customerId,
            orElse: () => const Customer(
              id: '',
              code: '',
              shopName: '',
              contactPerson: '',
              phone: '',
              address: '',
            ),
          );
          if (customer.id.isEmpty) {
            return const Center(child: Text('Customer not found.'));
          }
          return _DetailBody(
            customer: customer,
            canEdit: canEdit,
            canManage: canManage,
          );
        },
      ),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  final Customer customer;
  final bool canEdit;
  final bool canManage;

  const _DetailBody({
    required this.customer,
    required this.canEdit,
    required this.canManage,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _HeaderCard(customer: customer),
        const SizedBox(height: 16),
        _LocationCard(customer: customer, canEdit: canEdit),
        const SizedBox(height: 16),
        _InfoCard(customer: customer),
        const SizedBox(height: 16),
        _VisitHistoryCard(customerId: customer.id),
        const SizedBox(height: 16),
        _RecentChangesCard(customerId: customer.id),
        if (canManage) ...[
          const SizedBox(height: 16),
          _DangerZone(customer: customer),
        ],
        const SizedBox(height: 32),
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final Customer customer;
  const _HeaderCard({required this.customer});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          InitialAvatar(initials: customer.initials),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(customer.shopName,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  '#${customer.code}',
                  style: const TextStyle(
                    color: AppColors.textSecondaryLight,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    StatusBadge(
                      label: customer.isActive ? 'Active' : 'Inactive',
                      tone: customer.isActive
                          ? StatusBadgeTone.success
                          : StatusBadgeTone.neutral,
                    ),
                    if (customer.category != null)
                      _Pill(text: customer.category!),
                    if (customer.group != null) _Pill(text: customer.group!),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  final Customer customer;
  final bool canEdit;

  const _LocationCard({required this.customer, required this.canEdit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                customer.hasLocation
                    ? Icons.location_on
                    : Icons.location_off_outlined,
                size: 18,
                color: customer.hasLocation
                    ? AppColors.success
                    : AppColors.warningDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  customer.hasLocation ? 'Location set' : 'No location set',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              if (customer.hasLocation)
                _CircleAction(
                  icon: Icons.directions,
                  tooltip: 'Open in Maps',
                  color: AppColors.primary,
                  onTap: () => _openInMaps(
                    context,
                    customer.latitude!,
                    customer.longitude!,
                    customer.shopName,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (customer.hasLocation)
            Text(
              'Lat ${customer.latitude!.toStringAsFixed(6)}, '
              'Lng ${customer.longitude!.toStringAsFixed(6)}',
              style: const TextStyle(
                color: AppColors.textSecondaryLight,
                fontSize: 13,
              ),
            )
          else
            const Text(
              'Visits to this customer will be marked "No Location" until coordinates are set.',
              style: TextStyle(
                color: AppColors.textSecondaryLight,
                fontSize: 13,
              ),
            ),
          if (canEdit) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => GoRouter.of(context)
                    .push('/customers/${customer.id}/location'),
                icon: Icon(
                  customer.hasLocation ? Icons.edit_location_alt : Icons.add_location_alt,
                  size: 18,
                ),
                label: Text(customer.hasLocation
                    ? 'Update location'
                    : 'Set location'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openInMaps(
    BuildContext context,
    double lat,
    double lng,
    String label,
  ) async {
    // geo: URIs open the user's preferred map app on Android (Google Maps,
    // Waze, etc.). iOS opens Apple Maps via maps: scheme — we try geo: first
    // and fall back.
    final encodedLabel = Uri.encodeComponent(label);
    final candidates = [
      Uri.parse('geo:$lat,$lng?q=$lat,$lng($encodedLabel)'),
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
    ];
    for (final uri in candidates) {
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }
      } catch (_) {
        // try next
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open a maps app.')),
      );
    }
  }
}

class _InfoCard extends StatelessWidget {
  final Customer customer;
  const _InfoCard({required this.customer});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('Contact'),
          const SizedBox(height: 10),
          _InfoRow(
            icon: Icons.person_outline,
            label: customer.contactPerson.isEmpty ? '—' : customer.contactPerson,
          ),
          _InfoRow(
            icon: Icons.phone,
            label: customer.phone.isEmpty ? '—' : customer.phone,
            trailing: customer.phone.isEmpty
                ? null
                : _CircleAction(
                    icon: Icons.call,
                    tooltip: 'Call',
                    color: AppColors.success,
                    onTap: () => _callNumber(context, customer.phone),
                  ),
          ),
          _InfoRow(
            icon: Icons.place_outlined,
            label: customer.address.isEmpty ? '—' : customer.address,
          ),
          if (customer.ntnGst != null && customer.ntnGst!.isNotEmpty)
            _InfoRow(
              icon: Icons.badge_outlined,
              label: 'NTN / GST: ${customer.ntnGst}',
            ),
        ],
      ),
    );
  }

  Future<void> _callNumber(BuildContext context, String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
    final uri = Uri.parse('tel:$cleaned');
    try {
      final ok = await launchUrl(uri);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch dialer.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch dialer.')),
        );
      }
    }
  }
}

class _VisitHistoryCard extends ConsumerWidget {
  final String customerId;
  const _VisitHistoryCard({required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(appDatabaseProvider);
    return FutureBuilder<List<VisitsData>>(
      future: _recentVisits(db, customerId),
      builder: (context, snap) {
        final visits = snap.data ?? const [];
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _SectionLabel('Visit history'),
                  const Spacer(),
                  if (visits.isNotEmpty)
                    Text(
                      '${visits.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondaryLight,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (snap.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                      child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )),
                )
              else if (visits.isEmpty)
                const Text(
                  'No visits recorded yet.',
                  style: TextStyle(
                    color: AppColors.textSecondaryLight,
                    fontSize: 13,
                  ),
                )
              else
                for (final v in visits.take(8)) _VisitHistoryRow(visit: v),
            ],
          ),
        );
      },
    );
  }

  Future<List<VisitsData>> _recentVisits(AppDatabase db, String id) async {
    return await (db.select(db.visits)
          ..where((v) => v.customerId.equals(id))
          ..orderBy([(v) => OrderingTerm.desc(v.timestamp)])
          ..limit(20))
        .get();
  }
}

class _VisitHistoryRow extends StatelessWidget {
  final VisitsData visit;
  const _VisitHistoryRow({required this.visit});

  @override
  Widget build(BuildContext context) {
    final statusName = visit.status;
    IconData icon;
    Color color;
    switch (statusName) {
      case 'verified':
        icon = Icons.check_circle;
        color = AppColors.success;
        break;
      case 'outside':
        icon = Icons.warning_amber_rounded;
        color = AppColors.warningDark;
        break;
      case 'skipped':
        icon = Icons.skip_next;
        color = AppColors.textSecondaryLight;
        break;
      case 'noLocation':
        icon = Icons.location_off_outlined;
        color = AppColors.danger;
        break;
      default:
        icon = Icons.circle_outlined;
        color = AppColors.textSecondaryLight;
    }

    final when = DateFormat('d MMM y · HH:mm').format(visit.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(statusName),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  when,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
                if (visit.userName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline,
                            size: 11, color: AppColors.textTertiaryLight),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            visit.userRole.isEmpty
                                ? visit.userName
                                : '${visit.userName} · ${visit.userRole}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textTertiaryLight,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                // Captured GPS for the visit. Shown for any non-pending
                // visit (verified included, as a fallback verification).
                if (visit.capturedLat != null && visit.capturedLng != null)
                  _VisitCoordsRow(
                    lat: visit.capturedLat!,
                    lng: visit.capturedLng!,
                  ),
              ],
            ),
          ),
          if (visit.amount > 0)
            Text(
              'Rs ${visit.amount}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }

  String _label(String status) {
    switch (status) {
      case 'verified':
        return 'Verified visit';
      case 'outside':
        return 'Outside geofence';
      case 'skipped':
        return 'Skipped';
      case 'noLocation':
        return 'No location';
      default:
        return status;
    }
  }
}

class _RecentChangesCard extends ConsumerWidget {
  final String customerId;
  const _RecentChangesCard({required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(customerRepositoryProvider);

    return FutureBuilder<List<AuditEntry>>(
      future: repo.recentForEntity('customer', customerId, limit: 10),
      builder: (context, snap) {
        final entries = snap.data ?? const <AuditEntry>[];
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionLabel('Recent changes'),
              const SizedBox(height: 10),
              if (snap.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                      child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )),
                )
              else if (entries.isEmpty)
                const Text(
                  'No changes recorded.',
                  style: TextStyle(
                    color: AppColors.textSecondaryLight,
                    fontSize: 13,
                  ),
                )
              else
                for (final e in entries) _AuditRow(entry: e),
            ],
          ),
        );
      },
    );
  }
}

class _AuditRow extends StatelessWidget {
  final AuditEntry entry;
  const _AuditRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final when = DateFormat('d MMM · HH:mm').format(entry.timestamp);
    IconData icon;
    switch (entry.action) {
      case 'create':
        icon = Icons.add_circle_outline;
        break;
      case 'setLocation':
        icon = Icons.place_outlined;
        break;
      case 'activate':
        icon = Icons.check_circle_outline;
        break;
      case 'deactivate':
        icon = Icons.block;
        break;
      default:
        icon = Icons.edit_outlined;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondaryLight),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.summary,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.actorName} · ${entry.actorRole} · $when',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DangerZone extends ConsumerWidget {
  final Customer customer;
  const _DangerZone({required this.customer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.dangerLight.withOpacity(0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.danger.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Danger zone',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.dangerDark,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            customer.isActive
                ? 'Deactivating hides this customer from routes but preserves history.'
                : 'Activating restores this customer to active lists.',
            style: const TextStyle(
              color: AppColors.textSecondaryLight,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(customer.isActive
                        ? 'Deactivate customer?'
                        : 'Activate customer?'),
                    content: Text(customer.shopName),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(customer.isActive ? 'Deactivate' : 'Activate'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await ref
                      .read(customersControllerProvider.notifier)
                      .setActive(customer.id, !customer.isActive);
                }
              },
              icon: Icon(customer.isActive ? Icons.block : Icons.check),
              label: Text(customer.isActive ? 'Deactivate' : 'Activate'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.dangerDark,
                side: BorderSide(color: AppColors.danger.withOpacity(0.4)),
                minimumSize: const Size(0, 44),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;

  const _InfoRow({
    required this.icon,
    required this.label,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondaryLight),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label.isEmpty ? '—' : label,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _CircleAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  const _Pill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.borderLight,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.textSecondaryLight,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: AppColors.textSecondaryLight,
      ),
    );
  }
}

/// GPS coordinates of where the salesperson was when they marked
/// the visit. Tap to copy, long-press to open in Google Maps.
class _VisitCoordsRow extends StatelessWidget {
  final double lat;
  final double lng;
  const _VisitCoordsRow({required this.lat, required this.lng});

  @override
  Widget build(BuildContext context) {
    final formatted = '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: GestureDetector(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: formatted));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Coordinates copied'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        },
        onLongPress: () async {
          final uri = Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
          );
          try {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {}
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_on_outlined,
                size: 11, color: AppColors.textTertiaryLight),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                formatted,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiaryLight,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.copy,
                size: 9, color: AppColors.textTertiaryLight),
          ],
        ),
      ),
    );
  }
}

