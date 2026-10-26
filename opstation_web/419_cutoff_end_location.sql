-- 419 — End location for trips closed by the cut-off.
-- The cut-off closes a route the salesperson didn't end, but had no end
-- location, so the drive back wasn't counted. Now, whenever a trip is closed
-- at the cut-off without an end location:
--   • App Settings → "Cut-off: use start location as end" ON
--       (org.cutoff_end_at_start) → the trip's start location;
--   • OFF (default) → the location of the last visit with GPS
--       (the start location if no visit had GPS).
-- Also fills the cut-off trips already closed. Safe to run again.

create or replace function public._cutoff_end_point(p_trip text, p_org text,
  p_start_lat double precision, p_start_lng double precision,
  out lat double precision, out lng double precision)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._cfg_true(p_org, 'org.cutoff_end_at_start') then
    select v.captured_lat, v.captured_lng into lat, lng
      from public.visits v
     where v.trip_id = p_trip and v.captured_lat is not null and v.captured_lng is not null
     order by v.timestamp desc
     limit 1;
  end if;
  if lat is null then
    lat := p_start_lat;
    lng := p_start_lng;
  end if;
end $$;

create or replace function public.trg_trip_cutoff_end()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare p record;
begin
  if NEW.close_reason = 'cutoff' and NEW.ended_at is not null and NEW.end_lat is null then
    select * into p from public._cutoff_end_point(NEW.id, NEW.org_id, NEW.start_lat, NEW.start_lng);
    NEW.end_lat := p.lat;
    NEW.end_lng := p.lng;
  end if;
  return NEW;
end $$;

drop trigger if exists trip_cutoff_end on public.trips;
create trigger trip_cutoff_end before insert or update of close_reason, ended_at, end_lat on public.trips
  for each row execute function public.trg_trip_cutoff_end();

-- Fill the cut-off trips already closed without an end location.
with f as (
  select t.id, e.lat, e.lng
    from public.trips t,
         lateral public._cutoff_end_point(t.id, t.org_id, t.start_lat, t.start_lng) e
   where t.close_reason = 'cutoff' and t.ended_at is not null and t.end_lat is null
)
update public.trips t set end_lat = f.lat, end_lng = f.lng
  from f where t.id = f.id and f.lat is not null;

notify pgrst, 'reload schema';

-- Check: cut-off trips still without an end location (no start and no visit GPS).
select count(*) as cutoff_trips_without_end
  from public.trips where close_reason = 'cutoff' and ended_at is not null and end_lat is null;
