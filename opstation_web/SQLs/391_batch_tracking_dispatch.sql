-- 391 — Serial scan at dispatch (Delivery Order + POS). Needs 389.
--
--  * Admin Settings → Batch & warranty tracking → "Scan serials at dispatch"
--    (app_config 'org.bt_dispatch_scan' = off | optional | mandatory).
--  * Each scanned unit records who bought it, the document and the sale date;
--    the customer warranty runs from that date. A carton is marked dispatched
--    when all its units have gone.
--  * Voiding the DO (or a POS return of the unit) puts the serial back in stock.
-- Safe to run again.

alter table public.product_serials add column if not exists sold_doc_type   text;   -- do | pos
alter table public.product_serials add column if not exists sold_doc_id     text;
alter table public.product_serials add column if not exists sold_doc_number text;
alter table public.product_serials add column if not exists customer_name   text;
create index if not exists product_serials_sold_idx on public.product_serials (sold_doc_type, sold_doc_id);

create or replace function public._bt_carton_refresh(p_carton text)
returns void language sql security definer set search_path to 'public' as $$
  update public.product_cartons ct set status = case
      when exists (select 1 from public.product_serials s where s.carton_id = ct.id and s.status = 'in_stock') then 'in_stock'
      when exists (select 1 from public.product_serials s where s.carton_id = ct.id and s.status = 'dispatched') then 'dispatched'
      else ct.status end
   where ct.id = p_carton and ct.status in ('in_stock', 'dispatched');
$$;

-- Marks the given serials as sold. Returns how many were updated.
create or replace function public.bt_dispatch_serials(
  p_org text, p_doc_type text, p_doc_id text, p_doc_number text,
  p_customer text, p_customer_name text, p_date date, p_serials jsonb)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int; c text;
begin
  if p_org is null or not public._is_org_member(p_org) then
    raise exception 'You do not have access to this organisation.';
  end if;
  if not public._bt_on(p_org) then return 0; end if;
  update public.product_serials s
     set status = 'dispatched', sold_doc_type = p_doc_type, sold_doc_id = p_doc_id, sold_doc_number = p_doc_number,
         do_id = case when p_doc_type = 'do' then p_doc_id else s.do_id end,
         customer_id = p_customer, customer_name = p_customer_name,
         dispatched_on = coalesce(p_date, current_date)
   where s.org_id = p_org and s.status = 'in_stock'
     and upper(s.serial) in (select upper(x) from jsonb_array_elements_text(coalesce(p_serials, '[]'::jsonb)) x);
  get diagnostics n = row_count;
  for c in select distinct carton_id from public.product_serials
            where org_id = p_org and sold_doc_type = p_doc_type and sold_doc_id = p_doc_id and carton_id is not null loop
    perform public._bt_carton_refresh(c);
  end loop;
  return n;
end $$;
grant execute on function public.bt_dispatch_serials(text, text, text, text, text, text, date, jsonb) to authenticated;

-- Puts serials back in stock (returns). p_doc_id limits it to one sale.
create or replace function public.bt_return_serials(p_org text, p_doc_id text, p_serials jsonb)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int; c text; v_cartons text[];
begin
  if p_org is null or not public._is_org_member(p_org) then
    raise exception 'You do not have access to this organisation.';
  end if;
  select array_agg(distinct carton_id) into v_cartons from public.product_serials
   where org_id = p_org and status = 'dispatched' and (p_doc_id is null or sold_doc_id = p_doc_id)
     and upper(serial) in (select upper(x) from jsonb_array_elements_text(coalesce(p_serials, '[]'::jsonb)) x);
  update public.product_serials s
     set status = 'in_stock', sold_doc_type = null, sold_doc_id = null, sold_doc_number = null,
         do_id = null, customer_id = null, customer_name = null, dispatched_on = null
   where s.org_id = p_org and s.status = 'dispatched' and (p_doc_id is null or s.sold_doc_id = p_doc_id)
     and upper(s.serial) in (select upper(x) from jsonb_array_elements_text(coalesce(p_serials, '[]'::jsonb)) x);
  get diagnostics n = row_count;
  foreach c in array coalesce(v_cartons, '{}'::text[]) loop
    if c is not null then perform public._bt_carton_refresh(c); end if;
  end loop;
  return n;
end $$;
grant execute on function public.bt_return_serials(text, text, jsonb) to authenticated;

-- A voided DO puts its units back in stock (never blocks the void).
create or replace function public.trg_bt_do_void()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare c text; v_cartons text[];
begin
  begin
    if coalesce(NEW.is_voided, false) and not coalesce(OLD.is_voided, false) then
      select array_agg(distinct carton_id) into v_cartons from public.product_serials
       where sold_doc_type = 'do' and sold_doc_id = NEW.id and status = 'dispatched';
      update public.product_serials
         set status = 'in_stock', sold_doc_type = null, sold_doc_id = null, sold_doc_number = null,
             do_id = null, customer_id = null, customer_name = null, dispatched_on = null
       where sold_doc_type = 'do' and sold_doc_id = NEW.id and status = 'dispatched';
      foreach c in array coalesce(v_cartons, '{}'::text[]) loop
        if c is not null then perform public._bt_carton_refresh(c); end if;
      end loop;
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists bt_do_void on public.delivery_orders;
create trigger bt_do_void after update of is_voided on public.delivery_orders
  for each row execute function public.trg_bt_do_void();

-- No setting saved yet = Optional.

notify pgrst, 'reload schema';

-- Check
select count(*) filter (where status = 'dispatched') as dispatched_units,
       count(*) filter (where status = 'in_stock') as in_stock_units
  from public.product_serials;
