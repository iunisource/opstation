-- 459 — Smart route guide (shop brief) + shop notes.
-- Needs SQL 456 (Auto Pilot) to be run first.
--
--  • customer_shop_notes: notes for a shop, written from Customer 360 by anyone
--    with access to it. Optional "show until" date. Removing keeps the row
--    (removed_at) so nothing silently disappears.
--  • route_guide_briefs(org, customer ids): one brief per shop with only the
--    parts ticked in Admin Settings (org.route_guide_items):
--      missing_skus, notes, balance, last_payment, order_due, not_bought,
--      competitors, offers, credit_limit, visit_pattern
--    Returns nothing while org.route_guide is OFF.

create table if not exists public.customer_shop_notes (
  id               text primary key default ('csn_' || replace(gen_random_uuid()::text, '-', '')),
  org_id           text not null,
  customer_id      text not null,
  note             text not null,
  show_until       date,
  created_by       text,
  created_by_name  text,
  created_at       timestamptz not null default now(),
  removed_at       timestamptz,
  removed_by_name  text
);
create index if not exists customer_shop_notes_cust on public.customer_shop_notes (org_id, customer_id);
alter table public.customer_shop_notes enable row level security;
drop policy if exists csn_read on public.customer_shop_notes;
create policy csn_read on public.customer_shop_notes for select
  using (public._is_org_member(org_id) or public._is_super_admin());
grant select on public.customer_shop_notes to authenticated;

create or replace function public.shop_note_add(p_org text, p_customer text, p_note text, p_until date default null)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_me text; v_name text; v_id text;
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then
    raise exception 'You do not have access to this organisation.';
  end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Write the note.'; end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = p_org) then
    raise exception 'Shop not found.';
  end if;
  select a.id, a.name into v_me, v_name from public._acting_user(p_org) a;
  insert into public.customer_shop_notes (org_id, customer_id, note, show_until, created_by, created_by_name)
  values (p_org, p_customer, btrim(p_note), p_until, v_me, v_name)
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.shop_note_add(text, text, text, date) to authenticated;

