-- 321 — Duty Chart (Manufacturing ▸ Duty Roster ▸ Duty Chart).
-- The long-term, undated duty assignment: each person's standing station/line
-- and their list of duties. Separate from the dated weekly roster.
-- Needs 319 (stations). Safe to run again.

create table if not exists public.duty_chart_members (
  org_id      text not null,
  employee_id text not null,
  station_id  text,
  updated_by  text,
  updated_at  timestamptz not null default now(),
  primary key (org_id, employee_id)
);

create table if not exists public.duty_chart_duties (
  id          text primary key,
  org_id      text not null,
  employee_id text not null,
  duty        text not null,
  station_id  text,               -- optional: the duty belongs to a particular station
  sort_order  int not null default 0,
  updated_by  text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_duty_chart_duties_emp on public.duty_chart_duties(org_id, employee_id, sort_order);

alter table public.duty_chart_members enable row level security;
alter table public.duty_chart_duties  enable row level security;

drop policy if exists dcm_org on public.duty_chart_members;
create policy dcm_org on public.duty_chart_members for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
drop policy if exists dcd_org on public.duty_chart_duties;
create policy dcd_org on public.duty_chart_duties for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));

grant select, insert, update, delete on public.duty_chart_members, public.duty_chart_duties to authenticated;
