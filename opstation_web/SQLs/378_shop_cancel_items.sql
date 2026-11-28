-- 378 — Cancel an item while picking (not available / changed), protected by
-- a passcode set by admins (⋮ → Item cancel passcode). Only a fingerprint of
-- the passcode is kept, in the server-only secrets table. Safe to run again.
alter table public.shop_store_secrets add column if not exists cancel_pin_hash text;
alter table public.shop_stores        add column if not exists cancel_pin_set  boolean not null default false;
