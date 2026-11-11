-- 461 — Web check-in: same punch as the kiosk + quiet screening of suspicious punches.
-- Needs SQL 460.
--
--  • A web punch now runs through kiosk_punch itself, so attendance, late
--    marks, payroll, notifications and reports treat it exactly like a kiosk
--    punch. Only the audit line differs: "Web check-in 09:04 (Head Office)".
--  • Every web punch is logged with the computer it came from (a hidden ID the
--    browser keeps). A punch is flagged — quietly, it still counts — when:
--      shared_computer : this computer punched a DIFFERENT employee today
--      new_computer    : the employee has punched from the web before, but
--                        never from this computer
--      login_swap      : someone else used this browser just before, and this
--                        login started less than 5 minutes before the punch
--  • Flagged punches show in Attendance Review → "Punches to screen".
--    Approve keeps it; Reject removes that check-in / check-out (audit kept).
--  • Reviewers: admins, and anyone with the Attendance Review permission.

create table if not exists public.web_punch_log (
  id          text primary key default ('wpl_' || replace(gen_random_uuid()::text, '-', '')),
  org_id      text not null,
  employee_id text not null,
  user_id     text,
  device_id   text,
  direction   text not null,
  att_date    date not null,
  punched_at  timestamptz not null default now(),
  network     text
);
create index if not exists web_punch_log_dev on public.web_punch_log (org_id, device_id, att_date);
create index if not exists web_punch_log_emp on public.web_punch_log (org_id, employee_id);
alter table public.web_punch_log enable row level security;
revoke all on public.web_punch_log from anon, authenticated;

create table if not exists public.web_punch_flags (
  id               text primary key default ('wpf_' || replace(gen_random_uuid()::text, '-', '')),
  org_id           text not null,
  attendance_id    text,
  employee_id      text not null,
  att_date         date not null,
  direction        text not null,
  punch_time       text,
  network          text,
  device_id        text,
  reasons          text[] not null,
  other_employees  text[],
  prev_user_id     text,
  status           text not null default 'pending',   -- pending | approved | rejected
  reviewed_by_name text,
  reviewed_at      timestamptz,
  note             text,
  created_at       timestamptz not null default now()
);
create index if not exists web_punch_flags_org on public.web_punch_flags (org_id, status);
alter table public.web_punch_flags enable row level security;
revoke all on public.web_punch_flags from anon, authenticated;

-- Admins, or anyone given the Attendance Review screen.
create or replace function public._can_review_attendance(p_org text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_id text;
begin
  if public._is_org_admin(p_org) or public._is_super_admin() then return true; end if;
  select a.id into v_id from public._acting_user(p_org) a;
  if v_id is null then return false; end if;
  return exists (select 1 from public.user_permissions
                  where user_id = v_id and permission = 'report.hr_attendance_review.view');
end $$;

drop function if exists public.web_attendance_punch(text, text);
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
  select name into v_net from org_office_networks where org_id = p_org and ip = v_ip limit 1;
  if v_net is null then
    raise exception 'You are not on an office network. Connect to the office Wi-Fi and try again.';
  end if;
  e := public._web_att_employee(p_org);
  if e.id is null then
    raise exception 'Your login is not linked to an employee. Ask HR to put your login email on your employee record.';
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
     set changes = case when p_dir = 'in' then 'Web check-in ' else 'Web check-out ' end || coalesce(v_time, '') || ' (' || v_net || ')',
         changed_by = v_me,
         changed_by_name = coalesce(v_myname, e.full_name) || ' · Web'
   where id = (select id from hr_attendance_audit
                where attendance_id = v_att and changed_by_name = 'Kiosk'
                order by id desc limit 1);

  -- Quiet screening.
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
                                 network, device_id, reasons, other_employees, prev_user_id)
    values (p_org, v_att, e.id, v_day, p_dir, v_time, v_net, v_dev, v_reasons, v_others, nullif(p_prev_user, ''));
  end if;

  return jsonb_build_object('outcome', v_res ->> 'outcome', 'time', v_time);
end $$;
grant execute on function public.web_attendance_punch(text, text, text, timestamptz, text) to authenticated;

create or replace function public.web_punch_flags_count(p_org text)
returns int language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._can_review_attendance(p_org) then return 0; end if;
  return (select count(*) from web_punch_flags where org_id = p_org and status = 'pending');
end $$;
grant execute on function public.web_punch_flags_count(text) to authenticated;

create or replace function public.web_punch_flags_list(p_org text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._can_review_attendance(p_org) then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', f.id, 'att_date', f.att_date, 'direction', f.direction, 'time', f.punch_time,
             'network', f.network, 'reasons', to_jsonb(f.reasons), 'created_at', f.created_at,
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

-- Approve keeps the punch. Reject removes that check-in / check-out.
create or replace function public.web_punch_flag_decide(p_id text, p_decision text, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare f web_punch_flags%rowtype; v_me text; v_name text; a hr_attendance%rowtype; v_now timestamptz := now();
begin
  select * into f from web_punch_flags where id = p_id;
  if f.id is null then raise exception 'Not found.'; end if;
  if not public._can_review_attendance(f.org_id) then
    raise exception 'Only admins or Attendance Review users can screen punches.';
  end if;
  if f.status <> 'pending' then raise exception 'Already screened.'; end if;
  if p_decision not in ('approve', 'reject') then raise exception 'Unknown decision.'; end if;
  select x.id, x.name into v_me, v_name from public._acting_user(f.org_id) x;

  if p_decision = 'reject' and f.attendance_id is not null then
    select * into a from hr_attendance where id = f.attendance_id;
    if a.id is not null then
      if f.direction = 'in' and coalesce(a.status, '') in ('', 'present') then
        -- The day only had this punch: take it back to "no punch".
        delete from hr_attendance where id = a.id;
        a.id := null;
      elsif f.direction = 'in' then
        -- An admin had set a status (e.g. leave): keep it, drop the times.
        update hr_attendance set check_in = null, check_out = null, work_hours = null, updated_at = v_now where id = a.id;
      else
        update hr_attendance set check_out = null, work_hours = null, updated_at = v_now where id = a.id;
      end if;
      insert into hr_attendance_audit (id, org_id, attendance_id, employee_id, att_date, action, changes, changed_by, changed_by_name)
      values ('aud_' || (extract(epoch from v_now) * 1000000)::bigint || '_' || f.employee_id || '_rej', f.org_id, a.id,
              f.employee_id, f.att_date, 'updated',
              'Web ' || case when f.direction = 'in' then 'check-in ' else 'check-out ' end || coalesce(f.punch_time, '')
                || ' rejected in screening' || coalesce(' — ' || nullif(btrim(p_note), ''), ''),
              v_me, v_name);
    end if;
  end if;

  update web_punch_flags
     set status = case when p_decision = 'approve' then 'approved' else 'rejected' end,
         reviewed_by_name = v_name, reviewed_at = v_now, note = nullif(btrim(coalesce(p_note, '')), '')
   where id = f.id;
end $$;
grant execute on function public.web_punch_flag_decide(text, text, text) to authenticated;
