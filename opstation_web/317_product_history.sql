-- 317 — Product timeline: record every change to a product's master data.
-- Products screen ▸ timeline icon. A trigger logs each insert/update with the
-- fields that changed (old → new) and who did it — whichever screen, import or
-- database routine made the change. History starts from when this is run.
-- Safe to run again.

create table if not exists public.product_history (
  id              bigserial primary key,
  org_id          text not null,
  product_id      text not null,
  event_type      text not null default 'updated',   -- created | updated
  changes         jsonb not null default '{}'::jsonb, -- {field: {"old": …, "new": …}}
  changed_at      timestamptz not null default now(),
  changed_by      text,
  changed_by_name text
);
create index if not exists idx_product_history_product on public.product_history(org_id, product_id, changed_at desc);

alter table public.product_history enable row level security;

-- Any active user of the org (same as in 314; re-declared so 317 stands alone).
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

drop policy if exists ph_org_read on public.product_history;
create policy ph_org_read on public.product_history
  for select to authenticated using (public._is_org_member(org_id));
grant select on public.product_history to authenticated;

create or replace function public.trg_product_history()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  n jsonb := to_jsonb(NEW);
  o jsonb := case when TG_OP = 'UPDATE' then to_jsonb(OLD) else '{}'::jsonb end;
  f text;
  ch jsonb := '{}'::jsonb;
  v_uid text; v_name text;
  tracked text[] := array[
    'name', 'sku', 'barcode', 'base_uom_id', 'product_type',
    'product_main_group', 'product_group', 'product_sub_group', 'product_class',
    'product_movement_category', 'selling_price', 'cost_price', 'low_stock_limit',
    'is_active', 'is_consignment', 'is_service', 'supervised_at'];
begin
  begin
    foreach f in array tracked loop
      if n ? f and (TG_OP = 'INSERT' or (n -> f) is distinct from (o -> f)) then
        -- numeric fields: ignore 12 vs 12.00 noise
        if TG_OP = 'UPDATE' and f in ('selling_price', 'cost_price', 'low_stock_limit')
           and coalesce((n ->> f)::numeric, 0) = coalesce((o ->> f)::numeric, 0) then
          continue;
        end if;
        if TG_OP = 'INSERT' and (n -> f) = 'null'::jsonb then continue; end if;
        ch := ch || jsonb_build_object(f, jsonb_build_object('old', o -> f, 'new', n -> f));
      end if;
    end loop;

    if TG_OP = 'UPDATE' and ch = '{}'::jsonb then return NEW; end if;

    select u.id, u.name into v_uid, v_name
      from users u
     where u.org_id = n ->> 'org_id'
       and (u.account_id = public.current_account_id()
            or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
     limit 1;

    insert into product_history(org_id, product_id, event_type, changes, changed_by, changed_by_name)
    values (n ->> 'org_id', n ->> 'id', case when TG_OP = 'INSERT' then 'created' else 'updated' end,
            ch, v_uid, coalesce(v_name, case when auth.uid() is null then 'System' end));
  exception when others then
    null; -- never block a product save
  end;
  return NEW;
end $$;

drop trigger if exists zz_product_history on public.products;
create trigger zz_product_history after insert or update on public.products
  for each row execute function public.trg_product_history();
