-- 452 — Supervision for surveyor locations (Admin Settings, OFF by default).
--
-- OFF: a surveyor's location (photo + GPS) is applied straight away; its
-- review row is kept, already marked supervised, so the photo stays in the
-- shop's location history. ON: it waits for a supervisor like salespeople's.
-- Run after 451. Safe to run again.

create or replace function public.customer_capture_location(
  p_customer text, p_lat double precision, p_lng double precision,
  p_accuracy numeric, p_mocked boolean, p_photo_path text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_org text; v_has boolean; v_scope text; v_surveyor boolean;
begin
  select org_id, (latitude is not null and longitude is not null) into v_org, v_has
    from public.customers where id = p_customer;
  if v_org is null or not public._is_org_member(v_org) then
    raise exception 'This shop was not found.';
  end if;
  -- Surveyors' job is shop locations: always allowed, any shop (SQL 451).
  select coalesce(u.role, '') = 'surveyor' into v_surveyor
    from public._acting_user(v_org) a join public.users u on u.id = a.id;
  v_surveyor := coalesce(v_surveyor, false);
  if not v_surveyor and not public._cfg_true(v_org, 'org.field_location_capture') then
    raise exception 'Adding shop locations from the field is switched off.';
  end if;
  v_scope := coalesce((select value from public.app_config where org_id = v_org and key = 'org.field_location_capture_scope' limit 1), 'missing');
  -- A location shared with a different shop (wrong / copied) can always be
  -- recaptured, even when only missing locations may be added (SQL 450).
  if not v_surveyor and v_scope <> 'any' and v_has
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
  -- Surveyor with supervision OFF (default): applied directly — the review
  -- row (with the photo) is kept as already supervised (SQL 452).
  if v_surveyor and not public._cfg_true(v_org, 'org.surveyor_location_supervise') then
    update public.customer_edit_reviews
       set status = 'supervised', reviewed_at = now(), reviewed_by_name = 'Applied directly (surveyor)',
           note = 'Surveyor location — supervision is off'
     where id = (select id from public.customer_edit_reviews
                  where customer_id = p_customer and kind = 'location' and source = 'field_capture'
                  order by changed_at desc limit 1)
       and status = 'pending';
  end if;
  return 'ok';
end $$;
grant execute on function public.customer_capture_location(text, double precision, double precision, numeric, boolean, text) to authenticated;

notify pgrst, 'reload schema';
select 'surveyor location supervision ready' as result;
