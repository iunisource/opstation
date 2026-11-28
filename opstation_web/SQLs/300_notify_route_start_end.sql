-- 300 — Notifications centre: salesperson Route started / Route ended (Operations).
--   route_started   a salesperson started a route in the field app   → tap opens that route run on the Live Map
--   route_ended     a salesperson ended a route (visits, sales, time) → tap opens that route run on the Live Map
-- Fires only when the org has the Operations module switched on, and — like every
-- event — only to the people the master admin adds in Admin Settings → Notifications.
-- The mobile app's own route notifications are NOT touched.
-- Requires 296. Safe to run again.

create or replace function public.trg_notify_trip_events()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  n jsonb := to_jsonb(NEW);
  o jsonb := case when TG_OP = 'UPDATE' then to_jsonb(OLD) else '{}'::jsonb end;
  v_org text := n->>'org_id';
  v_uid text := n->>'user_id';
  v_name text; v_route text; v_line text; v_body text;
  v_visits int; v_sales numeric; v_mins int;
  v_started boolean; v_ended boolean;
begin
  begin
    if v_org is null then return NEW; end if;

    v_started := TG_OP = 'INSERT' and coalesce(n->>'started_at', '') <> '' and coalesce(n->>'ended_at', '') = '';
    v_ended   := coalesce(n->>'ended_at', '') <> '' and coalesce(o->>'ended_at', '') = '';
    if not (v_started or v_ended) then return NEW; end if;

    -- Module gate: Operations must be on for this org.
    if not exists (select 1 from org_modules
                    where org_id = v_org and module = 'operations' and is_enabled) then
      return NEW;
    end if;

    select name into v_name from users where id = v_uid;
    v_name := coalesce(nullif(v_name, ''), nullif(n->>'user_name', ''), 'Salesperson');
    v_route := nullif(n->>'route_name', '');
    if v_route is null and coalesce(n->>'route_id', '') <> '' then
      begin
        select name into v_route from sales_routes where id::text = n->>'route_id';
      exception when others then v_route := null;
      end;
    end if;
    v_line := v_name || coalesce(' · ' || v_route, '');

    if v_started then
      perform notify_event(v_org, 'route_started', null, v_uid,
        'Route started',
        v_line || ' · started ' || to_char(((n->>'started_at')::timestamptz) at time zone 'Asia/Karachi', 'HH12:MI AM'),
        '/live-map?trip=' || (n->>'id'));
    else
      begin
        select count(*), coalesce(sum(coalesce(amount, 0)), 0)
          into v_visits, v_sales
          from visits where trip_id::text = n->>'id';
      exception when others then v_visits := null; v_sales := null;
      end;
      if coalesce(n->>'started_at', '') <> '' then
        v_mins := greatest(0, round(extract(epoch from ((n->>'ended_at')::timestamptz - (n->>'started_at')::timestamptz)) / 60)::int);
      end if;
      v_body := v_line
        || ' · ended ' || to_char(((n->>'ended_at')::timestamptz) at time zone 'Asia/Karachi', 'HH12:MI AM')
        || case when v_mins is not null then ' (' || (v_mins / 60) || 'h ' || (v_mins % 60) || 'm)' else '' end
        || case when v_visits is not null then E'\n' || v_visits || ' visit' || case when v_visits = 1 then '' else 's' end
                || ' · Sales ' || to_char(v_sales, 'FM999,999,999,990') else '' end
        || case when coalesce(n->>'distance_meters', '') ~ '^[0-9.]+$'
                then ' · ' || to_char((n->>'distance_meters')::numeric / 1000, 'FM999,990.0') || ' km' else '' end;
      perform notify_event(v_org, 'route_ended', null, v_uid,
        'Route ended', v_body, '/live-map?trip=' || (n->>'id'));
    end if;
  exception when others then
    null;  -- never block the field app
  end;
  return NEW;
end $$;

drop trigger if exists zz_notify_trip_events on public.trips;
create trigger zz_notify_trip_events after insert or update on public.trips
  for each row execute function public.trg_notify_trip_events();
