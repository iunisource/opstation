-- 468 — Reimbursements: "Create Payment Advice" for a claim that was approved
-- BEFORE "After approval → Create a Payment Advice" was switched on.
-- Needs 466 + 467. Safe to run again.

create or replace function public.reimb_make_advice(p_claim text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_by text; v_by_id text; v_unpaid numeric; v_rate numeric; v_amount numeric;
begin
  select * into c from reimb_claims where id = p_claim;
  if c.id is null then raise exception 'Claim not found.'; end if;
  if not public.reimb_can_approve(c.org_id) then raise exception 'You are not an approver for reimbursements.'; end if;
  if c.status <> 'approved' then raise exception 'Only an approved, unpaid claim can get a Payment Advice.'; end if;
  if c.advice_id is not null then raise exception 'This claim already has Payment Advice %.', coalesce(c.advice_number, ''); end if;
  v_unpaid := public._reimb_unpaid_km(c.id);
  v_rate := public._reimb_rate(c.org_id);
  if v_rate is null then
    raise exception 'Set the rate per km first (Admin Settings → Reimbursement approvals) — the Payment Advice needs an amount.';
  end if;
  v_amount := round(v_unpaid * v_rate);
  if coalesce(v_amount, 0) <= 0 then raise exception 'Nothing left to pay — every trip on this claim was already paid.'; end if;
  select a.id, a.name into v_by_id, v_by from public._acting_user(c.org_id) a;
  update reimb_claims set rate = v_rate, unpaid_km = v_unpaid, amount = v_amount where id = c.id;
  return public._reimb_create_pa(c.id, v_by_id, coalesce(c.decided_by_name, v_by));
end $$;
grant execute on function public.reimb_make_advice(text) to authenticated;
