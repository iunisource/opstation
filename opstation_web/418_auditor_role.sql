-- 418 — New role "Auditor": survey-only field user (placement audits and
-- competitor spottings). Allows the role on users, and blocks auditors from
-- changing customer information anywhere (app, web, imports). Safe to run again.

-- 1) Allow 'auditor' wherever the users.role values are restricted.
do $$
declare c record; v_def text; v_type text;
begin
  -- a) role column is an enum type → add the value
  select t.typname into v_type
    from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = 'public.users'::regclass and a.attname = 'role' and t.typtype = 'e';
  if v_type is not null then
    execute format('alter type %I add value if not exists %L', v_type, 'auditor');
  end if;
  -- b) a CHECK constraint lists the roles → rebuild it with 'auditor'
  for c in select conname, pg_get_constraintdef(oid) as def
             from pg_constraint
            where conrelid = 'public.users'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%surveyor%'
              and pg_get_constraintdef(oid) not ilike '%auditor%' loop
    v_def := replace(c.def, '''surveyor''::text', '''surveyor''::text, ''auditor''::text');
    if v_def = c.def then
      v_def := replace(c.def, '''surveyor''', '''surveyor'', ''auditor''');
    end if;
    execute format('alter table public.users drop constraint %I', c.conname);
    execute format('alter table public.users add constraint %I %s', c.conname, v_def);
  end loop;
end $$;

-- 2) Auditors can't add, change or delete customers.
create or replace function public.trg_customer_auditor_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_org text := coalesce(NEW.org_id, OLD.org_id);
begin
  if auth.uid() is not null and exists (
       select 1 from public.users u
        where u.org_id = v_org and u.role = 'auditor' and coalesce(u.is_active, true)
          and (u.account_id = public.current_account_id()
               or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))) then
    raise exception 'Auditors cannot change customer information.';
  end if;
  return coalesce(NEW, OLD);
end $$;

drop trigger if exists customer_auditor_guard on public.customers;
create trigger customer_auditor_guard before insert or update or delete on public.customers
  for each row execute function public.trg_customer_auditor_guard();

notify pgrst, 'reload schema';

-- Check: the role rule on users now (should mention auditor, or be empty).
select conname, pg_get_constraintdef(oid) as rule
  from pg_constraint where conrelid = 'public.users'::regclass and contype = 'c'
   and pg_get_constraintdef(oid) ilike '%surveyor%';
