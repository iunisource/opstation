-- 436 — Inventory Integrity Check: stop false-flagging GRNs whose invoice
-- price differed after the goods were already sold.
--
-- When a Purchase Invoice comes in at a different price than the GRN cost,
-- post_purchase_invoice reprices the GRN's cost layers and splits the
-- difference: units still on hand → Stock in Hand ("Inventory cost true-up"),
-- units already sold → Purchase Price Variance ("Purchase price variance
-- (sold units)"). The check compared the GRN's inventory postings with the
-- REPRICED layers but ignored the sold-units variance, so it reported a
-- difference that isn't real (e.g. GRN-2026-0162: 10,200 vs 9,700).
--
-- Fix: for invoice entries, the "sold units" variance line is counted with the
-- GRN too. Nothing else changes. Safe to run again.

create or replace function public.rpc_inventory_gl_reconciliation__impl(p_org_id text, p_from date, p_to date, p_branch_id text DEFAULT NULL::text)
 RETURNS TABLE(doc_type text, voucher_no text, voucher_date date, gl_value numeric, ledger_value numeric, difference numeric, note text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_inv text;
  v_ppv text;
begin
  select inventory_account_id, ppv_account_id into v_inv, v_ppv
    from inventory_settings where org_id = p_org_id;
  return query
  with
  reval as (
    select distinct v.id
    from stock_adjustment_vouchers v
    join stock_adjustment_voucher_items i on i.voucher_id = v.id
    where v.org_id = p_org_id and i.line_type = 'revaluation'
  ),
  gl_base as (
    select
      case when je.reference_type = 'correction' then 'corrected' else je.reference_type end as ref_type_raw,
      je.reference_type                     as orig_type,
      je.reference_id                       as ref_id,
      je.reference_number                   as voucher_no,
      je.entry_date::date                   as vdate,
      round(sum(jl.credit - jl.debit), 2)   as gl_net
    from journal_entries je
    join journal_lines  jl on jl.entry_id = je.id
    where je.org_id = p_org_id
      and (jl.account_id = v_inv
           -- the invoice's price difference on units already sold belongs
           -- with the GRN's layers, which the invoice repriced
           or (v_ppv is not null and jl.account_id = v_ppv
               and je.reference_type = 'purchase_invoice'
               and jl.description = 'Purchase price variance (sold units)'))
      and je.entry_date between p_from and p_to
      and je.status is distinct from 'draft'
      and (p_branch_id is null or je.branch_id = p_branch_id)
      and je.reference_type <> 'opening_stock'
      and je.reference_type <> 'inventory_reconciliation'
      and je.reference_id not in (select id from reval)
    group by 1, 2, 3, 4, 5
  ),
  gl_raw as (
    select
      max(gb.orig_type) filter (where gb.orig_type <> 'correction') as ref_type,
      gb.ref_id,
      gb.voucher_no,
      max(gb.vdate)                 as vdate,
      round(sum(gb.gl_net), 2)      as gl_net
    from gl_base gb
    group by gb.ref_id, gb.voucher_no
  ),
  pi_to_grn as (
    select pi.id as pi_id, pi.grn_id
    from purchase_invoices pi
    where pi.org_id = p_org_id and pi.grn_id is not null
  ),
  grn_by_no as (
    select g.voucher_number, min(g.id) as grn_id
    from purchase_grns g
    where g.org_id = p_org_id
    group by g.voucher_number
  ),
  gl as (
    select
      case when g.ref_type = 'purchase_invoice' and m.grn_id is not null then 'grn'
           when g.ref_type = 'grn_qty_correction' and gn.grn_id is not null then 'grn'
           else coalesce(g.ref_type, 'unknown') end                as ref_type,
      coalesce(case when g.ref_type = 'purchase_invoice' then m.grn_id end,
               case when g.ref_type = 'grn_qty_correction' then gn.grn_id end,
               g.ref_id)                                         as ref_id,
      max(g.voucher_no)                                          as voucher_no,
      max(g.vdate)                                               as vdate,
      round(sum(g.gl_net), 2)                                    as gl_net
    from gl_raw g
    left join pi_to_grn m on m.pi_id = g.ref_id and g.ref_type = 'purchase_invoice'
    left join grn_by_no gn on gn.voucher_number = g.voucher_no and g.ref_type = 'grn_qty_correction'
    group by 1, 2
  ),
  gl_by_id as (
    select ref_id,
           max(ref_type)          as ref_type,
           max(voucher_no)        as voucher_no,
           max(vdate)             as vdate,
           round(sum(gl_net), 2)  as gl_net
    from gl
    group by ref_id
  ),
  ledger as (
    select source_id as ref_id, round(sum(val), 2) as net
    from (
      select icc.source_id, icc.qty_consumed * icc.unit_cost as val
      from inventory_cost_consumption icc
      where icc.org_id = p_org_id
        and (p_branch_id is null or icc.branch_id = p_branch_id)
      union all
      select coalesce(pjl.jobwork_id, l.source_id) as source_id, -(l.qty_in * l.unit_cost) as val
      from inventory_cost_layers l
      left join processor_jobwork_lines pjl
        on l.source_type = 'jobwork' and pjl.id = l.source_id
      where l.org_id = p_org_id
        and coalesce(l.source_type, '') not in ('negative', 'opening', 'reconcile', 'production')
        and (p_branch_id is null or l.branch_id = p_branch_id)
      union all
      select pv.id as source_id, -coalesce(pv.total_cost, 0) as val
      from production_vouchers pv
      where pv.org_id = p_org_id
        and coalesce(pv.status, '') = 'posted'
        and (p_branch_id is null or pv.branch_id = p_branch_id)
    ) x
    group by source_id
  )
  select
    g.ref_type,
    coalesce(g.voucher_no, '—'),
    g.vdate,
    g.gl_net,
    coalesce(l.net, 0),
    round(g.gl_net - coalesce(l.net, 0), 2),
    case
      when l.net is null
        then 'The GL moved inventory but the cost ledger has no record of it'
      when g.gl_net > l.net
        then 'The GL moved MORE value than the cost ledger — possible double-post'
      else 'The cost ledger moved MORE than the GL — possible missing journal entry'
    end
  from gl_by_id g
  left join ledger l on l.ref_id = g.ref_id
  where g.gl_net <> 0
    and abs(g.gl_net - coalesce(l.net, 0)) > 0.01
  order by abs(g.gl_net - coalesce(l.net, 0)) desc;
end
$function$;

notify pgrst, 'reload schema';
select 'integrity check: sold-units price variance counted with its GRN' as result;
