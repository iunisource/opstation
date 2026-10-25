-- 415 — Route editor: a customer unticked from a route must not come back
-- unless someone ticks them again. The editor now sends what it started with,
-- and only its own ticks / unticks are applied to the route as it is now — an
-- out-of-date screen (second tab, another admin, page not yet refreshed) can no
-- longer put back customers that were moved off. Safe to run again.

drop function if exists public.save_route_customers(text, text[], jsonb);

create or replace function public.save_route_customers(
  p_route text, p_customer_ids text[], p_moves jsonb default '[]'::jsonb, p_base text[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r public.sales_routes;
  v_new text[]; v_old text[]; v_added text[]; v_removed text[]; v_moved text[] := '{}';
  v_prev text; mv jsonb; v_to text; v_cust text; v_lines text[] := '{}';
  v_uid text; v_uname text; v_body text;
  v_req text[]; v_base text[]; v_req_add text[]; v_req_rem text[];
begin
  select * into r from public.sales_routes where id = p_route;
  if not found then raise exception 'Route not found — refresh and try again.'; end if;
  if not (public._is_org_member(r.org_id) or public._is_super_admin()) then
    raise exception 'You do not have access to this route.';
  end if;

  -- One save at a time per route, so two editors can't interleave.
  perform pg_advisory_xact_lock(hashtext('route_stops:' || p_route));

  -- keep order, drop duplicates / blanks
  select coalesce(array_agg(x order by o), '{}') into v_req
    from (select x, min(ord) o from unnest(coalesce(p_customer_ids, '{}')) with ordinality t(x, ord)
           where coalesce(x, '') <> '' group by x) s;
  select coalesce(array_agg(customer_id order by position), '{}') into v_old
    from public.route_stops where route_id = p_route;

  if p_base is null then
    -- Older screens: the list sent is the whole route.
    v_new := v_req;
  else
    -- Apply only what this editor changed (ticked / unticked) on top of the
    -- route as it is NOW. A customer taken off elsewhere since the editor
    -- opened stays off; one added elsewhere stays on.
    v_base    := array(select distinct x from unnest(p_base) x where coalesce(x, '') <> '');
    v_req_add := array(select x from unnest(v_req) x where not (x = any (v_base)));
    v_req_rem := array(select x from unnest(v_base) x where not (x = any (v_req)));
    v_new := array(
      select x from unnest(v_req) with ordinality t(x, o)
       where x = any (v_old) or x = any (v_req_add)
       order by o);
    v_new := v_new || array(
      select x from unnest(v_old) with ordinality t(x, o)
       where not (x = any (v_new)) and not (x = any (v_req_rem))
       order by o);
  end if;
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
revoke execute on function public.save_route_customers(text, text[], jsonb, text[]) from public, anon;
grant execute on function public.save_route_customers(text, text[], jsonb, text[]) to authenticated;

notify pgrst, 'reload schema';

select 'save_route_customers updated' as status;
