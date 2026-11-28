-- 462 — Web check-in, softer + linked logins. Needs SQL 460 and 461.
--
--  • Check-in / check-out is allowed even when NOT on an office network; that
--    punch goes to Attendance Review → "Punches to screen" marked
--    "Not on an office network". From there an admin can name that connection
--    and add it as an office network in one tap.
--  • An employee can be linked to an Opstation login on the employee form
--    ("Opstation login"). The link is used first; the email match stays as a
--    fallback.

alter table public.hr_employees add column if not exists login_user_id text;
alter table public.web_punch_flags add column if not exists ip text;

create or replace function public._web_att_employee(p_org text)
returns public.hr_employees language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_me text;
  v_email text := lower(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''));
  e hr_employees%rowtype;
begin
  select a.id into v_me from public._acting_user(p_org) a;
  if v_me is not null then
    select * into e from hr_employees
     where org_id = p_org and coalesce(is_voided, false) = false and login_user_id = v_me
     order by id desc limit 1;
    if found then return e; end if;
  end if;
  if v_email is null then return null; end if;
  select * into e from hr_employees
   where org_id = p_org and coalesce(is_voided, false) = false
     and lower(btrim(coalesce(email, ''))) = v_email
   order by id desc limit 1;
  if not found then return null; end if;
  return e;
end $$;

