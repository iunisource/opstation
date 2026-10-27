-- 426 — Quick Costing: price a prospect's custom spec without creating a
-- product or BOM first. Costs are worked out on the server; people who are
-- not allowed to see costs and profit only ever receive the selling price.
--
-- Who sees costs / profit: admins (and super admins) always; everyone with
-- the Quick Costing screen when org.quick_costing_cost_access = 'true'.
-- Default profit for people who can't see costs: org.quick_costing_default_profit.
-- Safe to run again.

-- ---------------------------------------------------------------- tables
create table if not exists public.quick_costings (
  id              text primary key default ('qc_' || replace(gen_random_uuid()::text, '-', '')),
  org_id          text not null,
  branch_id       text,
  code            text not null,
  prospect_name   text not null default '',
  prospect_phone  text,
  title           text not null default '',
  specs           text,
  quantity        numeric not null default 1,
  output_qty      numeric not null default 1,
  basis           text not null default 'method',
  wastage_pct     numeric not null default 0,
  profit_pct      numeric not null default 0,
  price_override  numeric,
  valid_days      int not null default 7,
  material_cost   numeric,
  wastage_cost    numeric,
  labor_cost      numeric,
  batch_cost      numeric,
  unit_cost       numeric,
  unit_price      numeric,
  total_price     numeric,
  notes           text,
  status          text not null default 'draft',
  product_id      text,
  bom_id          text,
  created_by      text,
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_by_name text,
  updated_at      timestamptz not null default now(),
  priced_at       timestamptz not null default now(),
  constraint quick_costings_code_uq unique (org_id, code),
  constraint quick_costings_basis_ck check (basis in ('method', 'purchase')),
  constraint quick_costings_status_ck check (status in ('draft', 'sent', 'won', 'lost'))
);
alter table public.quick_costings add column if not exists priced_at timestamptz not null default now();
alter table public.quick_costings add column if not exists seq int;
create index if not exists quick_costings_org_idx on public.quick_costings (org_id, updated_at desc);

create table if not exists public.quick_costing_lines (
  id            text primary key default ('qcl_' || replace(gen_random_uuid()::text, '-', '')),
  costing_id    text not null references public.quick_costings(id) on delete cascade,
  line_order    int not null default 0,
  kind          text not null,
  product_id    text,
  rate_id       text,
  description   text not null default '',
  uom           text,
  qty           numeric not null default 0,
  cost_override numeric,
  unit_cost     numeric,
  cost_source   text,
  amount        numeric,
  constraint quick_costing_lines_kind_ck check (kind in ('material', 'labor', 'overhead'))
);
create index if not exists quick_costing_lines_parent_idx on public.quick_costing_lines (costing_id, line_order);

