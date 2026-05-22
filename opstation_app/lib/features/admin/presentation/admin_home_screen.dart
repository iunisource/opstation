import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/admin_dashboard_body.dart';
import '../../../shared/widgets/role_home_scaffold.dart';
import '../../auth/providers/auth_controller.dart';

class AdminHomeScreen extends ConsumerWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final firstName = user?.name.split(' ').first ?? 'Admin';
    final org = user?.organizationName ?? "Here's your operations overview";

    return RoleHomeScaffold(
      appBarTitle: 'Opstation',
      body: AdminDashboardBody(
        firstName: firstName,
        subtitle: org,
        isMasterAdmin: false,
      ),
    );
  }
}
