import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../layout/main_layout.dart';
import '../../features/auth/auth_controller.dart';

/// Who may see what, in the financial reports.
///
/// The chart of accounts is ORG-level; branch is a dimension on journal_lines.
/// So a report is always the same accounts, sliced by branch — never a separate
/// ledger per branch.
///
/// The reporting RPCs take `p_branch_ids text[]`:
///   null       → no branch filter → ORGANISATION-WIDE
///   ['a','b']  → exactly those branches, consolidated in ONE query
///
/// That distinction is the security boundary. An erpUser scoped to two branches
/// must never be able to send null — that would hand them the whole company's
/// P&L. So "All branches" means something different depending on who is asking:
///
///   admin (non-erpUser)     → null (true org-wide)
///   erpUser, 1 branch       → [their branch]; no toggle is offered at all
///   erpUser, 2+ branches    → [their branches] — NEVER null
///
/// Consolidating with an array rather than summing separate single-branch runs
/// client-side matters: inter-branch in-transit stock would be double-counted by
/// naive addition. The Trial Balance screen already warns about exactly this.
class BranchScope {
  /// True when the signed-in user is restricted to specific branches.
  final bool restricted;

  /// The branches this user may see. Empty for an unrestricted admin.
  final List<Map<String, dynamic>> allowed;

  const BranchScope({required this.restricted, required this.allowed});

  /// Should the "All branches" toggle be offered?
  ///
  /// An erpUser with a single branch has nothing to consolidate — showing them
  /// a toggle would imply a wider view exists for them, which it does not.
  bool get canToggleAll => !restricted || allowed.length > 1;

  /// What "All branches" resolves to for this user.
  ///
  /// null for an admin (org-wide); the user's own branch ids otherwise. Never
  /// null for a restricted user — that is the leak this class exists to prevent.
  List<String>? allBranchIds() {
    if (!restricted) return null;
    return [
      for (final b in allowed)
        if (b['id'] != null) b['id'] as String
    ];
  }

  /// The value to send as p_branch_ids.
  ///
  /// [allSelected] is the toggle state; [selected] is the sidebar branch.
  List<String>? resolve({
    required bool allSelected,
    required Map<String, dynamic>? selected,
  }) {
    if (allSelected) return allBranchIds();
    final id = selected?['id'] as String?;
    if (id == null) return allBranchIds();
    // A restricted user cannot report on a branch outside their assignments,
    // even if the sidebar somehow offered one.
    if (restricted) {
      final ok = allowed.any((b) => b['id'] == id);
      if (!ok) return allBranchIds();
    }
    return [id];
  }

  /// Label for the header, so it is always obvious what is being shown.
  String label({
    required bool allSelected,
    required Map<String, dynamic>? selected,
  }) {
    if (allSelected) {
      if (!restricted) return 'All Branches (organization-wide)';
      if (allowed.length == 1) return 'Branch: ${allowed.first['name']}';
      return 'All My Branches (${allowed.length})';
    }
    if (selected == null) {
      return restricted
          ? 'All My Branches (${allowed.length})'
          : 'All Branches (organization-wide)';
    }
    return 'Branch: ${selected['name']}';
  }
}

/// Resolves the current user's branch scope.
///
/// Mirrors userBranchesProvider: a WebUserRole.erpUser is limited to the rows in
/// erp_user_branches; everyone else (admin/owner) sees every active branch in
/// the org and is therefore unrestricted.
final branchScopeProvider = FutureProvider<BranchScope>((ref) async {
  final user = ref.watch(currentUserProvider);
  final branches = await ref.watch(userBranchesProvider.future);
  final restricted = user?.role == WebUserRole.erpUser;
  return BranchScope(restricted: restricted, allowed: branches);
});
