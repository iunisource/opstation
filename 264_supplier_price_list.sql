-- ============================================================================
-- Migration 264: per-supplier price list (central record of agreed/suggested
-- purchase prices for a supplier, shown on the Supplier 360 "Price List" tab).
--
-- One price per (supplier, product). ADDITIVE + idempotent.
-- ============================================================================

create table if not exists public.supplier_price_list (
  id          text primary key,
  org_id      text not null,
  supplier_id text not null,
  product_id  text not null,
  price       numeric not null default 0,
  note        text,
  updated_at  timestamptz default now(),
  updated_by  text
);

-- One price per supplier per product (upsert target).
create unique index if not exists uq_supplier_price_list_supp_prod
  on public.supplier_price_list (org_id, supplier_id, product_id);

create index if not exists idx_supplier_price_list_supp
  on public.supplier_price_list (org_id, supplier_id);

grant select, insert, update, delete on public.supplier_price_list to authenticated;
alter table public.supplier_price_list enable row level security;

drop policy if exists spl_rw on public.supplier_price_list;
create policy spl_rw on public.supplier_price_list
  for all to authenticated
  using      (public.is_super_admin() OR org_id = public.current_user_org_id())
  with check (public.is_super_admin() OR org_id = public.current_user_org_id());
