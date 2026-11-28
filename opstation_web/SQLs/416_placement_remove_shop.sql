-- 416 — Remove a shop's Placement Audit survey (admins only). Deletes every
-- survey row for that shop in the organisation, so it drops off the report
-- until it is surveyed again. Phones drop their copy on the next refresh.
-- Safe to run again.

create or replace function public.placement_audit_remove_shop(p_org text, p_customer text)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if p_org is null or p_customer is null then return 0; end if;
  if not (public._is_org_admin(p_org) or public._is_super_admin()) then
    raise exception 'Only admins can remove a survey.';
  end if;
  delete from public.placement_audit where org_id = p_org and customer_id = p_customer;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.placement_audit_remove_shop(text, text) from public, anon;
grant execute on function public.placement_audit_remove_shop(text, text) to authenticated;

notify pgrst, 'reload schema';
select 'placement_audit_remove_shop ready' as status;
