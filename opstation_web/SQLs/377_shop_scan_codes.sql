-- 377 — Fulfillment scan setting per store (⋮ → Scan settings):
-- 'system' = only Opstation barcode / SKU count; 'any' (or empty) = Shopify codes too.
-- Safe to run again.
alter table public.shop_stores add column if not exists scan_codes text;
