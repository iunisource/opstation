-- 351 — Kiosk punch photos: delete after 40 days (per-org, Super Admin can change).
-- Before this there was NO cleanup of kiosk punch photos anywhere in the code.
-- Run the CHECK at the bottom too — it shows whether something in the database
-- was already deleting them.
--
-- • org_storage_policy.kiosk_retention_days: null = default 40 days, 0 = keep forever
-- • set_org_kiosk_retention(org, days)      → Super Admin only (min 7 days)
-- • kiosk_photos_due_for_purge / kiosk_photos_mark_purged → purge-support-docs
--   edge function (runs nightly, same job as support documents)
-- • Photos not linked to any attendance row (e.g. an ignored double scan) are
--   removed after the default 40 days.
-- Requires 350. Safe to run again.

alter table public.org_storage_policy add column if not exists kiosk_retention_days int;
alter table public.support_docs_purge_log add column if not exists kind text default 'docs';

-- ── Setting (Super Admin) ────────────────────────────────────────────────────
create or replace function public.set_org_kiosk_retention(p_org text, p_days int)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_name text;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;
  if p_days is not null and p_days > 0 and p_days < 7 then
    raise exception 'Minimum is 7 days';
  end if;
  select name into v_name from public.users
   where account_id = public.current_account_id() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
   limit 1;
  insert into public.org_storage_policy(org_id, kiosk_retention_days, updated_at, updated_by_name)
  values (p_org, p_days, now(), v_name)
  on conflict (org_id) do update
    set kiosk_retention_days = excluded.kiosk_retention_days, updated_at = now(), updated_by_name = excluded.updated_by_name;
end $$;
grant execute on function public.set_org_kiosk_retention(text, int) to authenticated;

-- ── Which kiosk photos are due ───────────────────────────────────────────────
create or replace function public.kiosk_photos_due_for_purge(p_limit int default 500, p_org text default null)
returns table(name text, org_id text, bytes bigint)
language sql stable security definer set search_path to 'public', 'storage' as $$
  with links as (
    select a.org_id::text as org_id, split_part(a.punch_in_photo, '/kiosk-punches/', 2) as nm
      from public.hr_attendance a where a.punch_in_photo like '%/kiosk-punches/%'
    union all
    select a.org_id::text, split_part(a.punch_out_photo, '/kiosk-punches/', 2)
      from public.hr_attendance a where a.punch_out_photo like '%/kiosk-punches/%'
  )
  select o.name::text, l.org_id, coalesce((o.metadata ->> 'size')::bigint, 0)
    from storage.objects o
    left join links l on l.nm = o.name
    left join public.org_storage_policy p on p.org_id = l.org_id
   where o.bucket_id = 'kiosk-punches'
     and coalesce(p.kiosk_retention_days, 40) > 0
     and o.created_at < now() - make_interval(days => coalesce(p.kiosk_retention_days, 40))
     and (p_org is null or l.org_id = p_org)
   order by o.created_at
   limit p_limit;
$$;
revoke all on function public.kiosk_photos_due_for_purge(int, text) from public, anon, authenticated;
grant execute on function public.kiosk_photos_due_for_purge(int, text) to service_role;

-- After the files are removed: clear the photo links on attendance (the
-- attendance times themselves are untouched).
create or replace function public.kiosk_photos_mark_purged(p_names text[])
returns int language plpgsql security definer set search_path to 'public' as $$
declare n1 int; n2 int;
begin
  update public.hr_attendance set punch_in_photo = null
   where punch_in_photo like '%/kiosk-punches/%'
     and split_part(punch_in_photo, '/kiosk-punches/', 2) = any (p_names);
  get diagnostics n1 = row_count;
  update public.hr_attendance set punch_out_photo = null
   where punch_out_photo like '%/kiosk-punches/%'
     and split_part(punch_out_photo, '/kiosk-punches/', 2) = any (p_names);
  get diagnostics n2 = row_count;
  return n1 + n2;
