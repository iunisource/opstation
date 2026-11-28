-- 438 — Lead Generation (super admin): distributors across Pakistan, by
-- industry, city and principal. Seeded from public web sources (each row keeps
-- its source links); the team keeps it updated from the web panel or by CSV.
-- Safe to run again.

create table if not exists public.lead_distributors (
  id          text primary key default ('ld_' || substr(md5(gen_random_uuid()::text), 1, 20)),
  name        text not null,
  industries  text[] not null default '{}',
  city        text not null default 'Other',
  address     text not null default '',
  phone       text not null default '',
  email       text not null default '',
  website     text not null default '',
  principals  text[] not null default '{}',
  notes       text not null default '',
  sources     text[] not null default '{}',
  status      text not null default 'new'
              check (status in ('new', 'contacted', 'interested', 'not_interested', 'customer')),
  follow_up   text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists lead_distributors_city_idx on public.lead_distributors (city);
create index if not exists lead_distributors_ind_idx  on public.lead_distributors using gin (industries);
create index if not exists lead_distributors_prin_idx on public.lead_distributors using gin (principals);

alter table public.lead_distributors enable row level security;
revoke all on public.lead_distributors from anon;
drop policy if exists ld_all on public.lead_distributors;
create policy ld_all on public.lead_distributors for all
  using (public._is_super_admin()) with check (public._is_super_admin());
grant select, insert, update, delete on public.lead_distributors to authenticated;

create or replace function public.trg_lead_distributor_touch()
returns trigger language plpgsql as $$
begin NEW.updated_at := now(); return NEW; end $$;
drop trigger if exists trg_lead_distributor_touch on public.lead_distributors;
create trigger trg_lead_distributor_touch before update on public.lead_distributors
  for each row execute function public.trg_lead_distributor_touch();

-- The distributor list itself is loaded from the screen: Import CSV
-- (opstation_leads_pakistan.csv).

notify pgrst, 'reload schema';
select count(*) as lead_rows from public.lead_distributors;
