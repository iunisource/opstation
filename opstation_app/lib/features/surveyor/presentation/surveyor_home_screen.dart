import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/role_home_scaffold.dart';
import '../../../shared/widgets/section_label.dart';
import '../../../shared/widgets/temp_password_banner.dart';
import '../../../shared/widgets/update_app_banner.dart';
import '../../../shared/widgets/org_logo.dart';
import '../../auth/providers/auth_controller.dart';
import '../../auth/models/user_role.dart';

class SurveyorHomeScreen extends ConsumerWidget {
  const SurveyorHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final firstName = user?.name.split(' ').first ?? 'Surveyor';
    // Auditor: surveys only — no customer editing.
    final isAuditor = user?.role == UserRole.auditor;
    final org = (user?.organizationName ?? '').trim();

    return RoleHomeScaffold(
      appBarTitle: 'Opstation',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'Hi, $firstName',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                ),
                if (org.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(org, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ],
                const SizedBox(height: 4),
                Text(
                  isAuditor ? 'Shop surveys' : 'Customer data & location fixes',
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
                    fontSize: 14,
                  ),
                ),
              ]),
            ),
            // Company logo, only when one is uploaded on the web.
            const OrgLogo(size: 56),
          ]),
          const SizedBox(height: 24),

          const TempPasswordBanner(),
          const UpdateAppBanner(padding: EdgeInsets.only(top: 8)),

          if (!isAuditor) ...[
            const SectionLabel('Actions'),
            const SizedBox(height: 10),
            ManagementTile(
              icon: Icons.storefront_outlined,
              title: 'All customers',
              subtitle: 'View and edit details',
              onTap: () => context.push('/customers'),
            ),
            ManagementTile(
              icon: Icons.wrong_location_outlined,
              title: 'Location fixes',
              subtitle: 'Shops with a wrong or missing location',
              onTap: () => context.push('/location-fixes'),
            ),
          ],
          // "Customers without location" and "Recent edits" tiles are
          // hidden until they have real implementations. Better to ship
          // one working entry point than three that go nowhere.
          if (!isAuditor) const SizedBox(height: 24),
          const SectionLabel('Intelligence'),
          const SizedBox(height: 10),
          // Auditors check surveys; recording them is the surveyor's job.
          if (!isAuditor) ...[
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
          ManagementTile(
            icon: Icons.visibility_outlined,
            title: 'Surveyed shops',
            subtitle: isAuditor ? 'View surveys, give feedback' : 'See the last survey of a shop',
            onTap: () => context.push('/surveyed-shops'),
          ),
          if (isAuditor)
            ManagementTile(
              icon: Icons.location_searching,
              title: 'Non-surveyed shops',
              subtitle: 'Shops still waiting for a survey',
              onTap: () => context.push('/non-surveyed-shops'),
            ),
        ],
      ),
    );
  }
}
