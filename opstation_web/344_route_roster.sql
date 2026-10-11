-- 344 — Route Roster (Operations ▸ Route Roster)
-- A standalone weekly planner: which salesperson covers which route(s) on which
-- day, plus an optional note per cell (e.g. "Leave", "Office"). It does not
-- change route assignments, trips or anything else.
-- Editing is controlled in the app by the "Route Roster" permission (Edit).
-- Safe to run again.

set lock_timeout = '5s';

create table if not exists public.route_roster (
  org_id          text not null,
  user_id         text not null,          -- the salesperson (users.id)
  day             date not null,
  route_ids       text[] not null default '{}',
  note            text,
  updated_at      timestamptz not null default now(),
  updated_by      text,
  updated_by_name text,
  primary key (org_id, user_id, day)
);
create index if not exists idx_route_roster_day on public.route_roster(org_id, day);

alter table public.route_roster enable row level security;
drop policy if exists rr_org_rw on public.route_roster;
create policy rr_org_rw on public.route_roster
  for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
grant select, insert, update, delete on public.route_roster to authenticated;

reset lock_timeout;

select count(*) as roster_cells from public.route_roster;
