-- 353 — Super Admin: organization profile (one call, Super Admin only).
-- Users (with last sign-in), branches, modules, subscription, and activity
-- counters for the main records (total, last 30 days, last activity).
-- Every counter is computed defensively: a table/column that doesn't exist
-- simply shows as empty. Requires 350 (_is_super_admin). Safe to run again.

create or replace function public._org_metric(p_org text, p_table text, p_amount text default null,
                                              p_extra text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  execute format(
    'select jsonb_build_object(
        ''total'', count(*),
        ''last_30d'', count(*) filter (where created_at > now() - interval ''30 days''),
        ''last_at'', max(created_at)%s)
       from public.%I where org_id::text = $1 %s',
    case when p_amount is null then ''
         else format(', ''amount_30d'', coalesce(sum(%I) filter (where created_at > now() - interval ''30 days''), 0)', p_amount) end,
    p_table,
    coalesce(p_extra, ''))
  into r using p_org;
  return r;
exception when others then
  return null;
end $$;
revoke all on function public._org_metric(text, text, text, text) from public, anon, authenticated;

create or replace function public.org_profile_summary(p_org text)
returns jsonb language plpgsql security definer set search_path to 'public', 'auth' as $$
declare r jsonb; v_users jsonb; v_branches jsonb; v_modules jsonb; v_sub jsonb; v_metrics jsonb := '{}'::jsonb;
        m record; v_last timestamptz;
begin
  if not public._is_super_admin() then raise exception 'Super Admin only'; end if;

  -- Users + last sign-in (from Supabase Auth, matched by email).
  begin
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', u.id, 'name', u.name, 'email', u.email, 'role', u.role,
             'active', coalesce(u.is_active, true),
             'last_sign_in', a.last_sign_in_at)
             order by coalesce(u.is_active, true) desc, a.last_sign_in_at desc nulls last, u.name), '[]'::jsonb)
      into v_users
      from public.users u
      left join auth.users a on lower(a.email) = lower(u.email)
     where u.org_id = p_org;
  exception when others then
    select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email, 'role', u.role,
                                                 'active', coalesce(u.is_active, true)) order by u.name), '[]'::jsonb)
      into v_users from public.users u where u.org_id = p_org;
  end;

  begin
    execute 'select coalesce(jsonb_agg(to_jsonb(b) order by b.name), ''[]''::jsonb)
               from (select id, name, coalesce(is_active, true) as is_active,
                            coalesce(is_virtual, false) as is_virtual
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

  for m in select * from (values
      ('sales_invoices',      'Sales invoices',      'grand_total', 'and coalesce(is_voided, false) = false'),
      ('purchase_invoices',   'Purchase invoices',   'grand_total', 'and coalesce(is_voided, false) = false'),
      ('sales_orders',        'Sales orders',        null, null),
      ('delivery_orders',     'Delivery orders',     null, null),
      ('purchase_orders',     'Purchase orders',     null, null),
      ('purchase_grns',       'GRNs',                null, null),
      ('journal_entries',     'Journal entries',     null, null),
      ('customers',           'Customers',           null, null),
      ('suppliers',           'Suppliers',           null, null),
      ('products',            'Products',            null, null),
      ('hr_employees',        'Employees',           null, null),
      ('hr_attendance',       'Attendance records',  null, null),
      ('assets',              'Assets',              null, null),
      ('voucher_documents',   'Support documents',   null, null)
    ) as t(tbl, label, amt, extra)
  loop
    v_metrics := v_metrics || jsonb_build_object(m.tbl,
      coalesce(public._org_metric(p_org, m.tbl, m.amt, m.extra), '{}'::jsonb) || jsonb_build_object('label', m.label));
  end loop;

  select max((v ->> 'last_at')::timestamptz) into v_last from jsonb_each(v_metrics) e(k, v);

  select jsonb_build_object(
      'org', to_jsonb(o),
      'users', v_users,
      'branches', v_branches,
      'modules', v_modules,
      'subscription', v_sub,
      'metrics', v_metrics,
      'last_activity', v_last)
    into r
    from public.orgs o where o.id = p_org;
  return r;
end $$;
grant execute on function public.org_profile_summary(text) to authenticated;
