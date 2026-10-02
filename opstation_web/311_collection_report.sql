-- 311 — Collection Report (Reports ▸ Collection Report).
--
-- One row per collection in the period, from two sources side by side:
--
--   kind = 'booked'  receipts posted to the customer's account in the GL
--                    (CRV / BRV / PDC / POS cash / other receipts) — the same
--                    basis as Sale vs Recovery and the customer ledger.
--                    Salesperson + route come from the customer's route
--                    (route_stops → route_assignments).
--   kind = 'field'   amounts salespeople recorded on visits in the field app.
--                    Salesperson is the visit's user; route is the trip's route
--                    (falls back to the customer's route).
--
-- Void reversals are classified like the receipt they reverse, so a voided CRV
-- nets itself out. Dates are Pakistan local dates. Safe to run again.

create or replace function public.rpc_collection_report(p_org text, p_from date, p_to date)
returns table(kind text, d date, customer_id text, customer_name text,
              user_id text, route_id text, amount numeric, mode text, ref text)
language sql
stable
security definer
set search_path to 'public'
as $$
  with cust_route as (            -- one home route per customer (active routes only)
    select distinct on (rs.customer_id) rs.customer_id, rs.route_id
      from route_stops rs
      join sales_routes r on r.id = rs.route_id and r.org_id = p_org
                         and coalesce(r.is_active, true)
     order by rs.customer_id, rs.route_id
  ),
  route_sp as (                   -- one salesperson per route (prefer role salesperson, latest assignment)
    select distinct on (ra.route_id) ra.route_id, ra.user_id
      from route_assignments ra
      join sales_routes r on r.id = ra.route_id and r.org_id = p_org
      left join users u on u.id = ra.user_id
     order by ra.route_id, (coalesce(u.role, '') = 'salesperson') desc, ra.assigned_at desc nulls last
  ),
  gl as (
    select jl.party_id as cid,
           je.entry_date::date as d,
           coalesce(jl.credit, 0) - coalesce(jl.debit, 0) as amt,
           lower(case when je.reference_type = 'void'
                      then coalesce(orig.reference_type, 'jv')
                      else coalesce(je.reference_type, 'jv') end) as rt,
           coalesce(orig.reference_number, je.reference_number, je.entry_number) as ref
      from journal_lines jl
      join journal_entries je on je.id = jl.entry_id
      join customers c on c.id = jl.party_id and c.org_id = p_org
      left join journal_entries orig
             on je.reference_type = 'void' and orig.reversed_by = je.id
     where jl.org_id = p_org
       and coalesce(je.status, '') <> 'draft'
       and je.entry_date::date between p_from and p_to
  ),
  booked as (
    select g.cid, g.d, g.amt, g.ref,
           case when g.rt like 'crv%'  then 'CRV'
                when g.rt like 'brv%'  then 'BRV'
                when g.rt like 'pdc%'  then 'PDC'
                when g.rt like 'pos%'  then 'POS'
                else 'Receipt' end as mode
      from gl g
     where (g.rt in ('crv', 'brv', 'receipt', 'pdc')
            or g.rt like 'crv%' or g.rt like 'brv%' or g.rt like 'receipt%' or g.rt like 'pdc%'
            or (g.rt like 'pos%' and g.rt not like '%return%' and g.rt not like '%refund%' and g.amt > 0))
       and g.amt <> 0
  )
  select 'booked', b.d, b.cid, c.shop_name, sp.user_id, cr.route_id, b.amt, b.mode, b.ref
    from booked b
    join customers c on c.id = b.cid
    left join cust_route cr on cr.customer_id = b.cid
    left join route_sp sp on sp.route_id = cr.route_id
  union all
  select 'field',
         (v."timestamp" at time zone 'Asia/Karachi')::date,
         v.customer_id, c.shop_name, v.user_id,
         coalesce(t.route_id::text, cr.route_id),
         v.amount::numeric, 'Field', nullif(v.receipt_number::text, '')
    from visits v
    left join trips t on t.id::text = v.trip_id::text
    left join customers c on c.id = v.customer_id
    left join cust_route cr on cr.customer_id = v.customer_id
   where v.org_id = p_org
     and v."timestamp" >= (p_from::timestamp at time zone 'Asia/Karachi')
     and v."timestamp" <  ((p_to + 1)::timestamp at time zone 'Asia/Karachi')
     and coalesce(v.amount, 0) > 0;
$$;

grant execute on function public.rpc_collection_report(text, date, date) to authenticated;
