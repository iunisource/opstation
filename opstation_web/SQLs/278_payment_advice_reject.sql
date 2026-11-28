-- Payment Advice: reject flow. A pending advice can be rejected by an admin or
-- a listed approver; an approved advice is final and can only be archived.

alter table if exists payment_advices
  add column if not exists rejected_by      text,
  add column if not exists rejected_by_name text,
  add column if not exists rejected_at      timestamptz,
  add column if not exists reject_reason    text;
