-- 303 — Payroll: exclude employees from a payroll run.
alter table public.hr_payroll_runs
  add column if not exists excluded_employee_ids text[] not null default '{}';
