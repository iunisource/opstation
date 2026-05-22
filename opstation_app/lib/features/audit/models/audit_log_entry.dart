/// Domain model for an audit-log entry. Wraps the Drift row with
/// convenience accessors.
class AuditLogEntry {
  final String id;
  final String entityType; // 'customer' | 'route' | 'user' | 'assignment'
  final String entityId;
  final String action; // 'create' | 'update' | 'delete' | 'setLocation' | 'assign' | 'unassign'
  final String actorId;
  final String actorName;
  final String actorRole;
  final DateTime timestamp;

  /// JSON-encoded map of changed fields ({"field": {"old": x, "new": y}}).
  /// Empty map '{}' when the event doesn't carry field diffs.
  final String diffJson;

  /// Short, human-readable summary — used as the primary list label.
  final String summary;

  const AuditLogEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.action,
    required this.actorId,
    required this.actorName,
    required this.actorRole,
    required this.timestamp,
    required this.diffJson,
    required this.summary,
  });
}
