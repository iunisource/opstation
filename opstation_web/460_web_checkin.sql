-- 460 — Web check-in / check-out on office Wi-Fi (ERP users).
--
--  • org_office_networks: the office internet connections (by address) that
--    count as "in the office". Added by an admin from Admin Settings while
--    connected to that Wi-Fi. No client access — only through the functions.
--  • The address is read on the SERVER from the request, so it can't be faked
--    from the browser.
--  • The login is matched to the HR employee by email (same company).
--  • Punch rules match the Attendance Kiosk: one check-in and one check-out a
--    day; a check-out keeps any status an admin set. Audit says "Web".
--  • Switched on by Admin Settings → org.web_checkin.

create table if not exists public.org_office_networks (
  id             text primary key default ('onet_' || replace(gen_random_uuid()::text, '-', '')),
  org_id         text not null,
  name           text not null,
  ip             text not null,
  added_by_name  text,
  created_at     timestamptz not null default now(),
  unique (org_id, ip)
);
alter table public.org_office_networks enable row level security;
revoke all on public.org_office_networks from anon, authenticated;

-- The caller's public internet address, as seen by the server.
create or replace function public._request_ip()
returns text language plpgsql stable set search_path to 'public' as $$
declare h json; v text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then h := null;
  end;
  if h is null then return null; end if;
  v := coalesce(nullif(btrim(h ->> 'cf-connecting-ip'), ''),
                nullif(btrim(h ->> 'x-real-ip'), ''),
                nullif(btrim(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1)), ''));
  return v;
end $$;

