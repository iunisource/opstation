-- 441 — Survey audits: an Auditor re-checks a surveyor's shop survey
-- (Placement Audit + Competitor Spotting) from the app: ticks "Matches" or
-- "Issue", adds a comment and an optional photo. Any data the auditor corrects
-- is saved as new survey rows by the auditor (the original rows stay), and is
-- listed on the audit. Audits are never edited or deleted from the apps — each
-- one adds to the shop's trail. Location is recorded and flagged when the
-- auditor is outside the shop's area. Safe to run again.

create table if not exists public.survey_audits (
  id              text primary key,
  org_id          text not null,
  customer_id     text not null,
  auditor_id      text,
  auditor_name    text,
  result          text not null check (result in ('ok', 'issue')),
  comment         text,
  photo_path      text,
  lat             double precision,
  lng             double precision,
  accuracy_m      double precision,
  distance_m      double precision,
  location_status text check (location_status in ('inside', 'outside', 'no_shop_location', 'no_gps')),
  survey_at       timestamptz,              -- latest survey the auditor was looking at
  corrections     jsonb not null default '[]'::jsonb,
  audited_at      timestamptz not null,
  created_at      timestamptz not null default now()
);
create index if not exists survey_audits_org_cust_idx
  on public.survey_audits (org_id, customer_id, audited_at desc);

alter table public.survey_audits enable row level security;
revoke all on public.survey_audits from anon;

drop policy if exists sa_read on public.survey_audits;
create policy sa_read on public.survey_audits for select
  using (public._is_org_member(org_id) or public._is_super_admin());

drop policy if exists sa_insert on public.survey_audits;
create policy sa_insert on public.survey_audits for insert
  with check (public._is_org_member(org_id) or public._is_super_admin());

-- The trail is permanent: only a super admin can remove an entry.
drop policy if exists sa_delete on public.survey_audits;
create policy sa_delete on public.survey_audits for delete
  using (public._is_super_admin());

grant select, insert, delete on public.survey_audits to authenticated;

notify pgrst, 'reload schema';
select 'survey audits ready' as result;
