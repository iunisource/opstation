-- 342 — Employee profile history (Employee Directory ▸ profile ▸ History)
-- A trigger records every change to an employee profile, one row per changed
-- field: old value → new value, who, when. Works for every screen, import, kiosk
-- card change or SQL, because it runs in the database.
-- Sensitive fields (salary, bank, CNIC, advances) are visible to admins only —
-- enforced by row security, not just hidden on screen.
-- A baseline snapshot of every current profile is saved on the first run, so
-- history starts from today with the profile as it stands.
-- Safe to run again.

set lock_timeout = '5s';

create table if not exists public.hr_employee_history (
  id              bigserial primary key,
  org_id          text not null,
  employee_id     text not null,
  event_type      text not null,              -- baseline | created | updated | deleted
  field           text not null,
  old_value       text,
  new_value       text,
  sensitive       boolean not null default false,
  changed_at      timestamptz not null default now(),
  changed_by      text,
  changed_by_name text
);
create index if not exists idx_hr_emp_hist on public.hr_employee_history(org_id, employee_id, changed_at desc);

-- Admins of the org (admin / master admin / super admin).
create or replace function public._is_org_admin(p_org text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.users u
     where u.org_id = p_org
       and u.role in ('admin', 'masterAdmin', 'superAdmin')
       and coalesce(u.is_active, true)
       and (u.account_id = public.current_account_id()
            or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))));
$$;

alter table public.hr_employee_history enable row level security;
drop policy if exists heh_read on public.hr_employee_history;
create policy heh_read on public.hr_employee_history
  for select to authenticated
  using (public._is_org_member(org_id) and (not sensitive or public._is_org_admin(org_id)));
grant select on public.hr_employee_history to authenticated;
-- No insert/update/delete policies: only the trigger writes, nobody edits history.

create or replace function public._hr_emp_sensitive(f text)
returns boolean language sql immutable as $$
  select f in ('basic_salary', 'bank_name', 'bank_account', 'cnic',
               'advance_account_id', 'advance_installment');
$$;

create or replace function public.trg_hr_employee_history()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  n jsonb := case when TG_OP = 'DELETE' then '{}'::jsonb else to_jsonb(NEW) end;
  o jsonb := case when TG_OP = 'INSERT' then '{}'::jsonb else to_jsonb(OLD) end;
  r jsonb := case when TG_OP = 'DELETE' then o else n end;
  f text; ov text; nv text;
  v_uid text; v_name text;
  -- bookkeeping columns that change on every save — not profile information
  skip text[] := array['updated_at', 'created_at', 'created_by', 'approved_by', 'approved_at',
                       'voided_by', 'voided_at', 'left_marked_by', 'left_marked_at', 'org_id', 'id'];
begin
  begin
    select u.id, u.name into v_uid, v_name
      from users u
     where u.org_id = r ->> 'org_id'
       and (u.account_id = public.current_account_id()
            or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
     limit 1;
    v_name := coalesce(v_name, case when auth.uid() is null then 'System' end);

    if TG_OP = 'DELETE' then
      insert into hr_employee_history(org_id, employee_id, event_type, field, old_value, changed_by, changed_by_name)
      values (o ->> 'org_id', o ->> 'id', 'deleted', 'employee',
              coalesce(o ->> 'employee_code', '') || ' ' || coalesce(o ->> 'full_name', ''), v_uid, v_name);
      return OLD;
    end if;

    for f in select k from (select jsonb_object_keys(n) k union select jsonb_object_keys(o)) x order by 1 loop
      continue when f = any (skip);
      ov := nullif(btrim(o ->> f), '');
      nv := nullif(btrim(n ->> f), '');
      continue when ov is not distinct from nv;
      -- 35000 vs 35000.00, true vs 'true': not a change
      if ov ~ '^-?[0-9]+(\.[0-9]+)?$' and nv ~ '^-?[0-9]+(\.[0-9]+)?$' and ov::numeric = nv::numeric then
        continue;
      end if;
      continue when TG_OP = 'INSERT' and nv is null;
      insert into hr_employee_history(org_id, employee_id, event_type, field, old_value, new_value,
                                      sensitive, changed_by, changed_by_name)
      values (n ->> 'org_id', n ->> 'id', case when TG_OP = 'INSERT' then 'created' else 'updated' end,
              f, ov, nv, public._hr_emp_sensitive(f), v_uid, v_name);
    end loop;
  exception when others then
    null; -- never block an employee save
  end;
  return coalesce(NEW, OLD);
end $$;

drop trigger if exists zz_hr_employee_history on public.hr_employees;
create trigger zz_hr_employee_history after insert or update or delete on public.hr_employees
  for each row execute function public.trg_hr_employee_history();

-- Baseline: today's profile of every employee (only once per employee).
insert into public.hr_employee_history(org_id, employee_id, event_type, field, new_value, sensitive, changed_by_name)
select e.org_id, e.id, 'baseline', kv.key, nullif(btrim(kv.value), ''), public._hr_emp_sensitive(kv.key),
       'Profile when history started'
  from public.hr_employees e
  cross join lateral jsonb_each_text(to_jsonb(e)) kv
 where kv.key <> all (array['updated_at', 'created_at', 'created_by', 'approved_by', 'approved_at',
                            'voided_by', 'voided_at', 'left_marked_by', 'left_marked_at', 'org_id', 'id'])
   and nullif(btrim(kv.value), '') is not null
   and not exists (select 1 from public.hr_employee_history h
                    where h.employee_id = e.id and h.event_type = 'baseline');

reset lock_timeout;

select count(distinct employee_id) as employees_with_baseline, count(*) as baseline_rows
  from public.hr_employee_history where event_type = 'baseline';
