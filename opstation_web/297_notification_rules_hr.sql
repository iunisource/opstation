-- 297 — Notifications centre: HR events.
--   hr_leave_pending      leave request saved (waiting for a decision)   → branch = employee's branch
--   hr_leave_approved     leave approved   → can go to "Document creator" (who applied it)
--   hr_leave_rejected     leave rejected   → can go to "Document creator"
--   hr_employee_pending   new employee saved by a non-admin, waiting for approval
--   payroll_finalized     payroll run finalized (someone pressed Finalize) — ready for payment
--   payroll_paid          payroll run marked paid
-- Like every event: nobody gets anything until added in Admin Settings → Notifications.
-- The daily attendance summary and the per-employee punch emails are NOT touched.
-- Requires 296. Safe to run again.

create or replace function public.trg_notify_hr_events()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  n jsonb := to_jsonb(NEW);
  o jsonb := case when TG_OP = 'UPDATE' then to_jsonb(OLD) else '{}'::jsonb end;
  v_org text := n->>'org_id';
  v_id text := n->>'id';
  v_emp record; v_type text; v_period text; v_body text;
begin
  begin
    if v_org is null then return NEW; end if;

    if TG_TABLE_NAME = 'hr_leave_requests' then
      select full_name, branch_id into v_emp from hr_employees where id = n->>'employee_id';
      select name into v_type from hr_leave_types where id = n->>'leave_type_id';
      v_body := coalesce(v_emp.full_name, 'Employee') || coalesce(' · ' || v_type, '')
             || ' · ' || coalesce(to_char((n->>'from_date')::date, 'DD Mon'), '')
             || case when coalesce(n->>'to_date', '') <> '' and n->>'to_date' <> n->>'from_date'
                     then ' – ' || to_char((n->>'to_date')::date, 'DD Mon') else '' end
             || coalesce(' (' || nullif(n->>'days', '') || ' day' || case when n->>'days' = '1' then '' else 's' end || ')', '');
      if _became(n, o, 'status', 'pending') then
        perform notify_event(v_org, 'hr_leave_pending', v_emp.branch_id, n->>'applied_by',
          'Leave request waiting for approval',
          v_body || coalesce(E'\nReason: ' || nullif(n->>'reason', ''), ''), '/hr/leave');
      elsif TG_OP = 'UPDATE' and coalesce(o->>'status', '') = 'pending' and _became(n, o, 'status', 'approved') then
        perform notify_event(v_org, 'hr_leave_approved', v_emp.branch_id, n->>'applied_by',
          'Leave approved', v_body, '/hr/leave');
      elsif TG_OP = 'UPDATE' and coalesce(o->>'status', '') = 'pending' and _became(n, o, 'status', 'rejected') then
        perform notify_event(v_org, 'hr_leave_rejected', v_emp.branch_id, n->>'applied_by',
          'Leave rejected', v_body, '/hr/leave');
      end if;

    elsif TG_TABLE_NAME = 'hr_employees' then
      if _became(n, o, 'approval_status', 'pending') then
        perform notify_event(v_org, 'hr_employee_pending', n->>'branch_id', n->>'created_by',
          'New employee waiting for approval',
          coalesce(n->>'full_name', '') || coalesce(' · ' || nullif(n->>'employee_code', ''), ''),
          '/hr/employees?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'hr_payroll_runs' then
      v_period := coalesce(to_char(to_date((n->>'period') || '-01', 'YYYY-MM-DD'), 'Mon YYYY'), n->>'period', '');
      if _became(n, o, 'status', 'finalized') then
        perform notify_event(v_org, 'payroll_finalized', n->>'branch_id', n->>'created_by',
          'Payroll finalized — ready for payment', 'Payroll for ' || v_period || ' was finalized.', '/hr/payroll');
      elsif _became(n, o, 'status', 'paid') then
        perform notify_event(v_org, 'payroll_paid', n->>'branch_id', n->>'created_by',
          'Payroll marked paid', 'Payroll for ' || v_period || ' was marked paid.', '/hr/payroll');
      end if;
    end if;
  exception when others then
    null;  -- never block HR saves
  end;
  return NEW;
end $$;

do $$
declare tbl text;
begin
  foreach tbl in array array['hr_leave_requests', 'hr_employees', 'hr_payroll_runs'] loop
    if to_regclass('public.' || tbl) is not null then
      execute format('drop trigger if exists zz_notify_hr_events on public.%I', tbl);
      execute format('create trigger zz_notify_hr_events after insert or update on public.%I
                      for each row execute function public.trg_notify_hr_events()', tbl);
    end if;
  end loop;
end $$;
