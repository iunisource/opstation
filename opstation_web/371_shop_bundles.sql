-- 371 — Online store matching: bundles + finished-products-only.
-- A store item can now be one Opstation product OR a bundle of several
-- (components = [{"product_id": "...", "qty": 1}, ...]); rows keyed "code:<code>"
-- remember a choice made for an item code. match_groups = the
-- product main groups the store's items are matched against (empty = the
-- finished-goods group). Safe to run again.

alter table public.shop_product_map alter column product_id drop not null;
alter table public.shop_product_map add column if not exists components jsonb;
alter table public.shop_stores add column if not exists match_groups text[];
