-- 469 — Reimbursements: a summary generated again AFTER its claim was
-- approved / paid / rejected becomes a NEW pending claim for review
-- (doc_key gets "#2", "#3" …; repeat_of points to the earlier claim).
-- While the latest claim for that summary is still pending, generating again
-- only counts it (no duplicate rows).
-- Trips already on an APPROVED or PAID claim are left out of every other
-- claim's amount, so nothing can be approved or paid twice.
-- Needs 466–468. Safe to run again.

alter table public.reimb_claims add column if not exists repeat_of text;

-- Km of a claim not already covered by another approved / paid claim.
create or replace function public._reimb_unpaid_km(p_claim text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce(sum(l.km), 0) from reimb_lines l
   where l.claim_id = p_claim
     and not exists (select 1 from reimb_trip_paid p
                      where p.org_id = l.org_id and p.trip_id = l.trip_id and p.claim_id <> p_claim)
     and not exists (select 1 from reimb_lines l2 join reimb_claims c2 on c2.id = l2.claim_id
                      where l2.org_id = l.org_id and l2.trip_id = l.trip_id and l2.claim_id <> p_claim
                        and c2.status in ('approved', 'paid'))
$$;

create or replace function public.reimb_submit(p_org text, p_type text, p_key text, p_claimant text,
                                               p_lines jsonb, p_record boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_lines jsonb := coalesce(p_lines, '[]'::jsonb);
  v_id text; v_from date; v_to date; v_km numeric; v_n int; v_seq int;
  v_rate numeric; v_paid jsonb; v_name text; v_by text; last reimb_claims%rowtype; c reimb_claims%rowtype;
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then return null; end if;
  v_rate := public._reimb_rate(p_org);

  -- Latest claim made from this summary (original key or a "#n" repeat).
  select * into last from reimb_claims
   where org_id = p_org and doc_type = p_type and (doc_key = p_key or doc_key like p_key || '#%')
   order by created_at desc limit 1;

  if p_record and p_claimant is not null and public._cfg_true(p_org, 'org.reimb_approvals')
     and jsonb_typeof(v_lines) = 'array' and jsonb_array_length(v_lines) > 0 then
    if last.id is not null and last.status = 'pending' then
      update reimb_claims set generated_count = generated_count + 1, last_generated_at = now() where id = last.id;
      v_id := last.id;
    else
      select min((l->>'day')::date), max((l->>'day')::date), round(sum(coalesce((l->>'km')::numeric, 0)), 2), count(*)
        into v_from, v_to, v_km, v_n
        from jsonb_array_elements(v_lines) l;
      select name into v_name from users where id = p_claimant;
      select a.name into v_by from public._acting_user(p_org) a;
      select count(*) + 1 into v_seq from reimb_claims
       where org_id = p_org and doc_type = p_type and (doc_key = p_key or doc_key like p_key || '#%');

      insert into reimb_claims (org_id, claimant_id, claimant_name, doc_type, doc_key, date_from, date_to, km, trips,
                                generated_by_name, repeat_of)
      values (p_org, p_claimant, v_name, p_type, case when last.id is null then p_key else p_key || '#' || v_seq end,
              v_from, v_to, v_km, v_n, coalesce(v_by, v_name), last.id)
      returning id into v_id;

      insert into reimb_lines (claim_id, org_id, trip_id, day, km)
      select v_id, p_org, l->>'trip', (l->>'day')::date, round(coalesce((l->>'km')::numeric, 0), 2)
        from jsonb_array_elements(v_lines) l
       where coalesce(l->>'trip', '') <> ''
      on conflict do nothing;

      begin
        perform public.notify_event(p_org, 'reimb_submitted', null, p_claimant,
          case when last.id is null then 'Trip summary to approve — ' else 'Trip summary generated again — ' end || coalesce(v_name, ''),
          case when v_from = v_to then to_char(v_from, 'DD Mon') else to_char(v_from, 'DD Mon') || ' – ' || to_char(v_to, 'DD Mon') end
            || ' · ' || v_km || ' km'
            || case when last.id is not null then ' · earlier claim ' || last.status else '' end,
          '/reimbursements?c=' || v_id);
      exception when others then null;
      end;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('trip', l.trip, 'day', l.day, 'paid_on', p.paid_on,
                                               'ref', c2.paid_ref, 'claim', p.claim_id) order by l.day), '[]'::jsonb)
    into v_paid
    from (select distinct l->>'trip' as trip, (l->>'day')::date as day from jsonb_array_elements(v_lines) l) l
    join reimb_trip_paid p on p.org_id = p_org and p.trip_id = l.trip
    left join reimb_claims c2 on c2.id = p.claim_id;

  if v_id is not null then
    select * into c from reimb_claims where id = v_id;
  else
    c := last;
  end if;

  return jsonb_build_object('rate', v_rate, 'paid', v_paid, 'claim', c.id, 'status', c.status,
                            'paid_amount', c.paid_amount, 'paid_on', c.paid_on, 'paid_ref', c.paid_ref,
                            'paid_method', c.paid_method, 'approved_by', c.decided_by_name);
end $$;
grant execute on function public.reimb_submit(text, text, text, text, jsonb, boolean) to authenticated;
