import 'user_role.dart';

/// Authenticated user identity.
class AuthUser {
  final String id;
  final String name;
  final String email;
  final UserRole role;
  final String? organizationId;
  final String? organizationName;

  const AuthUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.organizationId,
    this.organizationName,
  });

  /// Initials for avatar display (first char of up to two name parts).
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}
