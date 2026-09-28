-- 285 — Sale vs Recovery report (Sales ▸ Ledgers & Reports).
--
-- Per customer, straight from the posted GL (every journal line tagged with the
-- customer as party — same basis as rpc_party_net_balances / the ledgers):
--
--   opening   = net receivable (debit − credit) before p_from
--   sale      = sales invoices / POS sales, net of sales returns   (in period)
--   recovery  = receipts (CRV / bank / PDC / cash paid at POS)     (in period)
--   journal   = everything else — JVs, payment vouchers, adjustments (in period)
--   closing   = opening + sale − recovery + journal                (as of p_to)
--
-- A void reversal is classified like the document it reverses, so voiding an
-- invoice inside the period nets the Sale column instead of showing up as a
-- journal entry.

create or replace function public.rpc_sale_vs_recovery(p_org text, p_from date, p_to date)
returns table(customer_id text, opening numeric, sale numeric, recovery numeric,
              journal numeric, closing numeric)
language sql
stable
security definer
set search_path to 'public'
as $$
  with l as (
    select jl.party_id,
           je.entry_date::date as d,
           coalesce(jl.debit, 0) - coalesce(jl.credit, 0) as amt,
           lower(case when je.reference_type = 'void'
                      then coalesce(orig.reference_type, 'jv')
                      else coalesce(je.reference_type, 'jv') end) as rt
      from journal_lines jl
      join journal_entries je on je.id = jl.entry_id
      join customers c on c.id = jl.party_id and c.org_id = p_org
      left join journal_entries orig
             on je.reference_type = 'void' and orig.reversed_by = je.id
     where jl.org_id = p_org
       and coalesce(je.status, '') <> 'draft'
       and je.entry_date::date <= p_to
  ), k as (
    select party_id, d, amt,
           case
             when rt in ('sales_invoice', 'delivery_order', 'sri')
                  or rt like 'sales_return%' or rt like 'sale_return%'
                  or (rt like 'pos%' and (rt like '%return%' or rt like '%refund%' or amt > 0))
               then 'sale'
             when rt in ('crv', 'brv', 'receipt', 'pdc')
                  or rt like 'crv%' or rt like 'brv%' or rt like 'receipt%' or rt like 'pdc%'
                  or rt like 'pos%'
               then 'recovery'
             else 'journal'
           end as cat
      from l
  )
  select party_id,
         coalesce(sum(amt) filter (where d < p_from), 0),
         coalesce(sum(amt) filter (where d >= p_from and cat = 'sale'), 0),
         coalesce(-sum(amt) filter (where d >= p_from and cat = 'recovery'), 0),
         coalesce(sum(amt) filter (where d >= p_from and cat = 'journal'), 0),
         coalesce(sum(amt), 0)
    from k
   group by party_id;
$$;

grant execute on function public.rpc_sale_vs_recovery(text, date, date) to authenticated;
