-- 387 — Courier booking from Fulfillment (shipping label + tracking)
-- Per store: which courier books parcels, whether Fulfil asks to book, test
-- mode, and the API keys (kept in a table app users can't read).
-- Per order: the label link and booking details. Safe to run again.

alter table public.shop_stores add column if not exists courier_provider text;
alter table public.shop_stores add column if not exists courier_ask boolean not null default true;
alter table public.shop_stores add column if not exists courier_test boolean not null default false;
alter table public.shop_stores add column if not exists courier_key_set boolean not null default false;

create table if not exists public.shop_courier_secrets (
  store_id    text primary key references public.shop_stores(id) on delete cascade,
  provider    text,
  api_key     text,
  api_secret  text,
  account_id  text,
  pickup_id   text,
  updated_at  timestamptz not null default now()
);
-- No policies on purpose: only the server (service role) reads or writes keys.
alter table public.shop_courier_secrets enable row level security;
revoke all on public.shop_courier_secrets from anon, authenticated;

alter table public.shop_orders add column if not exists label_url text;
alter table public.shop_orders add column if not exists courier_booked_at timestamptz;
alter table public.shop_orders add column if not exists courier_booking jsonb;

notify pgrst, 'reload schema';

-- Check
select column_name, table_name from information_schema.columns
 where table_schema = 'public'
   and ((table_name = 'shop_stores' and column_name like 'courier_%')
     or (table_name = 'shop_orders' and column_name in ('label_url', 'courier_booked_at', 'courier_booking')))
 order by table_name, column_name;
