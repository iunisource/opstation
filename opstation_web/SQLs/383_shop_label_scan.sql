-- 383 — Per store: the courier label on the box must be scanned (and match the
-- order's booking) before fulfilling. ⋮ → Scan settings. Safe to run again.
alter table public.shop_stores add column if not exists require_label_scan boolean not null default false;
