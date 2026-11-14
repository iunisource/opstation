-- 475 — App Versions: which app version each person's phone is on.
--  • The phone reports its version on its regular check (about every 10 min
--    while open; app build 37+). Kept per person in user_app_versions, and on
--    that phone's row in the phone history (Team 360 → Devices).
--  • app_versions(org) lists every app user of the org with their latest
--    version, phone and last use — org members only, each org sees its own.
--  • Admin Settings (per org): org.app_update_banner + org.app_min_build show
--    a "Please update" banner on phones older than the minimum build.
-- Needs 421 / 423. Safe to run again.

create table if not exists public.user_app_versions (
  user_id      text primary key,
  org_id       text,
  device_id    text,
  app_version  text,
  build        int,
  device_model text,
  os_version   text,
  reported_at  timestamptz not null default now()
);
create index if not exists user_app_versions_org on public.user_app_versions (org_id);
alter table public.user_app_versions enable row level security;
drop policy if exists user_app_versions_read on public.user_app_versions;
create policy user_app_versions_read on public.user_app_versions for select
  using (public._is_org_member(org_id) or public._is_super_admin());
revoke insert, update, delete on public.user_app_versions from anon, authenticated;
grant select on public.user_app_versions to authenticated;

-- "1.3.6+34" → 34
create or replace function public._app_build(p text)
returns int language sql immutable as $$
  select case when split_part(coalesce(p, ''), '+', 2) ~ '^[0-9]+$' then split_part(p, '+', 2)::int end
$$;

-- Called by the phone (signed-in user) on its regular check.
create or replace function public.report_app_version(p_device text, p_app text,
                                                     p_model text default null, p_os text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_ids text[] := public._my_user_ids();
begin
  if coalesce(p_app, '') = '' or coalesce(array_length(v_ids, 1), 0) = 0 then return; end if;
  insert into user_app_versions (user_id, org_id, device_id, app_version, build, device_model, os_version, reported_at)
  select u.id, u.org_id, nullif(p_device, ''), p_app, public._app_build(p_app), nullif(p_model, ''), nullif(p_os, ''), now()
    from users u where u.id = any (v_ids)
  on conflict (user_id) do update
     set org_id = excluded.org_id, device_id = excluded.device_id, app_version = excluded.app_version,
         build = excluded.build, device_model = coalesce(excluded.device_model, user_app_versions.device_model),
         os_version = coalesce(excluded.os_version, user_app_versions.os_version), reported_at = now();
  -- Keep the phone history (Team 360 → Devices) current too.
  if coalesce(p_device, '') <> '' then
    update user_device_history h
       set app_version = p_app, last_seen_at = now(),
           device_model = coalesce(h.device_model, nullif(p_model, '')),
           os_version = coalesce(nullif(p_os, ''), h.os_version)
     where h.id in (select distinct on (h2.user_id) h2.id from user_device_history h2
                     where h2.user_id = any (v_ids) and h2.device_id = p_device
                     order by h2.user_id, h2.signin_at desc);
  end if;
end $$;
revoke execute on function public.report_app_version(text, text, text, text) from public, anon;
grant execute on function public.report_app_version(text, text, text, text) to authenticated;

-- Every app user of the org: latest version (reported, else from the last
-- sign-in), phone, last use.
create or replace function public.app_versions(p_org text)
returns table(user_id text, name text, role text, phone text, is_active boolean,
              app_version text, build int, device_model text, os_version text, last_seen timestamptz)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then return; end if;
  return query
  select u.id, u.name, u.role, u.phone, coalesce(u.is_active, true),
         coalesce(v.app_version, h.app_version),
         coalesce(v.build, public._app_build(h.app_version)),
         coalesce(v.device_model, h.device_model),
         coalesce(v.os_version, h.os_version),
         greatest(v.reported_at, coalesce(h.last_seen_at, h.signin_at))
    from users u
    left join user_app_versions v on v.user_id = u.id
    left join lateral (select x.* from user_device_history x where x.user_id = u.id
                        order by x.signin_at desc limit 1) h on true
   where u.org_id = p_org
     and coalesce(u.role, '') not in ('retailer')
     and (v.user_id is not null or h.id is not null
          or u.role in ('salesperson', 'driver', 'surveyor', 'dispatchManager', 'dispatch_manager'));
end $$;
revoke execute on function public.app_versions(text) from public, anon;
grant execute on function public.app_versions(text) to authenticated;
