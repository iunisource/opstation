-- 450 — Fixing wrong shop locations from the field.
--
-- Shops flagged "Same location as another customer" (a different shop at
-- the same spot — copied or wrongly imported) can be recaptured by
-- salespeople on their route even when Admin Settings only allows adding
-- missing locations. Each capture still goes to location review as today.
-- Run after 449 / 449b. Safe to run again.

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
  -- A location shared with a different shop (wrong / copied) can always be
  -- recaptured, even when only missing locations may be added (SQL 450).
  if v_scope <> 'any' and v_has
     and not exists (select 1 from public.customer_location_shared(v_org) s where s.customer_id = p_customer) then
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
select 'location fixes ready' as result;
