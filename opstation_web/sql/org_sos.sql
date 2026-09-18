-- SOS kill switch — one row per org. Run once in the Supabase SQL editor.

create table if not exists org_sos (
  org_id            text primary key,
  enabled           boolean not null default false,  -- master-admin availability toggle
  active            boolean not null default false,  -- live lockdown state
  triggered_by      text,
  triggered_by_name text,
  triggered_at      timestamptz,
  cancelled_by      text,
  cancelled_at      timestamptz,
  updated_at        timestamptz default now()
);

-- Realtime: the web app subscribes to this row so open sessions drop the moment
-- SOS is pressed. One persistent socket per client, silent until the flag flips
-- (far lighter than polling). Safe to run even if already added.
do $$
begin
  begin
    alter publication supabase_realtime add table org_sos;
  exception when duplicate_object then null;
  end;
end $$;

-- RLS — mirrors the app's other org tables (allow-all + block retailers). Org
-- scoping and the "only master admin can cancel" rule are enforced in the app,
-- consistent with the rest of this project's model.
alter table org_sos enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where tablename='org_sos' and policyname='org_sos_all') then
    create policy org_sos_all on org_sos for all using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='org_sos' and policyname='block_retailers') then
    create policy block_retailers on org_sos as restrictive for all
      using (current_user_role() is distinct from 'retailer')
      with check (current_user_role() is distinct from 'retailer');
  end if;
end $$;
