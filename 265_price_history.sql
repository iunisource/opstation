-- ============================================================================
-- Migration 265: price history (lifecycle of prices per SKU).
--
-- The *_price_list tables hold ONE current price per (party, product) via
-- upsert, so they overwrite on change. These append-only history tables record
-- every price the app writes, so the Customer/Supplier 360 "Price List" tab can
-- show a per-SKU price timeline (tap a row -> price history).
--
-- ADDITIVE + idempotent.
-- ============================================================================

-- ── Customer price history ────────────────────────────────────────────────
create table if not exists public.customer_price_history (
  id          text primary key,
  org_id      text not null,
  customer_id text not null,
  product_id  text not null,
  price       numeric not null default 0,
  note        text,
  changed_at  timestamptz not null default now(),
  changed_by  text
);

create index if not exists idx_customer_price_history_lookup
  on public.customer_price_history (org_id, customer_id, product_id, changed_at desc);

grant select, insert on public.customer_price_history to authenticated;
alter table public.customer_price_history enable row level security;

drop policy if exists cph_rw on public.customer_price_history;
create policy cph_rw on public.customer_price_history
  for all to authenticated
  using      (public.is_super_admin() OR org_id = public.current_user_org_id())
  with check (public.is_super_admin() OR org_id = public.current_user_org_id());

-- ── Supplier price history ────────────────────────────────────────────────
create table if not exists public.supplier_price_history (
  id          text primary key,
  org_id      text not null,
  supplier_id text not null,
  product_id  text not null,
  price       numeric not null default 0,
  note        text,
  changed_at  timestamptz not null default now(),
  changed_by  text
);

create index if not exists idx_supplier_price_history_lookup
  on public.supplier_price_history (org_id, supplier_id, product_id, changed_at desc);

grant select, insert on public.supplier_price_history to authenticated;
alter table public.supplier_price_history enable row level security;

drop policy if exists sph_rw on public.supplier_price_history;
create policy sph_rw on public.supplier_price_history
  for all to authenticated
  using      (public.is_super_admin() OR org_id = public.current_user_org_id())
  with check (public.is_super_admin() OR org_id = public.current_user_org_id());
