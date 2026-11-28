-- 352 — Audit-log archiving (per org, Super Admin setting).
-- Audit / history rows older than N months are moved out of the live tables
-- into compressed files (JSON, gzip) in the private 'audit-archive' bucket,
-- one file per org + table + run. The rows are then removed from the table.
-- Nothing is lost: Super Admin can download every archive file from the org's
-- Storage panel. Default: OFF (null) — nothing is archived until you pick a period.
--
-- Tables covered: every public table whose name ends in "_audit" or
-- "_audit_log" (e.g. voucher_audit_log, hr_attendance_audit) that has
-- org_id, id and a timestamp column (created_at / performed_at / changed_at).
-- Run by the nightly purge-support-docs edge function. Requires 350/351.
-- Safe to run again.

alter table public.org_storage_policy add column if not exists audit_archive_months int; -- null = off

create table if not exists public.audit_archive_files (
  id          bigserial primary key,
  org_id      text not null,
  table_name  text not null,
  path        text not null,
  rows        int,
  bytes       bigint,
  from_ts     timestamptz,
  to_ts       timestamptz,
  created_at  timestamptz default now()
);
alter table public.audit_archive_files enable row level security;
create index if not exists idx_audit_archive_files_org on public.audit_archive_files(org_id, created_at desc);

-- Private bucket for the archive files.
insert into storage.buckets (id, name, public)
values ('audit-archive', 'audit-archive', false)
on conflict (id) do nothing;

-- Super Admin may read (download) archive files; nobody else.
drop policy if exists audit_archive_superadmin_read on storage.objects;
create policy audit_archive_superadmin_read on storage.objects
  for select to authenticated
  using (bucket_id = 'audit-archive' and public._is_super_admin());

-- ── Setting (Super Admin) ────────────────────────────────────────────────────
create or replace function public.set_org_audit_archive(p_org text, p_months int)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_name text;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;
  if p_months is not null and p_months > 0 and p_months < 12 then
    raise exception 'Minimum is 12 months';
  end if;
  select name into v_name from public.users
   where account_id = public.current_account_id() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
   limit 1;
  insert into public.org_storage_policy(org_id, audit_archive_months, updated_at, updated_by_name)
  values (p_org, nullif(p_months, 0), now(), v_name)
  on conflict (org_id) do update
    set audit_archive_months = excluded.audit_archive_months, updated_at = now(), updated_by_name = excluded.updated_by_name;
end $$;
grant execute on function public.set_org_audit_archive(text, int) to authenticated;

-- ── Which tables qualify, and their timestamp column ─────────────────────────
create or replace function public._audit_tables()
returns table(table_name text, ts_col text)
language sql stable security definer set search_path to 'public' as $$
  select c.relname::text,
         (select a.attname::text from pg_attribute a
           where a.attrelid = c.oid and not a.attisdropped
             and a.attname in ('created_at', 'performed_at', 'changed_at', 'logged_at')
           order by array_position(array['created_at', 'performed_at', 'changed_at', 'logged_at'], a.attname::text)
           limit 1)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
   where c.relkind = 'r'
     and (c.relname like '%\_audit' or c.relname like '%\_audit\_log')
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'org_id' and not a.attisdropped)
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'id' and not a.attisdropped)
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and not a.attisdropped
                  and a.attname in ('created_at', 'performed_at', 'changed_at', 'logged_at'));
$$;
revoke all on function public._audit_tables() from public, anon, authenticated;

-- Per org + table: how many rows are older than that org's cutoff.
create or replace function public.audit_archive_due(p_org text default null)
returns table(org_id text, table_name text, cutoff timestamptz, due bigint)
language plpgsql stable security definer set search_path to 'public' as $$
declare p record; t record; n bigint; v_cut timestamptz;
begin
  for p in select s.org_id, s.audit_archive_months from public.org_storage_policy s
            where coalesce(s.audit_archive_months, 0) >= 12 and (p_org is null or s.org_id = p_org) loop
    v_cut := date_trunc('day', now() - make_interval(months => p.audit_archive_months));
    for t in select * from public._audit_tables() loop
      execute format('select count(*) from public.%I where org_id::text = $1 and %I < $2', t.table_name, t.ts_col)
        into n using p.org_id, v_cut;
      if n > 0 then
        org_id := p.org_id; table_name := t.table_name; cutoff := v_cut; due := n;
        return next;
      end if;
    end loop;
  end loop;
end $$;
revoke all on function public.audit_archive_due(text) from public, anon, authenticated;
grant execute on function public.audit_archive_due(text) to service_role;