create or replace function public.office_networks_list(p_org text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ip text := public._request_ip();
begin
  if not (public._is_org_admin(p_org) or public._is_super_admin()) then
    raise exception 'Only admins can see office networks.';
  end if;
  return jsonb_build_object(
    'current_ip_known', v_ip is not null,
    'on_listed', exists (select 1 from org_office_networks where org_id = p_org and ip = v_ip),
    'networks', coalesce((
      select jsonb_agg(jsonb_build_object('id', n.id, 'name', n.name, 'by', n.added_by_name,
                                          'at', n.created_at, 'current', n.ip = v_ip)
                       order by n.created_at)
        from org_office_networks n where n.org_id = p_org), '[]'::jsonb));
end $$;
grant execute on function public.office_networks_list(text) to authenticated;

create or replace function public.office_network_add(p_org text, p_name text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_ip text := public._request_ip(); v_me text; v_name text;
begin
  if not (public._is_org_admin(p_org) or public._is_super_admin()) then
    raise exception 'Only admins can add office networks.';
  end if;
  if v_ip is null then raise exception 'Could not read this connection. Try again.'; end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then raise exception 'Give the network a name.'; end if;
  if exists (select 1 from org_office_networks where org_id = p_org and ip = v_ip) then
    raise exception 'This network is already added.';
  end if;
  select a.id, a.name into v_me, v_name from public._acting_user(p_org) a;
  insert into org_office_networks (org_id, name, ip, added_by_name)
  values (p_org, btrim(p_name), v_ip, v_name);
  return 'ok';
end $$;
grant execute on function public.office_network_add(text, text) to authenticated;

create or replace function public.office_network_remove(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_org text;
begin
  select org_id into v_org from org_office_networks where id = p_id;
  if v_org is null then return; end if;
  if not (public._is_org_admin(v_org) or public._is_super_admin()) then
    raise exception 'Only admins can remove office networks.';
  end if;
  delete from org_office_networks where id = p_id;
end $$;
grant execute on function public.office_network_remove(text) to authenticated;

-- The logged-in user's HR employee in this company (matched by email).
create or replace function public._web_att_employee(p_org text)
returns public.hr_employees language plpgsql stable security definer set search_path to 'public' as $$
declare v_email text := lower(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), '')); e hr_employees%rowtype;
begin
  if v_email is null then return null; end if;
  select * into e from hr_employees
   where org_id = p_org and coalesce(is_voided, false) = false
     and lower(btrim(coalesce(email, ''))) = v_email
   order by id desc limit 1;
  if not found then return null; end if;
  return e;
end $$;

-- Everything the top-bar attendance button needs.
create or replace function public.web_attendance_status(p_org text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_ip text := public._request_ip();
  v_net text;
  e hr_employees%rowtype;
  v_day date := (now() at time zone 'Asia/Karachi')::date;
  a hr_attendance%rowtype;
  s record;
begin
  if p_org is null or not (public._is_org_member(p_org) or public._is_super_admin()) then
    return jsonb_build_object('enabled', false);
  end if;
  if not public._cfg_true(p_org, 'org.web_checkin') then
    return jsonb_build_object('enabled', false);
  end if;
  e := public._web_att_employee(p_org);
  if e.id is null then return jsonb_build_object('enabled', true, 'employee', false); end if;
  select name into v_net from org_office_networks where org_id = p_org and ip = v_ip limit 1;
  select * into a from hr_attendance where org_id = p_org and employee_id = e.id and att_date = v_day limit 1;
  select sh.name, sh.start_time, sh.end_time into s from hr_shifts sh where sh.id = e.shift_id;
  return jsonb_build_object(
    'enabled', true, 'employee', true,
    'name', e.full_name,
    'on_office', v_net is not null, 'network', v_net,
    'day', v_day,
    'check_in', nullif(a.check_in, ''), 'check_out', nullif(a.check_out, ''),
    'shift', case when s.end_time is null and s.start_time is null then null
                  else jsonb_build_object('name', s.name, 'start', s.start_time, 'end', s.end_time) end,
    'now', to_char(now() at time zone 'Asia/Karachi', 'HH24:MI'));
end $$;
grant execute on function public.web_attendance_status(text) to authenticated;

-- Check in ('in') or check out ('out') from the web, only on an office network.
create or replace function public.web_attendance_punch(p_org text, p_dir text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_ip text := public._request_ip();
  v_net text;
  e hr_employees%rowtype;
  v_now timestamptz := now();
  v_day date := (now() at time zone 'Asia/Karachi')::date;
  v_hhmm text := to_char(now() at time zone 'Asia/Karachi', 'HH24:MI');
  a hr_attendance%rowtype;
  v_have boolean;
  v_id text; v_me text; v_myname text;
  v_a int; v_b int; v_d int;
begin
  if p_org is null or not (public._is_org_member(p_org) or public._is_super_admin()) then
    raise exception 'You do not have access to this organisation.';
  end if;
  if not public._cfg_true(p_org, 'org.web_checkin') then
    raise exception 'Web check-in is switched off for this company.';
  end if;
  select name into v_net from org_office_networks where org_id = p_org and ip = v_ip limit 1;
  if v_net is null then
    raise exception 'You are not on an office network. Connect to the office Wi-Fi and try again.';
  end if;
  e := public._web_att_employee(p_org);
  if e.id is null then
    raise exception 'Your login is not linked to an employee. Ask HR to put your login email on your employee record.';
  end if;
  select au.id, au.name into v_me, v_myname from public._acting_user(p_org) au;

  select * into a from hr_attendance where org_id = p_org and employee_id = e.id and att_date = v_day limit 1;
  v_have := found;

  if p_dir = 'in' then
    if v_have and coalesce(a.check_in, '') <> '' then
      raise exception 'You are already checked in today (at %).', a.check_in;
    end if;
    v_id := coalesce(a.id, 'att_' || (extract(epoch from v_now) * 1000000)::bigint || '_' || e.id);
    insert into hr_attendance (id, org_id, employee_id, branch_id, att_date, status, check_in, check_out, work_hours, updated_at)
    values (v_id, p_org, e.id, e.branch_id, v_day, 'present', v_hhmm, null, null, v_now)
    on conflict (org_id, employee_id, att_date)
    do update set status = case when coalesce(hr_attendance.status, '') = '' then 'present' else hr_attendance.status end,
                  check_in = excluded.check_in, check_out = null, work_hours = null, updated_at = excluded.updated_at;
    insert into hr_attendance_audit (id, org_id, attendance_id, employee_id, att_date, action, changes, changed_by, changed_by_name)
    values ('aud_' || (extract(epoch from v_now) * 1000000)::bigint || '_' || e.id || '_web' || p_dir, p_org, v_id, e.id, v_day,
            case when v_have then 'updated' else 'created' end,
            'Web check-in ' || v_hhmm || ' (' || v_net || ')', v_me, coalesce(v_myname, e.full_name) || ' · Web');
    return jsonb_build_object('outcome', 'checked_in', 'time', v_hhmm);
  elsif p_dir = 'out' then
    if not v_have or coalesce(a.check_in, '') = '' then
      raise exception 'You have not checked in today.';
    end if;
    if coalesce(a.check_out, '') <> '' then
      raise exception 'You already checked out today (at %).', a.check_out;
    end if;
    v_a := split_part(a.check_in, ':', 1)::int * 60 + split_part(a.check_in, ':', 2)::int;
    v_b := split_part(v_hhmm, ':', 1)::int * 60 + split_part(v_hhmm, ':', 2)::int;
    v_d := v_b - v_a; if v_d <= 0 then v_d := v_d + 1440; end if;
    update hr_attendance
       set status = case when coalesce(status, '') = '' then 'present' else status end,
           check_out = v_hhmm, work_hours = round(v_d / 60.0, 2), updated_at = v_now
     where id = a.id;
    insert into hr_attendance_audit (id, org_id, attendance_id, employee_id, att_date, action, changes, changed_by, changed_by_name)
    values ('aud_' || (extract(epoch from v_now) * 1000000)::bigint || '_' || e.id || '_web' || p_dir, p_org, a.id, e.id, v_day, 'updated',
            'Web check-out ' || v_hhmm || ' (' || v_net || ')', v_me, coalesce(v_myname, e.full_name) || ' · Web');
    return jsonb_build_object('outcome', 'checked_out', 'time', v_hhmm);
  else
    raise exception 'Unknown action.';
  end if;
end $$;
grant execute on function public.web_attendance_punch(text, text) to authenticated;
