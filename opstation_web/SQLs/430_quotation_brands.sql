-- 430 — Quotation brands: a business can quote under its different brands.
-- Each brand has its own name, contact details, logo and a generated design
-- (layout / colours / fonts). A quotation can be issued under one brand.
-- Safe to run again.

create table if not exists public.quotation_brands (
  id         text primary key default ('qb_' || replace(gen_random_uuid()::text, '-', '')),
  org_id     text not null,
  name       text not null,
  tagline    text,
  phone      text,
  email      text,
  address    text,
  website    text,
  tax_no     text,
  footer     text,
  logo_data  text,          -- small logo as a data: URI
  design     jsonb not null default '{}'::jsonb,
  is_active  boolean not null default true,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists quotation_brands_org_idx on public.quotation_brands (org_id, name);

alter table public.quotation_brands enable row level security;

drop policy if exists qb_read on public.quotation_brands;
create policy qb_read on public.quotation_brands for select
  using (public._is_org_member(org_id) or public._is_super_admin());

drop policy if exists qb_write on public.quotation_brands;
create policy qb_write on public.quotation_brands for all
  using (public._is_org_admin(org_id))
  with check (public._is_org_admin(org_id));

grant select, insert, update, delete on public.quotation_brands to authenticated;

alter table public.quotations add column if not exists brand_id text;

notify pgrst, 'reload schema';
select 'quotation brands ready' as result;
