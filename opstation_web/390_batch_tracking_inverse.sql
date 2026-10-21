-- 390 — Batch tracking for Production Inverse (disassembly). Needs 389.
--
-- When a disassembly posts (status → posted), automatically:
--  * Serial product: the units being taken apart are marked "Disassembled"
--    (the serials picked on the voucher; if none / too few were picked, the
--    newest units still in stock from the source production voucher). A
--    carton whose units are all gone is closed too.
--  * Batch product: the quantity is taken out of the source voucher's batch
--    (or oldest batches in free mode).
--  * Recovered components go back into the batches they came
--    from — the source voucher's batches first, else the latest used batch.
-- If the disassembly is ever voided or deleted, all of it is put back.
-- Never blocks the post. Safe to run again.

alter table public.production_inverse_vouchers add column if not exists bt_serials jsonb;
alter table public.product_serials add column if not exists broken_by text;
alter table public.product_serials add column if not exists broken_number text;

create or replace function public._bt_after_inverse(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  v record; c record; b record;
  v_track text; v_need numeric; v_take numeric; v_units int; v_picked int;
begin
  select * into v from public.production_inverse_vouchers where id = p_id;
  if not found or not public._bt_on(v.org_id) then return; end if;
  if exists (select 1 from public.batch_allocations where consumer_type = 'inverse' and consumer_id = p_id)
     or exists (select 1 from public.product_serials where broken_by = p_id) then
    return;   -- already done
  end if;

  -- 1) the finished product taken apart
  v_track := coalesce((select batch_tracking from public.products where id = v.product_id), 'none');
  if v_track = 'serial' then
    v_units := floor(coalesce(v.input_qty, 0))::int;
    -- picked serials first
    update public.product_serials s set status = 'broken', broken_by = p_id, broken_number = v.voucher_number
     where s.org_id = v.org_id and s.product_id = v.product_id and s.status = 'in_stock'
       and s.serial in (select jsonb_array_elements_text(coalesce(v.bt_serials, '[]'::jsonb)) limit greatest(v_units, 0));
    get diagnostics v_picked = row_count;
    -- the rest: newest units of the source production voucher
    if v_picked < v_units and v.source_voucher_id is not null then
      update public.product_serials s set status = 'broken', broken_by = p_id, broken_number = v.voucher_number
       where s.id in (select id from public.product_serials
                       where source_type = 'production' and source_id = v.source_voucher_id
                         and product_id = v.product_id and status = 'in_stock'
                       order by serial desc limit (v_units - v_picked));
    end if;
    -- cartons with nothing left in them
    update public.product_cartons ct set status = 'broken'
     where ct.status = 'in_stock'
       and exists (select 1 from public.product_serials s where s.carton_id = ct.id and s.broken_by = p_id)
       and not exists (select 1 from public.product_serials s where s.carton_id = ct.id and s.status = 'in_stock');
  elsif v_track = 'batch' and coalesce(v.input_qty, 0) > 0 then
    v_need := v.input_qty;
    for b in
      select * from public.stock_batches
       where org_id = v.org_id and product_id = v.product_id and status = 'open' and qty_in > qty_used
       order by (source_type = 'production' and source_id is not distinct from v.source_voucher_id) desc,
                (branch_id is not distinct from v.branch_id) desc, received_on nulls last, created_at
    loop
      exit when v_need <= 0;
      v_take := least(v_need, b.qty_in - b.qty_used);
      insert into public.batch_allocations (org_id, batch_id, product_id, consumer_type, consumer_id, consumer_number, qty)
      values (v.org_id, b.id, v.product_id, 'inverse', p_id, v.voucher_number, v_take);
      perform public._bt_recount(b.id);
      v_need := v_need - v_take;
    end loop;
  end if;

  -- 2) recovered components back into their batches (negative use)
  for c in
    select ic.product_id, sum(ic.quantity) as qty
      from public.production_inverse_components ic
      join public.products p on p.id = ic.product_id
     where ic.voucher_id = p_id and coalesce(p.batch_tracking, 'none') <> 'none' and coalesce(ic.quantity, 0) > 0
     group by ic.product_id
  loop
    v_need := c.qty;
    for b in
      select sb.*, coalesce(src.used, 0) as src_used
        from public.stock_batches sb
        left join (select batch_id, sum(qty) as used from public.batch_allocations
                    where consumer_type = 'production' and consumer_id = v.source_voucher_id
                    group by batch_id) src on src.batch_id = sb.id
       where sb.org_id = v.org_id and sb.product_id = c.product_id and sb.status = 'open' and sb.qty_used > 0
       order by (coalesce(src.used, 0) > 0) desc, sb.received_on desc nulls last, sb.created_at desc
    loop
      exit when v_need <= 0;
      v_take := least(v_need, b.qty_used);
      insert into public.batch_allocations (org_id, batch_id, product_id, consumer_type, consumer_id, consumer_number, qty)
      values (v.org_id, b.id, c.product_id, 'inverse', p_id, v.voucher_number, -v_take);
      perform public._bt_recount(b.id);
      v_need := v_need - v_take;
    end loop;
  end loop;
end $$;

create or replace function public._bt_release_inverse(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare b text;
begin
  for b in delete from public.batch_allocations where consumer_type = 'inverse' and consumer_id = p_id
            returning batch_id loop
    if b is not null then perform public._bt_recount(b); end if;
  end loop;
  update public.product_cartons ct set status = 'in_stock'
   where ct.status = 'broken'
     and exists (select 1 from public.product_serials s where s.carton_id = ct.id and s.broken_by = p_id);
  update public.product_serials set status = 'in_stock', broken_by = null, broken_number = null
   where broken_by = p_id and status = 'broken';
end $$;

create or replace function public.trg_bt_inverse()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    if TG_OP = 'DELETE' then
      perform public._bt_release_inverse(OLD.id);
    elsif NEW.status = 'posted' and OLD.status is distinct from 'posted' then
      perform public._bt_after_inverse(NEW.id);
    elsif OLD.status = 'posted' and NEW.status is distinct from 'posted' then
      perform public._bt_release_inverse(NEW.id);
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists bt_inverse on public.production_inverse_vouchers;
create trigger bt_inverse after update of status or delete on public.production_inverse_vouchers
  for each row execute function public.trg_bt_inverse();

-- Disassemblies already posted since tracking was switched on.
do $bf$
declare r record;
begin
  for r in select v.id from public.production_inverse_vouchers v
            where v.status = 'posted'
              and v.created_at >= (select min(created_at) from public.stock_batches b where b.org_id = v.org_id) loop
    begin perform public._bt_after_inverse(r.id); exception when others then null; end;
  end loop;
end $bf$;

notify pgrst, 'reload schema';

-- Check
select count(*) as disassembled_units from public.product_serials where status = 'broken';
