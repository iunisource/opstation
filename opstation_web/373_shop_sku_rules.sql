-- 373 — Per-store SKU rules (Match products → SKU rules): bundle separators,
-- how quantity is written, and bracket tags like (S) → "special".
-- Empty = sensible defaults. Safe to run again.
alter table public.shop_stores add column if not exists sku_rules jsonb;
