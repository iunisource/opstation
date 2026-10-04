-- 314 — Saved price lists / cost sheets (Inventory ▸ Price List Generator ▸ Save).
-- Saved only when a user presses Save. Each row is a frozen copy: the lines and
-- rates exactly as generated (including manual edits) plus the settings used.
-- Visible to everyone in the same org. Safe to run again.

create table if not exists public.price_list_snapshots (
  id              text primary key,
  org_id          text not null,
  title           text not null default 'Price List',   -- 'Price List' | 'Cost Sheet'
  name            text not null,
  notes           text,
  settings        jsonb not null default '{}'::jsonb,    -- source, method, margin, groups, search …
  lines           jsonb not null default '[]'::jsonb,    -- [{product_id, sku, name, uom, rate, edited}]
  item_count      int not null default 0,
  edited_count    int not null default 0,
  created_by      text,
  created_by_name text,
  created_at      timestamptz not null default now()
);
create index if not exists idx_pls_org_created on public.price_list_snapshots(org_id, created_at desc);

alter table public.price_list_snapshots enable row level security;

-- Any active user of the org (same identity check as _is_org_master in 296).
create or replace function public._is_org_member(p_org text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.users u
     where u.org_id = p_org
       and coalesce(u.is_active, true)
       and (u.account_id = public.current_account_id()
            or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))));
$$;

drop policy if exists pls_org_rw on public.price_list_snapshots;
create policy pls_org_rw on public.price_list_snapshots
  for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
grant select, insert, update, delete on public.price_list_snapshots to authenticated;
