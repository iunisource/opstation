/// Plain-English name for an audit-log action key ("line_edited" -> "Line edited").
/// Shared by every voucher's Audit Trail so they all read the same way.
String auditActionLabel(String action) {
  const names = {
    'created': 'Created',
    'saved': 'Saved',
    'edited': 'Edited',
    'confirmed': 'Confirmed',
    'approved': 'Approved',
    'rejected': 'Rejected',
    'rejection_acknowledged': 'Rejection acknowledged',
    'deleted': 'Deleted',
    'cancelled': 'Cancelled',
    'voided': 'Voided',
    'locked': 'Locked',
    'unlocked': 'Unlocked',
    'supervised': 'Supervised',
    'unsupervised': 'Supervision removed',
    'invoiced': 'Invoiced',
    'sent_for_review': 'Sent for review',
    'line_edited': 'Line edited',
    'line_added': 'Line added',
    'line_removed': 'Line removed',
    'date_changed': 'Date changed',
    'supplier_changed': 'Supplier changed',
    'customer_changed': 'Customer changed',
    'approval_reset': 'Approval cleared',
    'short_closed': 'Short-closed',
    'scheme_applied': 'Scheme applied',
    'scheme_removed': 'Scheme removed',
    'scheme_applied': 'Scheme applied',
    'scheme_removed': 'Scheme removed',
  };
  final n = names[action];
  if (n != null) return n;
  final t = action.replaceAll('_', ' ').trim();
  return t.isEmpty ? '-' : t[0].toUpperCase() + t.substring(1);
}
