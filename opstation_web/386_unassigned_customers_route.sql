-- 386 — "Unassigned customers" route + customer route-change notification
--
--  * Toggle per org (app_config 'org.unassigned_route_flow'), switched by the
--    master admin on the Routes screen. Turned ON here for every org.
--  * While ON, each org has one system route "Unassigned customers" holding
--    every active customer that is on no other route. Adding a customer to a
--    real route takes them off it; removing a customer from their last route
--    puts them back on it. New customers land on it automatically.
--  * Routes are saved through save_route_customers() / delete_route(), which
--    also take the "next route" for removed customers and send the
--    'customer_route_changed' notification (Admin Settings → Notifications).
--  * While OFF, nothing changes from how routes work today.
-- Requires 296 (notifications). Safe to run again.

alter table public.sales_routes add column if not exists is_unassigned boolean not null default false;

-- ── helpers ────────────────────────────────────────────────────────────────
create or replace function public._unassigned_flow_on(p_org text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.app_config
                  where org_id = p_org and key = 'org.unassigned_route_flow' and value = 'true');
$$;

create or replace function public._unassigned_route_id(p_org text, p_create boolean default true)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v text;
begin
  select id into v from public.sales_routes where org_id = p_org and is_unassigned order by created_at limit 1;
  if v is null and p_create then
    v := 'route_unassigned_' || p_org;
    insert into public.sales_routes (id, org_id, name, kind, is_active, is_unassigned, created_at)
    values (v, p_org, 'Unassigned customers', 'recurring', true, true, now())
    on conflict (id) do update set is_unassigned = true, is_active = true;
  end if;
  return v;
end $$;

-- Puts route-less active customers on the Unassigned route and takes off the
-- ones that now have a real route (or are inactive). p_customers = null → all.
create or replace function public._sync_unassigned(p_org text, p_customers text[] default null)
returns int language plpgsql security definer set search_path to 'public' as $$
declare v_route text; v_max int; n int := 0; v_prev text;
begin
  if p_org is null or not public._unassigned_flow_on(p_org) then return 0; end if;
  v_prev := current_setting('opstation.route_sync', true);
  perform set_config('opstation.route_sync', '1', true);
  v_route := public._unassigned_route_id(p_org, true);

  delete from public.route_stops s
   where s.route_id = v_route
     and (p_customers is null or s.customer_id = any (p_customers))
     and (exists (select 1 from public.route_stops o where o.customer_id = s.customer_id and o.route_id <> v_route)
          or not exists (select 1 from public.customers c
                          where c.id = s.customer_id and c.org_id = p_org and coalesce(c.is_active, true)));

  select coalesce(max(position), 0) into v_max from public.route_stops where route_id = v_route;
  insert into public.route_stops (route_id, customer_id, position)
  select v_route, c.id, v_max + row_number() over (order by c.shop_name, c.id)
    from public.customers c
   where c.org_id = p_org and coalesce(c.is_active, true)
     and (p_customers is null or c.id = any (p_customers))
     and not exists (select 1 from public.route_stops o where o.customer_id = c.id);
  get diagnostics n = row_count;

  perform set_config('opstation.route_sync', coalesce(v_prev, ''), true);
  return n;
end $$;

-- ── keep it in sync whatever changes the stops (web, field app, imports) ───
create or replace function public.trg_route_stops_unassigned()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_org text;
begin
  if coalesce(current_setting('opstation.route_sync', true), '') = '1' then return null; end if;
  begin
    if TG_OP in ('DELETE', 'UPDATE') then
      v_org := coalesce(OLD.org_id, (select org_id from public.sales_routes where id = OLD.route_id));
      perform public._sync_unassigned(v_org, array[OLD.customer_id]);
    end if;
    if TG_OP in ('INSERT', 'UPDATE') then
      v_org := coalesce(NEW.org_id, (select org_id from public.sales_routes where id = NEW.route_id));
      perform public._sync_unassigned(v_org, array[NEW.customer_id]);
    end if;
  exception when others then null;   -- never block a route edit
  end;
  return null;
end $$;

drop trigger if exists zz_route_stops_unassigned on public.route_stops;
create trigger zz_route_stops_unassigned after insert or delete or update of route_id, customer_id
  on public.route_stops for each row execute function public.trg_route_stops_unassigned();

create or replace function public.trg_customer_unassigned()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    if TG_OP = 'INSERT' or OLD.is_active is distinct from NEW.is_active then
      perform public._sync_unassigned(NEW.org_id, array[NEW.id]);
    end if;
  exception when others then null;   -- never block a customer save
  end;
  return null;
end $$;

drop trigger if exists zz_customer_unassigned on public.customers;
create trigger zz_customer_unassigned after insert or update of is_active
  on public.customers for each row execute function public.trg_customer_unassigned();

