-- 394 — Keep full GPS precision on customer locations. Needs 392.
--
-- The photo showed 31.428042, 74.192382 but the profile 31.428000, 74.192400:
-- customers.latitude / longitude only keep 4 decimals (~11 m). This widens
-- them to 7 decimals (~1 cm) and keeps the exact reading on each review row.
-- Safe to run again.

-- 1) What the columns are now (for the record)
select column_name, data_type, numeric_precision, numeric_scale
  from information_schema.columns
 where table_schema = 'public' and table_name = 'customers' and column_name in ('latitude', 'longitude');

-- 2) Widen to numeric(10,7) when they hold fewer than 6 decimals
do $w$
declare v_scale int; v_type text;
begin
  select numeric_scale, data_type into v_scale, v_type from information_schema.columns
   where table_schema = 'public' and table_name = 'customers' and column_name = 'latitude';
  if v_type = 'real' or (v_type = 'numeric' and coalesce(v_scale, 0) between 0 and 5 and v_scale is not null) then
    begin
      alter table public.customers
        alter column latitude  type numeric(10,7),
        alter column longitude type numeric(10,7);
      raise notice 'customers latitude/longitude widened to numeric(10,7)';
    exception when others then
      raise notice 'Could not widen the columns: % (send this line back)', sqlerrm;
    end;
  else
    raise notice 'customers latitude/longitude already precise (%, scale %)', v_type, v_scale;
  end if;
end $w$;

-- 3) The exact reading on the review row, whatever the column keeps
alter table public.customer_edit_reviews add column if not exists captured_lat double precision;
alter table public.customer_edit_reviews add column if not exists captured_lng double precision;

create or replace function public.customer_capture_location(
  p_customer text, p_lat double precision, p_lng double precision,
  p_accuracy numeric, p_mocked boolean, p_photo_path text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_org text; v_has boolean; v_scope text;
begin
  select org_id, (latitude is not null and longitude is not null) into v_org, v_has
    from public.customers where id = p_customer;
  if v_org is null or not public._is_org_member(v_org) then
    raise exception 'This shop was not found.';
  end if;
  if not public._cfg_true(v_org, 'org.field_location_capture') then
    raise exception 'Adding shop locations from the field is switched off.';
  end if;
  v_scope := coalesce((select value from public.app_config where org_id = v_org and key = 'org.field_location_capture_scope' limit 1), 'missing');
  if v_scope <> 'any' and v_has then
    raise exception 'This shop already has a location.';
  end if;
  if p_lat is null or p_lng is null or abs(p_lat) > 90 or abs(p_lng) > 180 or (p_lat = 0 and p_lng = 0) then
    raise exception 'The location reading was not valid. Please try again.';
  end if;
  perform set_config('opstation.cer_meta', jsonb_build_object('source', 'field_capture', 'photo_path', p_photo_path,
      'accuracy', p_accuracy, 'mocked', coalesce(p_mocked, false))::text, true);
  update public.customers set latitude = p_lat, longitude = p_lng, updated_at = now() where id = p_customer;
  perform set_config('opstation.cer_meta', '', true);
  -- exact reading on the review row just written
  update public.customer_edit_reviews set captured_lat = p_lat, captured_lng = p_lng,
         changes = jsonb_set(jsonb_set(changes, '{latitude,new}', to_jsonb(p_lat)), '{longitude,new}', to_jsonb(p_lng))
   where id = (select id from public.customer_edit_reviews
                where customer_id = p_customer and kind = 'location' and source = 'field_capture'
                order by changed_at desc limit 1);
  return 'ok';
end $$;
grant execute on function public.customer_capture_location(text, double precision, double precision, numeric, boolean, text) to authenticated;

notify pgrst, 'reload schema';

-- Check
select column_name, data_type, numeric_scale from information_schema.columns
 where table_schema = 'public' and table_name = 'customers' and column_name in ('latitude', 'longitude');
