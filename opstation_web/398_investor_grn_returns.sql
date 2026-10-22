-- 398 — Investors: take sales returns off GRN-linked profit (toggle per investor).
--
--  * investors.deduct_returns (default ON) — the switch in the investor's setup.
--  * investor_grn_returns(): for each linked GRN, the returned units that came
--    from it, their return value and their original cost, in the period.
--      - POS returns: matched exactly to the original POS sale.
--      - Sales Return Invoices (issued, not voided): matched to that customer's
--        earlier invoiced sales of the same product, latest sale first. Each
--        sale can only be returned once, so returns never double-count.
--    Counted in the period of the return (SRI date / POS return date).
-- Safe to run again.

alter table public.investors add column if not exists deduct_returns boolean not null default true;

create or replace function public.investor_grn_returns(p_org text, p_grn_ids text[], p_from date, p_to date)
returns table(grn_id text, qty numeric, revenue numeric, cost numeric)
language plpgsql volatile security definer set search_path to 'public' as $$
declare r record; s record; v_left numeric; v_take numeric; v_price numeric;
begin
  if not public._is_org_member(p_org) then raise exception 'You do not have access to this organisation.'; end if;
  if p_grn_ids is null or cardinality(p_grn_ids) = 0 then return; end if;

  create temp table if not exists _igr_sales (
    cid text primary key, grn text, customer text, product text, sold_on date, left_qty numeric, unit_cost numeric
  ) on commit drop;
  create temp table if not exists _igr_out (grn text, q numeric, rev numeric, cst numeric) on commit drop;
  truncate _igr_sales; truncate _igr_out;

  -- Every invoiced sale (any stock, linked or not) for the customer + product
  -- pairs that ever received goods from the linked GRNs, up to the period end.
  insert into _igr_sales (cid, grn, customer, product, sold_on, left_qty, unit_cost)
  select distinct on (cc.id)
         cc.id::text,
         case when l.source_type = 'grn' and l.source_id = any (p_grn_ids) then l.source_id end,
         si.customer_id::text, cc.product_id::text, si.voucher_date::date, cc.qty_consumed, cc.unit_cost
    from public.inventory_cost_consumption cc
    join public.inventory_cost_layers l on l.id = cc.layer_id
    join public.sales_invoices si
      on (si.do_id = cc.source_id or si.id = cc.source_id)
     and coalesce(si.is_voided, false) = false and si.voucher_date <= p_to
   where l.org_id = p_org and cc.source_type <> 'pos' and cc.qty_consumed > 0
     and (si.customer_id, cc.product_id) in (
       select si2.customer_id, cc2.product_id
         from public.inventory_cost_consumption cc2
         join public.inventory_cost_layers l2 on l2.id = cc2.layer_id
         join public.sales_invoices si2
           on (si2.do_id = cc2.source_id or si2.id = cc2.source_id) and coalesce(si2.is_voided, false) = false
        where l2.org_id = p_org and l2.source_type = 'grn' and l2.source_id = any (p_grn_ids) and cc2.source_type <> 'pos')
   order by cc.id, si.voucher_date;

  -- Walk that customer's returns in date order; each takes from their latest
  -- earlier sales first. Returns before the period still use up sales (so they
  -- aren't counted twice) but only returns inside the period are deducted.
  for r in
    select ri.product_id::text as product, sr.customer_id::text as customer, sr.voucher_date::date as d,
           abs(coalesce(ri.quantity, 0)) as q,
           case when coalesce(ri.quantity, 0) <> 0 then abs(coalesce(ri.line_total, 0) / ri.quantity) else 0 end as price
      from public.sales_return_invoices sr
      join public.sales_return_invoice_items ri on ri.invoice_id = sr.id
     where sr.org_id = p_org and coalesce(sr.is_locked, false) and coalesce(sr.is_voided, false) = false
       and sr.voucher_date <= p_to and coalesce(ri.quantity, 0) <> 0
       and exists (select 1 from _igr_sales x where x.customer = sr.customer_id::text and x.product = ri.product_id::text)
     order by sr.voucher_date, sr.id, ri.id
  loop
    v_left := r.q;
    for s in
      select * from _igr_sales x
       where x.customer = r.customer and x.product = r.product and x.sold_on <= r.d and x.left_qty > 0
       order by x.sold_on desc, x.cid desc
    loop
      exit when v_left <= 0;
      v_take := least(s.left_qty, v_left);
      update _igr_sales set left_qty = left_qty - v_take where cid = s.cid;
      v_left := v_left - v_take;
      if s.grn is not null and r.d >= p_from then
        insert into _igr_out values (s.grn, v_take, v_take * r.price, v_take * s.unit_cost);
      end if;
    end loop;
  end loop;

  -- POS returns: exact link to the original sale; the returned quantity is
  -- spread over that sale's stock in the same proportion it was sold.
  insert into _igr_out
  select l.source_id,
         abs(ri.quantity) * cc.qty_consumed / tot.q,
         abs(ri.quantity) * cc.qty_consumed / tot.q *
           (coalesce(ri.unit_price, 0) - case when coalesce(ri.discount_type, 'fixed') = 'percent'
                                              then coalesce(ri.unit_price, 0) * coalesce(ri.discount, 0) / 100
                                              else coalesce(ri.discount, 0) / nullif(abs(ri.quantity), 0) end),
         abs(ri.quantity) * cc.qty_consumed / tot.q * cc.unit_cost
    from public.pos_transactions rt
    join public.pos_transaction_items ri on ri.transaction_id = rt.id and coalesce(ri.quantity, 0) <> 0
    join public.inventory_cost_consumption cc
      on cc.source_type = 'pos' and cc.source_id = rt.reference_transaction_id
     and cc.product_id = ri.product_id and cc.qty_consumed > 0
    join public.inventory_cost_layers l on l.id = cc.layer_id
    join (select c2.source_id, c2.product_id, sum(c2.qty_consumed) as q
            from public.inventory_cost_consumption c2
           where c2.source_type = 'pos' and c2.qty_consumed > 0
           group by c2.source_id, c2.product_id) tot
      on tot.source_id = cc.source_id and tot.product_id = cc.product_id
   where rt.org_id = p_org and rt.transaction_type = 'return' and rt.reference_transaction_id is not null
     and coalesce((to_jsonb(rt) ->> 'is_voided')::boolean, false) = false
     and (rt.transacted_at at time zone 'Asia/Karachi')::date between p_from and p_to
     and l.source_type = 'grn' and l.source_id = any (p_grn_ids);

  return query select o.grn, sum(o.q), sum(o.rev), sum(o.cst) from _igr_out o group by o.grn;
end $$;
grant execute on function public.investor_grn_returns(text, text[], date, date) to authenticated;

notify pgrst, 'reload schema';

-- Check
select count(*) filter (where deduct_returns) as investors_deducting_returns, count(*) as investors from public.investors;
