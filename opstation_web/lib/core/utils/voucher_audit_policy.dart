/// When a voucher's audit trail starts. A new voucher is only a draft that someone is typing: every line
/// added or quantity changed while it is being put together used to become an audit line ("Line added" x6),
/// which buries the real history. The trail now starts when the voucher is SAVED (confirmed): its creation is
/// recorded then (with the time it was really created), and from then on every event is recorded.

/// Events that are only noise while the voucher is still an unsaved draft.
const Set<String> kDraftOnlyAuditActions = {
  'created',
  'line_added',
  'line_edited',
  'line_removed',
  'date_changed',
  'supplier_changed',
  'customer_changed',
  'edited',
};

/// Is [action] one that is skipped until the voucher has been saved?
bool isDraftNoise(String action) => kDraftOnlyAuditActions.contains(action);

/// Should [action] be written to the trail? Everything is recorded once the voucher has been [saved]; before
/// that only events that are not draft noise (a deletion, for example, still is).
bool shouldRecordAudit(String action, {required bool saved}) => saved || !isDraftNoise(action);
