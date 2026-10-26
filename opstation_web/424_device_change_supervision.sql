-- 424 — Supervising a field person's phone change (App Settings).
--   • "Phone change needs approval" (org.device_change_approval): a new phone
--     can't run routes until an admin / picked supervisor approves it; the old
--     phone keeps working meanwhile.
--   • "Review phone changes" (org.device_change_review): the new phone works
--     at once; the change waits for a supervisor to mark it reviewed.
-- Only one of the two can be on (approval wins if both are set). Supervisors:
-- admins always, plus org.device_change_supervisors. Every decision is logged.
-- First phone ever for a person is never held. Field roles only
-- (salesperson, driver, surveyor, auditor). Needs 421 and 423. Safe to run again.

alter table public.users add column if not exists pending_device_id text;

create table if not exists public.device_change_requests (
  id            bigserial primary key,
  org_id        text not null,
  user_id       text not null,
  old_device    text,
  new_device    text not null,
  device_model  text,
  signin_lat    double precision,
  signin_lng    double precision,
  mode          text not null,                 -- 'approval' | 'review'
  status        text not null default 'pending', -- pending | approved | rejected | reviewed
  created_at    timestamptz not null default now(),
  decided_by    text,
  decided_by_name text,
  decided_at    timestamptz,
  note          text
);
create index if not exists device_change_requests_org_idx on public.device_change_requests (org_id, status);
create index if not exists device_change_requests_user_idx on public.device_change_requests (user_id, created_at desc);
alter table public.device_change_requests enable row level security;
revoke all on public.device_change_requests from anon, authenticated;

