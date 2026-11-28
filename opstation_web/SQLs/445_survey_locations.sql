-- 445 — Where the surveyor was when saving a survey.
--
-- The app reads the phone's GPS each time a Placement Audit or a Competitor
-- Spotting is saved and compares it with the shop's saved location (the
-- org's geofence radius):
--   inside            → Visited
--   outside           → Not visited
--   no_gps / no_shop_location → No location
-- Rows are written only through record_survey_location (the user is taken
-- from the login) and cannot be changed afterwards.
-- Run after 444. Safe to run again.

create table if not exists public.survey_locations (
  id text primary key,
  org_id text not null,
  customer_id text not null,
  user_id text not null,
  kind text not null check (kind in ('placement', 'competitor')),
  surveyed_at timestamptz not null,
  lat double precision,
  lng double precision,
  accuracy_m double precision,
  distance_m double precision,
  location_status text not null check (location_status in ('inside', 'outside', 'no_gps', 'no_shop_location')),
  received_at timestamptz not null default now()
);
create index if not exists survey_locations_org_at on public.survey_locations (org_id, surveyed_at);
create index if not exists survey_locations_shop on public.survey_locations (org_id, customer_id);

alter table public.survey_locations enable row level security;
drop policy if exists survey_locations_select on public.survey_locations;
create policy survey_locations_select on public.survey_locations for select to authenticated
  using (public._is_org_member(org_id) or public._is_super_admin());
-- No insert / update / delete policies: writes go through the function below.
revoke insert, update, delete on public.survey_locations from anon, authenticated;

create or replace function public.record_survey_location(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_org text := p->>'org_id';
  v_id text := p->>'id';
  v_cust text := p->>'customer_id';
  v_kind text := p->>'kind';
  v_status text := p->>'location_status';
  v_uid text;
begin
  if v_org is null or v_id is null or v_cust is null then raise exception 'Incomplete location.'; end if;
  if not public._is_org_member(v_org) then raise exception 'Not a member of this organisation.'; end if;
  select u.id into v_uid from public._acting_user(v_org) a join public.users u on u.id = a.id and u.org_id = v_org;
  if v_uid is null then raise exception 'Not a member of this organisation.'; end if;
  if v_kind not in ('placement', 'competitor') then raise exception 'Unknown survey type.'; end if;
  if v_status not in ('inside', 'outside', 'no_gps', 'no_shop_location') then raise exception 'Unknown location status.'; end if;
  if not exists (select 1 from public.customers where id = v_cust and org_id = v_org) then raise exception 'Shop not found.'; end if;
  insert into public.survey_locations
    (id, org_id, customer_id, user_id, kind, surveyed_at, lat, lng, accuracy_m, distance_m, location_status)
  values
    (v_id, v_org, v_cust, v_uid, v_kind,
     coalesce(nullif(p->>'surveyed_at', '')::timestamptz, now()),
     nullif(p->>'lat', '')::double precision, nullif(p->>'lng', '')::double precision,
     nullif(p->>'accuracy_m', '')::double precision, nullif(p->>'distance_m', '')::double precision,
     v_status)
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.record_survey_location(jsonb) from public, anon;
grant execute on function public.record_survey_location(jsonb) to authenticated;

notify pgrst, 'reload schema';
select 'survey locations ready' as result;
