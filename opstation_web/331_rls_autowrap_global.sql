-- 331 — Global, permanent fix for slow row-level security (RLS).
--
-- 330 fixed the existing rules once. This makes it stick:
--   1. rls_optimize_policy(oid)  — rewrites ONE policy so per-user helpers run
--      once per request instead of once per row:
--        is_super_admin(), current_user_org_id(), current_user_role(),
--        current_org(), current_account_id(), auth.uid(), auth.jwt()
--          → (SELECT fn())
--        _is_org_member(col)  → (col = ANY ((SELECT _my_org_ids())::text[]))
--   2. rls_optimize_all()       — runs it over every public policy (skips busy
--      tables instead of deadlocking; run again until it reports 0 left).
--   3. Event trigger            — every future CREATE POLICY / ALTER POLICY is
--      optimised automatically, so new features can't reintroduce the problem.
-- Same rules, same results — only faster. Safe to run again.

-- All orgs the signed-in user belongs to — same test as _is_org_member(), but
-- computed once per request as an array.
create or replace function public._my_org_ids()
returns text[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(distinct u.org_id), '{}')
  from public.users u
  where coalesce(u.is_active, true)
    and u.org_id is not null
    and (u.account_id = public.current_account_id()
         or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;
grant execute on function public._my_org_ids() to anon, authenticated;

create or replace function public._rls_rewrite(p text)
returns text language plpgsql immutable as $$
declare
  f text;
  s text := p;
begin
  if s is null then return null; end if;
  foreach f in array array['is_super_admin', 'current_user_org_id', 'current_user_role',
                           'current_org', 'current_account_id'] loop
    s := regexp_replace(s, '(?<!SELECT )\m((public\.)?' || f || '\(\))', '(SELECT \1)', 'g');
  end loop;
  s := regexp_replace(s, '(?<!SELECT )\m(auth\.(uid|jwt)\(\))', '(SELECT \1)', 'g');
  -- _is_org_member(<column>) → (<column> = ANY ((SELECT _my_org_ids())))
  s := regexp_replace(s, '\m(public\.)?_is_org_member\(([A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?)\)',
                      '(\2 = ANY ((SELECT public._my_org_ids())::text[]))', 'g');
  return s;
end $$;

-- Optimise one policy. Returns true if it changed something.
create or replace function public.rls_optimize_policy(p_oid oid)
returns boolean language plpgsql security definer set search_path to 'public', 'pg_catalog' as $$
declare
  pol record; q text; c text; nq text; nc text; sql text;
begin
  select p.polname, p.polrelid, n.nspname,
         pg_get_expr(p.polqual, p.polrelid) as qual,
         pg_get_expr(p.polwithcheck, p.polrelid) as wc
    into pol
    from pg_policy p join pg_class t on t.oid = p.polrelid join pg_namespace n on n.oid = t.relnamespace
   where p.oid = p_oid;
  if not found or pol.nspname <> 'public' then return false; end if;
  q := pol.qual; c := pol.wc;
  nq := public._rls_rewrite(q); nc := public._rls_rewrite(c);
  if nq is not distinct from q and nc is not distinct from c then return false; end if;
  sql := format('alter policy %I on %s', pol.polname, pol.polrelid::regclass);
  if nq is not null then sql := sql || ' using (' || nq || ')'; end if;
  if nc is not null then sql := sql || ' with check (' || nc || ')'; end if;
  perform set_config('opstation.rls_autowrap', 'busy', true);   -- don't re-trigger ourselves
  execute sql;
  perform set_config('opstation.rls_autowrap', '', true);
  return true;
end $$;

-- Optimise everything; busy tables are skipped (run again to finish them).
drop function if exists public.rls_optimize_all();
create or replace function public.rls_optimize_all()
returns table(changed int, skipped_busy int, failed int, still_slow int)
language plpgsql security definer set search_path to 'public', 'pg_catalog' as $$
declare r record; n int := 0; s int := 0; e int := 0;
begin
  perform set_config('lock_timeout', '500ms', true);
  for r in
    select p.oid from pg_policy p join pg_class t on t.oid = p.polrelid
    join pg_namespace ns on ns.oid = t.relnamespace where ns.nspname = 'public'
  loop
    begin
      if public.rls_optimize_policy(r.oid) then n := n + 1; end if;
    exception
      when lock_not_available or deadlock_detected then s := s + 1;
      when others then e := e + 1;   -- left exactly as it was
        raise warning 'RLS optimise failed for policy %: %', r.oid, sqlerrm;
    end;
  end loop;
  return query
    select n, s, e, (select count(*)::int from pg_policy p join pg_class t on t.oid = p.polrelid
                    join pg_namespace ns on ns.oid = t.relnamespace
                   where ns.nspname = 'public'
                     and (public._rls_rewrite(pg_get_expr(p.polqual, p.polrelid)) is distinct from pg_get_expr(p.polqual, p.polrelid)
                       or public._rls_rewrite(pg_get_expr(p.polwithcheck, p.polrelid)) is distinct from pg_get_expr(p.polwithcheck, p.polrelid)));
end $$;
revoke all on function public.rls_optimize_all() from public, anon, authenticated;
revoke all on function public.rls_optimize_policy(oid) from public, anon, authenticated;

-- Auto-optimise every future CREATE / ALTER POLICY.
create or replace function public._rls_autowrap()
returns event_trigger language plpgsql security definer set search_path to 'public', 'pg_catalog' as $$
declare obj record;
begin
  if current_setting('opstation.rls_autowrap', true) = 'busy' then return; end if;
  for obj in select * from pg_event_trigger_ddl_commands()
             where command_tag in ('CREATE POLICY', 'ALTER POLICY') loop
    begin
      perform public.rls_optimize_policy(obj.objid);
    exception when others then
      raise warning 'RLS auto-optimise skipped (%): %', obj.object_identity, sqlerrm;
    end;
  end loop;
end $$;

do $$
begin
  drop event trigger if exists rls_autowrap;
  create event trigger rls_autowrap on ddl_command_end
    when tag in ('CREATE POLICY', 'ALTER POLICY')
    execute function public._rls_autowrap();
exception when insufficient_privilege then
  raise warning 'Event trigger not allowed on this project — run  select * from rls_optimize_all();  after adding new policies.';
end $$;

-- Apply now. Run this line again until still_slow = 0.
select * from public.rls_optimize_all();
