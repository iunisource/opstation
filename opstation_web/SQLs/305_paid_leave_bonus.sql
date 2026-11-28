-- 305 — Payroll: monthly paid-leave days (bonus for unused days).
alter table public.hr_employees
  add column if not exists paid_leave_days numeric;          -- per-employee override (null = company default)
alter table public.hr_payroll_items
  add column if not exists notjoined_days numeric default 0,
  add column if not exists paid_leave_quota numeric default 0,
  add column if not exists paid_leave_used numeric default 0,
  add column if not exists leave_bonus_days numeric default 0,
  add column if not exists leave_bonus numeric default 0;

-- Company default: 2 paid leave days a month (Unisource Lahore).
delete from public.app_config where org_id = 'org_1784655141655' and key = 'hr.paid_leave_days';
insert into public.app_config (org_id, key, value) values ('org_1784655141655', 'hr.paid_leave_days', '2');

-- Join dates from the September sheet (first marked day), so mid-month joiners get the right share.
update public.hr_employees set join_date = v.d
  from (values
    ('emp_1790052439805', date '2026-09-08'),  -- Abdul Latif (was 7 Sep; sheet starts 8 Sep)
    ('emp_1790052620662', date '2026-09-19'),  -- Ghulam Rasool
    ('emp_1790052575460', date '2026-09-19'),  -- Zeeshan Ramzan
    ('emp_1790054518727', date '2026-09-21')   -- Abdullah Anwar (was 22 Sep; sheet has P on 21 Sep)
  ) as v(id, d)
 where hr_employees.id = v.id and hr_employees.org_id = 'org_1784655141655';
