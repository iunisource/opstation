/// Immutable audit entry for customer / route / user edits.
class AuditEntry {
  final String id;
  final String entityType;
  final String entityId;
  final String action; // create, update, delete, setLocation, activate, deactivate
  final String actorId;
  final String actorName;
  final String actorRole;
  final DateTime timestamp;

  /// Map of field -> {old, new}. May be empty for create/delete.
  final Map<String, Map<String, Object?>> diff;

  /// Human-readable one-liner ("Set location", "Changed phone", etc.).
  final String summary;

  const AuditEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.action,
    required this.actorId,
    required this.actorName,
    required this.actorRole,
    required this.timestamp,
    required this.diff,
    required this.summary,
  });
}
