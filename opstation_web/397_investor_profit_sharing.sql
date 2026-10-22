-- 397 — Investor profit sharing (Financials → Investors).
--
--  * investors            : one row per investor, their agreement (ratio, floor,
--                           cap, payout frequency, loss policy) and their own
--                           accounts (investment, profit payable, profit expense).
--  * investor_tranches    : each amount put in (or reinvested), with its date.
--  * investor_tranche_lines: the breakdown of a tranche — "Whole business"
--                           amounts and whole GRNs. Unallocated money earns nothing.
--  * investor_profit_runs : each period's calculation, kept for the record, and
--                           the journal voucher it posted.
--  * investor_grn_margin(): invoiced margin on goods from given GRNs (FIFO cost
--                           of exactly those goods), POS and Sales Invoices.
-- Safe to run again.

create table if not exists public.investors (
  id                    text primary key default 'inv_' || replace(gen_random_uuid()::text, '-', ''),
  org_id                text not null,
  name                  text not null,
  phone                 text,
  cnic                  text,
  notes                 text,
  start_date            date not null default current_date,
  share_pct             numeric not null default 50,        -- investor's share of the profit their money earned
  floor_pct             numeric not null default 0,         -- 0 = no floor
  cap_pct               numeric not null default 0,         -- 0 = no cap
  limit_basis           text not null default 'annual',     -- annual (scaled to days) | period
  payout_frequency      text not null default 'monthly',    -- monthly | quarterly | half_yearly | annually
  loss_policy           text not null default 'decide_later',
  investment_account_id text,
  payable_account_id    text,
  expense_account_id    text,
  is_active             boolean not null default true,
  created_by            text,
  created_at            timestamptz not null default now()
);
create index if not exists investors_org_idx on public.investors (org_id, is_active);

