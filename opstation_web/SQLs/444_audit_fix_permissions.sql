-- 444 — Who may correct surveys, and an optional approval layer.
--
--  • Auditors can't change survey data by default. Admin Settings →
--    "Auditors can correct surveys" (org.audit_fix_access) + the auditors
--    picked (org.audit_fix_users) are allowed to.
--  • Admin Settings → "Approval for auditor corrections"
--    (org.audit_fix_approval): when ON, a correction waits as "Pending" until
--    a master admin, or a user picked in org.audit_fix_approvers, approves it
--    on the web. When OFF, corrections apply immediately.
--  • Matches / Issue / Feedback stay open to every auditor; Feedback can be
--    given on any shop, surveyed or not.
-- Run after 443. Safe to run again.

alter table public.survey_audits
  add column if not exists fix_status text not null default 'none',
  add column if not exists fixes_pending jsonb,
  add column if not exists fix_decided_by text,
  add column if not exists fix_decided_by_name text,
  add column if not exists fix_decided_at timestamptz,
  add column if not exists fix_reject_reason text;
alter table public.survey_audits drop constraint if exists survey_audits_fix_status_check;
alter table public.survey_audits add constraint survey_audits_fix_status_check
  check (fix_status in ('none', 'applied', 'pending', 'approved', 'rejected'));
-- Corrections saved before this update counted as applied.
update public.survey_audits set fix_status = 'applied'
 where fix_status = 'none' and jsonb_typeof(corrections) = 'array' and jsonb_array_length(corrections) > 0;

