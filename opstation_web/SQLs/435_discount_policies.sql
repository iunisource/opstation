-- 435 — Discount management (Inventory → Discount Policies).
--
-- Two ways to give a customer a discount on a product:
--   1. Customer + SKU: a policy tagged to one customer for one product.
--   2. Discount group: a policy for a product inside a group; the customer
--      profile carries ONE discount group.
-- If both match, the customer + SKU policy wins.
--
-- A policy is % or Rs-per-unit, with optional start / end dates. Policies made
-- or changed by non-admins wait for an admin's approval before they apply;
-- an admin's own policies apply straight away.
--
-- Applied automatically on Quotations, Sales Invoices (created from a DO) and
-- POS through customer_discounts(). Safe to run again.

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.discount_groups (
  id          text primary key default ('dg_' || replace(gen_random_uuid()::text, '-', '')),
  org_id      text not null,
  name        text not null,
  description text,
  is_active   boolean not null default true,
  created_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists discount_groups_org_name_uq
  on public.discount_groups (org_id, lower(name));

create table if not exists public.discount_policies (
  id            text primary key default ('dp_' || replace(gen_random_uuid()::text, '-', '')),
  org_id        text not null,
  customer_id   text,                 -- way 1: customer + SKU
  group_id      text references public.discount_groups(id) on delete cascade, -- way 2
  product_id    text not null,
  disc_type     text not null default 'percent' check (disc_type in ('percent', 'amount')),
  value         numeric not null check (value > 0),
  valid_from    date,
  valid_to      date,
  is_active     boolean not null default true,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  notes         text,
  reject_reason text,
  created_by    text,
  updated_by    text,
  approved_by   text,
  approved_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint discount_policies_target_ck check ((customer_id is null) <> (group_id is null)),
  constraint discount_policies_pct_ck check (disc_type <> 'percent' or value <= 100),
  constraint discount_policies_dates_ck check (valid_from is null or valid_to is null or valid_to >= valid_from)
);
create index if not exists discount_policies_cust_idx  on public.discount_policies (org_id, customer_id, product_id);
create index if not exists discount_policies_group_idx on public.discount_policies (org_id, group_id, product_id);
create index if not exists discount_policies_status_idx on public.discount_policies (org_id, status);

alter table public.customers add column if not exists discount_group_id text;

-- ─────────────────────────────────────────────────────────────────────────────
-- Approval guard: non-admins can't approve, and any change by a non-admin
-- sends the policy back for approval. Admins' own changes are approved.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.trg_discount_policy_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_admin boolean; v_me text; v_changed boolean;
begin
  v_admin := coalesce(public._is_org_admin(NEW.org_id), false) or coalesce(public._is_super_admin(), false);
  select a.id into v_me from public._acting_user(NEW.org_id) a;
  NEW.updated_at := now();
  NEW.updated_by := coalesce(v_me, NEW.updated_by);

  if TG_OP = 'INSERT' then
    NEW.created_by := coalesce(NEW.created_by, v_me);
    if v_admin then
      NEW.status := 'approved'; NEW.approved_by := v_me; NEW.approved_at := now(); NEW.reject_reason := null;
    else
      NEW.status := 'pending'; NEW.approved_by := null; NEW.approved_at := null;
    end if;
    return NEW;
  end if;

  v_changed := NEW.product_id is distinct from OLD.product_id
            or NEW.customer_id is distinct from OLD.customer_id
            or NEW.group_id is distinct from OLD.group_id
            or NEW.disc_type is distinct from OLD.disc_type
            or NEW.value is distinct from OLD.value
            or NEW.valid_from is distinct from OLD.valid_from
            or NEW.valid_to is distinct from OLD.valid_to
            or (NEW.is_active and not OLD.is_active);

  if v_admin then
    if v_changed and NEW.status is not distinct from OLD.status then
      -- an admin editing a policy approves it
      NEW.status := 'approved'; NEW.approved_by := v_me; NEW.approved_at := now(); NEW.reject_reason := null;
    elsif NEW.status = 'approved' and OLD.status <> 'approved' then
      NEW.approved_by := v_me; NEW.approved_at := now(); NEW.reject_reason := null;
    end if;
  else
    if v_changed then
      NEW.status := 'pending'; NEW.approved_by := null; NEW.approved_at := null; NEW.reject_reason := null;
    else
      NEW.status := OLD.status; NEW.approved_by := OLD.approved_by;
      NEW.approved_at := OLD.approved_at; NEW.reject_reason := OLD.reject_reason;
    end if;
  end if;
  return NEW;
end $$;
drop trigger if exists trg_discount_policy_guard on public.discount_policies;
create trigger trg_discount_policy_guard before insert or update on public.discount_policies
  for each row execute function public.trg_discount_policy_guard();

create or replace function public.trg_discount_group_touch()
returns trigger language plpgsql as $$
begin
  NEW.updated_at := now();
  return NEW;
end $$;
drop trigger if exists trg_discount_group_touch on public.discount_groups;
create trigger trg_discount_group_touch before update on public.discount_groups
  for each row execute function public.trg_discount_group_touch();

-- ─────────────────────────────────────────────────────────────────────────────
-- Row security: the org reads and writes (screens gate by permission; only
-- admins can delete).
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.discount_groups enable row level security;
alter table public.discount_policies enable row level security;

drop policy if exists dg_read on public.discount_groups;
create policy dg_read on public.discount_groups for select
  using (public._is_org_member(org_id) or public._is_super_admin());
drop policy if exists dg_write on public.discount_groups;
create policy dg_write on public.discount_groups for insert
  with check (public._is_org_member(org_id));
drop policy if exists dg_update on public.discount_groups;
create policy dg_update on public.discount_groups for update
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
drop policy if exists dg_delete on public.discount_groups;
create policy dg_delete on public.discount_groups for delete
  using (public._is_org_admin(org_id) or public._is_super_admin());

drop policy if exists dp_read on public.discount_policies;
create policy dp_read on public.discount_policies for select
  using (public._is_org_member(org_id) or public._is_super_admin());
drop policy if exists dp_write on public.discount_policies;
create policy dp_write on public.discount_policies for insert
  with check (public._is_org_member(org_id));
drop policy if exists dp_update on public.discount_policies;
create policy dp_update on public.discount_policies for update
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
drop policy if exists dp_delete on public.discount_policies;
create policy dp_delete on public.discount_policies for delete
  using (public._is_org_admin(org_id) or public._is_super_admin());

grant select, insert, update, delete on public.discount_groups, public.discount_policies to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- The discounts a customer gets today, one per product:
--   { "<product_id>": {"type": "percent"|"amount", "value": n,
--                       "source": "sku"|"group", "policy": "<id>"} }
-- Customer + SKU beats the group; among equals the latest change wins.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.customer_discounts(p_customer text, p_on date default current_date)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with c as (
    select cu.id, cu.org_id, cu.discount_group_id
      from public.customers cu
     where cu.id = p_customer
       and (public._is_org_member(cu.org_id) or public._is_super_admin())
  ),
  pol as (
    select p.*, case when p.customer_id is not null then 1 else 2 end as pri
      from public.discount_policies p
      join c on c.org_id = p.org_id
      left join public.discount_groups g on g.id = p.group_id
     where p.status = 'approved' and p.is_active
       and (p.valid_from is null or p.valid_from <= coalesce(p_on, current_date))
       and (p.valid_to   is null or p.valid_to   >= coalesce(p_on, current_date))
       and (p.customer_id = c.id
            or (p.customer_id is null and p.group_id = c.discount_group_id and coalesce(g.is_active, false)))
  ),
  best as (
    select distinct on (product_id) * from pol order by product_id, pri, updated_at desc
  )
  select coalesce(jsonb_object_agg(product_id, jsonb_build_object(
           'type', disc_type, 'value', value,
           'source', case pri when 1 then 'sku' else 'group' end,
           'policy', id)), '{}'::jsonb)
    from best;
$$;
revoke all on function public.customer_discounts(text, date) from public, anon;
grant execute on function public.customer_discounts(text, date) to authenticated;

notify pgrst, 'reload schema';
select 'discount policies ready' as result;
