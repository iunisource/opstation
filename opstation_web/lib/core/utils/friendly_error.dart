import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns raw backend exceptions into short, user-readable messages.
/// Use in every catch that surfaces to a snackbar/dialog:
///   _snack(friendlyError('Save failed', e));
/// The raw error is appended in parentheses ONLY for unknown cases, so support
/// can still diagnose from a screenshot.
String friendlyError(String action, Object e) {
  if (e is PostgrestException) {
    final code = e.code ?? '';
    final msg = e.message;
    // Missing table / function — feature deployed ahead of its DB migration.
    if (code == 'PGRST205' || code == 'PGRST202' || msg.contains('schema cache')) {
      return '$action: this feature needs a database update that has not been applied yet. Please contact your administrator.';
    }
    // RLS / permission denied.
    if (code == '42501' || msg.contains('permission denied') || msg.contains('row-level security')) {
      return '$action: you do not have permission for this action.';
    }
    // Duplicate key.
    if (code == '23505' || msg.contains('duplicate key')) {
      return '$action: a record with this number already exists. Refresh and try again.';
    }
    // Foreign key.
    if (code == '23503') {
      return '$action: this record is linked to other records and the operation is not allowed.';
    }
    // Business-rule exceptions raised by our own DB functions (P0001) are
    // already written for humans — show them as-is.
    if (code == 'P0001') return '$action: $msg';
    return '$action: $msg';
  }
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('Connection refused')) {
    return '$action: no internet connection. Check your network and try again.';
  }
  if (s.contains('TimeoutException')) {
    return '$action: the server took too long to respond. Please try again.';
  }
  if (s.contains('JWT') || s.contains('401')) {
    return '$action: your session has expired. Please sign in again.';
  }
  return '$action. ($s)';
}
