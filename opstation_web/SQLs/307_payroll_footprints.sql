-- 307 — Payroll: approved-by / paid-by footprints with signature.
alter table public.hr_payroll_runs
  add column if not exists finalized_at timestamptz,
  add column if not exists finalized_by text,
  add column if not exists finalized_by_name text,
  add column if not exists finalized_signature_url text,
  add column if not exists paid_at timestamptz,
  add column if not exists paid_by text,
  add column if not exists paid_by_name text;
