-- 428 — Quick Costing: items made in-house are costed from their BOM
-- (components at the chosen basis + labour & overheads per unit), the same
-- way a Production Voucher estimates them — instead of a stale cost price.
-- Order for a stocked item:
--   1. has an active BOM          -> BOM cost (components costed the same way)
--   2. "Last purchase price" mode -> latest purchase invoice rate
--   3. stock cost (costing engine), else the product's cost price
-- Safe to run again.

-- every product in the lines plus all BOM components below them
create or replace function public._qc_bom_tree_ids(p_org text, p_ids text[])
returns text[] language sql stable security definer set search_path to 'public' as $$
  with recursive t(pid, depth) as (
    select unnest(coalesce(p_ids, '{}'::text[])), 0
    union
    select c.product_id, t.depth + 1
      from t
      join lateral (select b.id from public.bom_headers b
                     where b.org_id = p_org and b.product_id = t.pid
                       and coalesce(b.status, 'active') = 'active'
                     order by b.updated_at desc nulls last limit 1) b on true
      join public.bom_components c on c.bom_id = b.id
     where t.depth < 6 and c.product_id is not null
  )
  select coalesce(array_agg(distinct pid), '{}'::text[]) from t where pid is not null;
$$;

-- unit cost of one product: {"cost": n, "src": "..."}
create or replace function public._qc_unit_cost(p_org text, p_basis text, p_pid text, p_map jsonb, p_depth int)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  b record; c record; o record; v_sum numeric := 0; v_cc jsonb; v_rate numeric; v_cost numeric;
begin
  if p_depth < 6 then
    select id, coalesce(nullif(output_qty, 0), 1) as out_qty into b
      from public.bom_headers
     where org_id = p_org and product_id = p_pid and coalesce(status, 'active') = 'active'
     order by updated_at desc nulls last limit 1;
    if found then
      for c in select product_id, coalesce(quantity, 0) as qty from public.bom_components
                where bom_id = b.id and product_id is not null loop
        v_cc := public._qc_unit_cost(p_org, p_basis, c.product_id, p_map, p_depth + 1);
        v_sum := v_sum + c.qty * coalesce((v_cc ->> 'cost')::numeric, 0);
      end loop;
      for o in select cost_type, rate_id, coalesce(quantity, 0) as qty, amount from public.bom_overheads
                where bom_id = b.id loop
        v_rate := null;
        if o.cost_type = 'labor' then
          select rate into v_rate from public.labor_types where id = o.rate_id;
        else
          select rate into v_rate from public.overhead_types where id = o.rate_id;
        end if;
        v_sum := v_sum + coalesce(o.qty * v_rate, o.amount, 0);
      end loop;
      return jsonb_build_object('cost', round(v_sum / b.out_qty, 4), 'src', 'BOM cost');
    end if;
  end if;
  if p_basis = 'purchase' then
    v_cost := public._qc_last_purchase(p_org, p_pid);
    if v_cost is not null then
      return jsonb_build_object('cost', v_cost, 'src', 'last purchase');
    end if;
  end if;
  return jsonb_build_object('cost', (p_map ->> p_pid)::numeric,
    'src', case when p_basis = 'purchase' then 'no purchase yet' else 'stock cost' end);
end $$;

revoke all on function public._qc_bom_tree_ids(text, text[]) from public, anon, authenticated;
revoke all on function public._qc_unit_cost(text, text, text, jsonb, int) from public, anon, authenticated;

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
  v_old_ovr numeric; v_uc jsonb;
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
  v_ids := public._qc_bom_tree_ids(v_org, v_ids);
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
        v_uc := public._qc_unit_cost(v_org, v_basis, v_pid, v_method, 0);
        v_cost := coalesce((v_uc ->> 'cost')::numeric, 0);
        v_src := v_uc ->> 'src';
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


revoke all on function public._qc_compute(jsonb, text) from public, anon, authenticated;
notify pgrst, 'reload schema';
select 'quick costing bom cost ready' as result;
