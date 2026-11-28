-- 323 — Duty Chart: general notes printed at the end of the chart (one per org).
-- Safe to run again.
create table if not exists public.duty_chart_notes (
  org_id     text primary key,
  notes      text not null default '',
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.duty_chart_notes enable row level security;
drop policy if exists dcn_org on public.duty_chart_notes;
create policy dcn_org on public.duty_chart_notes for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
grant select, insert, update, delete on public.duty_chart_notes to authenticated;
