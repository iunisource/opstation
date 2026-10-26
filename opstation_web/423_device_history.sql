-- 423 — Phone history per person (Team 360 → Devices).
-- Every sign-in on a phone is recorded: which phone (its id, and from the new
-- app its model, Android version and app version), when, and where (GPS at
-- sign-in, new app only). The phone's last use is kept current. Each trip
-- already records the phone that ran it, so the profile also shows the first
-- route started on each phone with its GPS start. Safe to run again.

create table if not exists public.user_device_history (
  id           bigserial primary key,
  user_id      text not null,
  org_id       text,
  device_id    text not null,
  device_model text,
  os_version   text,
  app_version  text,
  signin_at    timestamptz not null default now(),
  signin_lat   double precision,
  signin_lng   double precision,
  last_seen_at timestamptz
);
create index if not exists user_device_history_user_idx on public.user_device_history (user_id, signin_at desc);
alter table public.user_device_history enable row level security;
revoke all on public.user_device_history from anon, authenticated;

drop function if exists public.claim_trip_device(text);
create or replace function public.claim_trip_device(
  p_device text, p_model text default null, p_os text default null, p_app text default null,
  p_lat double precision default null, p_lng double precision default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_ids text[] := public._my_user_ids();
begin
  if coalesce(p_device, '') = '' or coalesce(array_length(v_ids, 1), 0) = 0 then return; end if;
  update public.users set active_device_id = p_device, active_device_at = now()
   where id = any (v_ids);
  insert into public.user_device_history
         (user_id, org_id, device_id, device_model, os_version, app_version, signin_lat, signin_lng, last_seen_at)
  select u.id, u.org_id, p_device, nullif(p_model, ''), nullif(p_os, ''), nullif(p_app, ''), p_lat, p_lng, now()
    from public.users u where u.id = any (v_ids);
  perform set_config('opstation.device_claim', '1', true);
  update public.trips set device_id = p_device
   where user_id = any (v_ids) and ended_at is null;
  perform set_config('opstation.device_claim', '', true);
end $$;
revoke execute on function public.claim_trip_device(text, text, text, text, double precision, double precision) from public, anon;
grant execute on function public.claim_trip_device(text, text, text, text, double precision, double precision) to authenticated;

-- Also keeps "last used" current for the phone (the app checks every ~10 min).
create or replace function public.my_trip_device()
returns text language plpgsql security definer set search_path to 'public' as $$
declare v text; v_ids text[] := public._my_user_ids();
begin
  select u.active_device_id into v from public.users u
   where u.id = any (v_ids) and u.active_device_id is not null
   order by u.active_device_at desc nulls last limit 1;
  update public.user_device_history h set last_seen_at = now()
   where h.id = (select h2.id from public.user_device_history h2
                  where h2.user_id = any (v_ids) and h2.device_id = v
                  order by h2.signin_at desc limit 1);
  return v;
end $$;
revoke execute on function public.my_trip_device() from public, anon;
grant execute on function public.my_trip_device() to authenticated;

-- One row per phone for a person: first / last sign-in, model, last use,
-- the latest sign-in place, routes run on it and its first route's start.
create or replace function public.user_devices(p_user text)
returns table(device_id text, device_model text, os_version text, app_version text,
              first_signin timestamptz, last_signin timestamptz, last_seen timestamptz,
              signins int, signin_lat double precision, signin_lng double precision,
              is_current boolean, trips int,
              first_trip_at timestamptz, first_trip_lat double precision, first_trip_lng double precision)
language plpgsql stable security definer set search_path to 'public' as $$
declare v_org text; v_cur text;
begin
  select u.org_id, u.active_device_id into v_org, v_cur from public.users u where u.id = p_user;
  if v_org is null or not (public._is_org_member(v_org) or public._is_super_admin()) then return; end if;
  return query
  with h as (
    select * from public.user_device_history where user_id = p_user
  ), d as (
    select h.device_id,
           (array_agg(h.device_model order by h.signin_at desc) filter (where h.device_model is not null))[1] as device_model,
           (array_agg(h.os_version order by h.signin_at desc) filter (where h.os_version is not null))[1] as os_version,
           (array_agg(h.app_version order by h.signin_at desc) filter (where h.app_version is not null))[1] as app_version,
           min(h.signin_at) as first_signin, max(h.signin_at) as last_signin,
           max(coalesce(h.last_seen_at, h.signin_at)) as last_seen, count(*)::int as signins,
           (array_agg(h.signin_lat order by h.signin_at desc) filter (where h.signin_lat is not null))[1] as signin_lat,
           (array_agg(h.signin_lng order by h.signin_at desc) filter (where h.signin_lng is not null))[1] as signin_lng
      from h group by h.device_id
    union all
    -- the current phone even if signed in before this history began
    select v_cur, null, null, null, null, null, null, 0, null, null
     where v_cur is not null and not exists (select 1 from h where h.device_id = v_cur)
  )
  select d.device_id, d.device_model, d.os_version, d.app_version,
         d.first_signin, d.last_signin, d.last_seen, d.signins, d.signin_lat, d.signin_lng,
         d.device_id = v_cur,
         (select count(*)::int from public.trips t where t.user_id = p_user and t.device_id = d.device_id),
         ft.started_at, ft.start_lat, ft.start_lng
    from d
    left join lateral (select t.started_at, t.start_lat, t.start_lng from public.trips t
                        where t.user_id = p_user and t.device_id = d.device_id
                        order by t.started_at limit 1) ft on true
   order by (d.device_id = v_cur) desc, coalesce(d.last_signin, ft.started_at) desc nulls last;
end $$;
revoke execute on function public.user_devices(text) from public, anon;
grant execute on function public.user_devices(text) to authenticated;

notify pgrst, 'reload schema';
select 'device history ready' as status;
