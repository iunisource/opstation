-- 395 — Routes: only admins delete; others may only disable an EMPTY route.
-- Needs 386. Safe to run again.

create or replace function public._is_org_admin(p_org text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_role text;
begin
  if public._is_super_admin() then return true; end if;
  select u.role into v_role from public._acting_user(p_org) a join public.users u on u.id = a.id;
  return coalesce(v_role, '') in ('admin', 'masterAdmin', 'superAdmin');
end $$;

create or replace function public.delete_route(p_route text, p_move_to text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare r public.sales_routes; v_ids text[]; v_prev text; v_uid text; v_uname text; v_to_name text;
begin
  select * into r from public.sales_routes where id = p_route;
  if not found then return; end if;
  if not (public._is_org_member(r.org_id) or public._is_super_admin()) then
    raise exception 'You do not have access to this route.';
  end if;
  if not public._is_org_admin(r.org_id) then
    raise exception 'Only admins can delete a route. You can disable an empty route instead.';
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

-- Disabling a route that still has customers is admin-only (the screen hides
-- it too; this stops it from anywhere else).
create or replace function public.trg_route_disable_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(OLD.is_active, true) and NEW.is_active = false
     and exists (select 1 from public.route_stops where route_id = NEW.id)
     and not public._is_org_admin(NEW.org_id) then
    raise exception 'Only admins can disable a route that still has customers. Move its customers off first.';
  end if;
  return NEW;
end $$;
drop trigger if exists route_disable_guard on public.sales_routes;
create trigger route_disable_guard before update of is_active on public.sales_routes
  for each row execute function public.trg_route_disable_guard();

notify pgrst, 'reload schema';