-- ── Permission helpers ─────────────────────────────────────────────────────
create or replace function public._cfg_list_has(p_org text, p_key text, p_id text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select p_id is not null and p_id = any (string_to_array(replace(coalesce(
    (select value from public.app_config where org_id = p_org and key = p_key limit 1), ''), ' ', ''), ','));
$$;

create or replace function public._audit_fix_allowed(p_org text, p_user text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public._cfg_true(p_org, 'org.audit_fix_access') and public._cfg_list_has(p_org, 'org.audit_fix_users', p_user);
$$;

create or replace function public._can_approve_audit_fix(p_org text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_id text; v_role text;
begin
  if public._is_super_admin() then return true; end if;
  select u.id, u.role into v_id, v_role from public._acting_user(p_org) a join public.users u on u.id = a.id;
  if v_id is null then return false; end if;
  if v_role = 'masterAdmin' then return true; end if;
  return public._cfg_list_has(p_org, 'org.audit_fix_approvers', v_id);
end $$;

-- What the signed-in user may do (the app and web read this).
create or replace function public.my_audit_permissions(p_org text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_id text; v_role text;
begin
  select u.id, u.role into v_id, v_role from public._acting_user(p_org) a join public.users u on u.id = a.id;
  return jsonb_build_object(
    'is_auditor', coalesce(v_role, '') = 'auditor',
    'can_fix', coalesce(v_role, '') = 'auditor' and public._audit_fix_allowed(p_org, v_id),
    'needs_approval', public._cfg_true(p_org, 'org.audit_fix_approval'),
    'can_approve', public._can_approve_audit_fix(p_org));
end $$;
revoke execute on function public.my_audit_permissions(text) from public, anon;
grant execute on function public.my_audit_permissions(text) to authenticated;

-- ── Fixes: preview (from → to) and, when p_apply, write the survey rows ────
create or replace function public._survey_fixes(
  p_org text, p_cust text, p_user text, p_at timestamptz, p_audit text, p_fixes jsonb, p_apply boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_fix jsonb; v_corr jsonb := '[]'::jsonb;
  v_name text; v_from text; v_to text; v_brand text; v_price numeric; v_specs text; v_present boolean;
begin
  if jsonb_typeof(p_fixes) <> 'array' then return v_corr; end if;
  if p_apply then perform set_config('opstation.survey_rpc', '1', true); end if;
  for v_fix in select value from jsonb_array_elements(p_fixes) loop
    v_name := null; v_from := null;
    if v_fix->>'type' = 'placement' then
      select name into v_name from public.intelligence_products where id = v_fix->>'product_id' and org_id = p_org;
      if v_name is null or v_fix->>'id' is null then continue; end if;
      v_present := coalesce((v_fix->>'is_present')::boolean, false);
      select case when pa.is_present then 'Displayed' else 'Not displayed' end into v_from
        from public.placement_audit pa
       where pa.org_id = p_org and pa.customer_id = p_cust and pa.product_id = v_fix->>'product_id' and pa.voided_at is null
       order by pa.surveyed_at desc limit 1;
      if p_apply then
        insert into public.placement_audit
          (id, org_id, customer_id, product_id, is_present, surveyed_by_user_id, surveyed_at, created_at, source, audit_id)
        values (v_fix->>'id', p_org, p_cust, v_fix->>'product_id', v_present, p_user, p_at, p_at, 'audit_fix', p_audit)
        on conflict (id) do nothing;
      end if;
      v_corr := v_corr || jsonb_build_array(jsonb_build_object(
        'type', 'placement', 'product_id', v_fix->>'product_id', 'product', v_name,
        'from', v_from, 'to', case when v_present then 'Displayed' else 'Not displayed' end, 'row_id', v_fix->>'id'));
    elsif v_fix->>'type' = 'competitor' then
      select name into v_name from public.competitor_categories where id = v_fix->>'category_id' and org_id = p_org;
      v_brand := nullif(btrim(coalesce(v_fix->>'brand_name', '')), '');
      if v_name is null or v_brand is null or v_fix->>'id' is null then continue; end if;
      v_price := nullif(btrim(coalesce(v_fix->>'price', '')), '')::numeric;
      v_specs := nullif(btrim(coalesce(v_fix->>'specs', '')), '');
      select concat_ws(' · ', nullif(cs.brand_name, ''), case when cs.price is not null then 'Rs ' || cs.price::text end,
                       nullif(cs.specs, '')) into v_from
        from public.competitor_spotting cs
       where cs.org_id = p_org and cs.customer_id = p_cust and cs.category_id = v_fix->>'category_id' and cs.voided_at is null
       order by cs.surveyed_at desc limit 1;
      if p_apply then
        insert into public.competitor_spotting
          (id, org_id, customer_id, category_id, brand_name, price, specs, surveyed_by_user_id, surveyed_at, created_at, source, audit_id)
        values (v_fix->>'id', p_org, p_cust, v_fix->>'category_id', v_brand, v_price, v_specs, p_user, p_at, p_at, 'audit_fix', p_audit)
        on conflict (id) do nothing;
      end if;
      v_to := concat_ws(' · ', v_brand, case when v_price is not null then 'Rs ' || v_price::text end, v_specs);
      v_corr := v_corr || jsonb_build_array(jsonb_build_object(
        'type', 'competitor', 'category_id', v_fix->>'category_id', 'category', v_name,
        'from', v_from, 'to', v_to, 'row_id', v_fix->>'id'));
    end if;
  end loop;
  return v_corr;
end $$;
revoke execute on function public._survey_fixes(text, text, text, timestamptz, text, jsonb, boolean) from public, anon, authenticated;

-- ── Submit an audit (replaces 443's version) ───────────────────────────────
create or replace function public.submit_survey_audit(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_org text := p->>'org_id';
  v_id text := p->>'id';
  v_cust text := p->>'customer_id';
  v_result text := coalesce(p->>'result', '');
  v_comment text := nullif(btrim(coalesce(p->>'comment', '')), '');
  v_uid text; v_uname text; v_role text;
  v_at timestamptz;
  v_has_fixes boolean;
  v_pending boolean := false;
  v_corr jsonb := '[]'::jsonb;
begin
  if v_org is null or v_id is null or v_cust is null then raise exception 'Incomplete audit.'; end if;
  select u.id, u.name, u.role into v_uid, v_uname, v_role
    from public._acting_user(v_org) a join public.users u on u.id = a.id;
  if v_uid is null or coalesce(v_role, '') <> 'auditor' then
    raise exception 'Only auditors can record survey audits.';
  end if;
  if exists (select 1 from public.survey_audits where id = v_id) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  if v_result not in ('ok', 'issue', 'feedback') then raise exception 'Unknown audit result.'; end if;
  if v_result in ('issue', 'feedback') and v_comment is null then raise exception 'A comment is required.'; end if;
  if not exists (select 1 from public.customers where id = v_cust and org_id = v_org) then raise exception 'Shop not found.'; end if;
  v_at := coalesce(nullif(p->>'audited_at', '')::timestamptz, now());
  v_has_fixes := jsonb_typeof(p->'fixes') = 'array' and jsonb_array_length(p->'fixes') > 0;
  if v_has_fixes then
    if v_result <> 'issue' then raise exception 'Corrections can only be saved with an Issue.'; end if;
    if not public._audit_fix_allowed(v_org, v_uid) then
      raise exception 'You are not allowed to correct surveys.';
    end if;
    v_pending := public._cfg_true(v_org, 'org.audit_fix_approval');
    v_corr := public._survey_fixes(v_org, v_cust, v_uid, v_at, v_id, p->'fixes', not v_pending);
  elsif jsonb_typeof(p->'corrections') = 'array' then
    v_corr := p->'corrections';   -- first app version: fixes were synced directly
  end if;

  insert into public.survey_audits
    (id, org_id, customer_id, auditor_id, auditor_name, result, comment, photo_path,
     lat, lng, accuracy_m, distance_m, location_status, survey_at, corrections, audited_at,
     fix_status, fixes_pending)
  values
    (v_id, v_org, v_cust, v_uid, v_uname, v_result, v_comment, nullif(p->>'photo_path', ''),
     nullif(p->>'lat', '')::double precision, nullif(p->>'lng', '')::double precision,
     nullif(p->>'accuracy_m', '')::double precision, nullif(p->>'distance_m', '')::double precision,
     nullif(p->>'location_status', ''), nullif(p->>'survey_at', '')::timestamptz,
     v_corr, v_at,
     case when v_pending then 'pending' when jsonb_array_length(v_corr) > 0 then 'applied' else 'none' end,
     case when v_pending then p->'fixes' else null end);
  return jsonb_build_object('ok', true, 'pending', v_pending);
end $$;
revoke execute on function public.submit_survey_audit(jsonb) from public, anon;
grant execute on function public.submit_survey_audit(jsonb) to authenticated;

-- ── Approve / reject a pending correction (web) ────────────────────────────
create or replace function public.decide_survey_fix(p_audit text, p_approve boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a public.survey_audits; v_me text; v_me_name text; v_corr jsonb;
begin
  select * into a from public.survey_audits where id = p_audit for update;
  if not found then raise exception 'Audit not found.'; end if;
  if not public._can_approve_audit_fix(a.org_id) then
    raise exception 'You are not allowed to approve survey corrections.';
  end if;
  if a.fix_status <> 'pending' then
    return jsonb_build_object('ok', true, 'already', a.fix_status);
  end if;
  select u.id, u.name into v_me, v_me_name from public._acting_user(a.org_id) a2 join public.users u on u.id = a2.id;
  if p_approve then
    -- Saved with the audit's own time, so a newer survey of the shop still wins.
    v_corr := public._survey_fixes(a.org_id, a.customer_id, a.auditor_id, a.audited_at, a.id, a.fixes_pending, true);
    update public.survey_audits
       set fix_status = 'approved', corrections = v_corr, fix_decided_by = coalesce(v_me, 'super_admin'),
           fix_decided_by_name = coalesce(v_me_name, 'Super admin'), fix_decided_at = now(), fix_reject_reason = null
     where id = a.id;
  else
    update public.survey_audits
       set fix_status = 'rejected', fix_decided_by = coalesce(v_me, 'super_admin'),
           fix_decided_by_name = coalesce(v_me_name, 'Super admin'), fix_decided_at = now(),
           fix_reject_reason = nullif(btrim(coalesce(p_reason, '')), '')
     where id = a.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.decide_survey_fix(text, boolean, text) from public, anon;
grant execute on function public.decide_survey_fix(text, boolean, text) to authenticated;

-- ── First audit app version syncing fixes directly ─────────────────────────
-- Fix rows from auditors who aren't allowed to correct (or while approval is
-- ON) are kept but voided, so the phone's sync doesn't get stuck.
create or replace function public.trg_survey_row_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_rpc boolean := coalesce(current_setting('opstation.survey_rpc', true), '') = '1';
  v_uid text; v_role text;
  v_changed boolean;
begin
  if TG_OP = 'DELETE' then
    if public._is_super_admin() then return OLD; end if;
    raise exception 'Survey records cannot be deleted. Use Remove to void them.';
  end if;

  if TG_OP = 'INSERT' then
    NEW.inserted_by_uid := auth.uid();
    NEW.inserted_at := now();
    NEW.voided_at := null; NEW.voided_by := null; NEW.void_reason := null;
    if v_rpc then return NEW; end if;
    if NEW.id like 'pa\_aud\_%' or NEW.id like 'cs\_aud\_%' or NEW.source = 'audit_fix' then
      select u.id, u.role into v_uid, v_role from public._acting_user(NEW.org_id) a join public.users u on u.id = a.id;
      if coalesce(v_role, '') <> 'auditor' then
        raise exception 'Only auditors can save survey corrections.';
      end if;
      NEW.source := 'audit_fix';
      if not public._audit_fix_allowed(NEW.org_id, v_uid) then
        NEW.voided_at := now(); NEW.voided_by := v_uid; NEW.void_reason := 'Correction not authorized';
      elsif public._cfg_true(NEW.org_id, 'org.audit_fix_approval') then
        NEW.voided_at := now(); NEW.voided_by := v_uid; NEW.void_reason := 'Needs approval — update the app and resubmit';
      end if;
    else
      NEW.source := 'survey';
      NEW.audit_id := null;
    end if;
    return NEW;
  end if;

  NEW.inserted_by_uid := OLD.inserted_by_uid;
  NEW.inserted_at := OLD.inserted_at;
  NEW.source := OLD.source;
  NEW.audit_id := OLD.audit_id;
  if TG_TABLE_NAME = 'placement_audit' then
    v_changed := (NEW.org_id, NEW.customer_id, NEW.product_id, NEW.is_present, NEW.surveyed_by_user_id, NEW.surveyed_at)
       is distinct from (OLD.org_id, OLD.customer_id, OLD.product_id, OLD.is_present, OLD.surveyed_by_user_id, OLD.surveyed_at);
  else
    v_changed := (NEW.org_id, NEW.customer_id, NEW.category_id, NEW.brand_name, NEW.price, NEW.specs, NEW.surveyed_by_user_id, NEW.surveyed_at)
       is distinct from (OLD.org_id, OLD.customer_id, OLD.category_id, OLD.brand_name, OLD.price, OLD.specs, OLD.surveyed_by_user_id, OLD.surveyed_at);
  end if;
  if v_changed then
    raise exception 'Survey records cannot be changed. Record a new survey instead.';
  end if;
  if (NEW.voided_at, NEW.voided_by, NEW.void_reason) is distinct from (OLD.voided_at, OLD.voided_by, OLD.void_reason)
     and not (v_rpc or public._is_super_admin()) then
    NEW.voided_at := OLD.voided_at; NEW.voided_by := OLD.voided_by; NEW.void_reason := OLD.void_reason;
  end if;
  return NEW;
end $$;

notify pgrst, 'reload schema';
select 'audit correction permissions ready' as result;
