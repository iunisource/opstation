-- 478 — Reimbursements: approver adjusts a trip (per day of a claim).
--  • Untick visits and/or the return-to-end-point leg, each with a reason;
--    the web works out the new road distance and saves it here.
--  • The claim line's km becomes the adjusted km (so the amount, approval,
--    Payment Advice and "already approved" all use it); the original is kept
--    in reimb_adjustments. Generating the summary again keeps the adjustment.
--  • Only approvers, only while the claim is pending (or rejected).
-- Needs 466–477. Safe to run again.

create table if not exists public.reimb_adjustments (
  claim_id       text not null,
  trip_id        text not null,
  org_id         text not null,
  excluded       jsonb not null default '[]'::jsonb,   -- [{visit, shop, time, reason}]
  exclude_return boolean not null default false,
  return_reason  text,
  original_km    numeric not null,
  adjusted_km    numeric not null,
  by_name        text,
  at             timestamptz not null default now(),
  primary key (claim_id, trip_id)
);
alter table public.reimb_adjustments enable row level security;
drop policy if exists reimb_adjustments_read on public.reimb_adjustments;
create policy reimb_adjustments_read on public.reimb_adjustments for select
  using (public._is_org_member(org_id) or public._is_super_admin());
revoke insert, update, delete on public.reimb_adjustments from anon, authenticated;
grant select on public.reimb_adjustments to authenticated;

