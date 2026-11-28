-- 316 — BOM supervision: reject back to the creator (adds to 315). Safe to re-run.
alter table public.bom_headers
  add column if not exists rejected_at        timestamptz,
  add column if not exists rejected_by        text,
  add column if not exists rejected_by_name   text,
  add column if not exists reject_reason      text,
  add column if not exists last_reject_reason text,
  add column if not exists resubmitted_at     timestamptz;

create index if not exists idx_bom_headers_rejected
  on public.bom_headers(org_id, created_by) where rejected_at is not null and supervised_at is null;
