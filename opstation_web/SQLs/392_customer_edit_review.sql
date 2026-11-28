-- 392 — Customer edit supervision + shop location from the field.
--
--  * Admin Settings → "Supervision for customer edits" (org.customer_edit_supervise_flow,
--    supervisors: admins + org.customer_edit_supervisor_users). While ON, every
--    edit to an existing customer — web, app, import — is recorded with what
--    changed (old → new) and waits for a supervisor in Customer 360. The edit
--    itself applies straight away (non-blocking, like the other supervision
--    flows); the supervisor can Supervise it or Revert it.
--  * Admin Settings → "Salesperson can add shop location" (org.field_location_capture,
--    scope org.field_location_capture_scope = missing | any). A location taken
--    in the field always goes for review — with its photo, GPS accuracy and
--    whether the phone reported a fake location — whatever the edit toggle.
--  * Email alert on customer edit is untouched.
-- Needs 386 (_acting_user). Safe to run again.

create table if not exists public.customer_edit_reviews (
  id               text primary key default gen_random_uuid()::text,
  org_id           text not null,
  customer_id      text not null,
  kind             text not null,                 -- details | location
  changes          jsonb not null,                -- {"phone": {"old": "..", "new": ".."}}
  source           text not null default 'edit',  -- edit | field_capture
  photo_path       text,
  accuracy_m       numeric,
  is_mocked        boolean,
  changed_by       text,
  changed_by_name  text,
  changed_at       timestamptz not null default now(),
  status           text not null default 'pending', -- pending | supervised | reverted
  reviewed_by      text,
  reviewed_by_name text,
  reviewed_at      timestamptz,
  note             text
);
create index if not exists cer_org_status_idx on public.customer_edit_reviews (org_id, status);
create index if not exists cer_customer_idx on public.customer_edit_reviews (customer_id, status, changed_at desc);

alter table public.customer_edit_reviews enable row level security;
drop policy if exists customer_edit_reviews_sel on public.customer_edit_reviews;
create policy customer_edit_reviews_sel on public.customer_edit_reviews
  for select to authenticated using (public._is_org_member(org_id));

create or replace function public._cfg_true(p_org text, p_key text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.app_config where org_id = p_org and key = p_key and value = 'true');
$$;

