-- 422 — Road distances for trip reports (web and app), via the
-- `route-distances` server function that asks Google Directions.
-- Each trip's distances are saved under its exact points, so printing the same
-- trip again (web or app) costs nothing; a changed trip (visit added, end
-- repaired …) has different points and is asked again. A daily cap per
-- organisation (App setting org.route_distance_daily_calls, default 1000
-- Google calls) stops a runaway bill — past it, reports use straight lines
-- until the next day. Safe to run again.

create table if not exists public.route_distance_cache (
  org_id     text not null,
  points_key text not null,
  legs       jsonb not null,           -- km per leg, in order
  calls      int not null default 1,   -- Google calls it took
  created_at timestamptz not null default now(),
  primary key (org_id, points_key)
);
create table if not exists public.route_distance_usage (
  org_id text not null,
  day    date not null,
  calls  int not null default 0,
  primary key (org_id, day)
);
alter table public.route_distance_cache enable row level security;
alter table public.route_distance_usage enable row level security;
revoke all on public.route_distance_cache, public.route_distance_usage from anon, authenticated;

-- Saved legs for these points, or null.
create or replace function public.route_distance_cached(p_org text, p_key text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then
    raise exception 'not_member';
  end if;
  return (select legs from public.route_distance_cache where org_id = p_org and points_key = p_key);
end $$;

-- Reserve p_calls Google calls for today; false when the daily cap is reached.
create or replace function public.route_distance_reserve(p_org text, p_calls int)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare v_cap int; v_used int;
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then
    raise exception 'not_member';
  end if;
  v_cap := coalesce(nullif((select value from public.app_config
                             where org_id = p_org and key = 'org.route_distance_daily_calls' limit 1), '')::int, 1000);
  insert into public.route_distance_usage (org_id, day, calls)
  values (p_org, (now() at time zone 'Asia/Karachi')::date, 0)
  on conflict (org_id, day) do nothing;
  select calls into v_used from public.route_distance_usage
   where org_id = p_org and day = (now() at time zone 'Asia/Karachi')::date for update;
  if v_used + greatest(p_calls, 1) > v_cap then return false; end if;
  update public.route_distance_usage set calls = calls + greatest(p_calls, 1)
   where org_id = p_org and day = (now() at time zone 'Asia/Karachi')::date;
  return true;
end $$;

create or replace function public.route_distance_save(p_org text, p_key text, p_legs jsonb, p_calls int)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then
    raise exception 'not_member';
  end if;
  if jsonb_typeof(p_legs) <> 'array' then return; end if;
  insert into public.route_distance_cache (org_id, points_key, legs, calls)
  values (p_org, p_key, p_legs, coalesce(p_calls, 1))
  on conflict (org_id, points_key) do update set legs = excluded.legs, calls = excluded.calls, created_at = now();
end $$;

revoke execute on function public.route_distance_cached(text, text) from public, anon;
revoke execute on function public.route_distance_reserve(text, int) from public, anon;
revoke execute on function public.route_distance_save(text, text, jsonb, int) from public, anon;
grant execute on function public.route_distance_cached(text, text) to authenticated;
grant execute on function public.route_distance_reserve(text, int) to authenticated;
grant execute on function public.route_distance_save(text, text, jsonb, int) to authenticated;

notify pgrst, 'reload schema';
select 'route distances ready' as status;