create table if not exists public.investor_tranches (
  id          text primary key default 'itr_' || replace(gen_random_uuid()::text, '-', ''),
  org_id      text not null,
  investor_id text not null references public.investors(id) on delete cascade,
  amount      numeric not null check (amount > 0),
  invested_on date not null,
  ended_on    date,                       -- withdrawn on (null = still invested)
  source      text not null default 'deposit',   -- deposit | reinvest
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists investor_tranches_inv_idx on public.investor_tranches (investor_id);

create table if not exists public.investor_tranche_lines (
  id                text primary key default 'itl_' || replace(gen_random_uuid()::text, '-', ''),
  org_id            text not null,
  tranche_id        text not null references public.investor_tranches(id) on delete cascade,
  kind              text not null check (kind in ('business', 'grn')),
  amount            numeric not null check (amount > 0),
  grn_id            text,
  grn_number        text,
  expense_share_pct numeric not null default 0,   -- GRN lines: running-expense deduction on the margin
  created_at        timestamptz not null default now()
);
create index if not exists investor_tranche_lines_tr_idx on public.investor_tranche_lines (tranche_id);
-- A GRN funds one tranche only.
create unique index if not exists investor_tranche_lines_grn_uq on public.investor_tranche_lines (grn_id) where grn_id is not null;

create table if not exists public.investor_profit_runs (
  id           text primary key default 'ipr_' || replace(gen_random_uuid()::text, '-', ''),
  org_id       text not null,
  investor_id  text not null references public.investors(id) on delete cascade,
  period_from  date not null,
  period_to    date not null,
  status       text not null default 'posted',   -- posted | loss (nothing posted) | void
  amount       numeric not null default 0,       -- what was posted to the investor
  calc         jsonb not null,                   -- the full step-by-step calculation
  entry_id     text,                             -- journal voucher
  entry_number text,
  created_by   text,
  created_by_name text,
  created_at   timestamptz not null default now()
);
create index if not exists investor_profit_runs_inv_idx on public.investor_profit_runs (investor_id, period_from);
-- One live run per investor per period.
create unique index if not exists investor_profit_runs_uq on public.investor_profit_runs (investor_id, period_from, period_to)
  where status <> 'void';

do $rls$
declare t text;
begin
  foreach t in array array['investors', 'investor_tranches', 'investor_tranche_lines', 'investor_profit_runs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_all', t);
    execute format('create policy %I on public.%I for all to authenticated using (public._is_org_member(org_id)) with check (public._is_org_member(org_id))', t || '_all', t);
  end loop;
end $rls$;

-- ── accounts ─────────────────────────────────────────────────────────────
-- Next child code under a parent: parent code + 2-digit sequence (the same
-- pattern the chart of accounts uses, e.g. 210001 → 21000101, 21000102 …).
create or replace function public._coa_child_code(p_parent text)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare v_code text; v_max int;
begin
  v_code := (select code from public.chart_of_accounts where id = p_parent);
  if v_code is null then return null; end if;
  v_max := (select coalesce(max(nullif(regexp_replace(substr(code, length(v_code) + 1), '[^0-9]', '', 'g'), '')::int), 0)
              from public.chart_of_accounts
             where parent_id = p_parent and code like v_code || '%' and length(code) = length(v_code) + 2);
  return v_code || lpad((v_max + 1)::text, 2, '0');
end $$;

create or replace function public._coa_add_child(p_parent text, p_name text, p_type text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare p record; v_id text; v_code text;
begin
  select * into p from public.chart_of_accounts where id = p_parent;
  if not found then raise exception 'The parent account was not found. Pick it again in Investor settings.'; end if;
  v_code := public._coa_child_code(p_parent);
  v_id := 'coa_' || replace(gen_random_uuid()::text, '-', '');
  insert into public.chart_of_accounts (id, org_id, parent_id, code, name, account_group, level, account_type, is_active, sort_order)
  values (v_id, p.org_id, p_parent, v_code, p_name, p.account_group, coalesce(p.level, 0) + 1,
          coalesce(p_type, p.account_type), true,
          coalesce((select max(sort_order) from public.chart_of_accounts where parent_id = p_parent), 0) + 1);
  return v_id;
end $$;

-- Creates whichever of the investor's three accounts are still missing, under
-- the parents set in Investor settings (app_config):
--   org.investor_liability_parent → "Investment – Name" and "Profit payable – Name"
--   org.investor_expense_parent   → "Profit on investment – Name"
create or replace function public.investor_ensure_accounts(p_investor text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare i record; v_liab text; v_exp text;
begin
  select * into i from public.investors where id = p_investor;
  if not found then raise exception 'Investor not found.'; end if;
  if not public._is_org_member(i.org_id) then raise exception 'You do not have access to this organisation.'; end if;
  v_liab := (select value from public.app_config where org_id = i.org_id and key = 'org.investor_liability_parent' limit 1);
  v_exp  := (select value from public.app_config where org_id = i.org_id and key = 'org.investor_expense_parent' limit 1);
  if i.investment_account_id is null or i.payable_account_id is null then
    if coalesce(v_liab, '') = '' then raise exception 'Set the parent account for investor accounts in Investor settings first.'; end if;
  end if;
  if i.expense_account_id is null and coalesce(v_exp, '') = '' then
    raise exception 'Set the parent account for investor profit expense in Investor settings first.';
  end if;
  if i.investment_account_id is null then
    update public.investors set investment_account_id = public._coa_add_child(v_liab, 'Investment - ' || i.name, 'liability') where id = i.id;
  end if;
  if i.payable_account_id is null then
    update public.investors set payable_account_id = public._coa_add_child(v_liab, 'Profit payable - ' || i.name, 'liability') where id = i.id;
  end if;
  if i.expense_account_id is null then
    update public.investors set expense_account_id = public._coa_add_child(v_exp, 'Profit on investment - ' || i.name, 'expense') where id = i.id;
  end if;
  return (select to_jsonb(x) from public.investors x where x.id = i.id);
end $$;
grant execute on function public.investor_ensure_accounts(text) to authenticated;

-- ── margin on goods from specific GRNs, invoiced in [p_from, p_to] ───────
-- Sales Invoices (via their DO) and POS sales. Sale price per unit = the
-- invoice line value ÷ quantity; cost = the FIFO cost of exactly those units.
create or replace function public.investor_grn_margin(p_org text, p_grn_ids text[], p_from date, p_to date)
returns table(grn_id text, qty numeric, revenue numeric, cost numeric)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._is_org_member(p_org) then raise exception 'You do not have access to this organisation.'; end if;
  return query
  with c as (
    select l.source_id as grn, cc.source_type, cc.source_id, cc.product_id, cc.qty_consumed, cc.unit_cost, cc.consumed_at
      from public.inventory_cost_consumption cc
      join public.inventory_cost_layers l on l.id = cc.layer_id
     where l.org_id = p_org and l.source_type = 'grn' and l.source_id = any (p_grn_ids)
       and cc.qty_consumed > 0
  ),
  pos as (
    select c.grn, c.qty_consumed as q, c.qty_consumed * c.unit_cost as cst,
           c.qty_consumed * coalesce((
             select sum(i.unit_price * i.quantity
                        - case when coalesce(i.discount_type, 'fixed') = 'percent'
                               then i.unit_price * i.quantity * coalesce(i.discount, 0) / 100
                               else coalesce(i.discount, 0) end) / nullif(sum(i.quantity), 0)
               from public.pos_transaction_items i
              where i.transaction_id = c.source_id and i.product_id = c.product_id and i.quantity > 0), 0) as rev
      from c
     where c.source_type = 'pos' and (c.consumed_at at time zone 'Asia/Karachi')::date between p_from and p_to
  ),
  inv as (
    select c.grn, c.qty_consumed as q, c.qty_consumed * c.unit_cost as cst,
           c.qty_consumed * (sum(it.line_total) / nullif(sum(it.qty_delivered), 0)) as rev
      from c
      join public.sales_invoices s
        on (s.do_id = c.source_id or s.id = c.source_id)
       and coalesce(s.is_voided, false) = false
       and s.voucher_date between p_from and p_to
      join public.sales_invoice_items it on it.invoice_id = s.id and it.product_id = c.product_id
     where c.source_type <> 'pos'
     group by c.grn, c.source_id, c.product_id, c.qty_consumed, c.unit_cost, c.consumed_at
  )
  select x.grn, sum(x.q), sum(coalesce(x.rev, 0)), sum(x.cst)
    from (select * from pos union all select * from inv) x
   group by x.grn;
end $$;
grant execute on function public.investor_grn_margin(text, text[], date, date) to authenticated;

-- Received GRNs that are free to link (not voided, not linked to any tranche).
create or replace function public.investor_free_grns(p_org text, p_search text default null)
returns table(id text, voucher_number text, voucher_date date, supplier text, value numeric)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._is_org_member(p_org) then raise exception 'You do not have access to this organisation.'; end if;
  return query
  select g.id, g.voucher_number::text, g.voucher_date::date, s.name::text,
         coalesce((select sum(l.qty_in * l.unit_cost) from public.inventory_cost_layers l
                    where l.source_type = 'grn' and l.source_id = g.id), 0)
    from public.purchase_grns g
    left join public.suppliers s on s.id = g.supplier_id
   where g.org_id = p_org and coalesce(g.status, 'draft') <> 'draft' and coalesce(g.is_voided, false) = false
     and not exists (select 1 from public.investor_tranche_lines t where t.grn_id = g.id)
     and (p_search is null or p_search = '' or g.voucher_number ilike '%' || p_search || '%' or s.name ilike '%' || p_search || '%')
   order by g.voucher_date desc
   limit 200;
end $$;
grant execute on function public.investor_free_grns(text, text) to authenticated;

notify pgrst, 'reload schema';

-- Check
select count(*) as investors from public.investors;
