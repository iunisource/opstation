-- 427 — Quick Costing numbers that don't show how many offers were made.
-- QC-0001, QC-0002 … becomes QC-2610-G2BF: year+month, then a scrambled
-- serial. Read it back with:  select public.qc_decode('QC-2610-G2BF');
-- Existing costings keep their printed number. Safe to run again.

alter table public.quick_costings add column if not exists seq int;
update public.quick_costings
   set seq = nullif(regexp_replace(code, '\D', '', 'g'), '')::int
 where seq is null and code ~ '^QC-\d+$';

-- serial -> 4 characters (reversible scramble, 20 bits, Crockford base-32)
create or replace function public._qc_code(p_seq int, p_at timestamptz)
returns text language plpgsql immutable as $$
declare
  m bigint := 1048575; x bigint := p_seq;
  d text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; s text := '';
begin
  x := (x * 741457 + 318211) & m;
  x := x # (x >> 7);
  x := (x * 599479) & m;
  x := x # (x >> 11);
  for i in 1..4 loop
    s := substr(d, (x & 31)::int + 1, 1) || s;
    x := x >> 5;
  end loop;
  return 'QC-' || to_char(p_at at time zone 'Asia/Karachi', 'YYMM') || '-' || s;
end $$;

-- QC-2610-G2BF -> {"serial": 1, "month": "2026-10"}
create or replace function public.qc_decode(p_code text)
returns jsonb language plpgsql immutable as $$
declare
  m bigint := 1048575; x bigint := 0; c text;
  d text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_part text := upper(split_part(p_code, '-', 3));
  v_ym text := split_part(p_code, '-', 2);
begin
  if p_code ~* '^QC-\d+$' then
    return jsonb_build_object('serial', regexp_replace(p_code, '\D', '', 'g')::int);
  end if;
  if length(v_part) <> 4 or v_ym !~ '^\d{4}$' then return null; end if;
  for i in 1..4 loop
    c := substr(v_part, i, 1);
    if strpos(d, c) = 0 then return null; end if;
    x := x * 32 + strpos(d, c) - 1;
  end loop;
  x := x # (x >> 11);
  x := (x * 1034247) & m;
  x := x # (x >> 7) # (x >> 14);
  x := ((x - 318211) * 1046705) & m;
  return jsonb_build_object('serial', x,
    'month', '20' || substr(v_ym, 1, 2) || '-' || substr(v_ym, 3, 2));
end $$;

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


notify pgrst, 'reload schema';
select 'quick costing numbers ready' as result;
