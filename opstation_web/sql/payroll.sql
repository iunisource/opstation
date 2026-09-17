-- Payroll module — tables. Run once in the Supabase SQL editor. Safe to re-run.

create table if not exists hr_payroll_runs (
  id                text primary key,
  org_id            text not null,
  period            text not null,          -- 'YYYY-MM'
  status            text not null default 'draft',  -- draft / finalized / paid
  employee_count    integer default 0,
  total_net         numeric default 0,
  generated_at      timestamptz,
  generated_by      text,
  generated_by_name text,
  finalized_at      timestamptz,
  paid_at           timestamptz,
  notes             text,
  updated_at        timestamptz default now(),
  unique (org_id, period)
);

create table if not exists hr_payroll_items (
  id                text primary key,
  run_id            text not null,
  org_id            text not null,
  employee_id       text not null,
  period            text,
  basic             numeric default 0,
  calendar_days     integer default 0,
  per_day           numeric default 0,
  present_days      numeric default 0,
  absent_days       numeric default 0,
  penalty_days      numeric default 0,
  leave_days        numeric default 0,
  half_days         numeric default 0,
  holiday_days      numeric default 0,
  restday_days      numeric default 0,
  unpaid_days       numeric default 0,
  paid_days         numeric default 0,
  absence_deduction numeric default 0,
  allowances        numeric default 0,
  bonus             numeric default 0,
  other_deduction   numeric default 0,
  advance           numeric default 0,
  gross             numeric default 0,
  total_deduction   numeric default 0,
  net               numeric default 0,
  remarks           text,
  updated_at        timestamptz default now(),
  unique (run_id, employee_id)
);

create index if not exists hr_payroll_items_run_idx on hr_payroll_items (run_id);
create index if not exists hr_payroll_runs_org_idx on hr_payroll_runs (org_id, period);

-- ─────────────────────────────────────────────────────────────────────────────
-- RLS — IMPORTANT: payroll holds salary data, so these tables must be org-scoped
-- exactly like your other HR tables. This project's RLS lives in Supabase (not in
-- these files), so rather than guess the mechanism and risk a 42501 lockout,
-- FIRST reveal how hr_attendance is secured:
--
--   select policyname, cmd, qual, with_check
--   from pg_policies where tablename = 'hr_attendance';
--
-- Send me that output and I'll produce matching policies for hr_payroll_runs and
-- hr_payroll_items. Until then the tables are created WITHOUT RLS so you can test
-- the screen — do not put real payroll in until the matching policy is applied.
-- ─────────────────────────────────────────────────────────────────────────────
