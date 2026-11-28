-- 375 — Fulfilled online orders → Sales Order. Remembers which SO an order was
-- copied to (so it isn't copied twice by mistake) and the customer used for
-- each store's SOs. Safe to run again.
alter table public.shop_orders add column if not exists so_id          text;
alter table public.shop_orders add column if not exists so_number      text;
alter table public.shop_stores add column if not exists so_customer_id text;
create index if not exists idx_shop_orders_fulfilled on public.shop_orders(org_id, status, fulfilled_at);
