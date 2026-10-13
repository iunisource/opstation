-- 350 — Super Admin: storage usage per org + server overview, and a per-org
--       support-document retention period ("overwrite tenure").
--
-- • org_storage_usage(org)        → files per bucket, database estimate, retention status
-- • platform_storage_overview()   → whole-server totals, per-bucket, top orgs, 30-day uploads
-- • set_org_docs_retention(org, days) → Super Admin only. NULL / 0 = keep forever.
-- • support_docs_due_for_purge(limit) / log_support_docs_purge(...) → used only
--   by the daily purge-support-docs edge function (service role).
--
-- Files are found by path: every upload is stored under "<org_id>/…". Kiosk
-- punch photos (att/…) are matched to the org through hr_attendance.
-- Safe to run again.

-- ── Settings & log (no direct client access — RPCs only) ────────────────────
create table if not exists public.org_storage_policy (
  org_id              text primary key,
  docs_retention_days int,          -- null/0 = keep forever
  updated_at          timestamptz default now(),
  updated_by_name     text
);
alter table public.org_storage_policy enable row level security;

create table if not exists public.support_docs_purge_log (
  id          bigserial primary key,
  org_id      text,
  run_at      timestamptz default now(),
  files       int,
  bytes       bigint,
  older_than  date,
  note        text
);
alter table public.support_docs_purge_log enable row level security;

alter table public.voucher_documents add column if not exists created_at timestamptz default now();
-- If created_at was only just added, take each file's real upload time from storage.
update public.voucher_documents d
   set created_at = o.created_at
  from storage.objects o
 where o.bucket_id = d.bucket and o.name = d.path
   and o.created_at < d.created_at - interval '1 day';
create index if not exists idx_voucher_documents_org_created on public.voucher_documents(org_id, created_at);

-- ── Who is calling ──────────────────────────────────────────────────────────
create or replace function public._is_super_admin()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.users u
     where u.role = 'superAdmin' and coalesce(u.is_active, true)
       and (u.account_id = public.current_account_id()
            or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))));
$$;

-- ── Database share of one org (estimate) ────────────────────────────────────
-- For every public table with an org_id column: table size × (org rows / all rows).
create or replace function public._org_db_estimate(p_org text)
returns table(table_name text, org_rows bigint, est_bytes bigint)
language plpgsql stable security definer set search_path to 'public' as $$
declare
  t record; n bigint; tot bigint;
begin
  for t in
    select c.relname, c.oid, pg_total_relation_size(c.oid) as sz, greatest(c.reltuples, 0)::bigint as est
      from pg_class c
      join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = 'public'
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'org_id' and not a.attisdropped
     where c.relkind in ('r', 'p')
  loop
    begin
      execute format('select count(*) from public.%I where org_id::text = $1', t.relname) into n using p_org;
      continue when coalesce(n, 0) = 0;
      tot := t.est;
      if tot < n then execute format('select count(*) from public.%I', t.relname) into tot; end if;
      table_name := t.relname; org_rows := n;
      est_bytes := (t.sz::numeric * n / greatest(tot, 1))::bigint;
      return next;
    exception when others then null;
    end;
  end loop;
end $$;
revoke all on function public._org_db_estimate(text) from public, anon, authenticated;

-- ── Files of one org (by path prefix + kiosk photos via hr_attendance) ──────
create or replace function public._org_objects(p_org text)
returns table(bucket_id text, name text, bytes bigint, created_at timestamptz)
language plpgsql stable security definer set search_path to 'public', 'storage' as $$
begin
  return query
    select o.bucket_id::text, o.name::text, coalesce((o.metadata ->> 'size')::bigint, 0), o.created_at
      from storage.objects o
     where split_part(o.name, '/', 1) = p_org;
  begin
    return query
      select o.bucket_id::text, o.name::text, coalesce((o.metadata ->> 'size')::bigint, 0), o.created_at
        from storage.objects o
        join (select split_part(x.u, '/kiosk-punches/', 2) as nm
                from public.hr_attendance a
                cross join lateral (values (a.punch_in_photo), (a.punch_out_photo)) x(u)
               where a.org_id = p_org and x.u like '%/kiosk-punches/%') k on k.nm = o.name
       where o.bucket_id = 'kiosk-punches';
  exception when others then null;
  end;
end $$;
revoke all on function public._org_objects(text) from public, anon, authenticated;

