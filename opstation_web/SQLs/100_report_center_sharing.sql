-- 100_report_center_sharing.sql
-- ---------------------------------------------------------------------------
-- Report Center — saved custom reports & sharing.
--   * Only admins create/save custom reports (enforced in-app).
--   * Each saved report has a share_scope: 'admins' (default, admins only),
--     'all' (every user in the org), or 'selected' (a picked list of users).
--   * Admins always see every saved report in their org.
-- This migration is additive and idempotent — it does NOT rewrite any existing
-- report_templates policy, so the current builder keeps working unchanged. It
-- only ADDS a share_scope column, a per-user share table, and a permissive
-- SELECT policy that GRANTS shared visibility to non-admins (an additive OR
-- policy can never lock anyone out).
-- ---------------------------------------------------------------------------

-- 1) share_scope on report_templates ---------------------------------------
alter table public.report_templates
  add column if not exists share_scope text not null default 'admins';

-- Backfill from the legacy boolean: the old "Shared with org" switch meant
-- "everyone". Only nudge rows still sitting at the freshly-defaulted 'admins'.
update public.report_templates
   set share_scope = case when coalesce(is_shared, false) then 'all' else 'admins' end
 where share_scope = 'admins';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'report_templates_share_scope_chk') then
    alter table public.report_templates
      add constraint report_templates_share_scope_chk
      check (share_scope in ('admins','all','selected'));
  end if;
end $$;

-- 2) per-user share list ----------------------------------------------------
create table if not exists public.report_template_shares (
  template_id text not null references public.report_templates(id) on delete cascade,
  user_id     text not null,
  org_id      text,
  created_at  timestamptz not null default now(),
  primary key (template_id, user_id)
);
create index if not exists idx_rts_user     on public.report_template_shares(user_id);
create index if not exists idx_rts_template on public.report_template_shares(template_id);

alter table public.report_template_shares enable row level security;

-- Permissive, org-agnostic access for authenticated users (mirrors how the app
-- already reads/writes report_templates; the share rows are low-sensitivity
-- pointers, and the app always writes org_id). Kept simple on purpose.
drop policy if exists rts_all on public.report_template_shares;
create policy rts_all on public.report_template_shares
  for all to authenticated using (true) with check (true);

-- 3) additive read policy so NON-admins can see reports shared to them -------
--    ORs on top of whatever report_templates already allows (admins keep their
--    existing read). Scoped to the reader's own org. Never restricts.
drop policy if exists rt_center_shared_read on public.report_templates;
create policy rt_center_shared_read on public.report_templates
  for select to authenticated
  using (
    exists (
      select 1 from public.users u
       where u.id = auth.uid()::text
         and u.org_id = report_templates.org_id
    )
    and (
      report_templates.share_scope = 'all'
      or exists (
        select 1 from public.report_template_shares s
         where s.template_id = report_templates.id
           and s.user_id = auth.uid()::text
      )
    )
  );

-- ---- VERIFY (optional) ----
-- select id, name, share_scope from report_templates order by created_at desc;
-- select * from report_template_shares order by created_at desc limit 20;
