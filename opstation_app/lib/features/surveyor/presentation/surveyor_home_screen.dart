import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/role_home_scaffold.dart';
import '../../../shared/widgets/section_label.dart';
import '../../../shared/widgets/temp_password_banner.dart';
import '../../auth/providers/auth_controller.dart';

class SurveyorHomeScreen extends ConsumerWidget {
  const SurveyorHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final firstName = user?.name.split(' ').first ?? 'Surveyor';

    return RoleHomeScaffold(
      appBarTitle: 'Opstation',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const SizedBox(height: 8),
          Text(
            'Hi, $firstName',
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Customer data & location fixes',
            style: TextStyle(
              color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),

          const TempPasswordBanner(),

          const SectionLabel('Actions'),
          const SizedBox(height: 10),
          ManagementTile(
            icon: Icons.storefront_outlined,
            title: 'All customers',
            subtitle: 'View and edit details',
            onTap: () => context.push('/customers'),
          ),
          // "Customers without location" and "Recent edits" tiles are
          // hidden until they have real implementations. Better to ship
          // one working entry point than three that go nowhere.
          const SizedBox(height: 24),
          const SectionLabel('Intelligence'),
          const SizedBox(height: 10),
          ManagementTile(
            icon: Icons.checklist_outlined,
            title: 'Placement Audit',
            subtitle: 'Record which products are displayed',
            onTap: () => context.push('/placement-audit'),
          ),
          ManagementTile(
            icon: Icons.flag_outlined,
            title: 'Competitor Spotting',
            subtitle: 'Tag brands by category at each shop',
            onTap: () => context.push('/competitor-spotting'),
          ),
        ],
      ),
    );
  }
}
