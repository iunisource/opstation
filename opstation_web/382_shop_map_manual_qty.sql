-- 382 — Matching: quantities in a saved match follow the SKU rules (e.g. "(3)")
-- unless they were typed by hand in Match products (manual_qty). Safe to run again.
alter table public.shop_product_map add column if not exists manual_qty boolean not null default false;