-- ---------------------------------------------------------------- access
create or replace function public._qc_can_use(p_org text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public._is_org_member(p_org) or public._is_super_admin();
$$;

create or replace function public._qc_can_see_costs(p_org text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public._qc_can_use(p_org)
     and (public._is_org_admin(p_org) or public._cfg_true(p_org, 'org.quick_costing_cost_access'));
$$;

create or replace function public._qc_default_profit(p_org text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select case when value ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' then value::numeric end
                     from public.app_config
                    where org_id = p_org and key = 'org.quick_costing_default_profit'
                    order by branch_id nulls first limit 1), 25);
$$;

-- Tables are read only through the functions below (which hide costs from
-- people who may not see them). Direct reads: only cost-allowed users.
alter table public.quick_costings enable row level security;
alter table public.quick_costing_lines enable row level security;
drop policy if exists qc_read on public.quick_costings;
create policy qc_read on public.quick_costings for select
  using (public._qc_can_see_costs(org_id));
drop policy if exists qcl_read on public.quick_costing_lines;
create policy qcl_read on public.quick_costing_lines for select
  using (exists (select 1 from public.quick_costings q
                  where q.id = costing_id and public._qc_can_see_costs(q.org_id)));

-- ---------------------------------------------------------------- unit costs
-- Cost per unit of one product.
--   method   = stock cost from the costing engine (FIFO / average), else the
--              product's cost price
--   purchase = latest purchase invoice rate, else falls back to method
create or replace function public._qc_method_costs(p_org text, p_branch text, p_ids text[])
returns table (product_id text, unit_cost numeric)
language plpgsql security definer set search_path to 'public' as $$
begin
  if p_ids is null or array_length(p_ids, 1) is null then return; end if;
  begin
    if p_branch is not null then
      return query
        select c.product_id::text, c.unit_cost::numeric
          from public.rpc_stock_unit_costs(p_org, p_branch) c
         where c.product_id = any (p_ids) and coalesce(c.unit_cost, 0) > 0;
    end if;
  exception when others then
    null;   -- engine unavailable: product cost price below
  end;
  return query
    select p.id, p.cost_price::numeric
      from public.products p
     where p.org_id = p_org and p.id = any (p_ids);
end $$;

create or replace function public._qc_last_purchase(p_org text, p_product text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select case when coalesce(i.qty_received, 0) > 0 and coalesce(i.line_total, 0) > 0
              then i.line_total / i.qty_received
              else i.unit_cost end
    from public.purchase_invoice_items i
    join public.purchase_invoices v on v.id = i.invoice_id
   where v.org_id = p_org and i.product_id = p_product
     and not coalesce(v.is_voided, false)
     and coalesce(i.unit_cost, 0) > 0
   order by v.voucher_date desc nulls last, v.created_at desc nulls last
   limit 1;
$$;

-- ---------------------------------------------------------------- calculator
-- p: {org_id, branch_id, basis, quantity, output_qty, wastage_pct, profit_pct,
--     price_override, lines:[{id, kind, product_id, rate_id, description, uom,
--     qty, cost_override}]}
-- p_keep: existing costing id whose profit / price / cost overrides are kept
--         when the caller may not see costs.
create or replace function public._qc_compute(p jsonb, p_keep text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_org text := p ->> 'org_id';
  v_branch text := nullif(p ->> 'branch_id', '');
  v_basis text := case when p ->> 'basis' = 'purchase' then 'purchase' else 'method' end;
  v_see boolean;
  v_qty numeric := greatest(coalesce((p ->> 'quantity')::numeric, 1), 0);
  v_out numeric := coalesce((p ->> 'output_qty')::numeric, 1);
  v_waste numeric := greatest(coalesce((p ->> 'wastage_pct')::numeric, 0), 0);
  v_profit numeric; v_override numeric;
  v_ids text[];
  v_method jsonb := '{}'::jsonb;
  l jsonb; v_lines jsonb := '[]'::jsonb;
  v_kind text; v_pid text; v_rid text; v_lq numeric; v_cost numeric; v_src text; v_ovr numeric;
  v_old_ovr numeric;
  v_mat numeric := 0; v_lab numeric := 0; v_wcost numeric; v_batch numeric; v_unit numeric;
  v_sugg numeric; v_price numeric; v_i int := 0;
  k record;
begin
  if v_org is null or not public._qc_can_use(v_org) then
    raise exception 'You do not have access to Quick Costing.';
  end if;
  v_see := public._qc_can_see_costs(v_org);
  if v_out is null or v_out <= 0 then v_out := 1; end if;

  if v_see then
    v_profit := coalesce((p ->> 'profit_pct')::numeric, public._qc_default_profit(v_org));
    v_override := nullif((p ->> 'price_override')::numeric, 0);
  elsif p_keep is not null then
    select q.profit_pct, q.price_override into v_profit, v_override
      from public.quick_costings q where q.id = p_keep;
  end if;
  v_profit := coalesce(v_profit, public._qc_default_profit(v_org));

  -- stock costs for every product line, fetched once
  select array_agg(distinct x ->> 'product_id') into v_ids
    from jsonb_array_elements(coalesce(p -> 'lines', '[]'::jsonb)) x
   where x ->> 'kind' = 'material' and coalesce(x ->> 'product_id', '') <> '';
  for k in select * from public._qc_method_costs(v_org, v_branch, v_ids) loop
    if not v_method ? k.product_id then
      v_method := v_method || jsonb_build_object(k.product_id, k.unit_cost);
    end if;
  end loop;

  for l in select value from jsonb_array_elements(coalesce(p -> 'lines', '[]'::jsonb)) loop
    v_kind := case when l ->> 'kind' in ('labor', 'overhead') then l ->> 'kind' else 'material' end;
    v_pid := nullif(l ->> 'product_id', '');
    v_rid := nullif(l ->> 'rate_id', '');
    v_lq := coalesce((l ->> 'qty')::numeric, 0);
    v_ovr := (l ->> 'cost_override')::numeric;
    v_cost := null; v_src := null;

    -- A one-off item's price is typed by the user, so it is always taken.
    -- A stocked item's cost can only be replaced by someone who sees costs;
    -- otherwise any replacement already saved on this line is kept.
    if v_kind = 'material' and v_pid is not null and not v_see then
      v_ovr := null;
      if p_keep is not null and coalesce(l ->> 'id', '') <> '' then
        select cost_override into v_old_ovr from public.quick_costing_lines
         where costing_id = p_keep and id = l ->> 'id';
        v_ovr := v_old_ovr;
      end if;
    end if;

    if v_kind = 'material' then
      if v_pid is null then
        v_cost := coalesce(v_ovr, 0); v_src := 'typed';
      elsif v_ovr is not null and v_ovr >= 0 then
        v_cost := v_ovr; v_src := 'manual';
      else
        if v_basis = 'purchase' then
          v_cost := public._qc_last_purchase(v_org, v_pid);
          v_src := case when v_cost is null then 'no purchase yet' else 'last purchase' end;
        end if;
        if v_cost is null then
          v_cost := (v_method ->> v_pid)::numeric;
          v_src := coalesce(v_src, 'stock cost');
        end if;
        v_cost := coalesce(v_cost, 0);
        if v_cost = 0 then v_src := 'no cost found'; end if;
      end if;
      v_mat := v_mat + v_lq * v_cost;
    else
      if v_kind = 'labor' then
        select rate into v_cost from public.labor_types where id = v_rid and org_id = v_org;
      else
        select rate into v_cost from public.overhead_types where id = v_rid and org_id = v_org;
      end if;
      v_cost := coalesce(v_cost, 0); v_src := 'rate list';
      v_lab := v_lab + v_lq * v_cost;
    end if;

    v_lines := v_lines || jsonb_build_object(
      'id', coalesce(nullif(l ->> 'id', ''), 'qcl_' || replace(gen_random_uuid()::text, '-', '')),
      'line_order', v_i, 'kind', v_kind, 'product_id', v_pid, 'rate_id', v_rid,
      'description', coalesce(l ->> 'description', ''), 'uom', l ->> 'uom', 'qty', v_lq,
      'cost_override', case when v_kind = 'material' then v_ovr end,
      'unit_cost', round(v_cost, 4), 'cost_source', v_src, 'amount', round(v_lq * v_cost, 2));
    v_i := v_i + 1;
  end loop;

  v_wcost := round(v_mat * v_waste / 100, 2);
  v_batch := round(v_mat + v_wcost + v_lab, 2);
  v_unit  := round(v_batch / v_out, 4);
  v_sugg  := round(v_unit * (1 + v_profit / 100), 2);
  v_price := coalesce(v_override, v_sugg);

  return jsonb_build_object(
    'can_see_costs', v_see,
    'basis', v_basis, 'quantity', v_qty, 'output_qty', v_out, 'wastage_pct', v_waste,
    'profit_pct', v_profit, 'price_override', v_override,
    'material_cost', round(v_mat, 2), 'wastage_cost', v_wcost, 'labor_cost', round(v_lab, 2),
    'batch_cost', v_batch, 'unit_cost', v_unit,
    'suggested_price', v_sugg, 'unit_price', v_price,
    'total_price', round(v_price * v_qty, 2),
    'margin_pct', case when v_price > 0 then round((v_price - v_unit) / v_price * 100, 1) end,
    'lines', v_lines);
end $$;

-- What a caller may receive: strip costs / profit unless allowed.
create or replace function public._qc_public(r jsonb, p_see boolean)
returns jsonb language sql immutable as $$
  select case when p_see then r else
    (r - 'material_cost' - 'wastage_cost' - 'labor_cost' - 'batch_cost' - 'unit_cost'
       - 'suggested_price' - 'profit_pct' - 'margin_pct' - 'price_override')
    || jsonb_build_object('lines', coalesce((
         select jsonb_agg(case when x ->> 'kind' = 'material' and x ->> 'product_id' is null
                               then x - 'unit_cost' - 'amount' - 'cost_source'
                               else x - 'unit_cost' - 'amount' - 'cost_source' - 'cost_override' end
                          order by (x ->> 'line_order')::int)
           from jsonb_array_elements(coalesce(r -> 'lines', '[]'::jsonb)) x), '[]'::jsonb))
  end;
$$;

create or replace function public.qc_calc(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r jsonb; v_keep text := nullif(p ->> 'id', '');
begin
  if v_keep is not null and not exists (select 1 from public.quick_costings
                                         where id = v_keep and org_id = p ->> 'org_id') then
    v_keep := null;
  end if;
  r := public._qc_compute(p, v_keep);
  return public._qc_public(r, (r ->> 'can_see_costs')::boolean);
end $$;

-- ---------------------------------------------------------------- read
create or replace function public._qc_row(p_id text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select to_jsonb(q) || jsonb_build_object(
           'can_see_costs', public._qc_can_see_costs(q.org_id),
           'suggested_price', round(coalesce(q.unit_cost, 0) * (1 + q.profit_pct / 100), 2),
           'margin_pct', case when q.unit_price > 0 then round((q.unit_price - q.unit_cost) / q.unit_price * 100, 1) end,
           'valid_until', (q.priced_at at time zone 'Asia/Karachi')::date + q.valid_days,
           'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.line_order)
                                from public.quick_costing_lines l where l.costing_id = q.id), '[]'::jsonb))
    from public.quick_costings q where q.id = p_id;
$$;

create or replace function public.qc_get(p_id text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_org text;
begin
  select org_id into v_org from public.quick_costings where id = p_id;
  if v_org is null then raise exception 'This costing no longer exists.'; end if;
  if not public._qc_can_use(v_org) then raise exception 'You do not have access to Quick Costing.'; end if;
  return public._qc_public(public._qc_row(p_id), public._qc_can_see_costs(v_org));
end $$;

create or replace function public.qc_list(p_org text, p_search text default null, p_limit int default 300)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_see boolean; v_q text := lower(trim(coalesce(p_search, '')));
begin
  if not public._qc_can_use(p_org) then raise exception 'You do not have access to Quick Costing.'; end if;
  v_see := public._qc_can_see_costs(p_org);
  return jsonb_build_object('can_see_costs', v_see,
    'default_profit', case when v_see then public._qc_default_profit(p_org) end,
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', q.id, 'code', q.code, 'prospect_name', q.prospect_name, 'title', q.title,
               'quantity', q.quantity, 'unit_price', q.unit_price, 'total_price', q.total_price,
               'unit_cost', case when v_see then q.unit_cost end,
               'status', q.status, 'product_id', q.product_id,
               'valid_until', (q.priced_at at time zone 'Asia/Karachi')::date + q.valid_days,
               'created_by_name', q.created_by_name, 'updated_at', q.updated_at)
             order by q.updated_at desc)
        from (select * from public.quick_costings q
               where q.org_id = p_org
                 and (v_q = '' or lower(q.code || ' ' || q.prospect_name || ' ' || q.title || ' ' || coalesce(q.specs, '')) like '%' || v_q || '%')
               order by q.updated_at desc
               limit greatest(coalesce(p_limit, 300), 1)) q), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- save
create or replace function public.qc_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_org text := p ->> 'org_id';
  v_id text := nullif(p ->> 'id', '');
  v_code text; v_n int; r jsonb; v_uid text; v_uname text; v_see boolean;
begin
  if v_org is null or not public._qc_can_use(v_org) then
    raise exception 'You do not have access to Quick Costing.';
  end if;
  if coalesce(trim(p ->> 'prospect_name'), '') = '' then raise exception 'Enter the prospect''s name.'; end if;
  if coalesce(trim(p ->> 'title'), '') = '' then raise exception 'Enter what is being priced.'; end if;
  if coalesce((p ->> 'quantity')::numeric, 0) <= 0 then raise exception 'Quantity must be more than zero.'; end if;
  if coalesce((p ->> 'valid_days')::int, 7) < 1 then raise exception 'Price must be valid for at least 1 day.'; end if;
  if v_id is not null and not exists (select 1 from public.quick_costings where id = v_id and org_id = v_org) then
    raise exception 'This costing no longer exists.';
  end if;

  v_see := public._qc_can_see_costs(v_org);
  r := public._qc_compute(p, v_id);
  select id, name into v_uid, v_uname from public._acting_user(v_org);

  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('quick_costing_code:' || v_org));
    select coalesce(max(seq), 0) + 1 into v_n from public.quick_costings where org_id = v_org;
    v_code := public._qc_code(v_n, now());
    insert into public.quick_costings (org_id, branch_id, code, seq, created_by, created_by_name)
    values (v_org, nullif(p ->> 'branch_id', ''), v_code, v_n, v_uid, v_uname)
    returning id into v_id;
  end if;

  update public.quick_costings set
    branch_id      = coalesce(nullif(p ->> 'branch_id', ''), branch_id),
    prospect_name  = trim(p ->> 'prospect_name'),
    prospect_phone = nullif(trim(coalesce(p ->> 'prospect_phone', '')), ''),
    title          = trim(p ->> 'title'),
    specs          = nullif(trim(coalesce(p ->> 'specs', '')), ''),
    quantity       = (r ->> 'quantity')::numeric,
    output_qty     = (r ->> 'output_qty')::numeric,
    basis          = r ->> 'basis',
    wastage_pct    = (r ->> 'wastage_pct')::numeric,
    profit_pct     = (r ->> 'profit_pct')::numeric,
    price_override = (r ->> 'price_override')::numeric,
    valid_days     = coalesce((p ->> 'valid_days')::int, 7),
    material_cost  = (r ->> 'material_cost')::numeric,
    wastage_cost   = (r ->> 'wastage_cost')::numeric,
    labor_cost     = (r ->> 'labor_cost')::numeric,
    batch_cost     = (r ->> 'batch_cost')::numeric,
    unit_cost      = (r ->> 'unit_cost')::numeric,
    unit_price     = (r ->> 'unit_price')::numeric,
    total_price    = (r ->> 'total_price')::numeric,
    notes          = nullif(trim(coalesce(p ->> 'notes', '')), ''),
    status         = case when p ->> 'status' in ('draft', 'sent', 'won', 'lost') then p ->> 'status' else status end,
    updated_by_name = v_uname,
    priced_at      = now(),
    updated_at     = now()
  where id = v_id;

  delete from public.quick_costing_lines where costing_id = v_id;
  insert into public.quick_costing_lines
    (id, costing_id, line_order, kind, product_id, rate_id, description, uom, qty,
     cost_override, unit_cost, cost_source, amount)
  select case when exists (select 1 from public.quick_costing_lines o where o.id = x ->> 'id')
              then 'qcl_' || replace(gen_random_uuid()::text, '-', '') else x ->> 'id' end,
         v_id, (x ->> 'line_order')::int, x ->> 'kind', x ->> 'product_id', x ->> 'rate_id',
         coalesce(x ->> 'description', ''), x ->> 'uom', (x ->> 'qty')::numeric,
         (x ->> 'cost_override')::numeric, (x ->> 'unit_cost')::numeric, x ->> 'cost_source',
         (x ->> 'amount')::numeric
    from jsonb_array_elements(r -> 'lines') x;

  return public._qc_public(public._qc_row(v_id), v_see);
end $$;

create or replace function public.qc_set_status(p_id text, p_status text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_org text;
begin
  select org_id into v_org from public.quick_costings where id = p_id;
  if v_org is null or not public._qc_can_use(v_org) then raise exception 'This costing no longer exists.'; end if;
  if p_status not in ('draft', 'sent', 'won', 'lost') then raise exception 'Unknown status.'; end if;
  update public.quick_costings set status = p_status, updated_at = now() where id = p_id;
end $$;

create or replace function public.qc_delete(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare q public.quick_costings; v_uid text;
begin
  select * into q from public.quick_costings where id = p_id;
  if not found then return; end if;
  select id into v_uid from public._acting_user(q.org_id);
  if not (public._is_org_admin(q.org_id) or (public._qc_can_use(q.org_id) and q.created_by = v_uid)) then
    raise exception 'Only an admin or the person who made it can delete this costing.';
  end if;
  if q.product_id is not null then
    raise exception 'A product was already made from this costing, so it is kept for the record.';
  end if;
  delete from public.quick_costings where id = p_id;
end $$;

-- ---------------------------------------------------------------- product + BOM
create or replace function public.qc_make_product(
  p_id text, p_name text, p_sku text, p_uom text, p_type text, p_selling_price numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  q public.quick_costings; v_uid text; v_pid text; v_bom text; v_code text; v_n int;
  v_specs text; l record; v_i int := 0;
begin
  select * into q from public.quick_costings where id = p_id for update;
  if not found then raise exception 'This costing no longer exists.'; end if;
  if not public._qc_can_see_costs(q.org_id) then
    raise exception 'Only users who can see costs can make a product from a costing.';
  end if;
  if q.product_id is not null then raise exception 'A product was already made from this costing.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the product name.'; end if;
  if p_uom is null then raise exception 'Pick a unit.'; end if;
  if exists (select 1 from public.quick_costing_lines where costing_id = p_id and kind = 'material' and product_id is null) then
    raise exception 'Some materials are one-off items. Add them as products first, pick them in the costing, then try again.';
  end if;
  if not exists (select 1 from public.quick_costing_lines where costing_id = p_id and kind = 'material') then
    raise exception 'Add at least one material first.';
  end if;
  if nullif(trim(coalesce(p_sku, '')), '') is not null and exists (
       select 1 from public.products where org_id = q.org_id and lower(sku) = lower(trim(p_sku))) then
    raise exception 'SKU % is already used by another product.', trim(p_sku);
  end if;

  select id into v_uid from public._acting_user(q.org_id);
  v_pid := 'prod_' || (extract(epoch from clock_timestamp()) * 1000)::bigint;

  insert into public.products (id, org_id, name, sku, base_uom_id, product_type,
                               selling_price, cost_price, is_active, created_at, updated_at)
  values (v_pid, q.org_id, trim(p_name), nullif(trim(coalesce(p_sku, '')), ''), p_uom,
          nullif(trim(coalesce(p_type, '')), ''),
          coalesce(p_selling_price, q.unit_price, 0), coalesce(q.unit_cost, 0), true, now(), now());

  if q.branch_id is not null then
    insert into public.inventory_stock (id, org_id, product_id, branch_id, quantity)
    values ('invs_' || (extract(epoch from clock_timestamp()) * 1000)::bigint, q.org_id, v_pid, q.branch_id, 0)
    on conflict do nothing;
  end if;

  perform pg_advisory_xact_lock(hashtext('bom_code:' || q.org_id));
  select coalesce(max(nullif(regexp_replace(split_part(code, '-', 2), '\D', '', 'g'), '')::int), 0) + 1 into v_n
    from public.bom_headers where org_id = q.org_id and code like 'BOM-%';
  v_code := 'BOM-' || lpad(v_n::text, 4, '0');
  v_bom := 'bom_' || (extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_specs := concat_ws(E'\n',
    nullif(q.specs, ''),
    case when q.wastage_pct > 0 then 'Wastage allowance: ' || q.wastage_pct || '%' end,
    'Made from Quick Costing ' || q.code || ' (' || q.prospect_name || ')');

  insert into public.bom_headers (id, org_id, code, name, product_id, output_qty, status,
                                  production_specs, specs_updated_at, created_by, created_at, updated_at)
  values (v_bom, q.org_id, v_code, trim(p_name), v_pid, q.output_qty, 'active',
          v_specs, now(), v_uid, now(), now());

  for l in select * from public.quick_costing_lines where costing_id = p_id order by line_order loop
    if l.kind = 'material' then
      insert into public.bom_components (id, bom_id, product_id, quantity, line_order)
      values (v_bom || '_c' || v_i, v_bom, l.product_id, l.qty, v_i);
    else
      insert into public.bom_overheads (id, bom_id, cost_type, rate_id, quantity, description, amount, line_order)
      values (v_bom || '_o' || v_i, v_bom, l.kind, l.rate_id, l.qty, l.description, l.amount, v_i);
    end if;
    v_i := v_i + 1;
  end loop;

  update public.quick_costings set product_id = v_pid, bom_id = v_bom, status = 'won', updated_at = now()
   where id = p_id;
  return jsonb_build_object('product_id', v_pid, 'bom_id', v_bom, 'bom_code', v_code);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function public.qc_calc(jsonb) from public, anon;
revoke all on function public.qc_get(text) from public, anon;
revoke all on function public.qc_list(text, text, int) from public, anon;
revoke all on function public.qc_save(jsonb) from public, anon;
revoke all on function public.qc_set_status(text, text) from public, anon;
revoke all on function public.qc_delete(text) from public, anon;
revoke all on function public.qc_make_product(text, text, text, text, text, numeric) from public, anon;
grant execute on function public.qc_calc(jsonb) to authenticated;
grant execute on function public.qc_get(text) to authenticated;
grant execute on function public.qc_list(text, text, int) to authenticated;
grant execute on function public.qc_save(jsonb) to authenticated;
grant execute on function public.qc_set_status(text, text) to authenticated;
grant execute on function public.qc_delete(text) to authenticated;
grant execute on function public.qc_make_product(text, text, text, text, text, numeric) to authenticated;
revoke all on function public._qc_compute(jsonb, text) from public, anon, authenticated;
revoke all on function public._qc_method_costs(text, text, text[]) from public, anon, authenticated;
revoke all on function public._qc_last_purchase(text, text) from public, anon, authenticated;
revoke all on function public._qc_row(text) from public, anon, authenticated;
grant select on public.quick_costings, public.quick_costing_lines to authenticated;

notify pgrst, 'reload schema';
select 'quick costing ready' as result;
