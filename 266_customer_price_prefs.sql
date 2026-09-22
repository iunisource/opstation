-- ============================================================================
-- Migration 266: per-customer preference for applying the customer price list
-- to that customer's sales invoices (toggle lives on Customer 360 → Price List).
--
-- When use_on_invoice = true, opening a sales invoice for this customer
-- auto-fills any UNPRICED line whose product is in the customer's price list
-- with the agreed price (still editable). ADDITIVE + idempotent.
-- ============================================================================

create table if not exists public.customer_price_prefs (
  org_id         text not null,
  customer_id    text primary key,
  use_on_invoice boolean not null default false,
  updated_at     timestamptz default now(),
  updated_by     text
);

create index if not exists idx_customer_price_prefs_org
  on public.customer_price_prefs (org_id, customer_id);

grant select, insert, update, delete on public.customer_price_prefs to authenticated;
alter table public.customer_price_prefs enable row level security;

drop policy if exists cpp_rw on public.customer_price_prefs;
create policy cpp_rw on public.customer_price_prefs
  for all to authenticated
  using      (public.is_super_admin() OR org_id = public.current_user_org_id())
  with check (public.is_super_admin() OR org_id = public.current_user_org_id());
