-- 389 — Batch & warranty tracking (Admin Settings → Inventory & Products)
--
--  * Switched by app_config 'org.batch_tracking'. While OFF nothing here does
--    anything — GRN, production and stock work exactly as today.
--  * Product: tracking None / Batch / Serial, warranty months, units per carton.
--  * GRN: tracked lines carry a batch/lot (defaults to the GRN number) and the
--    supplier warranty-until date (GRN date + product warranty months). A batch
--    row is made when the GRN is received, kept in step when quantities are
--    adjusted, and voided when the GRN is voided or deleted.
--  * Production (job batch / production voucher): bt_after_production() records
--    which component batches were used (manual pick first, then oldest first),
--    and makes unit serials + cartons for Serial products (or one batch row for
--    Batch products). Voiding the batch / voucher releases all of it.
--  * Nothing here can block a GRN or a production post: every trigger catches
--    its own errors.
-- Safe to run again.

-- ── columns ────────────────────────────────────────────────────────────────
alter table public.products add column if not exists batch_tracking text not null default 'none';
alter table public.products add column if not exists warranty_months int;
alter table public.products add column if not exists units_per_carton int;
do $chk$ begin
  if not exists (select 1 from pg_constraint where conname = 'products_batch_tracking_chk') then
    alter table public.products add constraint products_batch_tracking_chk
      check (batch_tracking in ('none', 'batch', 'serial'));
  end if;
end $chk$;

alter table public.purchase_grn_items add column if not exists batch_no text;
alter table public.purchase_grn_items add column if not exists warranty_until date;

-- ── tables ─────────────────────────────────────────────────────────────────
create table if not exists public.stock_batches (
  id             text primary key default gen_random_uuid()::text,
  org_id         text not null,
  branch_id      text,
  product_id     text not null,
  batch_no       text not null,
  source_type    text not null,          -- grn | job_run | production
  source_id      text not null,
  source_line_id text not null default '',
  source_number  text,
  supplier_id    text,
  received_on    date,
  warranty_until date,
  qty_in         numeric not null default 0,
  qty_used       numeric not null default 0,
  status         text not null default 'open',   -- open | void
  created_at     timestamptz not null default now()
);
create unique index if not exists stock_batches_src_uq on public.stock_batches (source_type, source_id, source_line_id);
create index if not exists stock_batches_prod_idx on public.stock_batches (org_id, product_id, status, received_on);
create index if not exists stock_batches_no_idx on public.stock_batches (org_id, lower(batch_no));

create table if not exists public.batch_allocations (
  id              text primary key default gen_random_uuid()::text,
  org_id          text not null,
  batch_id        text,                  -- null = taken from older, untracked stock
  product_id      text not null,
  consumer_type   text not null,         -- job_run | production
  consumer_id     text not null,
  consumer_number text,
  qty             numeric not null,
  manual          boolean not null default false,
  created_at      timestamptz not null default now()
);
create index if not exists batch_alloc_consumer_idx on public.batch_allocations (consumer_type, consumer_id);
create index if not exists batch_alloc_batch_idx on public.batch_allocations (batch_id);

create table if not exists public.product_cartons (
  id            text primary key default gen_random_uuid()::text,
  org_id        text not null,
  carton_no     text not null,
  product_id    text not null,
  source_type   text not null,
  source_id     text not null,
  source_number text,
  branch_id     text,
  qty           int not null default 0,
  status        text not null default 'in_stock',  -- in_stock | dispatched | void
  created_at    timestamptz not null default now()
);
create unique index if not exists product_cartons_no_uq on public.product_cartons (org_id, carton_no);
create index if not exists product_cartons_src_idx on public.product_cartons (source_type, source_id);

create table if not exists public.product_serials (
  id              text primary key default gen_random_uuid()::text,
  org_id          text not null,
  serial          text not null,
  product_id      text not null,
  carton_id       text,
  source_type     text not null,
  source_id       text not null,
  source_number   text,
  branch_id       text,
  produced_on     date,
  warranty_months int,
  status          text not null default 'in_stock',  -- in_stock | dispatched | void
  do_id           text,
  customer_id     text,
  dispatched_on   date,
  created_at      timestamptz not null default now()
);
create unique index if not exists product_serials_uq on public.product_serials (org_id, serial);
create index if not exists product_serials_src_idx on public.product_serials (source_type, source_id);
create index if not exists product_serials_carton_idx on public.product_serials (carton_id);

