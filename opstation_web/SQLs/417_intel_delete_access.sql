-- 417 — Who can delete Intelligence items (placement surveys, competitor
-- spottings). Master admins always. With Admin Settings → "Users can delete
-- Intelligence items" ON (org.intel_delete_access), also the users picked
-- there (org.intel_delete_users). Plain admins only if picked. Safe to run again.

create or replace function public._can_delete_intel(p_org text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_id text; v_list text;
begin
  if p_org is null then return false; end if;
  if public._is_super_admin() then return true; end if;
  if exists (select 1 from public.users u
              where u.org_id = p_org and u.role in ('masterAdmin', 'superAdmin')
                and coalesce(u.is_active, true)
                and (u.account_id = public.current_account_id()
                     or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))) then
    return true;
  end if;
  if not public._cfg_true(p_org, 'org.intel_delete_access') then return false; end if;
  select a.id into v_id from public._acting_user(p_org) a;
  if v_id is null then return false; end if;
  v_list := (select value from public.app_config where org_id = p_org and key = 'org.intel_delete_users' limit 1);
  return v_id = any (string_to_array(replace(coalesce(v_list, ''), ' ', ''), ','));
end $$;
revoke execute on function public._can_delete_intel(text) from public, anon;
grant execute on function public._can_delete_intel(text) to authenticated;

create or replace function public.placement_audit_remove_shop(p_org text, p_customer text)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if p_org is null or p_customer is null then return 0; end if;
  if not public._can_delete_intel(p_org) then
    raise exception 'You are not allowed to delete Intelligence items.';
  end if;
  delete from public.placement_audit where org_id = p_org and customer_id = p_customer;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.placement_audit_remove_shop(text, text) from public, anon;
grant execute on function public.placement_audit_remove_shop(text, text) to authenticated;

create or replace function public.competitor_spotting_remove_shop(p_org text, p_customer text)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if p_org is null or p_customer is null then return 0; end if;
  if not public._can_delete_intel(p_org) then
    raise exception 'You are not allowed to delete Intelligence items.';
  end if;
  delete from public.competitor_spotting where org_id = p_org and customer_id = p_customer;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.competitor_spotting_remove_shop(text, text) from public, anon;
grant execute on function public.competitor_spotting_remove_shop(text, text) to authenticated;

notify pgrst, 'reload schema';
select 'intelligence delete access ready' as status;
