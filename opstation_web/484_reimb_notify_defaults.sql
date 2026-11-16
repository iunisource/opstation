-- 484 — Reimbursement push alerts switched on by default (Admin Settings →
-- Notifications → Reimbursements; each can still be changed there):
--   • "Trip summary submitted for approval" → the approvers
--     (Admin Settings → Reimbursement approvals; nobody picked = admins)
--   • "Reimbursement approved" → the driver / salesperson who claimed (Creator)
-- Only adds what is missing; never removes a rule someone set. Safe to run again.

-- Approvers get "submitted"
insert into public.notification_rules (org_id, event_key, user_id, push)
select distinct o.id, 'reimb_submitted', u.id, true
from public.orgs o
join public.users u on u.org_id = o.id and coalesce(u.is_active, true)
where (
  -- picked approvers
  u.id = any (select btrim(x) from public.app_config c,
                     unnest(string_to_array(coalesce(c.value, ''), ',')) x
               where c.org_id = o.id and c.key = 'org.reimb_approvers')
  or (
  -- nobody picked → admins
  not exists (select 1 from public.app_config c
               where c.org_id = o.id and c.key = 'org.reimb_approvers' and btrim(coalesce(c.value, '')) <> '')
  and u.role in ('admin', 'masterAdmin'))
)
and not exists (select 1 from public.notification_rules r
                 where r.org_id = o.id and r.event_key = 'reimb_submitted')
on conflict do nothing;

-- Claimant gets "approved"
insert into public.notification_rules (org_id, event_key, user_id, push)
select o.id, 'reimb_approved', '__creator__', true
from public.orgs o
on conflict do nothing;

select event_key, count(*) as rules from public.notification_rules
where event_key in ('reimb_submitted', 'reimb_approved') group by 1;