create table if not exists public.bt_counters (
  org_id text not null,
  kind   text not null,
  yymm   text not null,
  last   int  not null default 0,
  primary key (org_id, kind, yymm)
);

-- Read for org members; all writes go through the functions below.
do $rls$
declare t text;
begin
  foreach t in array array['stock_batches', 'batch_allocations', 'product_cartons', 'product_serials'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_sel', t);
    execute format('create policy %I on public.%I for select to authenticated using (public._is_org_member(org_id))', t || '_sel', t);
  end loop;
  alter table public.bt_counters enable row level security;
end $rls$;

-- ── helpers ────────────────────────────────────────────────────────────────
create or replace function public._bt_on(p_org text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.app_config
                  where org_id = p_org and key = 'org.batch_tracking' and value = 'true');
$$;

create or replace function public._bt_next(p_org text, p_kind text, p_yymm text, p_n int default 1)
returns int language plpgsql security definer set search_path to 'public' as $$
declare v int;
begin
  insert into public.bt_counters (org_id, kind, yymm, last) values (p_org, p_kind, p_yymm, p_n)
  on conflict (org_id, kind, yymm) do update set last = public.bt_counters.last + p_n
  returning last into v;
  return v - p_n + 1;   -- first number of the reserved block
end $$;

create or replace function public._bt_recount(p_batch text)
returns void language sql security definer set search_path to 'public' as $$
  update public.stock_batches b
     set qty_used = coalesce((select sum(a.qty) from public.batch_allocations a where a.batch_id = b.id), 0)
   where b.id = p_batch;
$$;

-- Batches for one GRN (made / refreshed when received; voided otherwise).
create or replace function public._bt_sync_grn(p_grn text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare g record; it record; v_live boolean;
begin
  select * into g from public.purchase_grns where id = p_grn;
  if not found then
    update public.stock_batches set status = 'void' where source_type = 'grn' and source_id = p_grn;
    return;
  end if;
  if not public._bt_on(g.org_id) then return; end if;
  v_live := coalesce(g.status, 'draft') <> 'draft' and coalesce(g.is_voided, false) = false;
  if not v_live then
    update public.stock_batches set status = 'void' where source_type = 'grn' and source_id = p_grn;
    return;
  end if;
  for it in
    select i.id, i.product_id, coalesce(i.qty_received, 0) as qty, i.batch_no, i.warranty_until,
           p.warranty_months
      from public.purchase_grn_items i
      join public.products p on p.id = i.product_id
     where i.grn_id = p_grn and coalesce(p.batch_tracking, 'none') <> 'none'
  loop
    insert into public.stock_batches (org_id, branch_id, product_id, batch_no, source_type, source_id,
        source_line_id, source_number, supplier_id, received_on, warranty_until, qty_in, status)
    values (g.org_id, g.branch_id, it.product_id,
        coalesce(nullif(trim(it.batch_no), ''), g.voucher_number, p_grn),
        'grn', p_grn, it.id, g.voucher_number, g.supplier_id, g.voucher_date::date,
        coalesce(it.warranty_until,
                 case when coalesce(it.warranty_months, 0) > 0
                      then (g.voucher_date::date + make_interval(months => it.warranty_months))::date end),
        it.qty, case when it.qty > 0 then 'open' else 'void' end)
    on conflict (source_type, source_id, source_line_id) do update set
        branch_id = excluded.branch_id, batch_no = excluded.batch_no, source_number = excluded.source_number,
        supplier_id = excluded.supplier_id, received_on = excluded.received_on,
        warranty_until = excluded.warranty_until, qty_in = excluded.qty_in, status = excluded.status;
  end loop;
  -- lines removed from the GRN (or no longer tracked)
  update public.stock_batches b set status = 'void'
   where b.source_type = 'grn' and b.source_id = p_grn
     and not exists (select 1 from public.purchase_grn_items i
                       join public.products p on p.id = i.product_id
                      where i.id = b.source_line_id and coalesce(p.batch_tracking, 'none') <> 'none');
end $$;

-- ── triggers (never block the GRN) ────────────────────────────────────────
create or replace function public.trg_bt_grn()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    if TG_OP = 'DELETE' then
      update public.stock_batches set status = 'void' where source_type = 'grn' and source_id = OLD.id;
    elsif OLD.status is distinct from NEW.status or OLD.is_voided is distinct from NEW.is_voided
       or OLD.voucher_date is distinct from NEW.voucher_date or OLD.voucher_number is distinct from NEW.voucher_number then
      perform public._bt_sync_grn(NEW.id);
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists bt_grn on public.purchase_grns;
create trigger bt_grn after update or delete on public.purchase_grns
  for each row execute function public.trg_bt_grn();

create or replace function public.trg_bt_grn_item()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    if TG_OP = 'DELETE' then
      update public.stock_batches set status = 'void'
       where source_type = 'grn' and source_id = OLD.grn_id and source_line_id = OLD.id;
    elsif exists (select 1 from public.stock_batches where source_type = 'grn' and source_id = NEW.grn_id)
       or exists (select 1 from public.purchase_grns where id = NEW.grn_id and coalesce(status, 'draft') <> 'draft') then
      perform public._bt_sync_grn(NEW.grn_id);
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists bt_grn_item on public.purchase_grn_items;
create trigger bt_grn_item after update of qty_received, batch_no, warranty_until, product_id or delete
  on public.purchase_grn_items for each row execute function public.trg_bt_grn_item();

-- Releases everything one production made / used (void, reverse, delete).
create or replace function public._bt_release(p_type text, p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare b text;
begin
  for b in delete from public.batch_allocations where consumer_type = p_type and consumer_id = p_id
            returning batch_id loop
    if b is not null then perform public._bt_recount(b); end if;
  end loop;
  update public.product_serials set status = 'void' where source_type = p_type and source_id = p_id and status = 'in_stock';
  update public.product_cartons set status = 'void' where source_type = p_type and source_id = p_id and status = 'in_stock';
  update public.stock_batches set status = 'void' where source_type = p_type and source_id = p_id;
end $$;

create or replace function public.trg_bt_run()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    if TG_OP = 'DELETE' then
      perform public._bt_release('job_run', OLD.id);
    elsif OLD.status = 'posted' and NEW.status is distinct from 'posted' then
      perform public._bt_release('job_run', NEW.id);
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists bt_run on public.job_card_runs;
create trigger bt_run after update of status or delete on public.job_card_runs
  for each row execute function public.trg_bt_run();

create or replace function public.trg_bt_prd()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    if TG_OP = 'DELETE' then
      perform public._bt_release('production', OLD.id);
    elsif OLD.status = 'posted' and NEW.status is distinct from 'posted' then
      perform public._bt_release('production', NEW.id);
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists bt_prd on public.production_vouchers;
create trigger bt_prd after update of status or delete on public.production_vouchers
  for each row execute function public.trg_bt_prd();

-- ── after a production post ───────────────────────────────────────────────
-- p_source_type: 'job_run' | 'production'.  p_picks: {"<component product id>": "<batch id>"}.
-- p_fallback: [{"product_id": "...", "qty": 5}] used only when no stock movement
-- is found for a component. Safe to call again (returns what was made before).
create or replace function public.bt_after_production(
  p_source_type text, p_source_id text, p_source_number text,
  p_product text, p_qty numeric, p_branch text, p_date date,
  p_picks jsonb default '{}'::jsonb, p_fallback jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_org text; v_track text; v_wm int; v_per int; v_sku text; v_prefix text; v_yymm text;
  v_need numeric; v_take numeric; v_pick text; v_start int; v_cstart int; v_units int;
  v_cartons int; v_carton_id text; v_carton_no text; i int; c record; b record;
  v_out jsonb;
begin
  v_org := (select org_id from public.products where id = p_product);
  if v_org is null or not public._is_org_member(v_org) then
    raise exception 'You do not have access to this product.';
  end if;
  if not public._bt_on(v_org) then return jsonb_build_object('on', false); end if;
  p_date := coalesce(p_date, current_date);
  v_yymm := to_char(p_date, 'YYMM');

  -- 1) component batches (once per source)
  if not exists (select 1 from public.batch_allocations where consumer_type = p_source_type and consumer_id = p_source_id) then
    for c in
      with mv as (
        select m.product_id, sum(-m.quantity) as qty
          from public.inventory_movements m
         where m.reference_id = p_source_id and m.quantity < 0
         group by m.product_id
      ), fb as (
        select x->>'product_id' as product_id, sum((x->>'qty')::numeric) as qty
          from jsonb_array_elements(coalesce(p_fallback, '[]'::jsonb)) x
         where coalesce(x->>'product_id', '') <> ''
         group by 1
      ), need as (
        select product_id, qty from mv
        union all
        select fb.product_id, fb.qty from fb where not exists (select 1 from mv where mv.product_id = fb.product_id)
      )
      select n.product_id, n.qty from need n
        join public.products p on p.id = n.product_id
       where coalesce(p.batch_tracking, 'none') <> 'none' and n.qty > 0
    loop
      v_need := c.qty;
      v_pick := nullif(coalesce(p_picks, '{}'::jsonb)->>c.product_id, '');
      if v_pick is not null then
        select * into b from public.stock_batches
         where id = v_pick and org_id = v_org and product_id = c.product_id and status = 'open';
        if found then
          v_take := least(v_need, greatest(b.qty_in - b.qty_used, 0));
          if v_take > 0 then
            insert into public.batch_allocations (org_id, batch_id, product_id, consumer_type, consumer_id, consumer_number, qty, manual)
            values (v_org, b.id, c.product_id, p_source_type, p_source_id, p_source_number, v_take, true);
            perform public._bt_recount(b.id);
            v_need := v_need - v_take;
          end if;
        end if;
      end if;
      for b in
        select * from public.stock_batches
         where org_id = v_org and product_id = c.product_id and status = 'open' and qty_in > qty_used
         order by (branch_id is not distinct from p_branch) desc, received_on nulls last, created_at
      loop
        exit when v_need <= 0;
        v_take := least(v_need, b.qty_in - b.qty_used);
        insert into public.batch_allocations (org_id, batch_id, product_id, consumer_type, consumer_id, consumer_number, qty, manual)
        values (v_org, b.id, c.product_id, p_source_type, p_source_id, p_source_number, v_take, false);
        perform public._bt_recount(b.id);
        v_need := v_need - v_take;
      end loop;
      if v_need > 0 then
        insert into public.batch_allocations (org_id, batch_id, product_id, consumer_type, consumer_id, consumer_number, qty, manual)
        values (v_org, null, c.product_id, p_source_type, p_source_id, p_source_number, v_need, false);
      end if;
    end loop;
  end if;

  -- 2) the finished product
  select coalesce(batch_tracking, 'none'), warranty_months, units_per_carton, sku
    into v_track, v_wm, v_per, v_sku
    from public.products where id = p_product;

  if v_track = 'serial' and coalesce(p_qty, 0) >= 1
     and not exists (select 1 from public.product_serials where source_type = p_source_type and source_id = p_source_id) then
    v_units := least(floor(p_qty)::int, 20000);
    v_prefix := upper(regexp_replace(coalesce(nullif(trim(v_sku), ''), 'SN'), '[^A-Za-z0-9]+', '', 'g'));
    if v_prefix = '' then v_prefix := 'SN'; end if;
    v_start := public._bt_next(v_org, 'serial:' || p_product, v_yymm, v_units);
    v_cartons := case when coalesce(v_per, 0) > 0 then ceil(v_units::numeric / v_per)::int else 0 end;
    if v_cartons > 0 then v_cstart := public._bt_next(v_org, 'carton', v_yymm, v_cartons); end if;
    for i in 0 .. v_units - 1 loop
      if v_cartons > 0 and i % v_per = 0 then
        v_carton_no := 'C-' || v_yymm || '-' || lpad((v_cstart + i / v_per)::text, 4, '0');
        insert into public.product_cartons (org_id, carton_no, product_id, source_type, source_id, source_number, branch_id, qty)
        values (v_org, v_carton_no, p_product, p_source_type, p_source_id, p_source_number, p_branch,
                least(v_per, v_units - i))
        returning id into v_carton_id;
      end if;
      insert into public.product_serials (org_id, serial, product_id, carton_id, source_type, source_id, source_number,
          branch_id, produced_on, warranty_months)
      values (v_org, v_prefix || '-' || v_yymm || '-' || lpad((v_start + i)::text, 6, '0'), p_product,
          case when v_cartons > 0 then v_carton_id end, p_source_type, p_source_id, p_source_number,
          p_branch, p_date, v_wm);
    end loop;
  elsif v_track = 'batch' and coalesce(p_qty, 0) > 0 then
    insert into public.stock_batches (org_id, branch_id, product_id, batch_no, source_type, source_id, source_line_id,
        source_number, received_on, warranty_until, qty_in)
    values (v_org, p_branch, p_product, coalesce(nullif(p_source_number, ''), p_source_id), p_source_type, p_source_id, '',
        p_source_number, p_date,
        case when coalesce(v_wm, 0) > 0 then (p_date + make_interval(months => v_wm))::date end, p_qty)
    on conflict (source_type, source_id, source_line_id) do nothing;
  end if;

  v_out := jsonb_build_object(
    'on', true,
    'tracking', v_track,
    'serials', coalesce((select jsonb_agg(jsonb_build_object('serial', s.serial, 'carton', ct.carton_no) order by s.serial)
                           from public.product_serials s left join public.product_cartons ct on ct.id = s.carton_id
                          where s.source_type = p_source_type and s.source_id = p_source_id and s.status <> 'void'), '[]'::jsonb),
    'cartons', coalesce((select jsonb_agg(jsonb_build_object('carton', ct.carton_no, 'qty', ct.qty,
                              'first', (select min(serial) from public.product_serials where carton_id = ct.id),
                              'last',  (select max(serial) from public.product_serials where carton_id = ct.id)) order by ct.carton_no)
                           from public.product_cartons ct
                          where ct.source_type = p_source_type and ct.source_id = p_source_id and ct.status <> 'void'), '[]'::jsonb),
    'components', coalesce((select jsonb_agg(jsonb_build_object('product_id', a.product_id, 'qty', a.qty,
                              'batch_no', sb.batch_no, 'manual', a.manual))
                           from public.batch_allocations a left join public.stock_batches sb on sb.id = a.batch_id
                          where a.consumer_type = p_source_type and a.consumer_id = p_source_id), '[]'::jsonb));
  return v_out;
end $$;
grant execute on function public.bt_after_production(text, text, text, text, numeric, text, date, jsonb, jsonb) to authenticated;

-- Back-fill: makes batches for GRNs received before a product was marked
-- tracked (Batch Tracking page → "Pick up past GRNs").
create or replace function public.bt_rebuild_grn_batches(p_org text, p_product text default null)
returns int language plpgsql security definer set search_path to 'public' as $$
declare v_org text := p_org; g record; n int := 0;
begin
  if v_org is null or not public._is_org_member(v_org) or not public._bt_on(v_org) then return 0; end if;
  for g in
    select distinct h.id from public.purchase_grns h
      join public.purchase_grn_items i on i.grn_id = h.id
      join public.products p on p.id = i.product_id
     where h.org_id = v_org and coalesce(h.status, 'draft') <> 'draft' and coalesce(h.is_voided, false) = false
       and coalesce(p.batch_tracking, 'none') <> 'none'
       and (p_product is null or p.id = p_product)
  loop
    perform public._bt_sync_grn(g.id);
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.bt_rebuild_grn_batches(text, text) to authenticated;

notify pgrst, 'reload schema';

-- Check
select table_name from information_schema.tables
 where table_schema = 'public' and table_name in ('stock_batches', 'batch_allocations', 'product_cartons', 'product_serials', 'bt_counters')
 order by 1;
