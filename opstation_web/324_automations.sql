-- 324 — Automations, phase 1: Inventory replenishment.
--
-- When stock of a product drops to / below its threshold, an automation rule
-- creates a DRAFT document straight away:
--   • purchased product  → draft Purchase Order (grouped per branch + supplier)
--   • produced product   → draft Job Card (status 'draft', BOM materials filled)
-- Nothing is approved or posted automatically — a person reviews the draft.
--
-- Runs instantly from a trigger on inventory_stock (any sale, transfer, issue,
-- consumption…). Never blocks the stock posting: errors are logged and skipped.
-- "Already on order" is respected: open POs (draft/ordered, not yet received)
-- and open jobs (draft/queued/in progress) count toward stock, so the same
-- shortage never creates a second draft.
--
-- Safe to run again.

-- ── Tables ───────────────────────────────────────────────────────────────────
create table if not exists public.automation_rules (
  id                 text primary key,
  org_id             text not null,
  name               text not null,
  kind               text not null default 'low_stock_replenish',
  is_active          boolean not null default true,
  -- What it watches
  main_groups        text[] not null default '{}',
  groups             text[] not null default '{}',
  sub_groups         text[] not null default '{}',
  product_ids        text[] not null default '{}',
  exclude_product_ids text[] not null default '{}',
  -- Where: 'branch' = each branch on its own; 'company' = total of the branches
  stock_scope        text not null default 'branch',
  branch_ids         text[] not null default '{}',   -- empty = all branches
  target_branch_id   text,                           -- company scope: drafts go here
  -- When: 'product_limit' = product's Low-stock limit; 'rule_min' = min_qty below
  trigger_mode       text not null default 'product_limit',
  min_qty            numeric not null default 0,
  -- How much: 'max_level' | 'fixed' | 'days_cover'
  qty_mode           text not null default 'max_level',
  max_level          numeric not null default 0,
  fixed_qty          numeric not null default 0,
  cover_days         int not null default 30,
  sales_window_days  int not null default 30,
  round_to           numeric not null default 0,     -- pack / MOQ multiple (0 = none)
  -- Make or buy: 'auto' (BOM → job, else PO) | 'purchase' | 'produce'
  source_mode        text not null default 'auto',
  -- Supplier for POs: 'last' (latest purchase invoice, fallback supplier_id) | 'fixed'
  supplier_mode      text not null default 'last',
  supplier_id        text,
  notes              text,
  created_by         text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  last_fired_at      timestamptz
);
create index if not exists idx_automation_rules_org on public.automation_rules(org_id, is_active);

create table if not exists public.automation_runs (
  id          bigserial primary key,
  org_id      text not null,
  rule_id     text,
  rule_name   text,
  product_id  text,
  branch_id   text,
  stock_qty   numeric,
  on_order    numeric,
  threshold   numeric,
  qty         numeric,
  action      text,        -- po | job | skipped | error
  doc_id      text,
  doc_number  text,
  message     text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_automation_runs_org on public.automation_runs(org_id, created_at desc);

-- Mark auto-created documents
alter table public.purchase_orders add column if not exists auto_rule_id text;
alter table public.job_cards       add column if not exists auto_rule_id text;

-- ── RLS ──────────────────────────────────────────────────────────────────────
create or replace function public._is_org_member(p_org text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.users u
     where u.org_id = p_org
       and coalesce(u.is_active, true)
       and (u.account_id = public.current_account_id()
            or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))));
$$;

alter table public.automation_rules enable row level security;
alter table public.automation_runs  enable row level security;
drop policy if exists ar_org on public.automation_rules;
create policy ar_org on public.automation_rules for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
drop policy if exists arun_org on public.automation_runs;
create policy arun_org on public.automation_runs for select to authenticated
  using (public._is_org_member(org_id));
grant select, insert, update, delete on public.automation_rules to authenticated;
grant select on public.automation_runs to authenticated;

