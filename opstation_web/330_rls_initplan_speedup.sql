-- 330 — Speed up row-level security (RLS) everywhere.
--
-- Problem: policies like  (is_super_admin() OR org_id = current_user_org_id())
-- call those functions once PER ROW. Each call looks the user up again, so a
-- plain "read all route stops" (5k rows) took ~6 s and sign-ins timed out.
--
-- Fix (Supabase's own recommendation): wrap the per-user functions as
--   (SELECT is_super_admin())  /  (SELECT current_user_org_id())  / ...
-- so Postgres works them out ONCE per request instead of once per row.
-- Same rules, same results — only faster. Uses ALTER POLICY (no drop/recreate).
-- Safe to run again (already-wrapped calls are left alone). Busy tables are
-- skipped, not waited on — run it again until still_per_row = 0.

-- Helpers look users up by e-mail / account — make those lookups indexed.
create index if not exists users_lower_email_idx on public.users (lower(email));
create index if not exists users_account_id_idx  on public.users (account_id);

do $$
declare
  r   record;
  fns text[] := array['is_super_admin', 'current_user_org_id', 'current_user_role', 'current_org',
                      'current_account_id'];
  f   text;
  q   text;
  c   text;
  sql text;
  n   int := 0;
  skipped int := 0;
begin
  -- Never wait long for a busy table: skip it and pick it up on the next run.
  -- (Waiting while holding locks on already-changed tables is what deadlocked.)
  perform set_config('lock_timeout', '500ms', true);
  for r in
    select schemaname, tablename, policyname, cmd, qual, with_check
    from pg_policies
    where schemaname = 'public'
  loop
    q := r.qual; c := r.with_check;
    foreach f in array fns loop
      -- wrap  fn()  /  public.fn()  unless it is already "SELECT fn()"
      q := regexp_replace(q, '(?<!SELECT )\m((public\.)?' || f || '\(\))', '(SELECT \1)', 'g');
      c := regexp_replace(c, '(?<!SELECT )\m((public\.)?' || f || '\(\))', '(SELECT \1)', 'g');
    end loop;

    if q is distinct from r.qual or c is distinct from r.with_check then
      sql := format('alter policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
      if q is not null then sql := sql || ' using (' || q || ')'; end if;
      if c is not null then sql := sql || ' with check (' || c || ')'; end if;
      begin
        execute sql;
        n := n + 1;
      exception when lock_not_available or deadlock_detected then
        skipped := skipped + 1;   -- busy right now; run the script again
      end;
    end if;
  end loop;
  raise notice 'Policies sped up: %, skipped (busy): %', n, skipped;
end $$;

-- Result: how many policies still call the helpers per row (should be 0).
select count(*) filter (where qual ~ '(?<!SELECT )\m(public\.)?(is_super_admin|current_user_org_id|current_user_role|current_org|current_account_id)\(\)'
                           or with_check ~ '(?<!SELECT )\m(public\.)?(is_super_admin|current_user_org_id|current_user_role|current_org|current_account_id)\(\)') as still_per_row,
       count(*) filter (where qual ~ 'SELECT (public\.)?(is_super_admin|current_user_org_id|current_user_role)' ) as now_once_per_request,
       count(*) as total_policies
from pg_policies where schemaname = 'public';
