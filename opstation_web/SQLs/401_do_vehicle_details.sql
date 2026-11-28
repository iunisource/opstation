-- 401 — Delivery Order: optional Vehicle Details (driver name, contact, vehicle #). Safe to run again.
alter table public.delivery_orders add column if not exists vehicle_driver_name    text;
alter table public.delivery_orders add column if not exists vehicle_driver_contact text;
alter table public.delivery_orders add column if not exists vehicle_number         text;
notify pgrst, 'reload schema';
select count(*) filter (where vehicle_number is not null) as dos_with_vehicle from public.delivery_orders;