-- ── Helpers ──────────────────────────────────────────────────────────────────
-- Does a rule cover this product?
create or replace function public._auto_rule_matches(r public.automation_rules, p public.products)
returns boolean language sql immutable as $$
  select not (p.id = any(r.exclude_product_ids))
     and ( p.id = any(r.product_ids)
        or (p.product_main_group is not null and p.product_main_group = any(r.main_groups))
        or (p.product_group      is not null and p.product_group      = any(r.groups))
        or (p.product_sub_group  is not null and p.product_sub_group  = any(r.sub_groups)) );
$$;

-- Next voucher number "<prefix>-YYYY-NNNN" — the app's counter first, max+1 as fallback.
create or replace function public._auto_next_no(p_org text, p_branch text, p_type text, p_table text, p_col text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare
  v_year int := extract(year from (now() at time zone 'Asia/Karachi'))::int;
  v_n text; v_max int;
begin
  if p_type is not null then
    begin
      execute 'select (public.next_voucher_number($1, $2, $3, $4))::text' into v_n using p_org, p_branch, p_type, v_year;
      if v_n is not null and v_n <> '' then
        if v_n ~ '^\d+$' then return p_type || '-' || v_year || '-' || lpad(v_n, 4, '0'); end if;
        return v_n;
      end if;
    exception when others then null;
    end;
  end if;
  execute format('select coalesce(max(case when regexp_replace(%1$I, ''^.*-'', '''') ~ ''^[0-9]+$''
                                         then regexp_replace(%1$I, ''^.*-'', '''')::int end), 0)
                    from %2$I where org_id = $1 and %1$I like $2', p_col, p_table)
     into v_max using p_org, coalesce(p_type, 'JOB') || '-' || v_year || '-%';
  return coalesce(p_type, 'JOB') || '-' || v_year || '-' || lpad((v_max + 1)::text, 4, '0');
end $$;

-- ── Core: evaluate one rule for one product at one branch ───────────────────
create or replace function public.automation_eval(p_rule_id text, p_product text, p_branch text, p_manual boolean default false)
returns text
language plpgsql security definer set search_path to 'public'
as $$
declare
  r public.automation_rules;
  p public.products;
  v_branches text[];
  v_stock numeric; v_on_po numeric; v_on_job numeric; v_on numeric;
  v_thr numeric; v_qty numeric; v_avg numeric;
  v_bom record; v_make boolean;
  v_target text; v_sup text;
  v_po_id text; v_po_no text; v_line text;
  v_job_id text; v_job_no text; v_scale numeric;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select * into r from automation_rules where id = p_rule_id;
  if not found or not r.is_active then return 'inactive'; end if;
  select * into p from products where id = p_product and org_id = r.org_id;
  if not found or coalesce(p.is_active, true) = false or coalesce(p.is_service, false) then return 'n/a'; end if;
  if not public._auto_rule_matches(r, p) then return 'n/a'; end if;

  -- Branches whose stock counts
  if r.stock_scope = 'company' then
    v_branches := case when cardinality(r.branch_ids) > 0 then r.branch_ids
                       else array(select id from branches where org_id = r.org_id and coalesce(is_active, true)
                                    and coalesce(to_jsonb(branches)->>'is_virtual', 'false') <> 'true') end;
    v_target := coalesce(r.target_branch_id, p_branch);
  else
    if cardinality(r.branch_ids) > 0 and not (p_branch = any(r.branch_ids)) then return 'n/a'; end if;
    v_branches := array[p_branch];
    v_target := p_branch;
  end if;
  if v_target is null then return 'no branch'; end if;

  -- Threshold
  v_thr := case when r.trigger_mode = 'rule_min' then r.min_qty
                else coalesce(nullif(p.low_stock_limit, 0), nullif(r.min_qty, 0)) end;
  if coalesce(v_thr, 0) <= 0 then return 'no threshold'; end if;

  -- Stock + already on order
  select coalesce(sum(quantity), 0) into v_stock from inventory_stock
   where org_id = r.org_id and product_id = p.id and branch_id = any(v_branches);

  select coalesce(sum(greatest(coalesce(i.quantity_ordered, 0) - coalesce(i.quantity_received, 0), 0)), 0) into v_on_po
    from purchase_order_items i join purchase_orders o on o.id = i.purchase_order_id
   where o.org_id = r.org_id and i.product_id = p.id and o.branch_id = any(v_branches || v_target)
     and coalesce(o.status, 'draft') in ('draft', 'ordered', 'partial', 'partially_received')
     and coalesce(to_jsonb(o)->>'is_voided', 'false') <> 'true';

  select coalesce(sum(greatest(coalesce(j.planned_qty, 0) - coalesce(j.produced_qty, 0), 0)), 0) into v_on_job
    from job_cards j
   where j.org_id = r.org_id and j.product_id = p.id and j.branch_id = any(v_branches || v_target)
     and coalesce(j.status, 'queued') in ('draft', 'queued', 'in_progress');

  v_on := v_on_po + v_on_job;
  if v_stock + v_on > v_thr then
    if p_manual and v_stock <= v_thr then
      insert into automation_runs(org_id, rule_id, rule_name, product_id, branch_id, stock_qty, on_order, threshold, qty, action, message)
      values (r.org_id, r.id, r.name, p.id, v_target, v_stock, v_on, v_thr, 0, 'skipped', 'Low, but already on order');
    end if;
    return 'ok';
  end if;

  -- Quantity
  if r.qty_mode = 'fixed' then
    v_qty := r.fixed_qty;
  elsif r.qty_mode = 'days_cover' then
    select coalesce(sum(-quantity), 0) / greatest(r.sales_window_days, 1) into v_avg
      from inventory_movements
     where org_id = r.org_id and product_id = p.id and movement_type = 'sale'
       and branch_id = any(v_branches)
       and moved_at >= now() - make_interval(days => greatest(r.sales_window_days, 1));
    v_qty := v_avg * r.cover_days - (v_stock + v_on);
  else
    v_qty := greatest(r.max_level, v_thr) - (v_stock + v_on);
  end if;
  if r.round_to > 0 and v_qty > 0 then v_qty := ceil(v_qty / r.round_to) * r.round_to; end if;
  v_qty := round(v_qty, 4);
  if coalesce(v_qty, 0) <= 0 then
    insert into automation_runs(org_id, rule_id, rule_name, product_id, branch_id, stock_qty, on_order, threshold, qty, action, message)
    values (r.org_id, r.id, r.name, p.id, v_target, v_stock, v_on, v_thr, 0, 'skipped',
            case when r.qty_mode = 'days_cover' then 'No sales in the window — nothing to order' else 'Calculated quantity is zero' end);
    return 'zero';
  end if;

  -- Make or buy
  select b.* into v_bom from bom_headers b
   where b.org_id = r.org_id and b.product_id = p.id and coalesce(b.status, 'active') = 'active'
   order by (b.supervised_at is not null) desc, b.updated_at desc nulls last limit 1;
  v_make := case r.source_mode when 'produce' then true when 'purchase' then false else v_bom.id is not null end;

  if v_make then
    if v_bom.id is null then
      insert into automation_runs(org_id, rule_id, rule_name, product_id, branch_id, stock_qty, on_order, threshold, qty, action, message)
      values (r.org_id, r.id, r.name, p.id, v_target, v_stock, v_on, v_thr, v_qty, 'skipped', 'No active BOM — cannot create a job');
      return 'no bom';
    end if;
    v_job_id := 'job_auto_' || replace(gen_random_uuid()::text, '-', '');
    v_job_no := public._auto_next_no(r.org_id, v_target, null, 'job_cards', 'job_number');
    insert into job_cards(id, org_id, branch_id, job_number, voucher_date, bom_id, product_id, planned_qty, is_open_ended,
                          status, priority, is_locked, notes, created_by, created_at, updated_at, auto_rule_id)
    values (v_job_id, r.org_id, v_target, v_job_no, v_today, v_bom.id, p.id, v_qty, false,
            'draft', 0, false, 'Auto-created by automation "' || r.name || '" — stock ' || v_stock || ', threshold ' || v_thr,
            r.created_by, now(), now(), r.id);
    v_scale := v_qty / greatest(coalesce(nullif(v_bom.output_qty, 0), 1), 0.0001);
    insert into job_card_materials(id, job_card_id, product_id, planned_qty, issued_qty, line_order)
    select v_job_id || '_m' || row_number() over (order by c.line_order), v_job_id, c.product_id,
           round(c.quantity * v_scale, 4), round(c.quantity * v_scale, 4), (row_number() over (order by c.line_order)) - 1
      from bom_components c where c.bom_id = v_bom.id;
    begin
      insert into job_card_overheads(id, job_card_id, cost_type, description, amount, line_order)
      select v_job_id || '_o' || row_number() over (order by o.line_order), v_job_id, coalesce(o.cost_type, 'overhead'),
             coalesce(o.description, ''), round(coalesce(o.amount, 0) * v_scale, 2), (row_number() over (order by o.line_order)) - 1
        from bom_overheads o where o.bom_id = v_bom.id;
    exception when others then null;
    end;
    insert into automation_runs(org_id, rule_id, rule_name, product_id, branch_id, stock_qty, on_order, threshold, qty, action, doc_id, doc_number, message)
    values (r.org_id, r.id, r.name, p.id, v_target, v_stock, v_on, v_thr, v_qty, 'job', v_job_id, v_job_no, 'Draft job card created');
    update automation_rules set last_fired_at = now() where id = r.id;
    return 'job';
  end if;

  -- Purchase: supplier
  if r.supplier_mode = 'last' then
    select pi.supplier_id into v_sup
      from purchase_invoice_items it join purchase_invoices pi on pi.id = it.invoice_id
     where pi.org_id = r.org_id and it.product_id = p.id and pi.supplier_id is not null
       and coalesce(to_jsonb(pi)->>'is_voided', 'false') <> 'true'
     order by pi.voucher_date desc nulls last, pi.id desc limit 1;
  end if;
  v_sup := coalesce(v_sup, r.supplier_id);
  if v_sup is null then
    insert into automation_runs(org_id, rule_id, rule_name, product_id, branch_id, stock_qty, on_order, threshold, qty, action, message)
    values (r.org_id, r.id, r.name, p.id, v_target, v_stock, v_on, v_thr, v_qty, 'skipped', 'No supplier found — set one on the rule');
    return 'no supplier';
  end if;

  -- Join an open auto draft PO for the same branch + supplier, else start one
  select o.id, o.voucher_number into v_po_id, v_po_no from purchase_orders o
   where o.org_id = r.org_id and o.branch_id = v_target and o.supplier_id = v_sup
     and o.auto_rule_id is not null and coalesce(o.status, 'draft') = 'draft'
     and coalesce(to_jsonb(o)->>'is_voided', 'false') <> 'true'
   order by o.voucher_date desc nulls last, o.id desc limit 1;
  if v_po_id is null then
    v_po_id := 'po_auto_' || replace(gen_random_uuid()::text, '-', '');
    v_po_no := public._auto_next_no(r.org_id, v_target, 'PO', 'purchase_orders', 'voucher_number');
    insert into purchase_orders(id, org_id, branch_id, voucher_number, voucher_date, supplier_id, remarks, status, is_locked, created_by, auto_rule_id)
    values (v_po_id, r.org_id, v_target, v_po_no, v_today, v_sup, 'Auto-created by automation "' || r.name || '"',
            'draft', false, r.created_by, r.id);
    begin
      insert into voucher_audit_log(id, org_id, voucher_id, voucher_type, action, details, performed_by, performed_at)
      values ('val_auto_' || replace(gen_random_uuid()::text, '-', ''), r.org_id, v_po_id, 'PO', 'created',
              'Auto-created by automation "' || r.name || '"', r.created_by, now());
    exception when others then null;
    end;
  end if;
  select id into v_line from purchase_order_items where purchase_order_id = v_po_id and product_id = p.id limit 1;
  if v_line is not null then
    update purchase_order_items set quantity_ordered = coalesce(quantity_ordered, 0) + v_qty where id = v_line;
  else
    insert into purchase_order_items(id, purchase_order_id, product_id, uom_id, quantity_ordered, quantity_received, unit_cost)
    values ('poi_auto_' || replace(gen_random_uuid()::text, '-', ''), v_po_id, p.id, p.base_uom_id, v_qty, 0, coalesce(p.cost_price, 0));
  end if;
  insert into automation_runs(org_id, rule_id, rule_name, product_id, branch_id, stock_qty, on_order, threshold, qty, action, doc_id, doc_number, message)
  values (r.org_id, r.id, r.name, p.id, v_target, v_stock, v_on, v_thr, v_qty, 'po', v_po_id, v_po_no,
          case when v_line is null then 'Added to draft PO' else 'Quantity added to existing line' end);
  update automation_rules set last_fired_at = now() where id = r.id;
  return 'po';
end $$;

-- ── Trigger: instant, on every stock decrease ───────────────────────────────
create or replace function public.trg_automation_stock()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  if TG_OP = 'UPDATE' and coalesce(NEW.quantity, 0) >= coalesce(OLD.quantity, 0) then return NEW; end if;
  if not exists (select 1 from automation_rules where org_id = NEW.org_id and is_active
                   and kind = 'low_stock_replenish') then return NEW; end if;
  for r in select id, name from automation_rules where org_id = NEW.org_id and is_active and kind = 'low_stock_replenish' order by created_at loop
    begin
      perform public.automation_eval(r.id, NEW.product_id, NEW.branch_id, false);
    exception when others then
      begin
        insert into automation_runs(org_id, rule_id, rule_name, product_id, branch_id, action, message)
        values (NEW.org_id, r.id, r.name, NEW.product_id, NEW.branch_id, 'error', left(sqlerrm, 500));
      exception when others then null;
      end;
    end;
  end loop;
  return NEW;
exception when others then
  return NEW; -- never block a stock posting
end $$;

drop trigger if exists zz_automation_stock on public.inventory_stock;
create trigger zz_automation_stock after insert or update of quantity on public.inventory_stock
  for each row execute function public.trg_automation_stock();

-- ── Run now: sweep every product a rule covers (for products already low) ───
create or replace function public.automation_run_rule(p_rule_id text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  r public.automation_rules; p record; b text; v text;
  n_po int := 0; n_job int := 0; n_skip int := 0; n_checked int := 0;
  v_branches text[];
begin
  select * into r from automation_rules where id = p_rule_id;
  if not found then raise exception 'Rule not found'; end if;
  if not public._is_org_member(r.org_id) then raise exception 'Not allowed'; end if;
  v_branches := case when cardinality(r.branch_ids) > 0 then r.branch_ids
                     else array(select id from branches where org_id = r.org_id and coalesce(is_active, true)
                                  and coalesce(to_jsonb(branches)->>'is_virtual', 'false') <> 'true') end;
  for p in select * from products pr where pr.org_id = r.org_id and coalesce(pr.is_active, true)
             and public._auto_rule_matches(r, pr) loop
    if r.stock_scope = 'company' then
      n_checked := n_checked + 1;
      begin
        v := public.automation_eval(r.id, p.id, coalesce(r.target_branch_id, v_branches[1]), true);
      exception when others then
        v := 'error';
        insert into automation_runs(org_id, rule_id, rule_name, product_id, action, message)
        values (r.org_id, r.id, r.name, p.id, 'error', left(sqlerrm, 500));
      end;
      if v = 'po' then n_po := n_po + 1; elsif v = 'job' then n_job := n_job + 1; else n_skip := n_skip + 1; end if;
    else
      -- Only branches that actually stock this product.
      foreach b in array coalesce((select array_agg(distinct s.branch_id) from inventory_stock s
                                    where s.org_id = r.org_id and s.product_id = p.id and s.branch_id = any(v_branches)), '{}') loop
        n_checked := n_checked + 1;
        begin
          v := public.automation_eval(r.id, p.id, b, true);
        exception when others then
          v := 'error';
          insert into automation_runs(org_id, rule_id, rule_name, product_id, branch_id, action, message)
          values (r.org_id, r.id, r.name, p.id, b, 'error', left(sqlerrm, 500));
        end;
        if v = 'po' then n_po := n_po + 1; elsif v = 'job' then n_job := n_job + 1; else n_skip := n_skip + 1; end if;
      end loop;
    end if;
  end loop;
  return jsonb_build_object('checked', n_checked, 'po_lines', n_po, 'jobs', n_job);
end $$;
grant execute on function public.automation_run_rule(text) to authenticated;
