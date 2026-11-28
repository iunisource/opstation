-- 356 — Stock transfer REJECT made atomic + repair of ST-2026-0183.
--
-- What happened: ST-2026-0183 (Marrakah → Factory, "Claim from Pattoki") was
-- rejected on 13 Oct. Reject first flipped the status to 'rejected', then the
-- app returned the goods line by line from the browser. That second part never
-- ran (connection / page closed), so the dispatched quantities were taken out of
-- Marrakah and never put back. Cost layers never moved (they only move at
-- receipt), so Inventory Integrity showed stock < layers for those 8 products.
--
-- 1) reject_stock_transfer(): status change + returned stock in ONE
--    transaction — all or nothing. The app now calls this.
-- 2) Repair: every REJECTED transfer whose goods were never returned to the
--    source branch gets the missing return now (preview first, then apply).
-- 3) Check: any GRN that was LOCKED without being received (like GRN-2026-0137).
-- Safe to run again.

-- ── 1) Atomic reject ─────────────────────────────────────────────────────────
create or replace function public.reject_stock_transfer(p_transfer_id text, p_user_id text default null)
returns void
language plpgsql
as $$
declare
  t public.stock_transfers;
  v_moved_at timestamptz;
begin
  update public.stock_transfers
     set status = 'rejected', updated_at = now()
   where id = p_transfer_id and status = 'in_transit'
  returning * into t;
  if not found then
    raise exception 'Transfer % was already received, rejected or cancelled — nothing changed.', p_transfer_id;
  end if;

  v_moved_at := coalesce(
    (t.transfer_date::date + (now() at time zone 'Asia/Karachi')::time) at time zone 'Asia/Karachi',
    now());

  insert into public.inventory_movements
    (id, org_id, product_id, branch_id, uom_id, quantity, movement_type,
     reference_id, reference_type, moved_at, created_by, source_line_id)
  select 'im_' || i.id || '_ret', t.org_id, i.product_id, t.from_branch_id, i.uom_id,
         i.quantity, 'transfer', t.id, 'stock_transfer', v_moved_at, p_user_id, i.id || ':ret'
    from public.stock_transfer_items i
   where i.transfer_id = t.id and coalesce(i.quantity, 0) > 0;

  insert into public.inventory_stock (id, org_id, product_id, branch_id, uom_id, quantity, updated_at)
  select 'is_' || min(i.id), t.org_id, i.product_id, t.from_branch_id, min(i.uom_id), sum(i.quantity), now()
    from public.stock_transfer_items i
   where i.transfer_id = t.id and coalesce(i.quantity, 0) > 0
   group by i.product_id
  on conflict (org_id, product_id, branch_id)
  do update set quantity = public.inventory_stock.quantity + excluded.quantity, updated_at = now();

  begin
    insert into public.voucher_audit_log (org_id, voucher_id, voucher_type, action, details, performed_by)
    values (t.org_id, t.id, 'ST', 'rejected', 'Rejected — stock returned to source', p_user_id);
  exception when others then null; -- the audit line never blocks the reject
  end;
end $$;
grant execute on function public.reject_stock_transfer(text, text) to authenticated;

-- ── 2) Repair rejected transfers whose goods never came back ────────────────
-- PREVIEW: per rejected transfer + product, out at the source vs returned.
with x as (
  select t.id, t.voucher_number, t.org_id, t.from_branch_id, m.product_id,
         sum(case when m.quantity < 0 then -m.quantity else 0 end) as sent,
         sum(case when m.quantity > 0 then  m.quantity else 0 end) as returned
    from public.stock_transfers t
    join public.inventory_movements m
      on m.reference_type = 'stock_transfer' and m.reference_id = t.id and m.branch_id = t.from_branch_id
   where t.status = 'rejected'
   group by 1, 2, 3, 4, 5
)
select x.voucher_number, p.sku, p.name, x.sent, x.returned, x.sent - x.returned as missing
  from x left join public.products p on p.id = x.product_id
 where x.sent - x.returned > 0.0001
 order by x.voucher_number, p.name;

-- APPLY (ST-2026-0183 only): put the missing quantity back, dated at the rejection time.
-- If the preview lists OTHER transfers too, send me the list before fixing those.
do $$
declare r record; n int := 0;
begin
  for r in
    with x as (
      select t.id, t.org_id, t.from_branch_id, t.updated_at, m.product_id, min(m.uom_id) as uom_id,
             sum(case when m.quantity < 0 then -m.quantity else 0 end)
           - sum(case when m.quantity > 0 then  m.quantity else 0 end) as missing
        from public.stock_transfers t
        join public.inventory_movements m
          on m.reference_type = 'stock_transfer' and m.reference_id = t.id and m.branch_id = t.from_branch_id
       where t.status = 'rejected'
         and t.id = 'st_1791543318606'   -- ST-2026-0183 only; others in the preview are reported, not touched
       group by 1, 2, 3, 4, 5
    )
    select * from x where missing > 0.0001
  loop
    insert into public.inventory_movements
      (id, org_id, product_id, branch_id, uom_id, quantity, movement_type,
       reference_id, reference_type, moved_at, created_by, source_line_id, notes)
    values ('im_strep_' || r.id || '_' || r.product_id, r.org_id, r.product_id, r.from_branch_id, r.uom_id,
            r.missing, 'transfer', r.id, 'stock_transfer', coalesce(r.updated_at, now()), null,
            'repair:' || r.id || ':' || r.product_id, 'Returned to source — transfer rejected (repair)')
    on conflict (id) do nothing;
    if found then
      insert into public.inventory_stock (id, org_id, product_id, branch_id, uom_id, quantity, updated_at)
      values ('is_strep_' || r.id || '_' || r.product_id, r.org_id, r.product_id, r.from_branch_id, r.uom_id, r.missing, now())
      on conflict (org_id, product_id, branch_id)
      do update set quantity = public.inventory_stock.quantity + excluded.quantity, updated_at = now();
      n := n + 1;
    end if;
  end loop;
  raise notice 'Returned stock on % transfer line(s).', n;
end $$;

-- ── 3) Check: GRNs locked but never received (cost booked, no stock) ────────
select g.voucher_number, g.voucher_date, g.status, g.is_locked, g.locked_at
  from public.purchase_grns g
 where g.status = 'draft' and coalesce(g.is_locked, false) = true
 order by g.voucher_date;
