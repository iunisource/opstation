-- 434 — Field returns: the salesperson requests a return from the app, the
-- office approves it on the web (Sales → Field Returns), which creates a draft
-- Sales Return Note. Stock comes back when that note is saved after the goods
-- arrive; the customer is credited through the Sales Return Invoice as usual.
-- Safe to run again.

create table if not exists public.field_returns (
  id             text primary key default ('fr_' || replace(gen_random_uuid()::text, '-', '')),
  org_id         text not null,
  branch_id      text,
  customer_id    text not null,
  salesperson_id text not null,
  invoice_id     text,
  invoice_number text,
  reason         text,
  note           text,
  photo_path     text,
  status         text not null default 'submitted'
                 check (status in ('submitted', 'approved', 'rejected', 'cancelled')),
  srn_id         text,
  reviewed_by    text,
  reviewed_at    timestamptz,
  reject_reason  text,
  cancelled_at   timestamptz,
  edit_count     int not null default 0,
  edited_at      timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists field_returns_org_idx on public.field_returns (org_id, status, created_at desc);
create index if not exists field_returns_sp_idx  on public.field_returns (salesperson_id, created_at desc);

create table if not exists public.field_return_items (
  id         text primary key default gen_random_uuid()::text,
  return_id  text not null references public.field_returns(id) on delete cascade,
  product_id text not null,
  uom_id     text,
  quantity   numeric not null default 0
);
create index if not exists field_return_items_ret_idx on public.field_return_items (return_id);

-- Read for the org; every write goes through the functions below.
alter table public.field_returns enable row level security;
alter table public.field_return_items enable row level security;
drop policy if exists fr_read on public.field_returns;
create policy fr_read on public.field_returns for select
  using (public._is_org_member(org_id) or public._is_super_admin());
drop policy if exists fri_read on public.field_return_items;
create policy fri_read on public.field_return_items for select
  using (exists (select 1 from public.field_returns r where r.id = return_id
                  and (public._is_org_member(r.org_id) or public._is_super_admin())));
revoke all on public.field_returns, public.field_return_items from anon, authenticated;
grant select on public.field_returns, public.field_return_items to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.field_returns;
exception when others then null;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Shared: replace the lines of a return. p_items: [{product_id, uom_id, quantity}]
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._fr_set_items(p_id text, p_org text, p_items jsonb)
returns int language plpgsql security definer set search_path to 'public' as $$
declare it jsonb; v_pid text; v_qty numeric; v_prod jsonb; n int := 0;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Add at least one product to return.';
  end if;
  delete from public.field_return_items where return_id = p_id;
  for it in select * from jsonb_array_elements(p_items) loop
    v_pid := nullif(it->>'product_id', '');
    v_qty := coalesce(nullif(it->>'quantity', '')::numeric, 0);
    if v_pid is null or v_qty <= 0 then continue; end if;
    select to_jsonb(p) into v_prod from public.products p where p.id = v_pid and p.org_id = p_org;
    if v_prod is null then raise exception 'One of the products is no longer available.'; end if;
    insert into public.field_return_items (return_id, product_id, uom_id, quantity)
    values (p_id, v_pid, coalesce(nullif(it->>'uom_id', ''), v_prod->>'base_uom_id'), v_qty);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Add at least one product to return.'; end if;
  return n;
end $$;
revoke all on function public._fr_set_items(text, text, jsonb) from public, anon, authenticated;

create or replace function public._fr_notify(p_id text, p_title text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare r public.field_returns; v_shop text; v_sp text;
begin
  select * into r from public.field_returns where id = p_id;
  select shop_name into v_shop from public.customers where id = r.customer_id;
  select name into v_sp from public.users where id = r.salesperson_id;
  -- Same people who get field-order alerts get return alerts.
  perform public.notify_event(r.org_id, 'field_order', r.branch_id, r.salesperson_id,
    p_title, coalesce(v_shop, 'Customer') || ' — ' || coalesce(v_sp, 'salesperson'),
    '/erp/field-returns?focus=' || p_id);
exception when others then null;
end $$;
revoke all on function public._fr_notify(text, text) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Salesperson: submit / change / cancel
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.submit_field_return(
  p_org text, p_customer text, p_items jsonb,
  p_reason text default null, p_note text default null,
  p_invoice_id text default null, p_photo_path text default null, p_id text default null)
returns text
language plpgsql security definer set search_path to 'public'
as $$
declare v_me text; v_id text; v_inv text; v_branch text;
begin
  select a.id into v_me from public._acting_user(p_org) a;
  if v_me is null or not public._is_org_member(p_org) then
    raise exception 'You are not signed in to this company.';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = p_org) then
    raise exception 'Please choose the shop again.';
  end if;
  -- Same request sent twice (e.g. a retry after a weak signal): return the first one.
  if p_id is not null and exists (select 1 from public.field_returns where id = p_id) then
    return p_id;
  end if;
  if p_invoice_id is not null then
    select voucher_number, branch_id into v_inv, v_branch from public.sales_invoices
     where id = p_invoice_id and org_id = p_org and customer_id = p_customer;
  end if;
  v_id := coalesce(p_id, 'fr_' || replace(gen_random_uuid()::text, '-', ''));
  insert into public.field_returns (id, org_id, branch_id, customer_id, salesperson_id,
     invoice_id, invoice_number, reason, note, photo_path)
  values (v_id, p_org, v_branch, p_customer, v_me,
     case when v_inv is null then null else p_invoice_id end, v_inv,
     nullif(trim(coalesce(p_reason, '')), ''), nullif(trim(coalesce(p_note, '')), ''),
     nullif(p_photo_path, ''));
  perform public._fr_set_items(v_id, p_org, p_items);
  perform public._fr_notify(v_id, 'Return request received');
  return v_id;
end $$;
revoke all on function public.submit_field_return(text, text, jsonb, text, text, text, text, text) from public, anon;
grant execute on function public.submit_field_return(text, text, jsonb, text, text, text, text, text) to authenticated;

create or replace function public.update_field_return(
  p_id text, p_items jsonb, p_reason text default null, p_note text default null,
  p_invoice_id text default null, p_photo_path text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r public.field_returns; v_me text; v_inv text; v_branch text;
begin
  select * into r from public.field_returns where id = p_id for update;
  if not found then raise exception 'This return request could not be found.'; end if;
  select a.id into v_me from public._acting_user(r.org_id) a;
  if v_me is null or v_me is distinct from r.salesperson_id then
    raise exception 'You can only change your own return requests.';
  end if;
  if r.status = 'cancelled' then raise exception 'This return request has been cancelled.'; end if;
  if r.status <> 'submitted' then
    raise exception 'The office has already reviewed this return request, so it can no longer be changed.';
  end if;
  if p_invoice_id is not null then
    select voucher_number, branch_id into v_inv, v_branch from public.sales_invoices
     where id = p_invoice_id and org_id = r.org_id and customer_id = r.customer_id;
  end if;
  perform public._fr_set_items(p_id, r.org_id, p_items);
  update public.field_returns
     set reason = nullif(trim(coalesce(p_reason, '')), ''),
         note = nullif(trim(coalesce(p_note, '')), ''),
         invoice_id = case when v_inv is null then null else p_invoice_id end,
         invoice_number = v_inv,
         branch_id = coalesce(v_branch, branch_id),
         photo_path = nullif(p_photo_path, ''),
         edit_count = edit_count + 1, edited_at = now()
   where id = p_id;
  perform public._fr_notify(p_id, 'Return request changed');
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.update_field_return(text, jsonb, text, text, text, text) from public, anon;
grant execute on function public.update_field_return(text, jsonb, text, text, text, text) to authenticated;

create or replace function public.cancel_field_return(p_id text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r public.field_returns; v_me text;
begin
  select * into r from public.field_returns where id = p_id for update;
  if not found then raise exception 'This return request could not be found.'; end if;
  select a.id into v_me from public._acting_user(r.org_id) a;
  if v_me is null or v_me is distinct from r.salesperson_id then
    raise exception 'You can only cancel your own return requests.';
  end if;
  if r.status = 'cancelled' then return jsonb_build_object('ok', true); end if;
  if r.status <> 'submitted' then
    raise exception 'The office has already reviewed this return request, so it can no longer be cancelled.';
  end if;
  update public.field_returns set status = 'cancelled', cancelled_at = now() where id = p_id;
  perform public._fr_notify(p_id, 'Return request cancelled');
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.cancel_field_return(text) from public, anon;
grant execute on function public.cancel_field_return(text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Office: approve (creates a draft Sales Return Note) / reject
--   p_items lets the office adjust products / quantities before approving.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.approve_field_return(p_id text, p_branch text, p_items jsonb default null)
returns text
language plpgsql security definer set search_path to 'public'
as $$
declare
  r public.field_returns; v_me text; v_year int := extract(year from now())::int;
  v_n bigint; v_num text; v_srn text; it record; i int := 0;
begin
  select * into r from public.field_returns where id = p_id for update;
  if not found then raise exception 'This return request could not be found.'; end if;
  if not (public._is_org_member(r.org_id) or public._is_super_admin()) then
    raise exception 'You do not have access to this company.';
  end if;
  if r.status = 'cancelled' then raise exception 'The salesperson cancelled this return request.'; end if;
  if r.status <> 'submitted' then raise exception 'This return request was already handled.'; end if;
  if p_branch is null or not exists (select 1 from public.branches where id = p_branch and org_id = r.org_id) then
    raise exception 'Choose the branch the goods will come back to.';
  end if;
  select a.id into v_me from public._acting_user(r.org_id) a;

  if p_items is not null then
    perform public._fr_set_items(p_id, r.org_id, p_items);
  end if;
  if not exists (select 1 from public.field_return_items where return_id = p_id and quantity > 0) then
    raise exception 'Add at least one product to return.';
  end if;

  v_n := public.next_voucher_number(p_org_id => r.org_id, p_branch_id => p_branch, p_type => 'SRN', p_year => v_year);
  v_num := 'SRN-' || v_year || '-' || lpad(v_n::text, 4, '0');
  v_srn := 'sr_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_' || substr(md5(p_id), 1, 4);

  insert into public.sales_returns (id, org_id, branch_id, voucher_number, voucher_date, customer_id,
     subtotal, discount_total, grand_total, status, is_locked, created_by)
  values (v_srn, r.org_id, p_branch, v_num, current_date, r.customer_id,
     0, 0, 0, 'draft', false, v_me);

  for it in select * from public.field_return_items where return_id = p_id and quantity > 0 order by id loop
    i := i + 1;
    insert into public.sales_return_items (id, return_id, product_id, uom_id, quantity, unit_price, discount, line_total)
    values (v_srn || '_i' || i, v_srn, it.product_id, it.uom_id, it.quantity, 0, 0, 0);
  end loop;

  begin
    insert into public.voucher_audit_log (org_id, voucher_id, voucher_type, action, details, performed_by)
    values (r.org_id, v_srn, 'SRN', 'created',
            v_num || ' created from a field return request'
            || coalesce(' (invoice ' || r.invoice_number || ')', '')
            || coalesce(' — ' || r.reason, ''), v_me);
  exception when others then null;
  end;

  update public.field_returns
     set status = 'approved', srn_id = v_srn, branch_id = p_branch,
         reviewed_by = v_me, reviewed_at = now()
   where id = p_id;
  return v_srn;
end $$;
revoke all on function public.approve_field_return(text, text, jsonb) from public, anon;
grant execute on function public.approve_field_return(text, text, jsonb) to authenticated;

create or replace function public.reject_field_return(p_id text, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r public.field_returns; v_me text;
begin
  select * into r from public.field_returns where id = p_id for update;
  if not found then raise exception 'This return request could not be found.'; end if;
  if not (public._is_org_member(r.org_id) or public._is_super_admin()) then
    raise exception 'You do not have access to this company.';
  end if;
  if r.status = 'cancelled' then raise exception 'The salesperson cancelled this return request.'; end if;
  if r.status <> 'submitted' then raise exception 'This return request was already handled.'; end if;
  select a.id into v_me from public._acting_user(r.org_id) a;
  update public.field_returns
     set status = 'rejected', reject_reason = nullif(trim(coalesce(p_reason, '')), ''),
         reviewed_by = v_me, reviewed_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.reject_field_return(text, text) from public, anon;
grant execute on function public.reject_field_return(text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- App: the salesperson's returns with their progress
--   stage: submitted | approved (waiting for goods) | received (stock back)
--          | credited (return invoice made) | rejected | cancelled
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.my_field_returns(p_org text, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_me text; out jsonb;
begin
  select a.id into v_me from public._acting_user(p_org) a;
  if v_me is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into out from (
    select jsonb_build_object(
      'id', r.id, 'status', r.status, 'created_at', r.created_at,
      'customer_id', r.customer_id, 'shop_name', c.shop_name, 'shop_code', c.code,
      'invoice_id', r.invoice_id, 'invoice_number', r.invoice_number,
      'reason', r.reason, 'note', r.note, 'photo_path', r.photo_path,
      'reject_reason', r.reject_reason, 'edit_count', r.edit_count,
      'srn_number', s.voucher_number,
      'srn_status', s.status,
      'srn_voided', coalesce((to_jsonb(s)->>'is_voided')::boolean, false),
      'credit_numbers', (select coalesce(jsonb_agg(si.voucher_number), '[]'::jsonb)
                           from public.sales_return_invoices si
                          where si.srn_id = r.srn_id
                            and coalesce((to_jsonb(si)->>'is_voided')::boolean, false) = false),
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                   'product_id', i.product_id, 'uom_id', i.uom_id, 'quantity', i.quantity,
                   'name', coalesce(p.name, 'Product'), 'sku', p.sku) order by p.name), '[]'::jsonb)
                  from public.field_return_items i left join public.products p on p.id = i.product_id
                 where i.return_id = r.id)
    ) x
      from public.field_returns r
      left join public.customers c on c.id = r.customer_id
      left join public.sales_returns s on s.id = r.srn_id
     where r.org_id = p_org and r.salesperson_id = v_me
       and r.created_at >= p_from and r.created_at < p_to + 1
  ) t;
  return out;
end $$;
revoke all on function public.my_field_returns(text, date, date) from public, anon;
grant execute on function public.my_field_returns(text, date, date) to authenticated;

-- App: a shop's recent invoices (to link a return to one), with their products.
create or replace function public.customer_recent_invoices(p_org text, p_customer text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare out jsonb;
begin
  if not public._is_org_member(p_org) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x->>'date' desc, x->>'number' desc), '[]'::jsonb) into out from (
    select jsonb_build_object(
      'id', s.id, 'number', s.voucher_number,
      'date', coalesce(to_jsonb(s)->>'voucher_date', to_jsonb(s)->>'created_at'),
      'total', coalesce(to_jsonb(s)->>'grand_total', '0'),
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                  'product_id', q.product_id, 'name', coalesce(p.name, 'Product'), 'sku', p.sku,
                  'uom_id', coalesce(q.uom_id, p.base_uom_id), 'quantity', q.qty) order by p.name), '[]'::jsonb)
                  from (select ii.product_id, max(to_jsonb(ii)->>'uom_id') uom_id,
                               sum(coalesce(nullif(to_jsonb(ii)->>'qty_delivered', '')::numeric,
                                            nullif(to_jsonb(ii)->>'quantity', '')::numeric, 0)) qty
                          from public.sales_invoice_items ii where ii.invoice_id = s.id
                         group by ii.product_id) q
                  left join public.products p on p.id = q.product_id)
    ) x
      from public.sales_invoices s
     where s.org_id = p_org and s.customer_id = p_customer
       and coalesce((to_jsonb(s)->>'is_voided')::boolean, false) = false
     order by s.created_at desc
     limit 20
  ) t;
  return out;
end $$;
revoke all on function public.customer_recent_invoices(text, text) from public, anon;
grant execute on function public.customer_recent_invoices(text, text) to authenticated;

notify pgrst, 'reload schema';
select 'field returns ready' as result;
