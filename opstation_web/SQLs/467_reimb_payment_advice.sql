-- 467 — Reimbursements → Payment Advice.
--
--  • Admin Settings → org.reimb_after_approval: 'mark_paid' (default — accounts
--    click Mark paid on Reimbursement Approvals) or 'payment_advice' (approving
--    a claim creates an APPROVED Payment Advice: one per claim, note "Trip
--    Reimbursement", the person as a free-text party, bank details from their
--    HR employee profile if any, the trip particulars in the line's Details).
--  • When that Payment Advice is marked paid, the claim turns Paid by itself.
--    When it is voided, the claim goes back to Pending (with the reason) so it
--    can be approved again (a new Payment Advice is made then).
--  • payment_advice_lines.details: optional particulars on any PA line.
-- Needs 466. Safe to run again.

alter table public.payment_advice_lines add column if not exists details text;
alter table public.reimb_claims add column if not exists advice_id text;
alter table public.reimb_claims add column if not exists advice_number text;
alter table public.reimb_claims add column if not exists note text;
create index if not exists reimb_claims_advice on public.reimb_claims (advice_id) where advice_id is not null;

create or replace function public._reimb_mode(p_org text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select nullif(btrim(value), '') from app_config
                    where org_id = p_org and key = 'org.reimb_after_approval' and branch_id is null limit 1), 'mark_paid')
$$;

-- Details of the lines of a public (QR) Payment Advice, in line order.
create or replace function public.public_payment_advice_details(p_token text)
returns json language sql stable security definer set search_path to 'public' as $$
  select coalesce(json_agg(l.details order by l.line_order), '[]'::json)
    from payment_advice_lines l
    join payment_advices a on a.id = l.advice_id
   where p_token is not null and length(p_token) >= 32 and a.public_token = p_token
$$;
grant execute on function public.public_payment_advice_details(text) to anon, authenticated;