-- The writer, or an admin, can remove a note.
create or replace function public.shop_note_remove(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_org text; v_by text; v_me text; v_name text;
begin
  select org_id, created_by into v_org, v_by from public.customer_shop_notes where id = p_id;
  if v_org is null then return; end if;
  select a.id, a.name into v_me, v_name from public._acting_user(v_org) a;
  if not (public._is_org_admin(v_org) or public._is_super_admin() or (v_me is not null and v_me = v_by)) then
    raise exception 'Only the person who wrote the note, or an admin, can remove it.';
  end if;
  update public.customer_shop_notes set removed_at = now(), removed_by_name = v_name
   where id = p_id and removed_at is null;
end $$;
grant execute on function public.shop_note_remove(text) to authenticated;

create or replace function public.route_guide_briefs(p_org text, p_customers text[])
returns table(customer_id text, brief jsonb)
language plpgsql security definer set search_path to 'public' as $$
declare
  v_items text[];
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  if p_org is null or not (public._is_org_member(p_org) or public._is_super_admin()) then return; end if;
  if not public._cfg_true(p_org, 'org.route_guide') then return; end if;
  select string_to_array(replace(coalesce(nullif(value, ''), 'missing_skus,notes'), ' ', ''), ',')
    into v_items from public.app_config
   where org_id = p_org and key = 'org.route_guide_items' and branch_id is null limit 1;
  v_items := coalesce(v_items, array['missing_skus', 'notes']);

  return query
  with shops as (
    select c.id as cid, c.credit_limit
      from public.customers c
     where c.org_id = p_org and c.id = any (p_customers)
  ),
  -- Placement: latest survey row per shop + item, plus Auto Pilot rows.
  pl as (
    select pa.customer_id as cid, pa.product_id as pid, pa.is_present, pa.surveyed_at as at
      from public.placement_audit pa
     where pa.org_id = p_org and pa.voided_at is null and pa.customer_id = any (p_customers)
       and 'missing_skus' = any (v_items)
    union all
    select r.customer_id, r.product_id, r.is_present, r.surveyed_at
      from public.placement_invoice_rows(p_org) r
     where r.customer_id = any (p_customers) and 'missing_skus' = any (v_items)
  ),
  pl_latest as (
    select distinct on (cid, pid) cid, pid, is_present from pl order by cid, pid, at desc
  ),
  items as (
    select ip.id, ip.name, ip.position from public.intelligence_products ip
     where ip.org_id = p_org and coalesce(ip.is_active, true)
  ),
  -- Receivable lines (customer's own account line only; see SQL 454).
  ar as (
    select jl.party_id as cid, je.entry_date::date as d,
           coalesce(jl.debit, 0) as dr, coalesce(jl.credit, 0) as cr
      from public.journal_lines jl
      join public.journal_entries je on je.id = jl.entry_id
      left join public.chart_of_accounts coa on coa.id = jl.account_id
     where jl.org_id = p_org and jl.party_id = any (p_customers)
       and coalesce(je.status, '') <> 'draft'
       and lower(coalesce(jl.account_type, '')) not in ('revenue', 'income', 'expense', 'expenses', 'cogs', 'cost_of_sales', 'cost of sales')
       and lower(coalesce(coa.account_type, '')) not in ('revenue', 'income', 'expense', 'expenses', 'cogs', 'cost_of_sales', 'cost of sales')
       and ('balance' = any (v_items) or 'credit_limit' = any (v_items))
  ),
  bal as (
    select cid, sum(dr - cr) as due, sum(dr) filter (where d > v_today - 60) as recent_dr
      from ar group by cid
  ),
  inv as (
    select s.customer_id as cid, s.id, s.voucher_date as d
      from public.sales_invoices s
     where s.org_id = p_org and s.customer_id = any (p_customers)
       and coalesce(s.is_voided, false) = false and coalesce(s.is_locked, false) = true
       and ('order_due' = any (v_items) or 'not_bought' = any (v_items))
  ),
  inv_rank as (
    select cid, d, row_number() over (partition by cid order by d desc) as rn from inv
  ),
  order_gap as (
    select cid, max(d) filter (where rn = 1) as last_d,
           (max(d) - min(d))::numeric / nullif(count(*) - 1, 0) as gap, count(*) as n
      from inv_rank where rn <= 6 group by cid
  ),
  bought as (
    select i.cid, it.product_id as pid,
           count(distinct i.id) filter (where i.d between v_today - 180 and v_today - 46) as older,
           count(distinct i.id) filter (where i.d > v_today - 46) as recent
      from inv i join public.sales_invoice_items it on it.invoice_id = i.id
     where 'not_bought' = any (v_items) and i.d > v_today - 180
     group by i.cid, it.product_id
  ),
  pay as (
    select v.customer_id as cid, v.timestamp as at, v.amount::numeric as amt
      from public.visits v
     where v.org_id = p_org and v.customer_id = any (p_customers) and coalesce(v.amount, 0) > 0
       and 'last_payment' = any (v_items)
  ),
  vis as (
    select v.customer_id as cid, v.status, v.timestamp as at,
           row_number() over (partition by v.customer_id order by v.timestamp desc) as rn
      from public.visits v
     where v.org_id = p_org and v.customer_id = any (p_customers)
       and 'visit_pattern' = any (v_items)
  )
  select s.cid,
    jsonb_strip_nulls(jsonb_build_object(
      'missing', case when 'missing_skus' = any (v_items) then (
          select coalesce(jsonb_agg(it.name order by it.position nulls last, it.name), '[]'::jsonb)
            from items it
            left join pl_latest l on l.cid = s.cid and l.pid = it.id
           where coalesce(l.is_present, false) = false) end,
      'notes', case when 'notes' = any (v_items) then (
          select coalesce(jsonb_agg(jsonb_build_object('text', n.note, 'by', n.created_by_name,
                                     'until', n.show_until) order by n.created_at desc), '[]'::jsonb)
            from public.customer_shop_notes n
           where n.org_id = p_org and n.customer_id = s.cid and n.removed_at is null
             and (n.show_until is null or n.show_until >= v_today)) end,
      'balance', case when 'balance' = any (v_items) then (
          select jsonb_build_object('due', round(b.due, 0),
                                    'over60', round(greatest(0, b.due - coalesce(b.recent_dr, 0)), 0))
            from bal b where b.cid = s.cid and b.due > 0.5) end,
      'credit', case when 'credit_limit' = any (v_items) then (
          select jsonb_build_object('limit', round(s.credit_limit, 0), 'due', round(b.due, 0))
            from bal b where b.cid = s.cid and coalesce(s.credit_limit, 0) > 0 and b.due > s.credit_limit) end,
      'last_payment', case when 'last_payment' = any (v_items) then (
          select jsonb_build_object('at', p.at, 'amount', round(p.amt, 0))
            from pay p where p.cid = s.cid order by p.at desc limit 1) end,
      'order_due', case when 'order_due' = any (v_items) then (
          select jsonb_build_object('last', g.last_d, 'days', v_today - g.last_d, 'gap', round(g.gap, 0))
            from order_gap g where g.cid = s.cid and g.n >= 3 and g.gap > 0
             and (v_today - g.last_d) >= g.gap) end,
      'not_bought', case when 'not_bought' = any (v_items) then (
          select nullif(jsonb_agg(x.name), '[]'::jsonb) from (
            select pr.name from bought bo join public.products pr on pr.id = bo.pid
             where bo.cid = s.cid and bo.older >= 2 and bo.recent = 0
             order by bo.older desc, pr.name limit 5) x) end,
      'competitors', case when 'competitors' = any (v_items) then (
          select nullif(jsonb_agg(distinct cs.brand_name), '[]'::jsonb)
            from public.competitor_spotting cs
           where cs.org_id = p_org and cs.customer_id = s.cid and cs.voided_at is null
             and coalesce(cs.brand_name, '') <> '' and cs.surveyed_at > now() - interval '180 days') end,
      'offers', case when 'offers' = any (v_items) then (
          select nullif(jsonb_agg(sc.name order by sc.priority nulls last, sc.name), '[]'::jsonb)
            from public.schemes sc
           where sc.org_id = p_org and coalesce(sc.is_active, false)
             and (sc.valid_from is null or sc.valid_from <= v_today)
             and (sc.valid_to is null or sc.valid_to >= v_today)
             and (coalesce(sc.all_customers, true)
                  or exists (select 1 from public.scheme_customers x where x.scheme_id = sc.id and x.customer_id = s.cid))) end,
      'visits', case when 'visit_pattern' = any (v_items) then (
          select jsonb_build_object(
                   'last', (select max(v.at) from vis v where v.cid = s.cid and v.status <> 'skipped'),
                   'skipped', (select count(*) from vis v where v.cid = s.cid and v.status = 'skipped'
                                 and v.rn < coalesce((select min(v2.rn) from vis v2 where v2.cid = s.cid and v2.status <> 'skipped'), 1000000)))
           where exists (select 1 from vis v where v.cid = s.cid)) end
    ))
    from shops s;
end $$;
grant execute on function public.route_guide_briefs(text, text[]) to authenticated;
