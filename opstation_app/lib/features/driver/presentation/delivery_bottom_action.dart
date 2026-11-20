import '../../dispatch/models/delivery.dart';

/// What the slider at the bottom of the driver's job screen offers.
enum DeliveryBottomAction { none, start, complete, end }

/// - every stop settled (delivered or failed) and the job still open (in progress, or
///   assigned because its start was lost) -> END: slide to end the job, which takes the
///   return location;
/// - assigned -> START;
/// - in progress with stops pending -> COMPLETE (closes the pending ones as failed);
/// - otherwise nothing (completed, cancelled, or not this driver's job).
DeliveryBottomAction deliveryBottomAction(Delivery d, {required bool isThisDriver}) {
  final open = d.status == DeliveryStatus.assigned || d.status == DeliveryStatus.inProgress;
  if (isThisDriver && open && d.stops.isNotEmpty && d.pendingCount == 0) return DeliveryBottomAction.end;
  if (isThisDriver && d.status == DeliveryStatus.assigned) return DeliveryBottomAction.start;
  if (d.status == DeliveryStatus.inProgress && d.pendingCount > 0) return DeliveryBottomAction.complete;
  return DeliveryBottomAction.none;
}
