-- 372 — Fulfillment: auto-fulfil switch per store (shown to every user on the
-- Fulfillment screen). On = an order is packed and fulfilled in the store as
-- soon as every item has been scanned right. Safe to run again.
alter table public.shop_stores add column if not exists auto_fulfil boolean not null default false;
