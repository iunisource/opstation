-- 308 — Shift payroll policy (paid leave, rest-day threshold) + employee "Left on".
alter table public.hr_shifts
  add column if not exists paid_leave_days numeric,       -- blank = company default
  add column if not exists rest_day_min_days numeric;     -- blank = company default
alter table public.hr_employees
  add column if not exists left_on date;                   -- last working day
alter table public.hr_payroll_items
  add column if not exists rest_unearned_days numeric default 0;

-- Company default: a rest day (Sunday) is earned with 3+ days worked in the 6 days before it.
delete from public.app_config where org_id = 'org_1784655141655' and key = 'hr.rest_day_min_days';
insert into public.app_config (org_id, key, value) values ('org_1784655141655', 'hr.rest_day_min_days', '3');

-- Zeeshan Ali: last working day 11 Sep 2026 (sheet blank from the 12th).
update public.hr_employees set left_on = date '2026-09-11'
 where id = 'emp_1790841999306' and org_id = 'org_1784655141655';
