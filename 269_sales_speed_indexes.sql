-- ============================================================================
-- Migration 269: indexes to keep the sales flow (SO/DO/SI) fast at high volume.
--
-- The lists now load the most-recent slice (ORDER BY created_at DESC LIMIT N)
-- and search server-side (voucher_number ILIKE, customer name ILIKE, parent
-- lookups). These indexes make those patterns index-backed instead of full
-- table scans. ADDITIVE + idempotent; safe to re-run.
-- ============================================================================

-- Trigram support for fast ILIKE '%text%' (voucher / customer name search).
create extension if not exists pg_trgm;

-- ── Recent-slice ordering: (org_id, created_at desc) ────────────────────────
create index if not exists idx_sales_orders_org_created
  on public.sales_orders (org_id, created_at desc);
create index if not exists idx_delivery_orders_org_created
  on public.delivery_orders (org_id, created_at desc);
create index if not exists idx_sales_invoices_org_created
  on public.sales_invoices (org_id, created_at desc);

-- ── Voucher-number search (ILIKE %..%) via trigram ─────────────────────────
create index if not exists idx_sales_orders_vnum_trgm
  on public.sales_orders using gin (voucher_number gin_trgm_ops);
create index if not exists idx_delivery_orders_vnum_trgm
  on public.delivery_orders using gin (voucher_number gin_trgm_ops);
create index if not exists idx_sales_invoices_vnum_trgm
  on public.sales_invoices using gin (voucher_number gin_trgm_ops);

-- ── Customer-name / code search (resolve customer ids by ILIKE) ────────────
create index if not exists idx_customers_shop_name_trgm
  on public.customers using gin (shop_name gin_trgm_ops);
create index if not exists idx_customers_code_trgm
  on public.customers using gin (code gin_trgm_ops);

-- ── Foreign-key lookups used by search + detail loads ──────────────────────
create index if not exists idx_sales_orders_customer     on public.sales_orders (customer_id);
create index if not exists idx_delivery_orders_customer  on public.delivery_orders (customer_id);
create index if not exists idx_delivery_orders_so        on public.delivery_orders (so_id);
create index if not exists idx_sales_invoices_customer   on public.sales_invoices (customer_id);
create index if not exists idx_sales_invoices_so         on public.sales_invoices (so_id);
create index if not exists idx_sales_invoices_do         on public.sales_invoices (do_id);