create or replace function public.web_attendance_punch(
  p_org text, p_dir text, p_device text default null,
  p_signed_in_at timestamptz default null, p_prev_user text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_ip text := public._request_ip();
  v_net text;
  e hr_employees%rowtype;
  v_day date := (now() at time zone 'Asia/Karachi')::date;
  a hr_attendance%rowtype;
  v_have boolean;
  v_me text; v_myname text;
  v_code text;
  v_res jsonb;
  v_att text; v_time text;
  v_reasons text[] := '{}';
  v_others text[];
  v_dev text := nullif(btrim(coalesce(p_device, '')), '');
begin
  if p_org is null or not (public._is_org_member(p_org) or public._is_super_admin()) then
    raise exception 'You do not have access to this organisation.';
  end if;
  if not public._cfg_true(p_org, 'org.web_checkin') then
    raise exception 'Web check-in is switched off for this company.';
  end if;
  -- Not on an office network: still allowed, but sent for review.
  select name into v_net from org_office_networks where org_id = p_org and ip = v_ip limit 1;
  e := public._web_att_employee(p_org);
  if e.id is null then
    raise exception 'Your login is not linked to an employee. Ask HR to pick your login under "Opstation login" on your employee record.';
  end if;
  select au.id, au.name into v_me, v_myname from public._acting_user(p_org) au;

  -- The button says in or out; make sure the kiosk logic will do that same thing.
  select * into a from hr_attendance where org_id = p_org and employee_id = e.id and att_date = v_day limit 1;
  v_have := found;
  if p_dir = 'in' then
    if v_have and coalesce(a.check_in, '') <> '' then
      raise exception 'You are already checked in today (at %).', a.check_in;
    end if;
  elsif p_dir = 'out' then
    if not v_have or coalesce(a.check_in, '') = '' then raise exception 'You have not checked in today.'; end if;
    if coalesce(a.check_out, '') <> '' then raise exception 'You already checked out today (at %).', a.check_out; end if;
  else
    raise exception 'Unknown action.';
  end if;

  -- Same punch as the kiosk: the card first (unique), else the employee code.
  v_code := coalesce(nullif(btrim(coalesce(e.card_uid, '')), ''), e.employee_code);
  if v_code is null then raise exception 'Your employee record has no code. Ask HR to add one.'; end if;
  v_res := public.kiosk_punch(v_code);
  if coalesce(v_res ->> 'outcome', '') not in ('checked_in', 'checked_out') then
    raise exception '%', coalesce(nullif(v_res ->> 'message', ''), v_res ->> 'title', 'Punch failed.');
  end if;
  v_att := v_res ->> 'attendance_id';
  v_time := v_res ->> 'time';

  -- Mark the kiosk's audit line as a web punch.
  update hr_attendance_audit
     set changes = case when p_dir = 'in' then 'Web check-in ' else 'Web check-out ' end || coalesce(v_time, '') || ' (' || coalesce(v_net, 'not an office network') || ')',
         changed_by = v_me,
         changed_by_name = coalesce(v_myname, e.full_name) || ' · Web'
   where id = (select id from hr_attendance_audit
                where attendance_id = v_att and changed_by_name = 'Kiosk'
                order by id desc limit 1);

  -- Quiet screening.
  if v_net is null then v_reasons := array_append(v_reasons, 'off_network'); end if;
  if v_dev is not null then
    select array_agg(distinct l.employee_id) into v_others
      from web_punch_log l
     where l.org_id = p_org and l.device_id = v_dev and l.att_date = v_day and l.employee_id <> e.id;
    if v_others is not null then v_reasons := array_append(v_reasons, 'shared_computer'); end if;
    if exists (select 1 from web_punch_log where org_id = p_org and employee_id = e.id and device_id is not null)
       and not exists (select 1 from web_punch_log where org_id = p_org and employee_id = e.id and device_id = v_dev) then
      v_reasons := array_append(v_reasons, 'new_computer');
    end if;
  end if;
  if nullif(p_prev_user, '') is not null and p_prev_user <> coalesce(v_me, '')
     and p_signed_in_at is not null and p_signed_in_at > now() - interval '5 minutes' then
    v_reasons := array_append(v_reasons, 'login_swap');
  end if;

  insert into web_punch_log (org_id, employee_id, user_id, device_id, direction, att_date, network)
  values (p_org, e.id, v_me, v_dev, p_dir, v_day, v_net);

  if array_length(v_reasons, 1) > 0 then
    insert into web_punch_flags (org_id, attendance_id, employee_id, att_date, direction, punch_time,
                                 network, device_id, reasons, other_employees, prev_user_id, ip)
    values (p_org, v_att, e.id, v_day, p_dir, v_time, v_net, v_dev, v_reasons, v_others, nullif(p_prev_user, ''), v_ip);
  end if;

  return jsonb_build_object('outcome', v_res ->> 'outcome', 'time', v_time);
end $$;
grant execute on function public.web_attendance_punch(text, text, text, timestamptz, text) to authenticated;

create or replace function public.web_punch_flags_list(p_org text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._can_review_attendance(p_org) then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', f.id, 'att_date', f.att_date, 'direction', f.direction, 'time', f.punch_time,
             'network', f.network, 'ip', f.ip,
             'ip_listed', exists (select 1 from org_office_networks n where n.org_id = f.org_id and n.ip = f.ip),
             'can_add_network', public._is_org_admin(f.org_id) or public._is_super_admin(),
             'reasons', to_jsonb(f.reasons), 'created_at', f.created_at,
             'employee', e.full_name, 'code', e.employee_code, 'photo_url', e.photo_url,
             'others', (select jsonb_agg(o.full_name order by o.full_name) from hr_employees o
                         where o.id = any (coalesce(f.other_employees, '{}'))),
             'prev_user', (select u.name from users u where u.id = f.prev_user_id limit 1),
             'check_in', at.check_in, 'check_out', at.check_out)
           order by f.created_at desc)
      from web_punch_flags f
      join hr_employees e on e.id = f.employee_id
      left join hr_attendance at on at.id = f.attendance_id
     where f.org_id = p_org and f.status = 'pending'), '[]'::jsonb);
end $$;
grant execute on function public.web_punch_flags_list(text) to authenticated;

-- Admin: add the connection a flagged punch came from as an office network.
create or replace function public.office_network_add_from_flag(p_flag text, p_name text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare f web_punch_flags%rowtype; v_me text; v_name text;
begin
  select * into f from web_punch_flags where id = p_flag;
  if f.id is null then raise exception 'Not found.'; end if;
  if not (public._is_org_admin(f.org_id) or public._is_super_admin()) then
    raise exception 'Only admins can add office networks.';
  end if;
  if f.ip is null then raise exception 'This punch has no connection to add.'; end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then raise exception 'Give the network a name.'; end if;
  if exists (select 1 from org_office_networks where org_id = f.org_id and ip = f.ip) then
    raise exception 'This network is already added.';
  end if;
  select a.id, a.name into v_me, v_name from public._acting_user(f.org_id) a;
  insert into org_office_networks (org_id, name, ip, added_by_name) values (f.org_id, btrim(p_name), f.ip, v_name);
  update web_punch_flags set network = btrim(p_name) where org_id = f.org_id and ip = f.ip and network is null;
  return 'ok';
end $$;
grant execute on function public.office_network_add_from_flag(text, text) to authenticated;
