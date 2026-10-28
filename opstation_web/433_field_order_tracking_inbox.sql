-- 433 — Field orders: edit / cancel before approval, order tracking
-- (SO / DO / SI numbers + dispatched vs pending), and a notifications inbox
-- for the field app. Safe to run again.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. New columns + allow the 'cancelled' status
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.field_orders add column if not exists edited_at        timestamptz;
alter table public.field_orders add column if not exists edit_count       int not null default 0;
alter table public.field_orders add column if not exists cancelled_at     timestamptz;
alter table public.field_orders add column if not exists cancel_reason    text;
alter table public.field_orders add column if not exists removed_item_ids text[];

do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.field_orders'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%status%' loop
    execute format('alter table public.field_orders drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.field_orders add constraint field_orders_status_check
  check (status in ('draft', 'pending', 'submitted', 'approved', 'rejected', 'cancelled')) not valid;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Guards
--   * A cancelled order can never be approved or rejected afterwards.
--   * An old copy of the order on a phone (re-sent by sync) cannot undo an
--     approval, a cancel or an edit.
--   * Lines cannot be changed directly once the order is no longer 'submitted',
--     and lines removed by an edit cannot come back from an old phone copy.
--   The RPCs below run as the owner, so these direct-write rules skip them.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.trg_fo_guard()
returns trigger language plpgsql as $$
begin
  if OLD.status = 'cancelled' and NEW.status is distinct from 'cancelled' then
    raise exception 'This order was cancelled by the salesperson.';
  end if;
  if current_user in ('authenticated', 'anon') and NEW.status = 'submitted' then
    -- An old phone copy being re-sent: never reopen a handled order...
    if OLD.status is distinct from 'submitted' then
      return OLD;
    end if;
    -- ...and never undo the salesperson's later change.
    if coalesce(OLD.edit_count, 0) > 0 then
      NEW.notes := OLD.notes;
      NEW.customer_id := OLD.customer_id;
      NEW.edit_count := OLD.edit_count;
      NEW.edited_at := OLD.edited_at;
      NEW.removed_item_ids := OLD.removed_item_ids;
    end if;
  end if;
  return NEW;
end $$;
drop trigger if exists trg_fo_guard on public.field_orders;
create trigger trg_fo_guard before update on public.field_orders
  for each row execute function public.trg_fo_guard();

create or replace function public.trg_foi_guard()
returns trigger language plpgsql as $$
declare
  v_fo text := case when TG_OP = 'DELETE' then OLD.field_order_id else NEW.field_order_id end;
  v_status text; v_removed text[];
begin
  if current_user not in ('authenticated', 'anon') then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;
  select f.status, f.removed_item_ids into v_status, v_removed
    from public.field_orders f where f.id = v_fo;
  if not found then
    return case when TG_OP = 'DELETE' then OLD else NEW end;   -- order not pushed yet
  end if;
  if v_status is distinct from 'submitted' then
    return null;
  end if;
  if TG_OP <> 'DELETE' and v_removed is not null and NEW.id = any (v_removed) then
    return null;
  end if;
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end $$;
drop trigger if exists trg_foi_guard on public.field_order_items;
create trigger trg_foi_guard before insert or update or delete on public.field_order_items
  for each row execute function public.trg_foi_guard();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Edit an order (salesperson, only while 'submitted')
--    p_items: [{product_id, uom_id, quantity, price}]
--    Products already on the order keep their original price; new products
--    take the product's selling price.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.update_field_order(p_id text, p_items jsonb, p_notes text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  fo public.field_orders;
  v_me text; v_me_name text; v_shop text;
  v_old_ids text[]; v_old_price jsonb; v_cnt int;
  it jsonb; v_pid text; v_qty numeric; v_price numeric; v_prod jsonb;
begin
  select * into fo from public.field_orders where id = p_id for update;
  if not found then raise exception 'This order could not be found.'; end if;

  select a.id, a.name into v_me, v_me_name from public._acting_user(fo.org_id) a;
  if v_me is null or (v_me is distinct from fo.salesperson_id and not coalesce(public._is_org_admin(fo.org_id), false)) then
    raise exception 'You can only change your own orders.';
  end if;
  if fo.status = 'cancelled' then raise exception 'This order has been cancelled.'; end if;
  if fo.status is distinct from 'submitted' then
    raise exception 'This order has already been reviewed by the office and can no longer be changed.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one product to the order.';
  end if;

  select array_agg(id::text),
         coalesce(jsonb_object_agg(product_id, price_at_submit), '{}'::jsonb)
    into v_old_ids, v_old_price
    from public.field_order_items where field_order_id = p_id;

  delete from public.field_order_items where field_order_id = p_id;

  v_cnt := 0;
  for it in select * from jsonb_array_elements(p_items) loop
    v_pid := nullif(it->>'product_id', '');
    v_qty := coalesce(nullif(it->>'quantity', '')::numeric, 0);
    if v_pid is null or v_qty <= 0 then continue; end if;
    select to_jsonb(p) into v_prod from public.products p where p.id = v_pid and p.org_id = fo.org_id;
    if v_prod is null then raise exception 'One of the products is no longer available.'; end if;
    v_price := coalesce((v_old_price->>v_pid)::numeric,
                        nullif(v_prod->>'selling_price', '')::numeric,
                        nullif(it->>'price', '')::numeric, 0);
    insert into public.field_order_items (id, field_order_id, product_id, uom_id, quantity, price_at_submit)
    values (gen_random_uuid()::text, p_id, v_pid,
            coalesce(nullif(it->>'uom_id', ''), v_prod->>'base_uom_id'), v_qty, v_price);
    v_cnt := v_cnt + 1;
  end loop;
  if v_cnt = 0 then raise exception 'Add at least one product to the order.'; end if;

  update public.field_orders
     set notes = case when p_notes is null then notes else nullif(trim(p_notes), '') end,
         edited_at = now(),
         edit_count = coalesce(edit_count, 0) + 1,
         removed_item_ids = (select array(select distinct x from unnest(coalesce(removed_item_ids, '{}') || coalesce(v_old_ids, '{}')) x))
   where id = p_id;

  select shop_name into v_shop from public.customers where id = fo.customer_id;
  begin
    perform public.notify_event(fo.org_id, 'field_order', fo.branch_id, fo.salesperson_id,
      'Field order changed', coalesce(v_shop, 'Order') || ' — changed by ' || coalesce(v_me_name, 'salesperson'),
      '/erp/field-orders?focus=' || p_id);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'items', v_cnt);
