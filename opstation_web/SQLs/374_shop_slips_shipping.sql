-- 374 — Fulfillment: courier booking prefill + packing slips.
-- ship_info = a courier booking found on the Shopify order (tracking number /
-- courier from the courier app), money breakdown for the slip, who picked,
-- and a per-store custom text printed on every packing slip. Safe to run again.
alter table public.shop_orders add column if not exists ship_info      jsonb;
alter table public.shop_orders add column if not exists subtotal       numeric;
alter table public.shop_orders add column if not exists shipping_total numeric;
alter table public.shop_orders add column if not exists discounts      numeric;
alter table public.shop_orders add column if not exists outstanding    numeric;   -- amount to collect (COD)
alter table public.shop_orders add column if not exists tags           text;
alter table public.shop_orders add column if not exists picked_by_name text;
alter table public.shop_orders add column if not exists picked_at      timestamptz;
alter table public.shop_stores add column if not exists slip_note      text;
alter table public.shop_stores add column if not exists slip_size      text;      -- a4 | a5
