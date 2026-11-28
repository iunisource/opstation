-- 443 — Secure lifecycle for shop surveys and audits.
--
--  • Survey rows (placement_audit, competitor_spotting) are append-only: they
--    can't be edited, and only a super admin can delete them. "Remove survey"
--    now VOIDS the shop's rows (hidden everywhere, kept with who / when / why).
--  • Every row records who really inserted it and when (server time).
--  • An auditor's audit and its fixes are saved together by one database
--    function (submit_survey_audit): only the Auditor role, the auditor's
--    identity comes from the login, the "old" value of each fix is read on the
--    server. Fix rows are marked source = 'audit_fix' and linked to the audit.
--  • Fixes apply immediately (they become the latest survey data).
--  • Audits can no longer be inserted directly — only through the function.
-- Run after 441 and 442. Safe to run again.

-- ── Columns ────────────────────────────────────────────────────────────────
alter table public.placement_audit
  add column if not exists source text not null default 'survey',
  add column if not exists audit_id text,
  add column if not exists inserted_by_uid uuid,
  add column if not exists inserted_at timestamptz default now(),
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by text,
  add column if not exists void_reason text;

alter table public.competitor_spotting
  add column if not exists source text not null default 'survey',
  add column if not exists audit_id text,
  add column if not exists inserted_by_uid uuid,
  add column if not exists inserted_at timestamptz default now(),
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by text,
  add column if not exists void_reason text;

-- Fixes already saved by the first audit app version (ids pa_aud_ / cs_aud_).
update public.placement_audit set source = 'audit_fix' where id like 'pa\_aud\_%' and source <> 'audit_fix';
update public.competitor_spotting set source = 'audit_fix' where id like 'cs\_aud\_%' and source <> 'audit_fix';

alter table public.survey_audits
  add column if not exists received_at timestamptz not null default now(),
  add column if not exists auditor_uid uuid default auth.uid();

-- ── Append-only guard on survey rows ───────────────────────────────────────
create or replace function public.trg_survey_row_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_rpc boolean := coalesce(current_setting('opstation.survey_rpc', true), '') = '1';
  v_role text;
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
    if v_rpc then return NEW; end if;              -- audit fixes from submit_survey_audit
    if NEW.id like 'pa\_aud\_%' or NEW.id like 'cs\_aud\_%' or NEW.source = 'audit_fix' then
      -- Fix synced directly by the first audit app version: auditors only.
      select u.role into v_role from public._acting_user(NEW.org_id) a join public.users u on u.id = a.id;
      if coalesce(v_role, '') <> 'auditor' then
        raise exception 'Only auditors can save survey corrections.';
      end if;
      NEW.source := 'audit_fix';
    else
      NEW.source := 'survey';
      NEW.audit_id := null;
    end if;
    return NEW;
  end if;

  -- UPDATE: survey data never changes; only voiding (through the void function).
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

drop trigger if exists trg_survey_row_guard on public.placement_audit;
create trigger trg_survey_row_guard before insert or update or delete on public.placement_audit
  for each row execute function public.trg_survey_row_guard();
drop trigger if exists trg_survey_row_guard on public.competitor_spotting;
create trigger trg_survey_row_guard before insert or update or delete on public.competitor_spotting
  for each row execute function public.trg_survey_row_guard();

-- Voided rows are hidden from everyone except super admin (screens, phones,
-- reports). Restrictive: applies on top of the existing read rules.
drop policy if exists hide_voided on public.placement_audit;
create policy hide_voided on public.placement_audit as restrictive for select
  using (voided_at is null or (select public._is_super_admin()));
drop policy if exists hide_voided on public.competitor_spotting;
create policy hide_voided on public.competitor_spotting as restrictive for select
  using (voided_at is null or (select public._is_super_admin()));

