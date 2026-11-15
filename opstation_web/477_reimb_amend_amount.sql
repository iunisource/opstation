-- 477 — Reimbursements: the approver can change the amount when approving
-- (e.g. a visit or two not justified). The worked-out amount is pre-filled;
-- a different amount needs a reason. Saved: claimed_amount (worked out),
-- amount (approved) and adjust_note. The Payment Advice line shows it too.
-- Needs 466–476. Safe to run again.

alter table public.reimb_claims add column if not exists claimed_amount numeric;
alter table public.reimb_claims add column if not exists adjust_note text;

drop function if exists public.reimb_decide(text, boolean, text);
create or replace function public.reimb_decide(p_claim text, p_approve boolean, p_reason text default null,
                                               p_amount numeric default null, p_adjust_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_by text; v_by_id text; v_unpaid numeric; v_rate numeric; v_pa boolean;
        v_amount numeric; v_calc numeric; v_note text;
begin
  select * into c from reimb_claims where id = p_claim;
  if c.id is null then raise exception 'Claim not found.'; end if;
  if not public.reimb_can_approve(c.org_id) then raise exception 'You are not an approver for reimbursements.'; end if;
  if c.status not in ('pending', 'rejected') and p_approve then raise exception 'This claim is already %.', c.status; end if;
  if c.status <> 'pending' and not p_approve then raise exception 'Only a pending claim can be rejected.'; end if;
  if not p_approve and nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Enter the reason.'; end if;
  select a.id, a.name into v_by_id, v_by from public._acting_user(c.org_id) a;
  v_unpaid := public._reimb_unpaid_km(c.id);
  v_rate := public._reimb_rate(c.org_id);
  v_calc := case when v_rate is not null then round(v_unpaid * v_rate) end;
  v_amount := v_calc;
  v_note := nullif(btrim(coalesce(p_adjust_note, '')), '');

  -- Amount changed by the approver.
  if p_approve and p_amount is not null then
    if p_amount < 0 then raise exception 'The amount cannot be negative.'; end if;
    if v_calc is null or round(p_amount) <> v_calc then
      if v_calc is not null and v_note is null then
        raise exception 'Enter the reason for changing the amount.';
      end if;
      v_amount := round(p_amount);
    end if;
  end if;

  v_pa := p_approve and public._reimb_mode(c.org_id) = 'payment_advice';
  if v_pa and v_amount is null then
    raise exception 'Enter the amount (or set the rate per km in Admin Settings) — the Payment Advice needs an amount.';
  end if;
  if v_pa and coalesce(v_amount, 0) <= 0 then
    raise exception 'Nothing to pay — the amount is 0.';
  end if;
  update reimb_claims
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by_name = v_by, decided_at = now(),
         reject_reason = case when p_approve then null else btrim(p_reason) end,
         note = case when p_approve then null else note end,
         rate = v_rate, unpaid_km = v_unpaid, amount = v_amount,
         claimed_amount = case when p_approve then v_calc end,
         adjust_note = case when p_approve and v_amount is distinct from v_calc then v_note end
   where id = c.id;
  if v_pa then
    perform public._reimb_create_pa(c.id, v_by_id, v_by);
    if v_amount is distinct from v_calc then
      begin
        update payment_advice_lines l
           set details = coalesce(l.details, '') || ' · Approved Rs ' || to_char(v_amount, 'FM999,999,999')
                         || coalesce(' (worked out Rs ' || to_char(v_calc, 'FM999,999,999') || ')', '')
                         || coalesce(': ' || v_note, '')
         where l.advice_id = (select advice_id from reimb_claims where id = c.id);
      exception when others then null;
      end;
    end if;
  end if;
  begin
    if p_approve then
      perform public.notify_event(c.org_id, 'reimb_approved', null, c.claimant_id,
        'Reimbursement approved — ' || coalesce(c.claimant_name, ''),
        v_unpaid || ' km' || coalesce(' · Rs ' || to_char(v_amount, 'FM999,999,999'), '')
          || case when v_amount is distinct from v_calc and v_note is not null then ' (changed: ' || v_note || ')' else '' end
          || ' · approved by ' || coalesce(v_by, '')
          || case when v_pa then ' · ' || coalesce((select advice_number from reimb_claims where id = c.id), 'Payment Advice') || ' created' else '' end,
        '/reimbursements?c=' || c.id);
    else
      perform public.notify_event(c.org_id, 'reimb_rejected', null, c.claimant_id,
        'Reimbursement rejected — ' || coalesce(c.claimant_name, ''),
        btrim(p_reason) || ' (' || coalesce(v_by, '') || ')', '/reimbursements?c=' || c.id);
    end if;
  exception when others then null;
  end;
end $$;
grant execute on function public.reimb_decide(text, boolean, text, numeric, text) to authenticated;
