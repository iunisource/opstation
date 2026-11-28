-- 446 — Auditors limited to customer groups.
--
-- Admin Settings → "Limit auditors to customer groups" (org.auditor_group_scope).
-- When ON, each auditor can be given customer groups (Customers → Group, e.g.
-- Paklite, Popular). The auditor then sees and audits only shops in those
-- groups — surveyed or not. An auditor with no group ticked sees all shops.
-- Run after 444. Safe to run again.

create table if not exists public.auditor_customer_groups (
  org_id text not null,
  user_id text not null,
  group_name text not null,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id, group_name)
);
alter table public.auditor_customer_groups enable row level security;
drop policy if exists acg_select on public.auditor_customer_groups;
create policy acg_select on public.auditor_customer_groups for select to authenticated
  using (public._is_org_member(org_id) or public._is_super_admin());
drop policy if exists acg_insert on public.auditor_customer_groups;
create policy acg_insert on public.auditor_customer_groups for insert to authenticated
  with check (public._is_org_admin(org_id) or public._is_super_admin());
drop policy if exists acg_delete on public.auditor_customer_groups;
create policy acg_delete on public.auditor_customer_groups for delete to authenticated
  using (public._is_org_admin(org_id) or public._is_super_admin());

-- An auditor's groups (lower-case, trimmed); null = not limited.
create or replace function public._auditor_groups(p_org text, p_user text)
returns text[] language sql stable security definer set search_path to 'public' as $$
  select case when not public._cfg_true(p_org, 'org.auditor_group_scope') then null
              else (select array_agg(distinct lower(btrim(g.group_name)))
                      from public.auditor_customer_groups g
                     where g.org_id = p_org and g.user_id = p_user and btrim(g.group_name) <> '') end;
$$;

create or replace function public._auditor_shop_allowed(p_org text, p_user text, p_cust text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_groups text[] := public._auditor_groups(p_org, p_user);
begin
  if v_groups is null then return true; end if;
  return exists (select 1 from public.customers c
                  where c.id = p_cust and c.org_id = p_org
                    and lower(btrim(coalesce(c.group_name, ''))) = any (v_groups));
end $$;

create or replace function public.my_audit_permissions(p_org text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_id text; v_role text;
begin
  select u.id, u.role into v_id, v_role from public._acting_user(p_org) a join public.users u on u.id = a.id;
  return jsonb_build_object(
    'is_auditor', coalesce(v_role, '') = 'auditor',
    'can_fix', coalesce(v_role, '') = 'auditor' and public._audit_fix_allowed(p_org, v_id),
    'needs_approval', public._cfg_true(p_org, 'org.audit_fix_approval'),
    'can_approve', public._can_approve_audit_fix(p_org),
    'groups', case when coalesce(v_role, '') = 'auditor' then to_jsonb(public._auditor_groups(p_org, v_id)) end);
end $$;
revoke execute on function public.my_audit_permissions(text) from public, anon;
grant execute on function public.my_audit_permissions(text) to authenticated;

-- ── Submit an audit (444's version + the group check) ─────────────────────
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
  if not public._auditor_shop_allowed(v_org, v_uid, v_cust) then
    raise exception 'This shop is not in your customer groups.';
  end if;
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

notify pgrst, 'reload schema';
select 'auditor customer groups ready' as result;