-- Save (or clear, when nothing is excluded) the adjustment of one trip.
create or replace function public.reimb_adjust_trip(p_claim text, p_trip text, p_excluded jsonb,
                                                    p_exclude_return boolean, p_return_reason text,
                                                    p_original_km numeric, p_adjusted_km numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c reimb_claims%rowtype; v_by text; v_ex jsonb := coalesce(p_excluded, '[]'::jsonb);
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
  select a.name into v_by from public._acting_user(c.org_id) a;

  if jsonb_array_length(v_ex) = 0 and not coalesce(p_exclude_return, false) then
    -- Nothing left out: back to the original distance.
    update reimb_lines l set km = coalesce((select a.original_km from reimb_adjustments a
                                             where a.claim_id = c.id and a.trip_id = p_trip), l.km)
     where l.claim_id = c.id and l.trip_id = p_trip;
    delete from reimb_adjustments where claim_id = c.id and trip_id = p_trip;
  else
    if p_adjusted_km is null or p_adjusted_km < 0 then raise exception 'Adjusted distance is missing.'; end if;
    insert into reimb_adjustments (claim_id, trip_id, org_id, excluded, exclude_return, return_reason,
                                   original_km, adjusted_km, by_name, at)
    values (c.id, p_trip, c.org_id, v_ex, coalesce(p_exclude_return, false), nullif(btrim(coalesce(p_return_reason, '')), ''),
            coalesce((select a.original_km from reimb_adjustments a where a.claim_id = c.id and a.trip_id = p_trip),
                     p_original_km, (select km from reimb_lines where claim_id = c.id and trip_id = p_trip)),
            round(p_adjusted_km, 2), v_by, now())
    on conflict (claim_id, trip_id) do update
       set excluded = excluded.excluded, exclude_return = excluded.exclude_return,
           return_reason = excluded.return_reason, adjusted_km = excluded.adjusted_km,
           by_name = excluded.by_name, at = now();
    update reimb_lines set km = round(p_adjusted_km, 2) where claim_id = c.id and trip_id = p_trip;
  end if;
  update reimb_claims set km = (select coalesce(sum(km), 0) from reimb_lines where claim_id = c.id) where id = c.id;
end $$;
grant execute on function public.reimb_adjust_trip(text, text, jsonb, boolean, text, numeric, numeric) to authenticated;

create or replace function public.reimb_submit(p_org text, p_type text, p_key text, p_claimant text,
                                               p_lines jsonb, p_record boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_lines jsonb := coalesce(p_lines, '[]'::jsonb);
  v_new jsonb;      -- lines not locked by an approved / paid claim
  v_id text; v_from date; v_to date; v_km numeric; v_n int; v_seq int;
  v_rate numeric; v_paid jsonb; v_gen jsonb; v_excl jsonb; v_first timestamptz; v_count int;
  v_name text; v_by text; last reimb_claims%rowtype; c reimb_claims%rowtype;
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then return null; end if;
  if jsonb_typeof(v_lines) <> 'array' then v_lines := '[]'::jsonb; end if;
  v_rate := public._reimb_rate(p_org);

  -- Latest claim made from this summary (original key or a "#n" one).
  select * into last from reimb_claims
   where org_id = p_org and doc_type = p_type and (doc_key = p_key or doc_key like p_key || '#%')
   order by created_at desc limit 1;

  -- Locked trips: on an approved / paid claim. (A pending claim of THIS sheet
  -- doesn't lock its own trips.)
  select coalesce(jsonb_agg(l), '[]'::jsonb) into v_new
    from jsonb_array_elements(v_lines) l
   where coalesce(l->>'trip', '') <> ''
     and public._reimb_lock_of(p_org, l->>'trip') is null;

  -- Every real generation is logged per trip, whether or not approvals are on.
  if p_record and jsonb_array_length(v_lines) > 0 then
    select a.name into v_by from public._acting_user(p_org) a;
    insert into reimb_generations (org_id, doc_type, doc_key, claimant_id, trip_id, day, by_name)
    select p_org, p_type, p_key, p_claimant, l->>'trip', (l->>'day')::date, v_by
      from (select distinct on (l->>'trip') l from jsonb_array_elements(v_lines) l where coalesce(l->>'trip', '') <> '') d(l)
    on conflict (org_id, doc_type, doc_key, trip_id) do update
       set gen_count = reimb_generations.gen_count + 1, last_at = now(), by_name = excluded.by_name;
  end if;

  if p_record and p_claimant is not null and public._cfg_true(p_org, 'org.reimb_approvals')
     and jsonb_array_length(v_new) > 0 then
    select min((l->>'day')::date), max((l->>'day')::date), round(sum(coalesce((l->>'km')::numeric, 0)), 2), count(*)
      into v_from, v_to, v_km, v_n
      from jsonb_array_elements(v_new) l;

    if last.id is not null and last.status = 'pending' then
      -- Same sheet, still pending: refresh its trips (some may have been
      -- approved on another claim since) and count the generation.
      v_id := last.id;
      delete from reimb_lines where claim_id = v_id;
      -- A day the approver adjusted keeps its adjusted km (SQL 478).
      insert into reimb_lines (claim_id, org_id, trip_id, day, km)
      select v_id, p_org, l->>'trip', (l->>'day')::date,
             coalesce((select a.adjusted_km from reimb_adjustments a where a.claim_id = v_id and a.trip_id = l->>'trip'),
                      round(coalesce((l->>'km')::numeric, 0), 2))
        from jsonb_array_elements(v_new) l
      on conflict do nothing;
      select coalesce(sum(km), 0) into v_km from reimb_lines where claim_id = v_id;
      update reimb_claims
         set generated_count = generated_count + 1, last_generated_at = now(),
             date_from = v_from, date_to = v_to, km = v_km, trips = v_n
       where id = v_id;
    else
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
        from jsonb_array_elements(v_new) l
      on conflict do nothing;

      begin
        perform public.notify_event(p_org, 'reimb_submitted', null, p_claimant,
          'Trip summary to approve — ' || coalesce(v_name, ''),
          case when v_from = v_to then to_char(v_from, 'DD Mon') else to_char(v_from, 'DD Mon') || ' – ' || to_char(v_to, 'DD Mon') end
            || ' · ' || v_km || ' km',
          '/reimbursements?c=' || v_id);
      exception when others then null;
      end;
    end if;
  end if;

  -- Why each locked trip is excluded: the claim that locks it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'trip', x.trip, 'day', x.day, 'km', x.km, 'claim', c2.id, 'type', c2.doc_type,
           'from', c2.date_from, 'to', c2.date_to, 'status', c2.status,
           'by', c2.decided_by_name, 'at', c2.decided_at, 'amount', coalesce(c2.paid_amount, c2.amount),
           'paid_on', c2.paid_on, 'advice', c2.advice_number) order by x.day), '[]'::jsonb)
    into v_excl
    from (select l->>'trip' as trip, (l->>'day')::date as day, coalesce((l->>'km')::numeric, 0) as km,
                 public._reimb_lock_of(p_org, l->>'trip') as lock
            from jsonb_array_elements(v_lines) l where coalesce(l->>'trip', '') <> '') x
    join reimb_claims c2 on c2.id = x.lock;

  -- Older clients read "paid".
  select coalesce(jsonb_agg(jsonb_build_object('trip', l.trip, 'day', l.day, 'paid_on', p.paid_on,
                                               'ref', c2.paid_ref, 'claim', p.claim_id) order by l.day), '[]'::jsonb)
    into v_paid
    from (select distinct l->>'trip' as trip, (l->>'day')::date as day from jsonb_array_elements(v_lines) l) l
    join reimb_trip_paid p on p.org_id = p_org and p.trip_id = l.trip
    left join reimb_claims c2 on c2.id = p.claim_id;

  -- Generated on other sheets but NOT locked (locked ones are in "excluded").
  select coalesce(jsonb_agg(x order by x->>'day'), '[]'::jsonb) into v_gen
    from (
      select distinct on (s.trip, s.base) jsonb_build_object(
               'trip', s.trip, 'day', s.day, 'claim', s.base, 'type', s.typ, 'at', s.at,
               'from', (select min(g2.day) from reimb_generations g2 where g2.org_id = p_org and g2.doc_type = s.typ and g2.doc_key = s.base),
               'to',   (select max(g2.day) from reimb_generations g2 where g2.org_id = p_org and g2.doc_type = s.typ and g2.doc_key = s.base),
               'status', (select c3.status from reimb_claims c3 where c3.org_id = p_org and c3.doc_type = s.typ
                            and (c3.doc_key = s.base or c3.doc_key like s.base || '#%') order by c3.created_at desc limit 1)) as x
        from (
          select g.trip_id as trip, g.day, g.doc_key as base, g.doc_type as typ, g.first_at as at
            from reimb_generations g
            join (select distinct l->>'trip' as trip from jsonb_array_elements(v_lines) l) t on t.trip = g.trip_id
           where g.org_id = p_org
          union all
          select l2.trip_id, l2.day, regexp_replace(c2.doc_key, '#[0-9]+$', ''), c2.doc_type, c2.first_generated_at
            from reimb_lines l2
            join (select distinct l->>'trip' as trip from jsonb_array_elements(v_lines) l) t on t.trip = l2.trip_id
            join reimb_claims c2 on c2.id = l2.claim_id
           where l2.org_id = p_org and c2.status <> 'rejected'
        ) s
       where not (s.typ = p_type and s.base = p_key)
         and not (p_type = 'combined_summary' and s.typ = 'combined_summary'
                  and s.base like '%|' || split_part(p_key, '|', 2) || '|' || split_part(p_key, '|', 3))
         and public._reimb_lock_of(p_org, s.trip) is null
       order by s.trip, s.base, s.at
    ) q
   where coalesce(x->>'status', '') <> 'rejected';

  select min(first_at), coalesce(max(gen_count), 0) into v_first, v_count
    from reimb_generations where org_id = p_org and doc_type = p_type and doc_key = p_key;
  if v_first is null then
    select min(first_generated_at), coalesce(sum(generated_count), 0) into v_first, v_count
      from reimb_claims where org_id = p_org and doc_type = p_type and (doc_key = p_key or doc_key like p_key || '#%');
  end if;

  if v_id is not null then
    select * into c from reimb_claims where id = v_id;
  else
    c := last;
  end if;

  return jsonb_build_object('rate', v_rate, 'paid', v_paid, 'claim', c.id, 'status', c.status,
                            'paid_amount', c.paid_amount, 'paid_on', c.paid_on, 'paid_ref', c.paid_ref,
                            'paid_method', c.paid_method, 'approved_by', c.decided_by_name,
                            'generated', v_gen, 'sheet_first_at', v_first, 'sheet_count', v_count,
                            'excluded', v_excl);
end $$;
grant execute on function public.reimb_submit(text, text, text, text, jsonb, boolean) to authenticated;