-- ── who is acting (for notifications) ──────────────────────────────────────
create or replace function public._acting_user(p_org text)
returns table(id text, name text) language sql stable security definer set search_path to 'public' as $$
  select u.id::text, u.name::text from public.users u
   where coalesce(u.is_active, true)
     and (u.account_id = public.current_account_id()
          or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
   order by (u.org_id = p_org) desc
   limit 1;
$$;

create or replace function public._names_list(p_ids text[], p_max int default 5)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(string_agg(n, ', '), '') ||
         case when coalesce(array_length(p_ids, 1), 0) > p_max
              then ' +' || (array_length(p_ids, 1) - p_max) || ' more' else '' end
    from (select coalesce(nullif(c.shop_name, ''), c.code, '?') as n
            from unnest(p_ids) with ordinality t(id, ord)
            left join public.customers c on c.id = t.id
           order by t.ord limit p_max) x;
$$;

-- ── save a route's customers (diff, next-route moves, sync, notify) ───────
-- p_moves: [{"customer_id": "...", "route_id": "..."}] — where removed
-- customers go next.
create or replace function public.save_route_customers(
  p_route text, p_customer_ids text[], p_moves jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r public.sales_routes;
  v_new text[]; v_old text[]; v_added text[]; v_removed text[]; v_moved text[] := '{}';
  v_prev text; mv jsonb; v_to text; v_cust text; v_lines text[] := '{}';
  v_uid text; v_uname text; v_body text;
begin
  select * into r from public.sales_routes where id = p_route;
  if not found then raise exception 'Route not found — refresh and try again.'; end if;
  if not (public._is_org_member(r.org_id) or public._is_super_admin()) then
    raise exception 'You do not have access to this route.';
  end if;

  -- keep order, drop duplicates / blanks
  select coalesce(array_agg(x order by o), '{}') into v_new
    from (select x, min(ord) o from unnest(coalesce(p_customer_ids, '{}')) with ordinality t(x, ord)
           where coalesce(x, '') <> '' group by x) s;
  select coalesce(array_agg(customer_id order by position), '{}') into v_old
    from public.route_stops where route_id = p_route;
  v_added   := array(select x from unnest(v_new) x where not (x = any (v_old)));
  v_removed := array(select x from unnest(v_old) x where not (x = any (v_new)));

  v_prev := current_setting('opstation.route_sync', true);
  perform set_config('opstation.route_sync', '1', true);

  delete from public.route_stops where route_id = p_route;
  insert into public.route_stops (route_id, customer_id, position)
  select p_route, x, o from unnest(v_new) with ordinality t(x, o);

  for mv in select value from jsonb_array_elements(coalesce(p_moves, '[]'::jsonb)) loop
    v_to := mv ->> 'route_id';
    v_cust := mv ->> 'customer_id';
    if v_to is null or v_cust is null or v_to = p_route then continue; end if;
    if not exists (select 1 from public.sales_routes where id = v_to and org_id = r.org_id) then continue; end if;
    if not exists (select 1 from public.route_stops where route_id = v_to and customer_id = v_cust) then
      insert into public.route_stops (route_id, customer_id, position)
      select v_to, v_cust, coalesce(max(position), 0) + 1 from public.route_stops where route_id = v_to;
    end if;
    v_moved := v_moved || v_cust;
    v_lines := v_lines || (public._names_list(array[v_cust], 1) || ' → ' ||
                           coalesce((select name from public.sales_routes where id = v_to), '?'));
  end loop;

  perform set_config('opstation.route_sync', coalesce(v_prev, ''), true);
  perform public._sync_unassigned(r.org_id, v_old || v_new || v_moved);

  -- Notify (only when customers actually changed)
  if coalesce(array_length(v_added, 1), 0) + coalesce(array_length(v_removed, 1), 0) > 0 then
    begin
      select id, name into v_uid, v_uname from public._acting_user(r.org_id);
      v_body := r.name || ' · by ' || coalesce(v_uname, 'someone');
      if coalesce(array_length(v_added, 1), 0) > 0 then
        v_body := v_body || chr(10) || 'Added: ' || public._names_list(v_added);
      end if;
      if coalesce(array_length(v_lines, 1), 0) > 0 then
        v_body := v_body || chr(10) || 'Moved: ' || array_to_string(v_lines[1:5], ', ') ||
                  case when array_length(v_lines, 1) > 5 then ' +' || (array_length(v_lines, 1) - 5) || ' more' else '' end;
      end if;
      v_removed := array(select x from unnest(v_removed) x where not (x = any (v_moved)));
      if coalesce(array_length(v_removed, 1), 0) > 0 then
        v_body := v_body || chr(10) || 'Removed: ' || public._names_list(v_removed);
      end if;
      perform public.notify_event(r.org_id, 'customer_route_changed', null, v_uid,
        'Customer route change', v_body, '/routes');
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('added', coalesce(array_length(v_added, 1), 0),
                            'removed', coalesce(array_length(v_removed, 1), 0),
                            'moved', coalesce(array_length(v_moved, 1), 0));
end $$;
grant execute on function public.save_route_customers(text, text[], jsonb) to authenticated;

-- ── delete a route (its customers go to p_move_to, else Unassigned) ───────
create or replace function public.delete_route(p_route text, p_move_to text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare r public.sales_routes; v_ids text[]; v_prev text; v_uid text; v_uname text; v_to_name text;
begin
  select * into r from public.sales_routes where id = p_route;
  if not found then return; end if;
  if not (public._is_org_member(r.org_id) or public._is_super_admin()) then
    raise exception 'You do not have access to this route.';
  end if;
  if r.is_unassigned and public._unassigned_flow_on(r.org_id) then
    raise exception 'The Unassigned customers route can''t be deleted while it is switched on.';
  end if;

  select coalesce(array_agg(customer_id), '{}') into v_ids from public.route_stops where route_id = p_route;
  v_prev := current_setting('opstation.route_sync', true);
  perform set_config('opstation.route_sync', '1', true);

  if p_move_to is not null and p_move_to <> p_route
     and exists (select 1 from public.sales_routes where id = p_move_to and org_id = r.org_id) then
    insert into public.route_stops (route_id, customer_id, position)
    select p_move_to, x, (select coalesce(max(position), 0) from public.route_stops where route_id = p_move_to) + o
      from unnest(array(select x from unnest(v_ids) x
                         where not exists (select 1 from public.route_stops s
                                            where s.customer_id = x and s.route_id <> p_route))) with ordinality t(x, o);
    select name into v_to_name from public.sales_routes where id = p_move_to;
  end if;

  delete from public.route_stops where route_id = p_route;
  delete from public.sales_routes where id = p_route;

  perform set_config('opstation.route_sync', coalesce(v_prev, ''), true);
  perform public._sync_unassigned(r.org_id, v_ids);

  if coalesce(array_length(v_ids, 1), 0) > 0 then
    begin
      select id, name into v_uid, v_uname from public._acting_user(r.org_id);
      perform public.notify_event(r.org_id, 'customer_route_changed', null, v_uid,
        'Customer route change',
        'Route ' || r.name || ' deleted by ' || coalesce(v_uname, 'someone') || ' · ' ||
          array_length(v_ids, 1) || ' customer(s) ' ||
          coalesce('moved to ' || v_to_name, 'moved off this route'),
        '/routes');
    exception when others then null;
    end;
  end if;
end $$;
grant execute on function public.delete_route(text, text) to authenticated;

-- ── master admin switch ────────────────────────────────────────────────────
create or replace function public.set_unassigned_route_flow(p_org text, p_on boolean)
returns int language plpgsql security definer set search_path to 'public' as $$
declare v_route text; v_prev text;
begin
  if not (public._is_org_master(p_org) or public._is_super_admin()) then
    raise exception 'Only the master admin can change this.';
  end if;
  update public.app_config set value = case when p_on then 'true' else 'false' end
   where org_id = p_org and key = 'org.unassigned_route_flow';
  if not found then
    insert into public.app_config (org_id, key, value)
    values (p_org, 'org.unassigned_route_flow', case when p_on then 'true' else 'false' end);
  end if;

  if p_on then
    return public._sync_unassigned(p_org, null);
  end if;

  -- OFF: remove the system route; routes work exactly as before.
  v_route := public._unassigned_route_id(p_org, false);
  if v_route is not null then
    v_prev := current_setting('opstation.route_sync', true);
    perform set_config('opstation.route_sync', '1', true);
    delete from public.route_stops where route_id = v_route;
    delete from public.route_assignments where route_id = v_route;
    delete from public.sales_routes where id = v_route;
    perform set_config('opstation.route_sync', coalesce(v_prev, ''), true);
  end if;
  return 0;
end $$;
grant execute on function public.set_unassigned_route_flow(text, boolean) to authenticated;

-- ── switch it ON for every org and fill the route ──────────────────────────
do $$
declare o record; n int;
begin
  for o in select id, name from public.orgs loop
    update public.app_config set value = 'true' where org_id = o.id and key = 'org.unassigned_route_flow';
    if not found then
      insert into public.app_config (org_id, key, value) values (o.id, 'org.unassigned_route_flow', 'true');
    end if;
    n := public._sync_unassigned(o.id, null);
    raise notice '%: % customer(s) on Unassigned customers', o.name, n;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Check: customers on the Unassigned route per org
select g.name as org, r.name as route, count(s.customer_id) as customers
  from public.sales_routes r
  join public.orgs g on g.id = r.org_id
  left join public.route_stops s on s.route_id = r.id
 where r.is_unassigned
 group by g.name, r.name
 order by g.name;
