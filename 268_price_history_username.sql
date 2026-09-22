-- ============================================================================
-- Migration 268: carry the acting user's NAME on price history rows, so the
-- price lifecycle shows "who" in plain language (not just an id). ADDITIVE +
-- idempotent. Existing rows keep NULL name (they predate this).
-- ============================================================================

alter table public.customer_price_history
  add column if not exists changed_by_name text;

alter table public.supplier_price_history
  add column if not exists changed_by_name text;