create or replace function public._can_supervise_devices(p_org text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_id text; v_list text;
begin
  if public._is_org_admin(p_org) or public._is_super_admin() then return true; end if;
  select a.id into v_id from public._acting_user(p_org) a;
  if v_id is null then return false; end if;
  v_list := (select value from public.app_config where org_id = p_org and key = 'org.device_change_supervisors' limit 1);
  return v_id = any (string_to_array(replace(coalesce(v_list, ''), ' ', ''), ','));
end $$;

drop function if exists public.claim_trip_device(text, text, text, text, double precision, double precision);
create or replace function public.claim_trip_device(
  p_device text, p_model text default null, p_os text default null, p_app text default null,
  p_lat double precision default null, p_lng double precision default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  v_ids text[] := public._my_user_ids();
  u record;
  v_field boolean; v_approval boolean; v_review boolean;
begin
  if coalesce(p_device, '') = '' or coalesce(array_length(v_ids, 1), 0) = 0 then return; end if;
  for u in select id, org_id, role, active_device_id from public.users where id = any (v_ids) loop
    insert into public.user_device_history
           (user_id, org_id, device_id, device_model, os_version, app_version, signin_lat, signin_lng, last_seen_at)
    values (u.id, u.org_id, p_device, nullif(p_model, ''), nullif(p_os, ''), nullif(p_app, ''), p_lat, p_lng, now());

    v_field := coalesce(u.role, '') in ('salesperson', 'driver', 'surveyor', 'auditor');
    v_approval := v_field and public._cfg_true(u.org_id, 'org.device_change_approval');
    v_review := v_field and not v_approval and public._cfg_true(u.org_id, 'org.device_change_review');

    if u.active_device_id is not null and u.active_device_id <> p_device and v_approval then
      -- Held: the new phone waits for approval; the old one keeps working.
      update public.users set pending_device_id = p_device where id = u.id;
      if not exists (select 1 from public.device_change_requests r
                      where r.user_id = u.id and r.new_device = p_device and r.status = 'pending') then
        insert into public.device_change_requests
               (org_id, user_id, old_device, new_device, device_model, signin_lat, signin_lng, mode)
        values (u.org_id, u.id, u.active_device_id, p_device, nullif(p_model, ''), p_lat, p_lng, 'approval');
      end if;
      continue;
    end if;

    if u.active_device_id is not null and u.active_device_id <> p_device and v_review then
      if not exists (select 1 from public.device_change_requests r
                      where r.user_id = u.id and r.new_device = p_device and r.status = 'pending') then
        insert into public.device_change_requests
               (org_id, user_id, old_device, new_device, device_model, signin_lat, signin_lng, mode)
        values (u.org_id, u.id, u.active_device_id, p_device, nullif(p_model, ''), p_lat, p_lng, 'review');
      end if;
    end if;

    update public.users
       set active_device_id = p_device, active_device_at = now(),
           pending_device_id = case when pending_device_id = p_device then null else pending_device_id end
     where id = u.id;
    perform set_config('opstation.device_claim', '1', true);
    update public.trips set device_id = p_device where user_id = u.id and ended_at is null;
    perform set_config('opstation.device_claim', '', true);
  end loop;
end $$;
revoke execute on function public.claim_trip_device(text, text, text, text, double precision, double precision) from public, anon;
grant execute on function public.claim_trip_device(text, text, text, text, double precision, double precision) to authenticated;

-- What this phone may do now: ok | other (another phone is in use) |
-- pending (waiting for approval) | rejected.
create or replace function public.my_device_status(p_device text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_ids text[] := public._my_user_ids(); v_active text; v_st text;
begin
  select u.active_device_id into v_active from public.users u
   where u.id = any (v_ids) and u.active_device_id is not null
   order by u.active_device_at desc nulls last limit 1;
  update public.user_device_history h set last_seen_at = now()
   where h.id = (select h2.id from public.user_device_history h2
                  where h2.user_id = any (v_ids) and h2.device_id = p_device
                  order by h2.signin_at desc limit 1);
  if v_active is null or v_active = p_device then return 'ok'; end if;
  select r.status into v_st from public.device_change_requests r
   where r.user_id = any (v_ids) and r.new_device = p_device and r.mode = 'approval'
   order by r.created_at desc limit 1;
  if v_st = 'pending' then return 'pending'; end if;
  if v_st = 'rejected' then return 'rejected'; end if;
  return 'other';
end $$;
revoke execute on function public.my_device_status(text) from public, anon;
grant execute on function public.my_device_status(text) to authenticated;

create or replace function public.device_change_decide(p_id bigint, p_decision text, p_note text default null)
returns text language plpgsql security definer set search_path to 'public' as $$
declare r public.device_change_requests; v_uid text; v_name text;
begin
  select * into r from public.device_change_requests where id = p_id;
  if not found then raise exception 'Request not found — refresh and try again.'; end if;
  if not public._can_supervise_devices(r.org_id) then
    raise exception 'You are not allowed to supervise phone changes.';
  end if;
  if r.status <> 'pending' then return r.status; end if;
  if p_decision not in ('approved', 'rejected', 'reviewed') then raise exception 'Unknown decision'; end if;
  if r.mode = 'review' and p_decision <> 'reviewed' then p_decision := 'reviewed'; end if;
  if r.mode = 'approval' and p_decision = 'reviewed' then p_decision := 'approved'; end if;
  select a.id, a.name into v_uid, v_name from public._acting_user(r.org_id) a;
  update public.device_change_requests
     set status = p_decision, decided_by = v_uid, decided_by_name = v_name, decided_at = now(),
         note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_id;
  if r.mode = 'approval' and p_decision = 'approved' then
    update public.users set active_device_id = r.new_device, active_device_at = now(),
                            pending_device_id = null
     where id = r.user_id;
    perform set_config('opstation.device_claim', '1', true);
    update public.trips set device_id = r.new_device where user_id = r.user_id and ended_at is null;
    perform set_config('opstation.device_claim', '', true);
  elsif r.mode = 'approval' and p_decision = 'rejected' then
    update public.users set pending_device_id = null where id = r.user_id and pending_device_id = r.new_device;
  end if;
  return p_decision;
end $$;
revoke execute on function public.device_change_decide(bigint, text, text) from public, anon;
grant execute on function public.device_change_decide(bigint, text, text) to authenticated;

-- Counters for the menu, Team list and profile (0 for non-supervisors).
create or replace function public.device_change_pending(p_org text)
returns table(user_id text, pending int)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._can_supervise_devices(p_org) then return; end if;
  return query select r.user_id, count(*)::int from public.device_change_requests r
                where r.org_id = p_org and r.status = 'pending' group by r.user_id;
end $$;
revoke execute on function public.device_change_pending(text) from public, anon;
grant execute on function public.device_change_pending(text) to authenticated;

-- One person's phone-change log (Team 360 → Devices).
create or replace function public.device_change_log(p_user text)
returns table(id bigint, mode text, status text, old_device text, new_device text, device_model text,
              signin_lat double precision, signin_lng double precision, created_at timestamptz,
              decided_by_name text, decided_at timestamptz, note text, can_decide boolean)
language plpgsql stable security definer set search_path to 'public' as $$
declare v_org text;
begin
  select u.org_id into v_org from public.users u where u.id = p_user;
  if v_org is null or not (public._is_org_member(v_org) or public._is_super_admin()) then return; end if;
  return query select r.id, r.mode, r.status, r.old_device, r.new_device, r.device_model,
                      r.signin_lat, r.signin_lng, r.created_at, r.decided_by_name, r.decided_at, r.note,
                      public._can_supervise_devices(v_org)
                 from public.device_change_requests r
                where r.user_id = p_user order by r.created_at desc limit 100;
end $$;
revoke execute on function public.device_change_log(text) from public, anon;
grant execute on function public.device_change_log(text) to authenticated;

notify pgrst, 'reload schema';
select 'phone change supervision ready' as status;