-- Oldest rows first, as JSON (the edge function compresses and stores them).
create or replace function public.audit_archive_fetch(p_org text, p_table text, p_cutoff timestamptz, p_limit int default 5000)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_ts text; r jsonb;
begin
  select ts_col into v_ts from public._audit_tables() where table_name = p_table;
  if v_ts is null then raise exception 'Not an audit table: %', p_table; end if;
  execute format(
    'select coalesce(jsonb_agg(to_jsonb(x) order by x.%1$I), ''[]''::jsonb)
       from (select * from public.%2$I where org_id::text = $1 and %1$I < $2 order by %1$I limit $3) x',
    v_ts, p_table) into r using p_org, p_cutoff, p_limit;
  return r;
end $$;
revoke all on function public.audit_archive_fetch(text, text, timestamptz, int) from public, anon, authenticated;
grant execute on function public.audit_archive_fetch(text, text, timestamptz, int) to service_role;

-- After the file is safely stored: record it and remove exactly those rows.
create or replace function public.audit_archive_commit(p_org text, p_table text, p_path text, p_ids text[],
                                                       p_bytes bigint, p_from timestamptz, p_to timestamptz)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if not exists (select 1 from public._audit_tables() where table_name = p_table) then
    raise exception 'Not an audit table: %', p_table;
  end if;
  insert into public.audit_archive_files(org_id, table_name, path, rows, bytes, from_ts, to_ts)
  values (p_org, p_table, p_path, coalesce(array_length(p_ids, 1), 0), p_bytes, p_from, p_to);
  execute format('delete from public.%I where org_id::text = $1 and id::text = any ($2)', p_table)
    using p_org, p_ids;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.audit_archive_commit(text, text, text, text[], bigint, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.audit_archive_commit(text, text, text, text[], bigint, timestamptz, timestamptz)
  to service_role;

-- ── Org profile → Storage: audit figures + archive file list ────────────────
create or replace function public.org_audit_usage(p_org text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_m int; t record; n bigint; v_old timestamptz; v_due bigint; v_cut timestamptz;
        v_tables jsonb := '[]'::jsonb;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;
  select audit_archive_months into v_m from public.org_storage_policy where org_id = p_org;
  v_cut := case when coalesce(v_m, 0) >= 12 then date_trunc('day', now() - make_interval(months => v_m)) end;
  for t in select * from public._audit_tables() order by 1 loop
    execute format('select count(*), min(%2$I), count(*) filter (where $2 is not null and %2$I < $2)
                      from public.%1$I where org_id::text = $1', t.table_name, t.ts_col)
      into n, v_old, v_due using p_org, v_cut;
    continue when n = 0;
    v_tables := v_tables || jsonb_build_object('table', t.table_name, 'rows', n, 'oldest', v_old, 'due', v_due);
  end loop;
  return jsonb_build_object(
    'months', v_m,
    'tables', v_tables,
    'files', (select coalesce(jsonb_agg(jsonb_build_object('path', f.path, 'table', f.table_name, 'rows', f.rows,
                                'bytes', f.bytes, 'from', f.from_ts, 'to', f.to_ts, 'created_at', f.created_at)
                                order by f.created_at desc), '[]'::jsonb)
                from (select * from public.audit_archive_files where org_id = p_org order by created_at desc limit 50) f),
    'last_run', (select to_jsonb(l) - 'id' - 'org_id' from public.support_docs_purge_log l
                  where l.org_id = p_org and l.kind = 'audit' order by run_at desc limit 1));
end $$;
grant execute on function public.org_audit_usage(text) to authenticated;

-- Log: older_than for audit runs = the archive cutoff.
create or replace function public.log_support_docs_purge(p_org text, p_files int, p_bytes bigint,
                                                         p_note text default null, p_kind text default 'docs')
returns void language sql security definer set search_path to 'public' as $$
  insert into public.support_docs_purge_log(org_id, files, bytes, older_than, note, kind)
  select p_org, p_files, p_bytes,
         case p_kind
           when 'kiosk' then (now() - make_interval(days => coalesce((select kiosk_retention_days from public.org_storage_policy where org_id = p_org), 40)))::date
           when 'audit' then (now() - make_interval(months => coalesce((select audit_archive_months from public.org_storage_policy where org_id = p_org), 0)))::date
           else (now() - make_interval(days => coalesce((select docs_retention_days from public.org_storage_policy where org_id = p_org), 0)))::date
         end,
         p_note, coalesce(p_kind, 'docs');
$$;
revoke all on function public.log_support_docs_purge(text, int, bigint, text, text) from public, anon, authenticated;
grant execute on function public.log_support_docs_purge(text, int, bigint, text, text) to service_role;

-- Which tables will be archived (check):
select * from public._audit_tables();
