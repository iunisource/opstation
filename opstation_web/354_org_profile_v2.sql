-- 354 — Super Admin org profile v2: platform usage only, no business figures.
-- Replaces org_profile_summary from 353. No sales/purchase amounts, no counts
-- of customers/products/invoices — only how the org USES Opstation:
--   • users + last sign-in (engagement)
--   • activity per day for the last 30 days (all record types mixed together)
--   • per-module adoption: last used + share of activity
-- Safe to run again.

drop function if exists public._org_metric(text, text, text, text);

create or replace function public.org_profile_summary(p_org text)
returns jsonb language plpgsql security definer set search_path to 'public', 'auth' as $$
declare
  r jsonb; v_users jsonb; v_branches jsonb; v_modules jsonb; v_sub jsonb;
  v_sql text := ''; t record; v_daily jsonb; v_mod jsonb; v_last timestamptz;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;

  begin
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', u.id, 'name', u.name, 'email', u.email, 'role', u.role,
             'active', coalesce(u.is_active, true), 'last_sign_in', a.last_sign_in_at)
             order by coalesce(u.is_active, true) desc, a.last_sign_in_at desc nulls last, u.name), '[]'::jsonb)
      into v_users
      from public.users u left join auth.users a on lower(a.email) = lower(u.email)
     where u.org_id = p_org;
  exception when others then
    select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email, 'role', u.role,
                                                 'active', coalesce(u.is_active, true)) order by u.name), '[]'::jsonb)
      into v_users from public.users u where u.org_id = p_org;
  end;

  begin
    execute 'select coalesce(jsonb_agg(to_jsonb(b) order by b.name), ''[]''::jsonb)
               from (select id, name, coalesce(is_active, true) as is_active, coalesce(is_virtual, false) as is_virtual
                       from public.branches where org_id = $1) b'
      into v_branches using p_org;
  exception when others then v_branches := '[]'::jsonb;
  end;

  begin
    select coalesce(jsonb_agg(jsonb_build_object('module', module, 'enabled', is_enabled) order by module), '[]'::jsonb)
      into v_modules from public.org_modules where org_id = p_org;
  exception when others then v_modules := '[]'::jsonb;
  end;

  begin
    execute 'select to_jsonb(s) from public.org_subscriptions s where s.org_id = $1 limit 1' into v_sub using p_org;
  exception when others then v_sub := null;
  end;

  -- Activity sources (module, table). Only tables that exist with org_id + created_at are used.
  for t in
    select x.module, x.tbl
      from (values
        ('inventory', 'products'), ('inventory', 'stock_transfers'), ('inventory', 'opening_stock'),
        ('purchase', 'purchase_orders'), ('purchase', 'purchase_grns'), ('purchase', 'purchase_invoices'),
        ('purchase', 'purchase_return_invoices'), ('purchase', 'suppliers'),
        ('sales', 'sales_orders'), ('sales', 'delivery_orders'), ('sales', 'sales_invoices'),
        ('sales', 'sales_return_invoices'), ('sales', 'customers'), ('sales', 'quotations'),
        ('hr', 'hr_attendance'), ('hr', 'hr_employees'), ('hr', 'hr_leave_requests'),
        ('production', 'bom_headers'), ('production', 'job_cards'),
        ('financial_reporting', 'journal_entries'), ('financial_reporting', 'payment_advices'),
        ('assets', 'assets'), ('assets', 'asset_maintenance'),
        ('facility', 'facility_tasks'),
        ('operations', 'field_orders'), ('operations', 'retailer_orders'), ('operations', 'route_roster'),
        ('logistics', 'dispatch_orders'), ('logistics', 'deliveries')
      ) as x(module, tbl)
      join pg_class c on c.relname = x.tbl and c.relkind = 'r'
      join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
     where exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'org_id' and not a.attisdropped)
       and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'created_at' and not a.attisdropped)
  loop
    v_sql := v_sql || case when v_sql = '' then '' else ' union all ' end ||
      format('select %L::text as module, created_at from public.%I where org_id::text = $1 and created_at > now() - interval ''90 days''',
             t.module, t.tbl);
  end loop;

  if v_sql <> '' then
    begin
      execute format(
        'with a as (%s)
         select
           (select coalesce(jsonb_agg(jsonb_build_object(''day'', d::date, ''n'', coalesce(c.n, 0)) order by d), ''[]''::jsonb)
              from generate_series(current_date - 29, current_date, interval ''1 day'') d
              left join (select created_at::date as day, count(*) n from a
                          where created_at >= current_date - 29 group by 1) c on c.day = d::date),
           (select coalesce(jsonb_agg(jsonb_build_object(''module'', module, ''last_at'', last_at, ''n30'', n30)), ''[]''::jsonb)
              from (select module, max(created_at) last_at,
                           count(*) filter (where created_at > now() - interval ''30 days'') n30
                      from a group by module) m),
           (select max(created_at) from a)', v_sql)
        into v_daily, v_mod, v_last using p_org;
    exception when others then
      v_daily := '[]'::jsonb; v_mod := '[]'::jsonb;
    end;
  end if;

  select jsonb_build_object(
      'org', to_jsonb(o) - 'settings',
      'users', v_users, 'branches', v_branches, 'modules', v_modules, 'subscription', v_sub,
      'daily', coalesce(v_daily, '[]'::jsonb),
      'module_usage', coalesce(v_mod, '[]'::jsonb),
      'last_activity', v_last)
    into r
    from public.orgs o where o.id = p_org;
  return r;
end $$;
grant execute on function public.org_profile_summary(text) to authenticated;
