-- ============================================================================
-- Migration 267: product lifecycle (Manufacturing/Production).
--
-- Append-only timeline of a product's BOM/recipe changes. Every successful save
-- on the Bill of Materials screen writes one snapshot row here, so the product's
-- "Lifecycle" view can show what changed (components, waste, labor/overhead,
-- output qty, status) over time and who changed it.
--
-- Going-forward only (history starts accruing after deploy). ADDITIVE + idempotent.
-- ============================================================================

create table if not exists public.product_lifecycle (
  id              text primary key,
  org_id          text not null,
  product_id      text not null,
  bom_id          text,
  code            text,
  event_type      text not null default 'updated', -- 'created' | 'updated'
  snapshot        jsonb,                            -- full BOM state at this point
  changed_at      timestamptz not null default now(),
  changed_by      text,
  changed_by_name text
);

create index if not exists idx_product_lifecycle_lookup
  on public.product_lifecycle (org_id, product_id, changed_at desc);

grant select, insert on public.product_lifecycle to authenticated;
alter table public.product_lifecycle enable row level security;

drop policy if exists plc_rw on public.product_lifecycle;
create policy plc_rw on public.product_lifecycle
  for all to authenticated
  using      (public.is_super_admin() OR org_id = public.current_user_org_id())
  with check (public.is_super_admin() OR org_id = public.current_user_org_id());
