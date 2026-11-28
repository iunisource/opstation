-- 486 — Admin Settings → Notifications: admins can manage it too (was master
-- admin only). Who gets which alert, pause / resume, and "Send test".
-- Safe to run again.

drop policy if exists nr_master on public.notification_rules;
create policy nr_master on public.notification_rules for all to authenticated
  using (public._is_org_admin(org_id)) with check (public._is_org_admin(org_id));

drop policy if exists nes_master on public.notification_event_state;
create policy nes_master on public.notification_event_state for all to authenticated
  using (public._is_org_admin(org_id)) with check (public._is_org_admin(org_id));

-- "Send test": same check, admins allowed.
do $$
declare d text;
begin
  select pg_get_functiondef('public.notify_test_event(text, text, text)'::regprocedure) into d;
  if position('_is_org_master(p_org)' in d) > 0 then
    d := replace(d, 'public._is_org_master(p_org)', 'public._is_org_admin(p_org)');
    d := replace(d, 'Only the master admin can send tests.', 'Only admins can send tests.');
    execute d;
  end if;
end $$;

select 'notifications: admins allowed' as status;