-- Make the Payment Advice for an approved claim. Returns the advice id.
create or replace function public._reimb_create_pa(p_claim text, p_by_id text, p_by_name text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare
  c reimb_claims%rowtype; v_id text; v_no text; v_seq int; v_bank text; v_details text; v_sig text; v_stamp text;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select * into c from reimb_claims where id = p_claim;
  perform pg_advisory_xact_lock(hashtext('pa_number_' || c.org_id));
  select coalesce(max((substring(advice_number from '([0-9]+)$'))::int), 0) into v_seq
    from payment_advices where org_id = c.org_id and advice_number ~ '[0-9]+$';
  v_no := 'PA-' || extract(year from v_today)::int || '-' || lpad((v_seq + 1)::text, 4, '0');
  v_id := 'pa_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_r';

  begin
    select nullif(concat_ws(E'\n',
             case when nullif(btrim(e.bank_name), '') is not null then 'Bank: ' || btrim(e.bank_name) end,
             case when nullif(btrim(e.bank_account), '') is not null then 'Account: ' || btrim(e.bank_account) end), '')
      into v_bank
      from employees e
     where e.org_id = c.org_id and e.login_user_id = c.claimant_id
     order by coalesce(e.is_active, true) desc
     limit 1;
  exception when others then v_bank := null;
  end;

  v_details := case when c.date_from = c.date_to or c.date_to is null then to_char(c.date_from, 'FMDD Mon YYYY')
                    when date_trunc('month', c.date_from) = date_trunc('month', c.date_to)
                      then to_char(c.date_from, 'FMDD') || '–' || to_char(c.date_to, 'FMDD Mon YYYY')
                    else to_char(c.date_from, 'FMDD Mon') || ' – ' || to_char(c.date_to, 'FMDD Mon YYYY') end
               || ' · ' || trim(to_char(c.unpaid_km, 'FM999,999,990.0')) || ' km @ Rs ' || trim(to_char(c.rate, 'FM999,990.##'))
               || case when c.unpaid_km < c.km then ' (' || trim(to_char(c.km - c.unpaid_km, 'FM999,990.0')) || ' km already paid)' else '' end
               || ' · ' || case when c.doc_type = 'combined_summary' then 'Combined Trip Summary' else 'Trip Summary' end
               || ' · approved by ' || coalesce(p_by_name, '');

  insert into payment_advices (id, org_id, advice_number, advice_date, status, note, grand_total,
                               created_by, created_by_name, approved_by, approved_by_name, approved_at)
  values (v_id, c.org_id, v_no, v_today, 'approved', 'Trip Reimbursement', c.amount,
          p_by_id, p_by_name, p_by_id, p_by_name, now());

  insert into payment_advice_lines (id, advice_id, org_id, party_type, party_id, party_name, bank_details,
                                    amount_due, amount_to_pay, line_order, details)
  values ('pal_' || (extract(epoch from clock_timestamp()) * 1000000)::bigint || '_r', v_id, c.org_id, 'other',
          'ft_' || c.id, coalesce(c.claimant_name, 'Reimbursement'), coalesce(v_bank, ''),
          c.amount, c.amount, 0, v_details);

  -- Signatures (best effort — columns from SQL 288).
  begin
    select nullif(btrim(signature_url), '') into v_sig from users where id = p_by_id;
    select nullif(btrim(value), '') into v_stamp from app_config where org_id = c.org_id and key = 'org.stamp_url' limit 1;
    update payment_advices
       set created_signature_url = v_sig, approved_signature_url = v_sig, approved_stamp_url = v_stamp
     where id = v_id;
  exception when others then null;
  end;
  begin
    insert into voucher_audit_log (id, org_id, voucher_id, voucher_type, action, details, performed_by, performed_at)
    values ('val_' || replace(gen_random_uuid()::text, '-', ''), c.org_id, v_id, 'PA', 'created',
            'Created from reimbursement claim (' || coalesce(c.claimant_name, '') || ') and approved by ' || coalesce(p_by_name, ''),
            p_by_id, now());
  exception when others then null;
  end;

  update reimb_claims set advice_id = v_id, advice_number = v_no where id = c.id;
  return v_id;
end $$;
revoke all on function public._reimb_create_pa(text, text, text) from public, anon, authenticated;

-- Approve / reject — same as 466, plus the Payment Advice in that mode.
create or replace function public.reimb_decide(p_claim text, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_by text; v_by_id text; v_unpaid numeric; v_rate numeric; v_pa boolean; v_amount numeric;
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
  v_amount := case when v_rate is not null then round(v_unpaid * v_rate) end;
  v_pa := p_approve and public._reimb_mode(c.org_id) = 'payment_advice';
  if v_pa and v_rate is null then
    raise exception 'Set the rate per km first (Admin Settings → Reimbursement approvals) — the Payment Advice needs an amount.';
  end if;
  if v_pa and coalesce(v_amount, 0) <= 0 then
    raise exception 'Nothing left to pay — every trip on this claim was already paid.';
  end if;
  update reimb_claims
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by_name = v_by, decided_at = now(),
         reject_reason = case when p_approve then null else btrim(p_reason) end,
         note = case when p_approve then null else note end,
         rate = v_rate, unpaid_km = v_unpaid, amount = v_amount
   where id = c.id;
  if v_pa then
    perform public._reimb_create_pa(c.id, v_by_id, v_by);
  end if;
  begin
    if p_approve then
      perform public.notify_event(c.org_id, 'reimb_approved', null, c.claimant_id,
        'Reimbursement approved — ' || coalesce(c.claimant_name, ''),
        v_unpaid || ' km' || coalesce(' · Rs ' || to_char(v_amount, 'FM999,999,999'), '') || ' · approved by ' || coalesce(v_by, '')
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
grant execute on function public.reimb_decide(text, boolean, text) to authenticated;

-- Mark paid here only for claims that have no Payment Advice.
create or replace function public.reimb_mark_paid(p_claim text, p_amount numeric, p_paid_on date,
                                                  p_method text default null, p_ref text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_by text;
begin
  select * into c from reimb_claims where id = p_claim;
  if c.id is null then raise exception 'Claim not found.'; end if;
  if c.advice_id is not null then raise exception 'This claim is paid through Payment Advice %.', coalesce(c.advice_number, ''); end if;
  if not public.reimb_can_pay(c.org_id) then raise exception 'You cannot mark reimbursements paid.'; end if;
  if c.status <> 'approved' then raise exception 'Only an approved claim can be marked paid.'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Enter the amount paid.'; end if;
  select a.name into v_by from public._acting_user(c.org_id) a;
  update reimb_claims
     set status = 'paid', paid_amount = p_amount, paid_on = coalesce(p_paid_on, (now() at time zone 'Asia/Karachi')::date),
         paid_method = nullif(btrim(coalesce(p_method, '')), ''), paid_ref = nullif(btrim(coalesce(p_ref, '')), ''),
         paid_by_name = v_by, paid_at = now()
   where id = c.id;
  insert into reimb_trip_paid (org_id, trip_id, claim_id, paid_on)
  select c.org_id, l.trip_id, c.id, coalesce(p_paid_on, (now() at time zone 'Asia/Karachi')::date)
    from reimb_lines l where l.claim_id = c.id
  on conflict (org_id, trip_id) do nothing;
  begin
    perform public.notify_event(c.org_id, 'reimb_paid', null, c.claimant_id,
      'Reimbursement paid — ' || coalesce(c.claimant_name, ''),
      'Rs ' || to_char(p_amount, 'FM999,999,999') || coalesce(' · ' || nullif(btrim(coalesce(p_method, '')), ''), '')
        || coalesce(' · ref ' || nullif(btrim(coalesce(p_ref, '')), ''), ''),
      '/reimbursements?c=' || c.id);
  exception when others then null;
  end;
end $$;
grant execute on function public.reimb_mark_paid(text, numeric, date, text, text) to authenticated;

-- Payment Advice paid / voided → the claim follows.
create or replace function public._reimb_pa_sync()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_on date;
begin
  if new.paid_at is not null and old.paid_at is null then
    v_on := (new.paid_at at time zone 'Asia/Karachi')::date;
    for c in select * from reimb_claims where advice_id = new.id and status = 'approved' loop
      update reimb_claims
         set status = 'paid', paid_amount = coalesce(new.grand_total, c.amount), paid_on = v_on,
             paid_method = 'Payment Advice ' || coalesce(new.advice_number, ''), paid_ref = new.paid_ref,
             paid_by_name = new.paid_by_name, paid_at = now()
       where id = c.id;
      insert into reimb_trip_paid (org_id, trip_id, claim_id, paid_on)
      select c.org_id, l.trip_id, c.id, v_on from reimb_lines l where l.claim_id = c.id
      on conflict (org_id, trip_id) do nothing;
      begin
        perform public.notify_event(c.org_id, 'reimb_paid', null, c.claimant_id,
          'Reimbursement paid — ' || coalesce(c.claimant_name, ''),
          'Rs ' || to_char(coalesce(new.grand_total, c.amount), 'FM999,999,999') || ' · ' || coalesce(new.advice_number, '')
            || coalesce(' · ref ' || nullif(btrim(coalesce(new.paid_ref, '')), ''), ''),
          '/reimbursements?c=' || c.id);
      exception when others then null;
      end;
    end loop;
  end if;
  if new.status = 'void' and coalesce(old.status, '') <> 'void' then
    for c in select * from reimb_claims where advice_id = new.id and status in ('approved', 'paid') loop
      delete from reimb_trip_paid where claim_id = c.id;
      update reimb_claims
         set status = 'pending', advice_id = null, advice_number = null,
             decided_by_name = null, decided_at = null, amount = null, unpaid_km = null, rate = null,
             paid_amount = null, paid_on = null, paid_method = null, paid_ref = null, paid_by_name = null, paid_at = null,
             note = 'Payment Advice ' || coalesce(new.advice_number, '') || ' was voided'
                    || coalesce(': ' || nullif(btrim(coalesce(new.void_reason, '')), ''), '') || '. Approve again to make a new one.'
       where id = c.id;
    end loop;
  end if;
  return new;
end $$;

drop trigger if exists reimb_pa_sync on public.payment_advices;
create trigger reimb_pa_sync after update on public.payment_advices
  for each row execute function public._reimb_pa_sync();
