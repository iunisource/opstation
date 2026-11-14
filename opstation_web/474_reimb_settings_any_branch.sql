-- 474 — Reimbursements: read "Rate per km" and "After approval" even when the
-- setting row was saved with a branch (it was ignored, so approvals got no
-- rate / amount and Mark paid said "no rate per km set"). The org-wide row
-- (no branch) wins; otherwise the most recently saved one. Safe to run again.

create or replace function public._reimb_cfg(p_org text, p_key text)
returns text language sql stable security definer set search_path to 'public' as $$
  select nullif(btrim(value), '') from app_config
   where org_id = p_org and key = p_key and nullif(btrim(value), '') is not null
   order by (branch_id is null) desc, ctid desc
   limit 1
$$;

create or replace function public._reimb_rate(p_org text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select case when v ~ '^[0-9]+(\.[0-9]+)?$' and v::numeric > 0 then v::numeric end
    from (select coalesce(public._reimb_cfg(p_org, 'org.reimb_rate_km'), '') as v) x
$$;

create or replace function public._reimb_mode(p_org text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(public._reimb_cfg(p_org, 'org.reimb_after_approval'), 'mark_paid')
$$;

-- Approved claims that got no rate (because of the above): fill rate and amount now.
update public.reimb_claims c
   set rate = public._reimb_rate(c.org_id),
       amount = round(coalesce(c.unpaid_km, public._reimb_unpaid_km(c.id)) * public._reimb_rate(c.org_id))
 where c.status = 'approved' and c.rate is null and c.paid_amount is null
   and public._reimb_rate(c.org_id) is not null;