-- ── Org profile → Storage ───────────────────────────────────────────────────
create or replace function public.org_storage_usage(p_org text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_buckets jsonb; v_tables jsonb; v_files bigint; v_bytes bigint; v_db bigint;
  v_up30 bigint; v_days int; v_docs jsonb; v_purge jsonb; v_due jsonb;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;

  create temp table if not exists _so(bucket_id text, name text, bytes bigint, created_at timestamptz) on commit drop;
  truncate _so;
  insert into _so select * from public._org_objects(p_org);

  select coalesce(jsonb_agg(jsonb_build_object('bucket', bucket_id, 'files', f, 'bytes', b) order by b desc), '[]'::jsonb),
         coalesce(sum(f), 0), coalesce(sum(b), 0)
    into v_buckets, v_files, v_bytes
    from (select bucket_id, count(*) f, sum(bytes) b from _so group by 1) x;
  select coalesce(sum(bytes), 0) into v_up30 from _so where created_at > now() - interval '30 days';

  select coalesce(jsonb_agg(jsonb_build_object('table', table_name, 'rows', org_rows, 'bytes', est_bytes)
                            order by est_bytes desc), '[]'::jsonb),
         coalesce(sum(est_bytes), 0)
    into v_tables, v_db
    from (select * from public._org_db_estimate(p_org) order by est_bytes desc) t;

  select docs_retention_days into v_days from public.org_storage_policy where org_id = p_org;

  select jsonb_build_object('files', count(*), 'bytes', coalesce(sum(size_bytes), 0),
                            'oldest', min(created_at))
    into v_docs from public.voucher_documents where org_id = p_org;

  if coalesce(v_days, 0) > 0 then
    select jsonb_build_object('files', count(*), 'bytes', coalesce(sum(size_bytes), 0))
      into v_due from public.voucher_documents
     where org_id = p_org and created_at < now() - make_interval(days => v_days);
  end if;

  select to_jsonb(l) - 'id' - 'org_id' into v_purge
    from public.support_docs_purge_log l where l.org_id = p_org order by run_at desc limit 1;

  return jsonb_build_object(
    'files', v_files, 'file_bytes', v_bytes, 'uploaded_30d', v_up30,
    'buckets', v_buckets,
    'db_bytes', v_db, 'tables', (select coalesce(jsonb_agg(e), '[]'::jsonb)
                                  from (select e from jsonb_array_elements(v_tables) e limit 12) z),
    'total_bytes', v_bytes + v_db,
    'retention_days', v_days,
    'support_docs', v_docs,
    'due_now', v_due,
    'last_purge', v_purge);
end $$;
grant execute on function public.org_storage_usage(text) to authenticated;

-- ── Super Admin → Server overview ───────────────────────────────────────────
create or replace function public.platform_storage_overview()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;
  select jsonb_build_object(
    'db_bytes', pg_database_size(current_database()),
    'file_bytes', (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects),
    'files', (select count(*) from storage.objects),
    'uploaded_30d', (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects
                      where created_at > now() - interval '30 days'),
    'uploaded_7d', (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects
                     where created_at > now() - interval '7 days'),
    'buckets', (select coalesce(jsonb_agg(jsonb_build_object('bucket', bucket_id, 'files', f, 'bytes', b) order by b desc), '[]'::jsonb)
                  from (select bucket_id, count(*) f, coalesce(sum((metadata ->> 'size')::bigint), 0) b
                          from storage.objects group by 1) x),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object('month', m, 'files', f, 'bytes', b) order by m), '[]'::jsonb)
                  from (select to_char(date_trunc('month', created_at), 'YYYY-MM') m, count(*) f,
                               coalesce(sum((metadata ->> 'size')::bigint), 0) b
                          from storage.objects where created_at > date_trunc('month', now()) - interval '5 months'
                         group by 1) x),
    'orgs', (select coalesce(jsonb_agg(jsonb_build_object('org_id', o.id, 'name', o.name, 'files', x.f, 'bytes', x.b)
                                        order by x.b desc), '[]'::jsonb)
               from (select split_part(name, '/', 1) oid, count(*) f, coalesce(sum((metadata ->> 'size')::bigint), 0) b
                       from storage.objects group by 1) x
               join public.orgs o on o.id = x.oid),
    'largest_tables', (select coalesce(jsonb_agg(jsonb_build_object('table', relname, 'bytes', sz) order by sz desc), '[]'::jsonb)
                         from (select c.relname, pg_total_relation_size(c.oid) sz
                                 from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
                                where c.relkind = 'r' order by 2 desc limit 10) t)
  ) into r;
  return r;
