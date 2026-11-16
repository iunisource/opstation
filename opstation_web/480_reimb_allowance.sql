-- 480 — Reimbursements: allowance per day is part of the claim.
--  • Worked-out amount = distance × rate + allowance for each day (days
--    already approved on another claim get none). Default allowance = Admin
--    Settings → "Allowance per day" (when that setting is on; else 0).
--  • The approver can change a day's allowance (e.g. 0 for a half day) in
--    Adjust trip; saved on reimb_adjustments.allowance (null = default).
-- Needs 466–479. Safe to run again.

alter table public.reimb_adjustments add column if not exists allowance numeric;
alter table public.reimb_claims add column if not exists allowance_amount numeric;

-- Org default allowance per day (0 when off / not set).
create or replace function public._reimb_allowance(p_org text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select case when coalesce(public._reimb_cfg(p_org, 'org.reimb_allowance_print'), 'true') = 'false' then 0
              when coalesce(public._reimb_cfg(p_org, 'org.reimb_allowance_day'), '') ~ '^[0-9]+(\.[0-9]+)?$'
                then public._reimb_cfg(p_org, 'org.reimb_allowance_day')::numeric
              else 0 end
$$;

-- Allowance of a claim: per day, the approver's figure (any trip of that day
-- adjusted) or the default; only days with a trip not approved elsewhere.
create or replace function public._reimb_claim_allowance(p_claim text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  with c as (select id, org_id from reimb_claims where id = p_claim),
  d as (
    select l.day,
           bool_or(public._reimb_lock_of(l.org_id, l.trip_id, l.claim_id) is null) as open,
           max(a.allowance) as adj
      from reimb_lines l
      left join reimb_adjustments a on a.claim_id = l.claim_id and a.trip_id = l.trip_id
     where l.claim_id = p_claim
     group by l.day)
  select coalesce(sum(coalesce(d.adj, public._reimb_allowance((select org_id from c)))) filter (where d.open), 0)
    from d
$$;

-- Adjust trip now also takes the day's allowance (null = default).
drop function if exists public.reimb_adjust_trip(text, text, jsonb, boolean, text, numeric, numeric);
create or replace function public.reimb_adjust_trip(p_claim text, p_trip text, p_excluded jsonb,
                                                    p_exclude_return boolean, p_return_reason text,
                                                    p_original_km numeric, p_adjusted_km numeric,
                                                    p_allowance numeric default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_by text; v_ex jsonb := coalesce(p_excluded, '[]'::jsonb);
        v_def numeric; v_allow numeric;
begin
  select * into c from reimb_claims where id = p_claim;
  if c.id is null then raise exception 'Claim not found.'; end if;
  if not public.reimb_can_approve(c.org_id) then raise exception 'You are not an approver for reimbursements.'; end if;
  if c.status not in ('pending', 'rejected') then
    raise exception 'Only a pending claim can be adjusted (cancel the approval first).';
  end if;
  if not exists (select 1 from reimb_lines where claim_id = c.id and trip_id = p_trip) then
    raise exception 'This trip is not on the claim.';
  end if;
  if p_exclude_return and nullif(btrim(coalesce(p_return_reason, '')), '') is null then
    raise exception 'Enter the reason for leaving out the return leg.';
  end if;
  if exists (select 1 from jsonb_array_elements(v_ex) e where nullif(btrim(coalesce(e->>'reason', '')), '') is null) then
    raise exception 'Enter the reason for every visit left out.';
  end if;
  if p_allowance is not null and p_allowance < 0 then raise exception 'The allowance cannot be negative.'; end if;
  v_def := public._reimb_allowance(c.org_id);
  v_allow := case when p_allowance is null or round(p_allowance, 2) = round(v_def, 2) then null else round(p_allowance, 2) end;
  select a.name into v_by from public._acting_user(c.org_id) a;

  if jsonb_array_length(v_ex) = 0 and not coalesce(p_exclude_return, false) and v_allow is null then
    update reimb_lines l set km = coalesce((select a.original_km from reimb_adjustments a
                                             where a.claim_id = c.id and a.trip_id = p_trip), l.km)
     where l.claim_id = c.id and l.trip_id = p_trip;
    delete from reimb_adjustments where claim_id = c.id and trip_id = p_trip;
  else
    if p_adjusted_km is null or p_adjusted_km < 0 then raise exception 'Adjusted distance is missing.'; end if;
    insert into reimb_adjustments (claim_id, trip_id, org_id, excluded, exclude_return, return_reason,
                                   original_km, adjusted_km, allowance, by_name, at)
    values (c.id, p_trip, c.org_id, v_ex, coalesce(p_exclude_return, false), nullif(btrim(coalesce(p_return_reason, '')), ''),
            coalesce((select a.original_km from reimb_adjustments a where a.claim_id = c.id and a.trip_id = p_trip),
                     p_original_km, (select km from reimb_lines where claim_id = c.id and trip_id = p_trip)),
            round(p_adjusted_km, 2), v_allow, v_by, now())
    on conflict (claim_id, trip_id) do update
       set excluded = excluded.excluded, exclude_return = excluded.exclude_return,
           return_reason = excluded.return_reason, adjusted_km = excluded.adjusted_km,
           allowance = excluded.allowance, by_name = excluded.by_name, at = now();
    update reimb_lines set km = round(p_adjusted_km, 2) where claim_id = c.id and trip_id = p_trip;
  end if;
  update reimb_claims set km = (select coalesce(sum(km), 0) from reimb_lines where claim_id = c.id) where id = c.id;
end $$;
grant execute on function public.reimb_adjust_trip(text, text, jsonb, boolean, text, numeric, numeric, numeric) to authenticated;

-- Approve: worked-out amount includes the allowance.
drop function if exists public.reimb_decide(text, boolean, text, numeric, text);
create or replace function public.reimb_decide(p_claim text, p_approve boolean, p_reason text default null,
                                               p_amount numeric default null, p_adjust_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_by text; v_by_id text; v_unpaid numeric; v_rate numeric; v_pa boolean;
        v_amount numeric; v_calc numeric; v_note text; v_allow numeric;
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
  v_allow := public._reimb_claim_allowance(c.id);
  -- Worked out = distance × rate + allowance (per day, SQL 480).
  v_calc := case when v_rate is not null or v_allow > 0
                 then round(coalesce(v_unpaid * v_rate, 0)) + round(v_allow) end;
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
         allowance_amount = case when p_approve then v_allow end,
         adjust_note = case when p_approve and v_amount is distinct from v_calc then v_note end
   where id = c.id;
  if v_pa then
    perform public._reimb_create_pa(c.id, v_by_id, v_by);
    if v_allow > 0 then
      begin
        update payment_advice_lines l
           set details = coalesce(l.details, '') || ' · incl. allowance Rs ' || to_char(v_allow, 'FM999,999,999')
         where l.advice_id = (select advice_id from reimb_claims where id = c.id);
      exception when others then null;
      end;
    end if;
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
