-- 322 — Duty Chart: more than one standing station per person.
-- station_ids holds all of them (first = main); station_id keeps the main one.
-- Safe to run again.
alter table public.duty_chart_members add column if not exists station_ids text[];
update public.duty_chart_members
   set station_ids = array[station_id]
 where station_id is not null and (station_ids is null or cardinality(station_ids) = 0);