-- ── Remove (void) a shop's survey — same people as before ──────────────────
drop function if exists public.placement_audit_remove_shop(text, text);
create or replace function public.placement_audit_remove_shop(p_org text, p_customer text, p_reason text default null)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int; v_me text;
begin
  if p_org is null or p_customer is null then return 0; end if;
  if not public._can_delete_intel(p_org) then
    raise exception 'You are not allowed to delete Intelligence items.';
  end if;
  select a.id into v_me from public._acting_user(p_org) a;
  perform set_config('opstation.survey_rpc', '1', true);
  update public.placement_audit
     set voided_at = now(), voided_by = coalesce(v_me, 'super_admin'), void_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where org_id = p_org and customer_id = p_customer and voided_at is null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.placement_audit_remove_shop(text, text, text) from public, anon;
grant execute on function public.placement_audit_remove_shop(text, text, text) to authenticated;

drop function if exists public.competitor_spotting_remove_shop(text, text);
create or replace function public.competitor_spotting_remove_shop(p_org text, p_customer text, p_reason text default null)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int; v_me text;
begin
  if p_org is null or p_customer is null then return 0; end if;
  if not public._can_delete_intel(p_org) then
    raise exception 'You are not allowed to delete Intelligence items.';
  end if;
  select a.id into v_me from public._acting_user(p_org) a;
  perform set_config('opstation.survey_rpc', '1', true);
  update public.competitor_spotting
     set voided_at = now(), voided_by = coalesce(v_me, 'super_admin'), void_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where org_id = p_org and customer_id = p_customer and voided_at is null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.competitor_spotting_remove_shop(text, text, text) from public, anon;
grant execute on function public.competitor_spotting_remove_shop(text, text, text) to authenticated;

-- Permanent delete: super admin only.
create or replace function public.survey_delete_shop(p_org text, p_customer text, p_kind text)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if not public._is_super_admin() then
    raise exception 'Only a super admin can delete survey records permanently.';
  end if;
  if p_kind = 'placement' then
    delete from public.placement_audit where org_id = p_org and customer_id = p_customer;
  elsif p_kind = 'competitor' then
    delete from public.competitor_spotting where org_id = p_org and customer_id = p_customer;
  else
    return 0;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.survey_delete_shop(text, text, text) from public, anon;
grant execute on function public.survey_delete_shop(text, text, text) to authenticated;

-- ── Audits: only through submit_survey_audit ───────────────────────────────
drop policy if exists sa_insert on public.survey_audits;

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
  v_fix jsonb;
  v_corr jsonb := '[]'::jsonb;
  v_has_fixes boolean;
  v_name text; v_from text; v_to text; v_brand text; v_price numeric; v_specs text; v_present boolean;
