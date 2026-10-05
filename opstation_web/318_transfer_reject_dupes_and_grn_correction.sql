-- 318 — (A) Undo duplicate "Reject transfer" returns (all orgs)
--       (B) Integrity check: count a GRN quantity correction with its GRN
--
-- (A) Rejecting an in-transit stock transfer put the goods back into the source
--     branch. The button could run more than once for the same transfer (a retry
--     after an error, a double click, a stale screen) and each run added the stock
--     back again — e.g. ST st_1790070210447 was rejected 3 times on 5 Oct, so its
--     4 products came back 3×. Only the first return got cost layers, so stock
--     ran ahead of layers (Integrity Check: "Stock ≠ layers").
--     Fix: for every transfer, keep the FIRST return per product and reverse the
--     extra ones with an offsetting movement (audit-friendly — nothing deleted),
--     and take the extra quantity back off inventory_stock.
--
-- (B) A GRN quantity edit posts its GL correction under its own reference, while
--     the cost ledger updates the GRN's own layer. The check compared them apart
--     and flagged both halves (−2,920 and +2,920 on GRN-2026-0125). They are one
--     document: fold the correction into its GRN before comparing.
--
-- Safe to run again.

-- ── (A) ────────────────────────────────────────────────────────────────────────
create temp table if not exists _dup_fix (org_id text, transfer_id text, product_id text, branch_id text, extra_qty numeric);
truncate _dup_fix;

with ret as (
  select m.org_id, m.reference_id, m.product_id, m.branch_id, max(m.uom_id) as uom_id,
         sum(m.quantity) as returned, max(m.moved_at) as moved_at
    from inventory_movements m
    join stock_transfers st on st.id = m.reference_id and st.org_id = m.org_id
   where m.reference_type = 'stock_transfer'
     and m.id like 'im\_%\_ret' escape '\'
     and m.quantity > 0
     and m.branch_id = st.from_branch_id
   group by m.org_id, m.reference_id, m.product_id, m.branch_id
), expected as (   -- what one reject should have returned: the transfer's own quantity
  select t.org_id, t.id as reference_id, i.product_id, sum(i.quantity) as qty
    from stock_transfers t join stock_transfer_items i on i.transfer_id = t.id
   group by t.org_id, t.id, i.product_id
), extra as (
  select r.org_id, r.reference_id as transfer_id, r.product_id, r.branch_id, r.uom_id, r.moved_at,
         r.returned - e.qty as qty
    from ret r join expected e on e.org_id = r.org_id and e.reference_id = r.reference_id and e.product_id = r.product_id
   where r.returned - e.qty > 0.0001
), already as (   -- reversals posted by an earlier run of this script
  select org_id, reference_id as transfer_id, product_id, branch_id, -sum(quantity) as qty
    from inventory_movements
   where reference_type = 'stock_transfer' and notes like 'Reversal of duplicate reject%'
   group by org_id, reference_id, product_id, branch_id
), todo as (
  select e.org_id, e.transfer_id, e.product_id, e.branch_id, e.uom_id, e.moved_at,
         e.qty - coalesce(a.qty, 0) as qty
    from extra e
    left join already a using (org_id, transfer_id, product_id, branch_id)
   where e.qty - coalesce(a.qty, 0) > 0
), ins as (
  insert into inventory_movements(id, org_id, product_id, branch_id, uom_id, quantity, movement_type,
                                  reference_id, reference_type, moved_at, notes)
  select 'im_dupfix_' || replace(gen_random_uuid()::text, '-', ''), org_id, product_id, branch_id, uom_id,
         -qty, 'transfer', transfer_id, 'stock_transfer', moved_at,
         'Reversal of duplicate reject (transfer rejected more than once)'
    from todo
  returning org_id, reference_id, product_id, branch_id, -quantity as qty
)
insert into _dup_fix select org_id, reference_id, product_id, branch_id, qty from ins;

update inventory_stock s
   set quantity = s.quantity - f.q, updated_at = now()
  from (select org_id, product_id, branch_id, sum(extra_qty) as q from _dup_fix group by 1, 2, 3) f
 where s.org_id = f.org_id and s.product_id = f.product_id and s.branch_id = f.branch_id;

-- ── (B) ────────────────────────────────────────────────────────────────────────
-- Recreate the reconciliation with GRN quantity corrections folded into the GRN.
-- (Same as before plus the grn_qty_correction mapping; keeps the job-work fix.)
create or replace function public.rpc_inventory_gl_reconciliation(p_org_id text, p_from date, p_to date, p_branch_id text default null::text)
 returns table(doc_type text, voucher_no text, voucher_date date, gl_value numeric, ledger_value numeric, difference numeric, note text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
declare
  v_inv text;
begin
  select inventory_account_id into v_inv
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
      and jl.account_id = v_inv
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

-- What (A) reversed:
select f.org_id, coalesce(to_jsonb(st)->>'voucher_number', f.transfer_id) as transfer, p.name as product, b.name as branch, f.extra_qty as reversed_qty
  from _dup_fix f
  left join stock_transfers st on st.id = f.transfer_id
  left join products p on p.id = f.product_id
  left join branches b on b.id = f.branch_id
 order by 1, 2, 3;
