-- 472 — Reimbursements: cancel an approval (before it is paid). The claim
-- goes back to Pending with the reason, so it can be approved or rejected
-- again. If a Payment Advice was made for it (and is not paid yet), that
-- advice is voided too. Needs 466–471. Safe to run again.

create or replace function public.reimb_cancel_approval(p_claim text, p_reason text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_by text; v_by_id text; pa record;
begin
  select * into c from reimb_claims where id = p_claim;
  if c.id is null then raise exception 'Claim not found.'; end if;
  if not public.reimb_can_approve(c.org_id) then raise exception 'You are not an approver for reimbursements.'; end if;
  if c.status <> 'approved' then raise exception 'Only an approved, unpaid claim can be cancelled.'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Enter the reason.'; end if;
  select a.id, a.name into v_by_id, v_by from public._acting_user(c.org_id) a;

  if c.advice_id is not null then
    select id, advice_number, status, paid_at into pa from payment_advices where id = c.advice_id;
    if pa.paid_at is not null then
      raise exception 'Payment Advice % is already paid — it cannot be cancelled.', pa.advice_number;
    end if;
    if pa.id is not null and coalesce(pa.status, '') <> 'void' then
      -- Voiding the advice puts the claim back to Pending (trigger from SQL 467).
      update payment_advices
         set status = 'void', voided_by = v_by_id, voided_by_name = v_by, voided_at = now(),
             void_reason = 'Reimbursement approval cancelled: ' || btrim(p_reason)
       where id = pa.id;
      begin
        insert into voucher_audit_log (id, org_id, voucher_id, voucher_type, action, details, performed_by, performed_at)
        values ('val_' || replace(gen_random_uuid()::text, '-', ''), c.org_id, pa.id, 'PA', 'voided',
                'Voided: reimbursement approval cancelled — ' || btrim(p_reason), v_by_id, now());
      exception when others then null;
      end;
    end if;
  end if;

  update reimb_claims
     set status = 'pending', advice_id = null, advice_number = null,
         decided_by_name = null, decided_at = null, amount = null, unpaid_km = null, rate = null,
         note = 'Approval cancelled by ' || coalesce(v_by, '') || ': ' || btrim(p_reason)
   where id = c.id;

  begin
    perform public.notify_event(c.org_id, 'reimb_rejected', null, c.claimant_id,
      'Reimbursement approval cancelled — ' || coalesce(c.claimant_name, ''),
      btrim(p_reason) || ' (' || coalesce(v_by, '') || ')', '/reimbursements?c=' || c.id);
  exception when others then null;
  end;
end $$;
grant execute on function public.reimb_cancel_approval(text, text) to authenticated;
