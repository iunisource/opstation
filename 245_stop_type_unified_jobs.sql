-- Unified driver jobs: the delivery/pickup distinction moves from the JOB
-- (deliveries.job_type) to each STOP (delivery_stops.stop_type), so one job
-- can mix supplier pickups and customer deliveries in a single trip.
--
-- Why: the driver app allows only one active job per driver, so separate
-- pickup and delivery jobs could never run in the same outing. A mixed job
-- matches how a van actually moves.
--
-- Safe / idempotent. Existing stops inherit their job's old job_type so
-- nothing already created changes meaning.

alter table delivery_stops
  add column if not exists stop_type text not null default 'delivery';

-- Backfill from the job-level flag introduced in 244 (no-op on fresh DBs).
update delivery_stops s
   set stop_type = d.job_type
  from deliveries d
 where d.id = s.delivery_id
   and d.job_type = 'pickup'
   and s.stop_type = 'delivery';

-- deliveries.job_type is now informational only (composition is derived from
-- the stops). Left in place for backward compatibility; nothing reads it as
-- a behaviour switch any more.

-- Verify:
--   select stop_type, count(*) from delivery_stops group by 1;
