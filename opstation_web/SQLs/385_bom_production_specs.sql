-- 385 — Production specs on BOMs
-- Specs (text + artwork / label files) written on a BOM show on every job card
-- and production voucher made from it. A job card flags "Specs updated" when
-- the BOM's specs change after the job was made, until production notes it.
-- Safe to run again.

alter table public.bom_headers add column if not exists production_specs text;
alter table public.bom_headers add column if not exists specs_updated_at timestamptz;
alter table public.job_cards  add column if not exists specs_seen_at timestamptz;

-- Spec files live in voucher_documents with voucher_type 'BOM'. If that table
-- limits voucher_type with a check constraint, widen it (keeps existing types).
do $$
declare c record; vals text[];
begin
  for c in
    select con.conname, pg_get_constraintdef(con.oid) as def
      from pg_constraint con
     where con.conrelid = 'public.voucher_documents'::regclass
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%voucher_type%'
  loop
    select array_agg(distinct btrim(v, ' "')) into vals
      from regexp_matches(c.def, '''([^'']+)''', 'g') m,
           unnest(string_to_array(btrim(m[1], '{}'), ',')) v;
    vals := array(select distinct unnest(coalesce(vals, '{}') || array['BOM']));
    execute format('alter table public.voucher_documents drop constraint %I', c.conname);
    execute format('alter table public.voucher_documents add constraint %I check (voucher_type = any (%L::text[]))',
                   c.conname, vals);
    raise notice 'Widened %: %', c.conname, vals;
  end loop;
end $$;

-- Job card audit trail: allow the new 'specs_noted' action if actions are limited.
do $$
declare c record; vals text[];
begin
  if to_regclass('public.job_card_audit_trail') is null then return; end if;
  for c in
    select con.conname, pg_get_constraintdef(con.oid) as def
      from pg_constraint con
     where con.conrelid = 'public.job_card_audit_trail'::regclass
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%action%'
  loop
    select array_agg(distinct btrim(v, ' "')) into vals
      from regexp_matches(c.def, '''([^'']+)''', 'g') m,
           unnest(string_to_array(btrim(m[1], '{}'), ',')) v;
    vals := array(select distinct unnest(coalesce(vals, '{}') || array['specs_noted']));
    execute format('alter table public.job_card_audit_trail drop constraint %I', c.conname);
    execute format('alter table public.job_card_audit_trail add constraint %I check (action = any (%L::text[]))',
                   c.conname, vals);
    raise notice 'Widened %: %', c.conname, vals;
  end loop;
end $$;

-- Spec artwork must never be removed by the support-documents retention purge.
do $do$
begin
  if to_regclass('public.org_storage_policy') is null then return; end if;
  execute $f$
create or replace function public.support_docs_due_for_purge(p_limit int default 500, p_org text default null)
returns table(id text, org_id text, bucket text, path text, size_bytes bigint)
language sql stable security definer set search_path to 'public' as $q$
  select d.id::text, d.org_id::text, d.bucket::text, d.path::text, coalesce(d.size_bytes, 0)::bigint
    from public.voucher_documents d
    join public.org_storage_policy p on p.org_id = d.org_id and coalesce(p.docs_retention_days, 0) >= 30
   where d.created_at < now() - make_interval(days => p.docs_retention_days)
     and coalesce(d.voucher_type, '') <> 'BOM'
     and (p_org is null or d.org_id = p_org)
   order by d.created_at
   limit p_limit;
$q$$f$;
  revoke all on function public.support_docs_due_for_purge(int, text) from public, anon, authenticated;
  grant execute on function public.support_docs_due_for_purge(int, text) to service_role;
end $do$;

notify pgrst, 'reload schema';

-- Check
select column_name, table_name from information_schema.columns
 where table_schema = 'public'
   and ((table_name = 'bom_headers' and column_name in ('production_specs', 'specs_updated_at'))
     or (table_name = 'job_cards' and column_name = 'specs_seen_at'));