end $$;
revoke all on function public.update_field_order(text, jsonb, text) from public, anon;
grant execute on function public.update_field_order(text, jsonb, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Cancel an order (salesperson, only while 'submitted')
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.cancel_field_order(p_id text, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare fo public.field_orders; v_me text; v_me_name text; v_shop text;
begin
  select * into fo from public.field_orders where id = p_id for update;
  if not found then raise exception 'This order could not be found.'; end if;

  select a.id, a.name into v_me, v_me_name from public._acting_user(fo.org_id) a;
  if v_me is null or (v_me is distinct from fo.salesperson_id and not coalesce(public._is_org_admin(fo.org_id), false)) then
    raise exception 'You can only cancel your own orders.';
  end if;
  if fo.status = 'cancelled' then return jsonb_build_object('ok', true); end if;
  if fo.status is distinct from 'submitted' then
    raise exception 'This order has already been reviewed by the office and can no longer be cancelled.';
  end if;

  update public.field_orders
     set status = 'cancelled', cancelled_at = now(), cancel_reason = nullif(trim(coalesce(p_reason, '')), '')
   where id = p_id;

  select shop_name into v_shop from public.customers where id = fo.customer_id;
  begin
    perform public.notify_event(fo.org_id, 'field_order', fo.branch_id, fo.salesperson_id,
      'Field order cancelled', coalesce(v_shop, 'Order') || ' — cancelled by ' || coalesce(v_me_name, 'salesperson'),
      '/erp/field-orders?focus=' || p_id);
  exception when others then null;
  end;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.cancel_field_order(text, text) from public, anon;
grant execute on function public.cancel_field_order(text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Tracking: what happened to each order after approval.
--    Returns one object per order:
--    { id, stage, so_number, so_status, dos:[{number,date}], invoices:[{number,date}],
--      lines:[{product_id, name, ordered, dispatched}] }
--    stage: submitted | approved | partially_dispatched | dispatched | invoiced
--           | rejected | cancelled
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.field_order_tracking(p_ids text[])
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  out jsonb := '[]'::jsonb;
  fo record; so jsonb; v_do_ids text[]; v_dos jsonb; v_sis jsonb; v_lines jsonb;
  v_ord numeric; v_disp numeric; v_stage text; v_pending boolean; v_uninv int;
begin
  if p_ids is null then return out; end if;
  for fo in select f.* from public.field_orders f
             where f.id = any (p_ids[1:300])
               and (public._is_org_member(f.org_id) or public._is_super_admin()) loop
    so := null; v_uninv := 0; v_dos := '[]'; v_sis := '[]'; v_lines := '[]'; v_do_ids := '{}';
    v_stage := coalesce(fo.status, 'submitted');

    if fo.sales_order_id is not null then
      select to_jsonb(s) into so from public.sales_orders s where s.id = fo.sales_order_id;
    end if;

    if so is not null then
      -- Delivery orders on this SO (not voided / cancelled)
      select coalesce(array_agg(d->>'id'), '{}'),
             coalesce(jsonb_agg(jsonb_build_object('number', d->>'voucher_number',
                        'date', coalesce(d->>'voucher_date', d->>'created_at')) order by d->>'created_at'), '[]')
        into v_do_ids, v_dos
        from (select to_jsonb(x) d from public.delivery_orders x where x.so_id = fo.sales_order_id) t
       where coalesce((d->>'is_voided')::boolean, false) = false
         and coalesce(d->>'status', '') <> 'cancelled';

      -- Invoices on those DOs (not voided / cancelled)
      if array_length(v_do_ids, 1) > 0 then
        select coalesce(jsonb_agg(jsonb_build_object('number', i->>'voucher_number',
                          'date', coalesce(i->>'voucher_date', i->>'created_at')) order by i->>'created_at'), '[]')
          into v_sis
          from (select to_jsonb(x) i from public.sales_invoices x where x.do_id = any (v_do_ids)) t
         where coalesce((i->>'is_voided')::boolean, false) = false
           and coalesce(i->>'status', '') <> 'cancelled';
        -- delivery orders that do not have an invoice yet
        select count(*) into v_uninv from unnest(v_do_ids) d(id)
         where not exists (select 1 from public.sales_invoices x
                            where x.do_id = d.id
                              and coalesce((to_jsonb(x)->>'is_voided')::boolean, false) = false
                              and coalesce(to_jsonb(x)->>'status', '') <> 'cancelled');
      end if;

      -- Ordered (on the SO) vs dispatched (on the DOs), per product
      select coalesce(jsonb_agg(jsonb_build_object(
               'product_id', q.product_id, 'name', coalesce(p.name, 'Product'),
               'ordered', q.ordered, 'dispatched', q.dispatched) order by p.name), '[]'),
             coalesce(sum(q.ordered), 0), coalesce(sum(least(q.dispatched, q.ordered)), 0),
             coalesce(bool_or(q.dispatched < q.ordered), false)
        into v_lines, v_ord, v_disp, v_pending
        from (select coalesce(a.product_id, b.product_id) product_id,
                     coalesce(a.qty, 0) ordered, coalesce(b.qty, 0) dispatched
                from (select soi.product_id, sum(soi.quantity) qty
                        from public.sales_order_items soi
                       where soi.sales_order_id = fo.sales_order_id group by soi.product_id) a
                full join
                     (select doi.product_id, sum(doi.qty_delivered) qty
                        from public.delivery_order_items doi
                       where doi.delivery_order_id = any (v_do_ids) group by doi.product_id) b
                  on a.product_id = b.product_id) q
        left join public.products p on p.id = q.product_id;

      if coalesce(so->>'status', '') = 'cancelled' or coalesce((so->>'is_voided')::boolean, false) then
        v_stage := 'cancelled';
      elsif jsonb_array_length(v_sis) > 0 and not v_pending and v_uninv = 0 then
        v_stage := 'invoiced';
      elsif v_disp > 0 and v_pending then
        v_stage := 'partially_dispatched';
      elsif v_disp > 0 then
        v_stage := 'dispatched';
      else
        v_stage := 'approved';
      end if;
    end if;

    out := out || jsonb_build_array(jsonb_build_object(
      'id', fo.id, 'stage', v_stage,
      'so_number', so->>'voucher_number', 'so_status', so->>'status',
      'dos', v_dos, 'invoices', v_sis, 'lines', v_lines,
      'invoiced_partly', jsonb_array_length(v_sis) > 0 and v_pending));
  end loop;
  return out;
end $$;
revoke all on function public.field_order_tracking(text[]) from public, anon;
grant execute on function public.field_order_tracking(text[]) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Notifications inbox: every push sent to a user is kept here
--    (written by the send-notification / send-notification-batch functions).
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.push_inbox (
  id         text primary key default gen_random_uuid()::text,
  user_id    text not null,
  org_id     text,
  title      text,
  body       text,
  data       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists push_inbox_user_idx on public.push_inbox (user_id, created_at desc);

-- _my_user_ids() (text[]) already exists from 421.

alter table public.push_inbox enable row level security;
drop policy if exists push_inbox_read on public.push_inbox;
create policy push_inbox_read on public.push_inbox for select
  using (user_id = any (public._my_user_ids()));
revoke all on public.push_inbox from anon, authenticated;
grant select on public.push_inbox to authenticated;

create or replace function public.mark_push_inbox_read(p_ids text[] default null)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  update public.push_inbox set read_at = now()
   where read_at is null
     and user_id = any (public._my_user_ids())
     and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mark_push_inbox_read(text[]) from public, anon;
grant execute on function public.mark_push_inbox_read(text[]) to authenticated;

notify pgrst, 'reload schema';
select 'field order edit/cancel, tracking and inbox ready' as result;
