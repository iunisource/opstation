-- 288 — Payment Advice: pictorial signatures snapshotted at the moment of
-- creation / approval (plus the company stamp with the approval).
alter table if exists public.payment_advices
  add column if not exists created_signature_url  text,
  add column if not exists approved_signature_url text,
  add column if not exists approved_stamp_url     text;
