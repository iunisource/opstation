-- 463 — Logistics → Fleet.
--
--  • fleet_vehicles: vehicles (copied from Assets or added new), photos,
--    assigned drivers, starting odometer.
--  • fleet_services: regular services, every X km and/or every X months.
--    fleet_service_log: each time a service was done.
--  • fleet_tasks: repairs / ongoing tasks.
--  • fleet_mileage_log: km added per day. "auto" rows come from the assigned
--    drivers' day (route start → visits / delivery stops → route end, straight
--    line × 1.3 for roads); "reading" rows are odometer readings someone typed
--    in (they correct the running total).
--  • fleet_sync(org): adds the km (runs when Fleet opens and every night).
--  • fleet_reminders(): nightly — services coming due (within
--    org.fleet_alert_km km, default 200, or 7 days) or overdue → push to the
--    vehicle's drivers + push and bell to the users in org.fleet_alert_users.
--    Once when due, once when overdue, then weekly while overdue.
--    Switched on by Admin Settings → org.fleet_alerts.
--  • Storage bucket fleet-photos.
-- Safe to run again.

create table if not exists public.fleet_vehicles (
  id              text primary key default ('veh_' || replace(gen_random_uuid()::text, '-', '')),
  org_id          text not null,
  reg_no          text not null,
  vehicle_type    text,
  make            text,
  model           text,
  year            int,
  colour          text,
  engine_no       text,
  chassis_no      text,
  fuel            text,
  branch_id       text,
  driver_ids      text[] not null default '{}',
  start_odometer  numeric not null default 0,
  start_date      date not null default ((now() at time zone 'Asia/Karachi')::date),
  odometer        numeric not null default 0,
  photos          jsonb not null default '[]'::jsonb,
  asset_id        text,
  is_active       boolean not null default true,
  notes           text,
  last_synced     date,
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists fleet_vehicles_org on public.fleet_vehicles (org_id);

create table if not exists public.fleet_services (
  id           text primary key default ('fsv_' || replace(gen_random_uuid()::text, '-', '')),
  org_id       text not null,
  vehicle_id   text not null,
  name         text not null,
  every_km     numeric,
  every_months int,
  last_km      numeric,
  last_date    date,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);
create index if not exists fleet_services_veh on public.fleet_services (vehicle_id);

create table if not exists public.fleet_service_log (
  id           text primary key default ('fsl_' || replace(gen_random_uuid()::text, '-', '')),
  org_id       text not null,
  vehicle_id   text not null,
  service_id   text,
  service_name text,
  done_date    date not null,
  odometer     numeric,
  cost         numeric,
  note         text,
  done_by_name text,
  created_at   timestamptz not null default now()
);
create index if not exists fleet_service_log_veh on public.fleet_service_log (vehicle_id);

create table if not exists public.fleet_tasks (
  id             text primary key default ('ftk_' || replace(gen_random_uuid()::text, '-', '')),
  org_id         text not null,
  vehicle_id     text not null,
  title          text not null,
  kind           text not null default 'repair',
  workshop       text,
  est_cost       numeric,
  actual_cost    numeric,
  status         text not null default 'open',
  note           text,
  opened_by_name text,
  opened_at      timestamptz not null default now(),
  closed_by_name text,
  closed_at      timestamptz
);
create index if not exists fleet_tasks_veh on public.fleet_tasks (vehicle_id);

create table if not exists public.fleet_mileage_log (
  id             text primary key default ('fml_' || replace(gen_random_uuid()::text, '-', '')),
  org_id         text not null,
  vehicle_id     text not null,
  log_date       date not null,
  source         text not null,            -- auto | reading
  km             numeric not null default 0,
  reading        numeric,
  odometer_after numeric,
  ref            text,
  by_name        text,
  created_at     timestamptz not null default now()
);
create unique index if not exists fleet_mileage_auto_uq on public.fleet_mileage_log (vehicle_id, log_date) where source = 'auto';
create index if not exists fleet_mileage_veh on public.fleet_mileage_log (vehicle_id, log_date);

create table if not exists public.fleet_alert_log (
  id         bigint generated always as identity primary key,
  org_id     text not null,
  service_id text not null,
  cycle      text not null,
  stage      text not null,                -- due | overdue
  sent_at    timestamptz not null default now()
);
create index if not exists fleet_alert_log_svc on public.fleet_alert_log (service_id, cycle);

do $$
declare t text;
begin
  foreach t in array array['fleet_vehicles','fleet_services','fleet_service_log','fleet_tasks','fleet_mileage_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_org', t);
    execute format('create policy %I on public.%I for all using (public._is_org_member(org_id) or public._is_super_admin())
                    with check (public._is_org_member(org_id) or public._is_super_admin())', t || '_org', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
alter table public.fleet_alert_log enable row level security;
revoke all on public.fleet_alert_log from anon, authenticated;

-- Photos.
insert into storage.buckets (id, name, public) values ('fleet-photos', 'fleet-photos', true)
on conflict (id) do nothing;
drop policy if exists fleet_photos_read on storage.objects;
create policy fleet_photos_read on storage.objects for select using (bucket_id = 'fleet-photos');
drop policy if exists fleet_photos_write on storage.objects;
create policy fleet_photos_write on storage.objects for insert to authenticated
  with check (bucket_id = 'fleet-photos' and public._is_org_member((storage.foldername(name))[1]));
drop policy if exists fleet_photos_update on storage.objects;
create policy fleet_photos_update on storage.objects for update to authenticated
  using (bucket_id = 'fleet-photos' and public._is_org_member((storage.foldername(name))[1]));
drop policy if exists fleet_photos_delete on storage.objects;
create policy fleet_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'fleet-photos' and public._is_org_member((storage.foldername(name))[1]));

-- ── distance ────────────────────────────────────────────────────────────────
create or replace function public._geo_km(a1 double precision, o1 double precision, a2 double precision, o2 double precision)
returns double precision language sql immutable as $$
  select 6371.0 * 2 * asin(sqrt(
           power(sin(radians(a2 - a1) / 2), 2) +
           cos(radians(a1)) * cos(radians(a2)) * power(sin(radians(o2 - o1) / 2), 2)))
$$;

-- Km one or more users drove on a day: route start → visits / delivery stops →
-- route end, in time order. Straight lines × 1.3 for roads; GPS jumps over
-- 40 km in one leg are ignored.
create or replace function public.fleet_day_km(p_org text, p_users text[], p_day date)
returns table(km numeric, stops int)
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_s timestamptz := (p_day::timestamp at time zone 'Asia/Karachi');
  v_e timestamptz := ((p_day + 1)::timestamp at time zone 'Asia/Karachi');
begin
  return query
  with pts as (
    select t.user_id::text as uid, t.started_at::timestamptz as ts, t.start_lat::float8 as la, t.start_lng::float8 as lo
      from trips t where t.user_id::text = any (p_users) and t.started_at >= v_s and t.started_at < v_e and t.start_lat is not null
    union all
    select t.user_id::text, t.ended_at::timestamptz, t.end_lat::float8, t.end_lng::float8
      from trips t where t.user_id::text = any (p_users) and t.ended_at >= v_s and t.ended_at < v_e and t.end_lat is not null
    union all
    select v.user_id::text, v.timestamp::timestamptz, v.captured_lat::float8, v.captured_lng::float8
      from visits v where v.org_id = p_org and v.user_id::text = any (p_users)
       and v.timestamp >= v_s and v.timestamp < v_e and v.captured_lat is not null
    union all
    select d.driver_id::text, s.delivered_at::timestamptz, s.captured_lat::float8, s.captured_lng::float8
      from delivery_stops s join deliveries d on d.id = s.delivery_id
     where d.org_id = p_org and d.driver_id::text = any (p_users)
       and s.delivered_at >= v_s and s.delivered_at < v_e and s.captured_lat is not null
  ),
  legs as (
    select public._geo_km(lag(la) over w, lag(lo) over w, la, lo) as k
      from pts window w as (partition by uid order by ts)
  )
  select round((coalesce(sum(k) filter (where k is not null and k > 0.02 and k <= 40), 0) * 1.3)::numeric, 1),
         (select count(*)::int from pts)
    from legs;
end $$;

-- Odometer chain: start → + auto km → readings reset it.
create or replace function public.fleet_recalc(p_vehicle text)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare v fleet_vehicles%rowtype; r record; run numeric;
begin
  select * into v from fleet_vehicles where id = p_vehicle;
  if v.id is null then return null; end if;
  if auth.uid() is not null and not (public._is_org_member(v.org_id) or public._is_super_admin()) then return null; end if;
  run := coalesce(v.start_odometer, 0);
  for r in select * from fleet_mileage_log where vehicle_id = p_vehicle
            order by log_date, case when source = 'auto' then 0 else 1 end, created_at loop
    if r.source = 'reading' then
      update fleet_mileage_log set km = coalesce(r.reading, run) - run, odometer_after = coalesce(r.reading, run) where id = r.id;
      run := coalesce(r.reading, run);
    else
      run := run + coalesce(r.km, 0);
      update fleet_mileage_log set odometer_after = run where id = r.id;
    end if;
  end loop;
  update fleet_vehicles set odometer = run, updated_at = now() where id = p_vehicle;
  return run;
end $$;
grant execute on function public.fleet_recalc(text) to authenticated;

-- Add the km from trips / deliveries for every vehicle of the org.
create or replace function public.fleet_sync(p_org text)
returns int language plpgsql security definer set search_path to 'public' as $$
declare
  v record; d date; v_from date; v_today date := (now() at time zone 'Asia/Karachi')::date;
  k numeric; n int; c int := 0;
begin
  if auth.uid() is not null and not (public._is_org_member(p_org) or public._is_super_admin()) then return 0; end if;
  for v in select * from fleet_vehicles where org_id = p_org and is_active and cardinality(driver_ids) > 0 loop
    v_from := greatest(v.start_date, coalesce(v.last_synced - 2, v.start_date), v_today - 60);
    d := v_from;
    while d <= v_today loop
      select x.km, x.stops into k, n from public.fleet_day_km(p_org, v.driver_ids, d) x;
      if coalesce(k, 0) > 0 then
        insert into fleet_mileage_log (org_id, vehicle_id, log_date, source, km, ref)
        values (p_org, v.id, d, 'auto', k, n || ' points from trips and deliveries')
        on conflict (vehicle_id, log_date) where source = 'auto'
        do update set km = excluded.km, ref = excluded.ref;
      else
        delete from fleet_mileage_log where vehicle_id = v.id and log_date = d and source = 'auto';
      end if;
      d := d + 1;
    end loop;
    perform public.fleet_recalc(v.id);
    update fleet_vehicles set last_synced = v_today where id = v.id;
    c := c + 1;
  end loop;
  return c;
end $$;
grant execute on function public.fleet_sync(text) to authenticated;

-- Odometer reading typed in by someone.
create or replace function public.fleet_add_reading(p_vehicle text, p_date date, p_reading numeric, p_note text default null)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare v fleet_vehicles%rowtype; v_name text;
begin
  select * into v from fleet_vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle not found.'; end if;
  if not (public._is_org_member(v.org_id) or public._is_super_admin()) then raise exception 'No access.'; end if;
  if p_reading is null or p_reading < 0 then raise exception 'Enter the odometer reading.'; end if;
  select a.name into v_name from public._acting_user(v.org_id) a;
  insert into fleet_mileage_log (org_id, vehicle_id, log_date, source, reading, ref, by_name)
  values (v.org_id, v.id, coalesce(p_date, (now() at time zone 'Asia/Karachi')::date), 'reading', p_reading,
          coalesce(nullif(btrim(p_note), ''), 'Odometer reading'), v_name);
  return public.fleet_recalc(v.id);
end $$;
grant execute on function public.fleet_add_reading(text, date, numeric, text) to authenticated;

-- A service was done: log it and restart its counter.
create or replace function public.fleet_service_done(p_service text, p_date date, p_odometer numeric,
                                                     p_cost numeric default null, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s fleet_services%rowtype; v_name text; v_odo numeric;
begin
  select * into s from fleet_services where id = p_service;
  if s.id is null then raise exception 'Service not found.'; end if;
  if not (public._is_org_member(s.org_id) or public._is_super_admin()) then raise exception 'No access.'; end if;
  select odometer into v_odo from fleet_vehicles where id = s.vehicle_id;
  select a.name into v_name from public._acting_user(s.org_id) a;
  insert into fleet_service_log (org_id, vehicle_id, service_id, service_name, done_date, odometer, cost, note, done_by_name)
  values (s.org_id, s.vehicle_id, s.id, s.name, coalesce(p_date, (now() at time zone 'Asia/Karachi')::date),
          coalesce(p_odometer, v_odo), p_cost, nullif(btrim(coalesce(p_note, '')), ''), v_name);
  update fleet_services set last_km = coalesce(p_odometer, v_odo),
                            last_date = coalesce(p_date, (now() at time zone 'Asia/Karachi')::date)
   where id = s.id;
end $$;
grant execute on function public.fleet_service_done(text, date, numeric, numeric, text) to authenticated;

-- Where a service stands. state: ok | due | overdue.
create or replace function public._fleet_service_state(s fleet_services, p_odo numeric, p_lead_km numeric)
returns jsonb language plpgsql stable as $$
declare
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  next_km numeric; next_date date; km_left numeric; days_left int; st text := 'ok';
begin
  if s.every_km is not null and s.every_km > 0 then
    next_km := coalesce(s.last_km, 0) + s.every_km;
    km_left := next_km - coalesce(p_odo, 0);
  end if;
  if s.every_months is not null and s.every_months > 0 and s.last_date is not null then
    next_date := (s.last_date + make_interval(months => s.every_months))::date;
    days_left := next_date - v_today;
  end if;
  if (km_left is not null and km_left < 0) or (days_left is not null and days_left < 0) then st := 'overdue';
  elsif (km_left is not null and km_left <= coalesce(p_lead_km, 200)) or (days_left is not null and days_left <= 7) then st := 'due';
  end if;
  return jsonb_build_object('state', st, 'next_km', next_km, 'km_left', km_left, 'next_date', next_date, 'days_left', days_left);
end $$;

-- Pending counter for the menu (services due or overdue).
create or replace function public.fleet_due_count(p_org text)
returns int language plpgsql stable security definer set search_path to 'public' as $$
declare v_lead numeric;
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then return 0; end if;
  select nullif(value, '')::numeric into v_lead from app_config where org_id = p_org and key = 'org.fleet_alert_km' and branch_id is null limit 1;
  return (select count(*) from fleet_services s join fleet_vehicles v on v.id = s.vehicle_id
           where s.org_id = p_org and s.is_active and v.is_active
             and public._fleet_service_state(s, v.odometer, coalesce(v_lead, 200)) ->> 'state' <> 'ok');
end $$;
grant execute on function public.fleet_due_count(text) to authenticated;

-- Nightly: add km, then remind about services coming due.
create or replace function public.fleet_reminders()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  o record; r record; v_lead numeric; v_users text[]; v_ids text[]; v_st jsonb; v_cycle text; v_stage text;
  v_last timestamptz; v_title text; v_body text; v_notif text; n int := 0;
begin
  for o in select distinct org_id from app_config where key = 'org.fleet_alerts' and value = 'true' loop
    perform public.fleet_sync(o.org_id);
    select nullif(value, '')::numeric into v_lead from app_config where org_id = o.org_id and key = 'org.fleet_alert_km' and branch_id is null limit 1;
    select string_to_array(replace(coalesce(value, ''), ' ', ''), ',') into v_users
      from app_config where org_id = o.org_id and key = 'org.fleet_alert_users' and branch_id is null limit 1;
    for r in select s as svc, s.id, s.name, s.vehicle_id, s.last_km, s.last_date,
                    v.reg_no, v.make, v.model, v.odometer, v.driver_ids
               from fleet_services s join fleet_vehicles v on v.id = s.vehicle_id
              where s.org_id = o.org_id and s.is_active and v.is_active loop
      v_st := public._fleet_service_state(r.svc, r.odometer, coalesce(v_lead, 200));
      v_stage := v_st ->> 'state';
      if v_stage = 'ok' then continue; end if;
      v_cycle := coalesce(r.last_km::text, '') || '|' || coalesce(r.last_date::text, '');
      select max(sent_at) into v_last from fleet_alert_log where service_id = r.id and cycle = v_cycle and stage = v_stage;
      if v_last is not null and (v_stage = 'due' or v_last > now() - interval '7 days') then continue; end if;

      v_title := r.name || case when v_stage = 'overdue' then ' overdue — ' else ' due — ' end || r.reg_no;
      v_body := trim(both ' ' from concat_ws(' ', r.make, r.model)) ||
                case when (v_st ->> 'km_left') is not null
                     then case when (v_st ->> 'km_left')::numeric < 0
                               then ' · ' || round(abs((v_st ->> 'km_left')::numeric)) || ' km past due'
                               else ' · ' || round((v_st ->> 'km_left')::numeric) || ' km left' end
                     else '' end ||
                case when (v_st ->> 'next_date') is not null then ' · due ' || to_char((v_st ->> 'next_date')::date, 'DD Mon YYYY') else '' end ||
                '. Please get it serviced.';
      v_body := regexp_replace(v_body, '^\s*·\s*', '');
      select array_agg(distinct u.id) into v_ids from users u
       where u.org_id = o.org_id and coalesce(u.is_active, true)
         and (u.id = any (coalesce(r.driver_ids, '{}')) or u.id = any (coalesce(v_users, '{}')));
      if v_ids is null then continue; end if;
      begin
        perform public.push_send(o.org_id, v_ids, v_title, v_body, '/fleet?v=' || r.vehicle_id);
      exception when others then null;
      end;
      begin
        insert into notifications (org_id, title, body, audience, audience_roles, link_url, created_by, origin)
        values (o.org_id, v_title, v_body, 'roles', '{}'::text[], '/fleet?v=' || r.vehicle_id, v_ids[1], 'system')
        returning id::text into v_notif;
        insert into notification_recipients (notification_id, recipient_user_id) select v_notif, unnest(v_ids);
      exception when others then null;
      end;
      insert into fleet_alert_log (org_id, service_id, cycle, stage) values (o.org_id, r.id, v_cycle, v_stage);
      n := n + 1;
    end loop;
  end loop;
  return jsonb_build_object('alerts', n);
end $$;
revoke all on function public.fleet_reminders() from public, anon, authenticated;

do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — fleet reminders not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'fleet-reminders') then
    perform cron.unschedule('fleet-reminders');
  end if;
  perform cron.schedule('fleet-reminders', '20 4 * * *', 'select public.fleet_reminders();');
end $do$;

-- Name of the person using the app (for "opened by" on repairs).
create or replace function public.fleet_my_name(p_org text)
returns text language sql stable security definer set search_path to 'public' as $$
  select a.name from public._acting_user(p_org) a limit 1
$$;
grant execute on function public.fleet_my_name(text) to authenticated;
