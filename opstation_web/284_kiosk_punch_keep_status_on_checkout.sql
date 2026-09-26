-- Kiosk check-out no longer overwrites a status an admin set (e.g. Absent).
-- Check-out is time-keeping only: it records the time + work hours and keeps
-- the existing status; an empty status still becomes 'present'.
-- Only the punch-out UPDATE changes vs. the previous definition.

CREATE OR REPLACE FUNCTION public.kiosk_punch(p_code text, p_photo_url text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_code text := trim(p_code);
  v_cnt int;
  v_emp hr_employees%rowtype;
  v_now timestamptz := now();
  v_day date := (now() at time zone 'Asia/Karachi')::date;
  v_hhmm text := to_char(now() at time zone 'Asia/Karachi', 'HH24:MI');
  v_row hr_attendance%rowtype;
  v_have_row boolean := false;
  v_recent boolean := false;
  v_att_id text;
  v_wh numeric;
  v_a int; v_b int; v_d int;
begin
  if v_code is null or v_code = '' then
    return jsonb_build_object('outcome','error','title','Empty code');
  end if;

  select count(*) into v_cnt from hr_employees
    where card_uid = v_code and coalesce(is_voided,false) = false;
  if v_cnt > 1 then
    return jsonb_build_object('outcome','error','title','Ambiguous card',
      'message','This card is registered in more than one company.');
  elsif v_cnt = 1 then
    select * into v_emp from hr_employees
      where card_uid = v_code and coalesce(is_voided,false) = false limit 1;
  else
    select count(*) into v_cnt from hr_employees
      where employee_code ilike v_code and coalesce(is_voided,false) = false;
    if v_cnt > 1 then
      return jsonb_build_object('outcome','error','title','Ambiguous code',
        'message','This code exists in more than one company - scan the ID card instead.');
    elsif v_cnt = 1 then
      select * into v_emp from hr_employees
        where employee_code ilike v_code and coalesce(is_voided,false) = false limit 1;
    else
      if exists (select 1 from hr_employees
                 where (card_uid = v_code or employee_code ilike v_code)
                   and coalesce(is_voided,false) = true) then
        return jsonb_build_object('outcome','blocked','title','Inactive employee');
      end if;
      return jsonb_build_object('outcome','error','title','Card not recognized',
        'message','No employee for code "' || v_code || '"');
    end if;
  end if;

  select * into v_row from hr_attendance
    where org_id = v_emp.org_id and employee_id = v_emp.id
      and att_date = v_day
    limit 1;
  v_have_row := found;

  if v_have_row and coalesce(v_row.check_out, '') <> '' then
    return jsonb_build_object('outcome','blocked','title','Already completed today',
      'name', v_emp.full_name, 'code', v_emp.employee_code, 'photo_url', v_emp.photo_url,
      'message','Checked out at ' || v_row.check_out || '. Ask an admin to re-open.');
  end if;

  if v_have_row then
    begin
      v_recent := v_row.updated_at is not null
        and v_now - v_row.updated_at::timestamptz < interval '60 seconds';
    exception when others then v_recent := false;
    end;
    if v_recent then
      return jsonb_build_object('outcome','blocked',
        'title', case when coalesce(v_row.check_in,'') <> '' then 'Already punched in' else 'Please wait' end,
        'name', v_emp.full_name, 'code', v_emp.employee_code, 'photo_url', v_emp.photo_url,
        'message','Scanned moments ago - try again in a minute.');
    end if;
  end if;

  if v_have_row and coalesce(v_row.check_in, '') <> '' then
    -- PUNCH OUT: time-keeping only. Keep whatever status is set (an admin's
    -- "Absent" stays Absent); an empty status becomes 'present'.
    v_a := split_part(v_row.check_in, ':', 1)::int * 60 + split_part(v_row.check_in, ':', 2)::int;
    v_b := split_part(v_hhmm, ':', 1)::int * 60 + split_part(v_hhmm, ':', 2)::int;
    v_d := v_b - v_a;
    if v_d <= 0 then v_d := v_d + 1440; end if;
    v_wh := round(v_d / 60.0, 2);
    update hr_attendance
       set status = case when coalesce(status, '') = '' then 'present' else status end,
           check_out = v_hhmm, work_hours = v_wh,
           updated_at = v_now,
           punch_out_photo = coalesce(p_photo_url, punch_out_photo)
     where id = v_row.id;
    insert into hr_attendance_audit
      (id, org_id, attendance_id, employee_id, att_date, action, changes, changed_by, changed_by_name)
    values ('aud_' || (extract(epoch from v_now) * 1000000)::bigint || '_' || v_emp.id,
            v_emp.org_id, v_row.id, v_emp.id, v_day, 'updated',
            'Kiosk check-out ' || v_hhmm, null, 'Kiosk');
    return jsonb_build_object('outcome','checked_out','title','Checked Out',
      'name', v_emp.full_name, 'code', v_emp.employee_code,
      'photo_url', v_emp.photo_url, 'time', v_hhmm,
      'attendance_id', v_row.id, 'direction', 'out');
  else
    v_att_id := coalesce(v_row.id,
      'att_' || (extract(epoch from v_now) * 1000000)::bigint || '_' || v_emp.id);
    insert into hr_attendance
      (id, org_id, employee_id, branch_id, att_date, status, check_in, check_out,
       work_hours, updated_at, punch_in_photo)
    values (v_att_id, v_emp.org_id, v_emp.id, v_emp.branch_id, v_day, 'present',
            v_hhmm, null, null, v_now, p_photo_url)
    on conflict (org_id, employee_id, att_date)
    do update set status = 'present', check_in = excluded.check_in,
                  check_out = null, work_hours = null, updated_at = excluded.updated_at,
                  punch_in_photo = coalesce(excluded.punch_in_photo, hr_attendance.punch_in_photo);
    insert into hr_attendance_audit
      (id, org_id, attendance_id, employee_id, att_date, action, changes, changed_by, changed_by_name)
    values ('aud_' || (extract(epoch from v_now) * 1000000)::bigint || '_' || v_emp.id,
            v_emp.org_id, v_att_id, v_emp.id, v_day, 'created',
            'Kiosk check-in ' || v_hhmm, null, 'Kiosk');
    return jsonb_build_object('outcome','checked_in','title','Checked In',
      'name', v_emp.full_name, 'code', v_emp.employee_code,
      'photo_url', v_emp.photo_url, 'time', v_hhmm,
      'attendance_id', v_att_id, 'direction', 'in');
  end if;
end;
$function$;
