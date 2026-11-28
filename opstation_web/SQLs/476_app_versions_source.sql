-- 476 — App Versions: say where each version comes from. "reported" = the
-- phone told us (app build 37+, every ~10 min); otherwise it is the version
-- from the person's last sign-in (signin_at), which may be older than what
-- the phone runs now. Needs 475. Safe to run again.

drop function if exists public.app_versions(text);
create or replace function public.app_versions(p_org text)
returns table(user_id text, name text, role text, phone text, is_active boolean,
              app_version text, build int, device_model text, os_version text, last_seen timestamptz,
              reported_at timestamptz, signin_at timestamptz)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then return; end if;
  return query
  select u.id, u.name, u.role, u.phone, coalesce(u.is_active, true),
         coalesce(v.app_version, h.app_version),
         coalesce(v.build, public._app_build(h.app_version)),
         coalesce(v.device_model, h.device_model),
         coalesce(v.os_version, h.os_version),
         greatest(v.reported_at, coalesce(h.last_seen_at, h.signin_at)),
         v.reported_at,
         h.signin_at
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
