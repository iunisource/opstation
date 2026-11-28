-- 370 — Online stores (Shopify) + Fulfillment.
-- Orders from connected stores land in shop_orders (pushed by Shopify the
-- moment they happen, plus a sync every 10 minutes as a safety net), are
-- picked / packed in Sales → Fulfillment with the barcode scanner, and marked
-- fulfilled back in the store with the courier + tracking number.
-- Store keys live in shop_store_secrets, which no app user can read — only the
-- server (the `shopify` edge function). Safe to run again.

create table if not exists public.shop_stores (
  id           text primary key default 'st_' || replace(gen_random_uuid()::text, '-', ''),
  org_id       text not null,
  platform     text not null default 'shopify',
  name         text,
  shop_domain  text not null,               -- mystore.myshopify.com
  branch_id    text,                        -- ships from
  is_active    boolean not null default true,
  last_sync_at timestamptz,
  last_error   text,
  webhooks_ok  boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (org_id, shop_domain)
);

create table if not exists public.shop_store_secrets (
  store_id         text primary key references public.shop_stores(id) on delete cascade,
  client_id        text,
  client_secret    text,          -- also signs Shopify's notifications
  access_token     text,
  token_expires_at timestamptz    -- null = a permanent (legacy) token
);

create table if not exists public.shop_orders (
  id                  text primary key default 'sho_' || replace(gen_random_uuid()::text, '-', ''),
  org_id              text not null,
  store_id            text not null references public.shop_stores(id) on delete cascade,
  external_id         text not null,          -- Shopify order id (gid)
  order_no            text,                   -- #1001
  placed_at           timestamptz,
  ext_updated_at      timestamptz,
  financial_status    text,                   -- PAID / PENDING / REFUNDED …
  ext_fulfillment     text,                   -- UNFULFILLED / FULFILLED …
  payment_methods     text,
  cancelled_at        timestamptz,
  customer_name       text,
  email               text,
  phone               text,
  ship_to             jsonb,
  note                text,
  total               numeric,
  currency            text,
  lines               jsonb not null default '[]'::jsonb,  -- [{line_id,title,variant_title,sku,barcode,variant_id,qty,price,product_id,picked}]
  status              text not null default 'new',         -- new | picking | packed | fulfilled | cancelled
  packed_at           timestamptz,
  packed_by_name      text,
  tracking_company    text,
  tracking_number     text,
  tracking_url        text,
  fulfilled_at        timestamptz,
  fulfilled_by_name   text,
  fulfil_error        text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (store_id, external_id)
);
create index if not exists idx_shop_orders_org_status on public.shop_orders(org_id, status, placed_at desc);

-- Remembered "this store item = that Opstation product" choices.
create table if not exists public.shop_product_map (
  org_id     text not null,
  store_id   text not null references public.shop_stores(id) on delete cascade,
  ext_key    text not null,       -- variant id, or "sku:<sku>"
  product_id text not null,
  primary key (store_id, ext_key)
);

alter table public.shop_stores        enable row level security;
alter table public.shop_store_secrets enable row level security;   -- no policies: server only
alter table public.shop_orders        enable row level security;
alter table public.shop_product_map   enable row level security;

drop policy if exists shop_stores_read on public.shop_stores;
create policy shop_stores_read on public.shop_stores for select using (public._is_org_member(org_id));
drop policy if exists shop_stores_edit on public.shop_stores;
create policy shop_stores_edit on public.shop_stores for update
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));

drop policy if exists shop_orders_read on public.shop_orders;
create policy shop_orders_read on public.shop_orders for select using (public._is_org_member(org_id));
drop policy if exists shop_orders_edit on public.shop_orders;
create policy shop_orders_edit on public.shop_orders for update
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));

drop policy if exists shop_map_all on public.shop_product_map;
create policy shop_map_all on public.shop_product_map for all
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));

grant select, update on public.shop_stores to authenticated;
grant select, update on public.shop_orders to authenticated;
grant select, insert, update, delete on public.shop_product_map to authenticated;
revoke all on public.shop_store_secrets from anon, authenticated;

-- Live list: new orders appear on the Fulfillment screen instantly.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'shop_orders') then
    alter publication supabase_realtime add table public.shop_orders;
  end if;
end $$;

-- Safety-net sync every 10 minutes (needs the `shopify` edge function deployed
-- and the same `edge_service_key` Vault secret the other jobs use).
DO $do$
declare v_key text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — sync not scheduled'; return;
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_service_key' limit 1;
  if v_key is null then raise notice 'edge_service_key missing in Vault — sync not scheduled'; return; end if;
  if exists (select 1 from cron.job where jobname = 'shop-orders-sync') then
    perform cron.unschedule('shop-orders-sync');
  end if;
  perform cron.schedule('shop-orders-sync', '*/10 * * * *', format($cron$
    select net.http_post(
      url     := 'https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/shopify',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s'),
      body    := '{"action":"sync_all"}'::jsonb);
  $cron$, v_key));
  raise notice 'Scheduled shop-orders-sync every 10 minutes.';
end $do$;
