import '../../auth/models/user_role.dart';

/// A member of the team — stored in the users table.
/// Kept distinct from [AuthUser] (session identity) so that team
/// management can expose admin-only fields like createdAt and
/// passwordTemporary without polluting every screen that reads the
/// authenticated user.
class TeamUser {
  final String id;
  final String name;
  final String email;
  final String phone;
  final UserRole role;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool passwordTemporary;
  final String? orgId;

  const TeamUser({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    required this.role,
    required this.isActive,
    required this.createdAt,
    this.updatedAt,
    this.passwordTemporary = false,
    this.orgId,
  });

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  TeamUser copyWith({
    String? name,
    String? email,
    String? phone,
    UserRole? role,
    bool? isActive,
    DateTime? updatedAt,
    bool? passwordTemporary,
  }) {
    return TeamUser(
      id: id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      passwordTemporary: passwordTemporary ?? this.passwordTemporary,
    );
  }
}
