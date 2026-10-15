-- 381 — Fulfillment checkpoints:
--   A. picking lock  — who is picking an order right now
--   B. pack check    — the packing slip (and courier label) scanned before Packed
--                      (per store: shop_stores.require_slip_scan)
--   C. handover      — courier pickup scanned box by box, saved as a dispatch
-- Safe to run again.
alter table public.shop_orders add column if not exists picking_by          text;
alter table public.shop_orders add column if not exists picking_by_name     text;
alter table public.shop_orders add column if not exists picking_at          timestamptz;
alter table public.shop_orders add column if not exists slip_verified_at    timestamptz;
alter table public.shop_orders add column if not exists slip_verified_by    text;
alter table public.shop_orders add column if not exists label_verified_at   timestamptz;
alter table public.shop_orders add column if not exists handed_over_at      timestamptz;
alter table public.shop_orders add column if not exists handed_over_by_name text;
alter table public.shop_orders add column if not exists dispatch_id         text;
alter table public.shop_stores add column if not exists require_slip_scan   boolean not null default false;

create table if not exists public.shop_dispatches (
  id            text primary key default 'dsp_' || replace(gen_random_uuid()::text, '-', ''),
  org_id        text not null,
  courier       text,
  created_at    timestamptz not null default now(),
  created_by    text,
  created_by_name text,
  expected      int not null default 0,
  handed_over   int not null default 0,
  order_ids     text[] not null default '{}',
  missing_ids   text[] not null default '{}',
  note          text
);
create index if not exists idx_shop_dispatches_org on public.shop_dispatches(org_id, created_at desc);
alter table public.shop_dispatches enable row level security;
drop policy if exists shop_dispatches_read on public.shop_dispatches;
create policy shop_dispatches_read on public.shop_dispatches for select using (public._is_org_member(org_id));
drop policy if exists shop_dispatches_add on public.shop_dispatches;
create policy shop_dispatches_add on public.shop_dispatches for insert with check (public._is_org_member(org_id));
grant select, insert on public.shop_dispatches to authenticated;
