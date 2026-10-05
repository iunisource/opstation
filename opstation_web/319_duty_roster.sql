-- 319 — Duty Roster (Manufacturing ▸ Duty Roster).
-- Work stations / lines, and which worker is on which station each day.
-- Attendance is only READ by the screen (absent / on leave flags); payroll is
-- not affected. Safe to run again.

create table if not exists public.duty_stations (
  id          text primary key,
  org_id      text not null,
  name        text not null,
  color       text not null default '#2F6FED',
  sort_order  int  not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_duty_stations_org on public.duty_stations(org_id, sort_order);

create table if not exists public.duty_roster (
  id          text primary key,
  org_id      text not null,
  employee_id text not null,
  roster_date date not null,
  station_id  text,                 -- null when is_off
  is_off      boolean not null default false,
  note        text,
  updated_by  text,
  updated_at  timestamptz not null default now(),
  unique (org_id, employee_id, roster_date)
);
create index if not exists idx_duty_roster_org_date on public.duty_roster(org_id, roster_date);

-- Any active user of the org (same as in 314 / 317).
create or replace function public._is_org_member(p_org text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.users u
     where u.org_id = p_org
       and coalesce(u.is_active, true)
       and (u.account_id = public.current_account_id()
            or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))));
$$;

alter table public.duty_stations enable row level security;
alter table public.duty_roster   enable row level security;

drop policy if exists ds_org on public.duty_stations;
create policy ds_org on public.duty_stations for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
drop policy if exists dr_org on public.duty_roster;
create policy dr_org on public.duty_roster for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));

grant select, insert, update, delete on public.duty_stations, public.duty_roster to authenticated;
