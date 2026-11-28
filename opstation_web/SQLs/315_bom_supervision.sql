-- 315 — BOM supervision (non-blocking), toggled by org.bom_supervise_flow.
-- New BOMs start un-supervised; supervisors mark them checked. Existing BOMs are
-- auto-supervised so only BOMs created from now on show as pending. Safe to re-run.

alter table public.bom_headers
  add column if not exists supervised_at      timestamptz,
  add column if not exists supervised_by      text,
  add column if not exists supervised_by_name text;

-- Existing BOMs: mark as supervised (once — only rows that pre-date this column).
update public.bom_headers
   set supervised_at = coalesce(created_at, now()), supervised_by_name = 'Auto (existing BOM)'
 where supervised_at is null
   and created_at < now() - interval '1 minute'
   and not exists (select 1 from public.app_config c
                    where c.org_id = bom_headers.org_id and c.key = 'org.bom_supervise_flow' and c.value = 'true');

create index if not exists idx_bom_headers_unsupervised
  on public.bom_headers(org_id) where supervised_at is null;

-- Live pendency counter: stream bom_headers changes.
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bom_headers') then
    alter publication supabase_realtime add table public.bom_headers;
  end if;
end $$;
