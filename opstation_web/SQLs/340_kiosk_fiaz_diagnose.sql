-- 340 — read-only: why Fiaz Umar's second scan was taken as a check-out
with e as (
  select id from hr_employees
   where org_id = 'org_1784655141655' and to_jsonb(hr_employees)::text ilike '%fiaz%umar%'
)
select 'attendance' as what, to_jsonb(a) - 'punch_in_photo' - 'punch_out_photo' as row
  from hr_attendance a join e on a.employee_id = e.id
 where to_jsonb(a)::text like '%' || to_char(now() at time zone 'Asia/Karachi', 'YYYY-MM-DD') || '%'
    or to_jsonb(a)::text like '%' || to_char((now() at time zone 'Asia/Karachi') - interval '1 day', 'YYYY-MM-DD') || '%'
union all
select 'audit', to_jsonb(x)
  from hr_attendance_audit x
 where to_jsonb(x)::text like any (select '%' || id || '%' from e)
   and to_jsonb(x)::text like '%' || to_char(now() at time zone 'Asia/Karachi', 'YYYY-MM-DD') || '%'
union all
select 'function', to_jsonb(pg_get_functiondef('public.kiosk_punch'::regproc));
