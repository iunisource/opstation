-- 306 — Payroll: deduction breakdown on payslips.
alter table public.hr_payroll_items
  add column if not exists approved_leave_days numeric default 0,
  add column if not exists unapproved_days numeric default 0;
