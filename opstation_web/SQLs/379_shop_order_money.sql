-- 379 — Online orders: money as Shopify shows it (discount codes, tax) for
-- packing slips. Safe to run again.
alter table public.shop_orders add column if not exists tax_total      numeric;
alter table public.shop_orders add column if not exists taxes_included boolean;
alter table public.shop_orders add column if not exists discount_codes text;
