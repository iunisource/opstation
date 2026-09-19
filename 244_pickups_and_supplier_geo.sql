-- Pickups + supplier geolocation.
--
-- Adds a job_type discriminator so the existing deliveries/delivery_stops
-- tables (and the driver app) can carry supplier PICKUP jobs alongside
-- customer DELIVERY jobs. Also adds geo-coordinates to suppliers (entered
-- via web) and snapshots the target coordinates onto each stop so the driver
-- app can run the same geofence location check for pickups as for deliveries.
--
-- Safe / idempotent: re-running does nothing harmful.

-- 1) Deliveries carry a job type: 'delivery' (default) or 'pickup'.
alter table deliveries
  add column if not exists job_type text not null default 'delivery';

-- 2) Suppliers get lat/long for pickup location validation.
alter table suppliers
  add column if not exists latitude  double precision,
  add column if not exists longitude double precision;

-- 3) Each stop snapshots the target coordinates (customer or supplier) so the
--    driver app can validate location without a local party lookup — suppliers
--    are not synced to the driver's device.
alter table delivery_stops
  add column if not exists target_lat double precision,
  add column if not exists target_lng double precision;

-- 4) Pickups store payment_type = 'not_required' (and deliveries now offer a
--    "Not Required" option too). If any CHECK constraint on delivery_stops
--    restricts payment_type to cash/credit, drop it so 'not_required' is
--    accepted. (No-op when no such constraint exists.)
do $$
declare r record;
begin
  for r in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'delivery_stops'::regclass
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%payment_type%'
  loop
    execute format('alter table delivery_stops drop constraint %I', r.conname);
    raise notice 'Dropped payment_type check constraint: %', r.conname;
  end loop;
end $$;

-- 5) A pickup stores the supplier id in customer_id (the column is a generic
--    "party" reference for this operational table). If a FOREIGN KEY ties
--    delivery_stops.customer_id to customers(id), drop it so supplier ids are
--    allowed. (No-op when no such FK exists.)
do $$
declare r record;
begin
  for r in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'delivery_stops'::regclass
      and con.contype = 'f'
      and con.confrelid = 'customers'::regclass
  loop
    execute format('alter table delivery_stops drop constraint %I', r.conname);
    raise notice 'Dropped customers FK on delivery_stops: %', r.conname;
  end loop;
end $$;

-- Verify:
--   select column_name from information_schema.columns where table_name='deliveries' and column_name='job_type';
--   select column_name from information_schema.columns where table_name='suppliers' and column_name in ('latitude','longitude');
--   select column_name from information_schema.columns where table_name='delivery_stops' and column_name in ('target_lat','target_lng');