end $$;
grant execute on function public.platform_storage_overview() to authenticated;

-- ── Retention setting (Super Admin) ─────────────────────────────────────────
create or replace function public.set_org_docs_retention(p_org text, p_days int)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_name text;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;
  if p_days is not null and p_days > 0 and p_days < 30 then
    raise exception 'Minimum retention is 30 days';
  end if;
  select name into v_name from public.users
   where account_id = public.current_account_id() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
   limit 1;
  insert into public.org_storage_policy(org_id, docs_retention_days, updated_at, updated_by_name)
  values (p_org, nullif(p_days, 0), now(), v_name)
  on conflict (org_id) do update
    set docs_retention_days = excluded.docs_retention_days, updated_at = now(), updated_by_name = excluded.updated_by_name;
end $$;
grant execute on function public.set_org_docs_retention(text, int) to authenticated;

-- ── Used by the purge edge function (service role only) ─────────────────────
drop function if exists public.support_docs_due_for_purge(int);
create or replace function public.support_docs_due_for_purge(p_limit int default 500, p_org text default null)
returns table(id text, org_id text, bucket text, path text, size_bytes bigint)
language sql stable security definer set search_path to 'public' as $$
  select d.id::text, d.org_id::text, d.bucket::text, d.path::text, coalesce(d.size_bytes, 0)::bigint
    from public.voucher_documents d
    join public.org_storage_policy p on p.org_id = d.org_id and coalesce(p.docs_retention_days, 0) >= 30
   where d.created_at < now() - make_interval(days => p.docs_retention_days)
     and (p_org is null or d.org_id = p_org)
   order by d.created_at
   limit p_limit;
$$;
revoke all on function public.support_docs_due_for_purge(int, text) from public, anon, authenticated;
grant execute on function public.support_docs_due_for_purge(int, text) to service_role;

create or replace function public.log_support_docs_purge(p_org text, p_files int, p_bytes bigint, p_note text default null)
returns void language sql security definer set search_path to 'public' as $$
  insert into public.support_docs_purge_log(org_id, files, bytes, older_than, note)
  select p_org, p_files, p_bytes,
         (now() - make_interval(days => coalesce((select docs_retention_days from public.org_storage_policy
                                                   where org_id = p_org), 0)))::date,
         p_note;
$$;
revoke all on function public.log_support_docs_purge(text, int, bigint, text) from public, anon, authenticated;
grant execute on function public.log_support_docs_purge(text, int, bigint, text) to service_role;

-- ── Daily purge at 02:15 PKT (21:15 UTC) ────────────────────────────────────
-- Needs the purge-support-docs edge function deployed first. Uses the same
-- `edge_service_key` Vault secret as the other daily jobs.
DO $do$
declare v_key text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — purge not scheduled'; return;
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_service_key' limit 1;
  if v_key is null then raise notice 'edge_service_key missing in Vault — purge not scheduled'; return; end if;
  if exists (select 1 from cron.job where jobname = 'purge-support-docs') then
    perform cron.unschedule('purge-support-docs');
  end if;
  perform cron.schedule('purge-support-docs', '15 21 * * *', format($cron$
    select net.http_post(
      url     := 'https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/purge-support-docs',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s'),
      body    := '{}'::jsonb);
  $cron$, v_key));
  raise notice 'Scheduled purge-support-docs daily 21:15 UTC.';
end $do$;

-- ── Find the OLD backend default (so it can be switched off) ────────────────
-- Lists any scheduled job or database function that already deletes support
-- documents. Please send me this output if it returns rows.
select 'cron job' as kind, jobname as name, schedule, left(command, 300) as detail
  from cron.job
 where jobname <> 'purge-support-docs'
   and (command ilike '%document%' or command ilike '%purge%' or command ilike '%cleanup%' or command ilike '%storage%')
union all
select 'function', p.proname, null, left(pg_get_functiondef(p.oid), 300)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
 where p.prokind = 'f'
   and pg_get_functiondef(p.oid) ilike '%delete%'
   and (pg_get_functiondef(p.oid) ilike '%voucher_documents%' or pg_get_functiondef(p.oid) ilike '%storage.objects%')
   and p.proname not in ('support_docs_due_for_purge', 'log_support_docs_purge');