begin
  if v_org is null or v_id is null or v_cust is null then
    raise exception 'Incomplete audit.';
  end if;
  select u.id, u.name, u.role into v_uid, v_uname, v_role
    from public._acting_user(v_org) a join public.users u on u.id = a.id;
  if v_uid is null or coalesce(v_role, '') <> 'auditor' then
    raise exception 'Only auditors can record survey audits.';
  end if;
  if exists (select 1 from public.survey_audits where id = v_id) then
    return jsonb_build_object('ok', true, 'duplicate', true);   -- already received (retry)
  end if;
  if v_result not in ('ok', 'issue', 'feedback') then
    raise exception 'Unknown audit result.';
  end if;
  if v_result in ('issue', 'feedback') and v_comment is null then
    raise exception 'A comment is required.';
  end if;
  if not exists (select 1 from public.customers where id = v_cust and org_id = v_org) then
    raise exception 'Shop not found.';
  end if;
  v_at := coalesce(nullif(p->>'audited_at', '')::timestamptz, now());
  v_has_fixes := jsonb_typeof(p->'fixes') = 'array' and jsonb_array_length(p->'fixes') > 0;
  if v_has_fixes and v_result <> 'issue' then
    raise exception 'Corrections can only be saved with an Issue.';
  end if;

  perform set_config('opstation.survey_rpc', '1', true);

  if v_has_fixes then
    for v_fix in select value from jsonb_array_elements(p->'fixes') loop
      v_name := null; v_from := null;
      if v_fix->>'type' = 'placement' then
        select name into v_name from public.intelligence_products
         where id = v_fix->>'product_id' and org_id = v_org;
        if v_name is null or v_fix->>'id' is null then continue; end if;
        v_present := coalesce((v_fix->>'is_present')::boolean, false);
        select case when pa.is_present then 'Displayed' else 'Not displayed' end into v_from
          from public.placement_audit pa
         where pa.org_id = v_org and pa.customer_id = v_cust and pa.product_id = v_fix->>'product_id'
           and pa.voided_at is null
         order by pa.surveyed_at desc limit 1;
        insert into public.placement_audit
          (id, org_id, customer_id, product_id, is_present, surveyed_by_user_id, surveyed_at, created_at, source, audit_id)
        values (v_fix->>'id', v_org, v_cust, v_fix->>'product_id', v_present, v_uid, v_at, v_at, 'audit_fix', v_id)
        on conflict (id) do nothing;
        v_corr := v_corr || jsonb_build_array(jsonb_build_object(
          'type', 'placement', 'product_id', v_fix->>'product_id', 'product', v_name,
          'from', v_from, 'to', case when v_present then 'Displayed' else 'Not displayed' end,
          'row_id', v_fix->>'id'));
      elsif v_fix->>'type' = 'competitor' then
        select name into v_name from public.competitor_categories
         where id = v_fix->>'category_id' and org_id = v_org;
        v_brand := nullif(btrim(coalesce(v_fix->>'brand_name', '')), '');
        if v_name is null or v_brand is null or v_fix->>'id' is null then continue; end if;
        v_price := nullif(btrim(coalesce(v_fix->>'price', '')), '')::numeric;
        v_specs := nullif(btrim(coalesce(v_fix->>'specs', '')), '');
        select concat_ws(' · ', nullif(cs.brand_name, ''),
                         case when cs.price is not null then 'Rs ' || cs.price::text end,
                         nullif(cs.specs, '')) into v_from
          from public.competitor_spotting cs
         where cs.org_id = v_org and cs.customer_id = v_cust and cs.category_id = v_fix->>'category_id'
           and cs.voided_at is null
         order by cs.surveyed_at desc limit 1;
        insert into public.competitor_spotting
          (id, org_id, customer_id, category_id, brand_name, price, specs, surveyed_by_user_id, surveyed_at, created_at, source, audit_id)
        values (v_fix->>'id', v_org, v_cust, v_fix->>'category_id', v_brand, v_price, v_specs, v_uid, v_at, v_at, 'audit_fix', v_id)
        on conflict (id) do nothing;
        v_to := concat_ws(' · ', v_brand, case when v_price is not null then 'Rs ' || v_price::text end, v_specs);
        v_corr := v_corr || jsonb_build_array(jsonb_build_object(
          'type', 'competitor', 'category_id', v_fix->>'category_id', 'category', v_name,
          'from', v_from, 'to', v_to, 'row_id', v_fix->>'id'));
      end if;
    end loop;
  end if;

  insert into public.survey_audits
    (id, org_id, customer_id, auditor_id, auditor_name, result, comment, photo_path,
     lat, lng, accuracy_m, distance_m, location_status, survey_at, corrections, audited_at)
  values
    (v_id, v_org, v_cust, v_uid, v_uname, v_result, v_comment, nullif(p->>'photo_path', ''),
     nullif(p->>'lat', '')::double precision, nullif(p->>'lng', '')::double precision,
     nullif(p->>'accuracy_m', '')::double precision, nullif(p->>'distance_m', '')::double precision,
     nullif(p->>'location_status', ''), nullif(p->>'survey_at', '')::timestamptz,
     case when v_has_fixes then v_corr else coalesce(p->'corrections', '[]'::jsonb) end,
     v_at);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.submit_survey_audit(jsonb) from public, anon;
grant execute on function public.submit_survey_audit(jsonb) to authenticated;

-- Super Summary's placement scores: leave voided rows out.
do $$
declare d text;
begin
  if to_regprocedure('public.rpc_org_super_summary__impl(text,date,date)') is null then return; end if;
  d := pg_get_functiondef('public.rpc_org_super_summary__impl(text,date,date)'::regprocedure);
  if position('voided_at' in d) = 0 and position('where pa.org_id = p_org' in d) > 0 then
    execute replace(d, 'where pa.org_id = p_org', 'where pa.org_id = p_org and pa.voided_at is null');
  end if;
end $$;

notify pgrst, 'reload schema';
select 'survey lifecycle ready' as result;