end $$;
revoke all on function public.kiosk_photos_mark_purged(text[]) from public, anon, authenticated;
grant execute on function public.kiosk_photos_mark_purged(text[]) to service_role;

-- Log with a kind ('docs' | 'kiosk').
drop function if exists public.log_support_docs_purge(text, int, bigint, text);
create or replace function public.log_support_docs_purge(p_org text, p_files int, p_bytes bigint,
                                                         p_note text default null, p_kind text default 'docs')
returns void language sql security definer set search_path to 'public' as $$
  insert into public.support_docs_purge_log(org_id, files, bytes, older_than, note, kind)
  select p_org, p_files, p_bytes,
         (now() - make_interval(days => case when p_kind = 'kiosk'
            then coalesce((select kiosk_retention_days from public.org_storage_policy where org_id = p_org), 40)
            else coalesce((select docs_retention_days from public.org_storage_policy where org_id = p_org), 0) end))::date,
         p_note, coalesce(p_kind, 'docs');
$$;
revoke all on function public.log_support_docs_purge(text, int, bigint, text, text) from public, anon, authenticated;
grant execute on function public.log_support_docs_purge(text, int, bigint, text, text) to service_role;

-- ── Org profile → Storage: add kiosk figures ────────────────────────────────
create or replace function public.org_kiosk_usage(p_org text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_days int; v_set int; r jsonb;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;
  select kiosk_retention_days into v_set from public.org_storage_policy where org_id = p_org;
  v_days := coalesce(v_set, 40);
  select jsonb_build_object(
      'retention_days', v_days,
      'is_default', v_set is null,
      'files', count(*), 'bytes', coalesce(sum(bytes), 0), 'oldest', min(created_at),
      'due_files', count(*) filter (where v_days > 0 and created_at < now() - make_interval(days => v_days)),
      'due_bytes', coalesce(sum(bytes) filter (where v_days > 0 and created_at < now() - make_interval(days => v_days)), 0))
    into r
    from public._org_objects(p_org) o where o.bucket_id = 'kiosk-punches';
  return r || jsonb_build_object('last_purge',
    (select to_jsonb(l) - 'id' - 'org_id' from public.support_docs_purge_log l
      where l.org_id = p_org and l.kind = 'kiosk' order by run_at desc limit 1));
end $$;
grant execute on function public.org_kiosk_usage(text) to authenticated;

-- Support-docs "last run" must ignore kiosk runs.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.org_storage_usage(text)'::regprocedure);
  if d not ilike '%l.kind%' then
    d := replace(d, 'where l.org_id = p_org order by run_at desc limit 1',
                    'where l.org_id = p_org and coalesce(l.kind, ''docs'') = ''docs'' order by run_at desc limit 1');
    execute d;
  end if;
end $$;

-- ── CHECK: was anything already deleting kiosk photos? ───────────────────────
-- Rows here = an existing job/function; send me the output if any appear.
select 'cron job' as kind, jobname as name, schedule, left(command, 300) as detail
  from cron.job
 where command ilike '%kiosk%'
union all
select 'function', p.proname, null, left(pg_get_functiondef(p.oid), 300)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
 where p.prokind = 'f' and pg_get_functiondef(p.oid) ilike '%kiosk-punches%'
   and p.proname not in ('kiosk_photos_due_for_purge', 'kiosk_photos_mark_purged', '_org_objects', 'org_kiosk_usage');

-- How old is the oldest kiosk photo today? (If older than 40 days, nothing was cleaning them.)
select count(*) as kiosk_photos, pg_size_pretty(coalesce(sum((metadata ->> 'size')::bigint), 0)) as size,
       min(created_at)::date as oldest,
       count(*) filter (where created_at < now() - interval '40 days') as older_than_40_days
  from storage.objects where bucket_id = 'kiosk-punches';
