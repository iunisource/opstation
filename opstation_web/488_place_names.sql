-- 488 — Shared place names for reports. Once anyone gets the area name of a
-- GPS spot (~10 m), it is saved here and every later report uses it at once,
-- instead of asking OpenStreetMap again (its free service allows about one
-- lookup a second, so busy reports used to show coordinates).
-- Place names only (no people, no organisation data). Safe to run again.

create table if not exists public.place_names (
  key        text primary key,          -- "31.4768,74.2428" (4 decimals)
  lat        double precision,
  lng        double precision,
  name       text not null,
  created_at timestamptz not null default now()
);
alter table public.place_names enable row level security;
drop policy if exists place_names_read on public.place_names;
create policy place_names_read on public.place_names for select to authenticated using (true);
drop policy if exists place_names_add on public.place_names;
create policy place_names_add on public.place_names for insert to authenticated
  with check (length(name) between 1 and 200 and key ~ '^-?[0-9]+\.[0-9]{4},-?[0-9]+\.[0-9]{4}$');
grant select, insert on public.place_names to authenticated;

select 'place names ready' as status;