-- Admins, master admins and the users picked in Admin Settings.
create or replace function public._can_supervise_customer_edits(p_org text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_id text; v_role text; v_list text;
begin
  select u.id, u.role into v_id, v_role from public._acting_user(p_org) a join public.users u on u.id = a.id;
  if v_id is null then return false; end if;
  if v_role in ('admin', 'masterAdmin', 'superAdmin') then return true; end if;
  v_list := (select value from public.app_config where org_id = p_org and key = 'org.customer_edit_supervisor_users' limit 1);
  return v_id = any (string_to_array(replace(coalesce(v_list, ''), ' ', ''), ','));
end $$;

-- ── record edits ─────────────────────────────────────────────────────────
create or replace function public.trg_customer_edit_review()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  f text; d jsonb := '{}'::jsonb; loc jsonb := '{}'::jsonb;
  o jsonb := to_jsonb(OLD); n jsonb := to_jsonb(NEW);
  meta jsonb; v_uid text; v_uname text; v_edits boolean; v_field boolean;
begin
  begin
    if coalesce(current_setting('opstation.cer_skip', true), '') = '1' then return null; end if;
    begin meta := nullif(current_setting('opstation.cer_meta', true), '')::jsonb; exception when others then meta := null; end;
    v_field := coalesce(meta->>'source', '') = 'field_capture';
    v_edits := public._cfg_true(NEW.org_id, 'org.customer_edit_supervise_flow');
    if not v_edits and not v_field then return null; end if;

    foreach f in array array['shop_name', 'code', 'contact_person', 'phone', 'address', 'category',
                             'group_name', 'credit_limit', 'monthly_sale_target', 'ntn_gst', 'is_active'] loop
      if (o ? f or n ? f) and (o->f) is distinct from (n->f)
         and coalesce(nullif(trim(o->>f), ''), '∅') is distinct from coalesce(nullif(trim(n->>f), ''), '∅') then
        d := d || jsonb_build_object(f, jsonb_build_object('old', o->f, 'new', n->f));
      end if;
    end loop;
    if (OLD.latitude is null) <> (NEW.latitude is null) or (OLD.longitude is null) <> (NEW.longitude is null)
       or abs(coalesce(OLD.latitude, 0) - coalesce(NEW.latitude, 0)) > 0.0000005
       or abs(coalesce(OLD.longitude, 0) - coalesce(NEW.longitude, 0)) > 0.0000005 then
      loc := jsonb_build_object(
        'latitude',  jsonb_build_object('old', OLD.latitude,  'new', NEW.latitude),
        'longitude', jsonb_build_object('old', OLD.longitude, 'new', NEW.longitude));
    end if;
    if d = '{}'::jsonb and loc = '{}'::jsonb then return null; end if;

    select a.id, a.name into v_uid, v_uname from public._acting_user(NEW.org_id) a;
    if loc <> '{}'::jsonb and (v_edits or v_field) then
      insert into public.customer_edit_reviews (org_id, customer_id, kind, changes, source, photo_path,
          accuracy_m, is_mocked, changed_by, changed_by_name)
      values (NEW.org_id, NEW.id, 'location', loc, case when v_field then 'field_capture' else 'edit' end,
          meta->>'photo_path', nullif(meta->>'accuracy', '')::numeric, (meta->>'mocked')::boolean, v_uid, v_uname);
    end if;
    if d <> '{}'::jsonb and v_edits then
      insert into public.customer_edit_reviews (org_id, customer_id, kind, changes, changed_by, changed_by_name)
      values (NEW.org_id, NEW.id, 'details', d, v_uid, v_uname);
    end if;
  exception when others then null;   -- never block a customer save
  end;
  return null;
end $$;
drop trigger if exists zz_customer_edit_review on public.customers;
create trigger zz_customer_edit_review after update on public.customers
  for each row execute function public.trg_customer_edit_review();

-- ── shop location from the field (salesperson app) ───────────────────────
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
  return 'ok';
end $$;
grant execute on function public.customer_capture_location(text, double precision, double precision, numeric, boolean, text) to authenticated;

-- ── supervise / revert ───────────────────────────────────────────────────
create or replace function public.customer_review_supervise(p_ids text[])
returns int language plpgsql security definer set search_path to 'public' as $$
declare v_org text; v_uid text; v_uname text; n int;
begin
  v_org := (select org_id from public.customer_edit_reviews where id = any (p_ids) limit 1);
  if v_org is null then return 0; end if;
  if not public._can_supervise_customer_edits(v_org) then
    raise exception 'You are not allowed to supervise customer changes.';
  end if;
  select a.id, a.name into v_uid, v_uname from public._acting_user(v_org) a;
  update public.customer_edit_reviews
     set status = 'supervised', reviewed_by = v_uid, reviewed_by_name = v_uname, reviewed_at = now()
   where id = any (p_ids) and org_id = v_org and status = 'pending';
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.customer_review_supervise(text[]) to authenticated;

-- Puts back the old values (only fields still holding the reviewed value).
create or replace function public.customer_review_revert(p_id text, p_note text default null)
returns text language plpgsql security definer set search_path to 'public' as $$
declare r record; f text; cur jsonb; v_set text := ''; v_uid text; v_uname text; skipped int := 0;
begin
  select * into r from public.customer_edit_reviews where id = p_id;
  if not found then raise exception 'This change was not found.'; end if;
  if r.status <> 'pending' then raise exception 'This change has already been reviewed.'; end if;
  if not public._can_supervise_customer_edits(r.org_id) then
    raise exception 'You are not allowed to supervise customer changes.';
  end if;
  select to_jsonb(c) into cur from public.customers c where c.id = r.customer_id;
  for f in select jsonb_object_keys(r.changes) loop
    if f !~ '^[a-z_]+$' then continue; end if;
    if (cur->f) is not distinct from (r.changes->f->'new') then
      v_set := v_set || case when v_set = '' then '' else ', ' end ||
               format('%I = (jsonb_populate_record(null::public.customers, jsonb_build_object(%L, %L::jsonb))).%I',
                      f, f, coalesce(r.changes->f->'old', 'null'::jsonb)::text, f);
    else
      skipped := skipped + 1;
    end if;
  end loop;
  perform set_config('opstation.cer_skip', '1', true);
  if v_set <> '' then
    execute format('update public.customers set %s, updated_at = now() where id = %L', v_set, r.customer_id);
  end if;
  perform set_config('opstation.cer_skip', '', true);
  select a.id, a.name into v_uid, v_uname from public._acting_user(r.org_id) a;
  update public.customer_edit_reviews
     set status = 'reverted', reviewed_by = v_uid, reviewed_by_name = v_uname, reviewed_at = now(), note = p_note
   where id = p_id;
  return case when skipped > 0 then 'partly' else 'ok' end;
end $$;
grant execute on function public.customer_review_revert(text, text) to authenticated;

notify pgrst, 'reload schema';

-- Check
select count(*) as pending_reviews from public.customer_edit_reviews where status = 'pending';
