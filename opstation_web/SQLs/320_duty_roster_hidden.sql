-- 320 — Duty Roster: hide members (e.g. roster only the team leads).
-- One row per employee hidden from the roster. Shared by everyone in the org.
-- Safe to run again.

create table if not exists public.duty_roster_hidden (
  org_id      text not null,
  employee_id text not null,
  hidden_by   text,
  hidden_at   timestamptz not null default now(),
  primary key (org_id, employee_id)
);

alter table public.duty_roster_hidden enable row level security;
drop policy if exists drh_org on public.duty_roster_hidden;
create policy drh_org on public.duty_roster_hidden for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));

grant select, insert, update, delete on public.duty_roster_hidden to authenticated;
