-- 376 — Orders un-fulfilled again in Shopify come back to the Fulfillment
-- queue; reopened_at marks when that happened. Safe to run again.
alter table public.shop_orders add column if not exists reopened_at timestamptz;
