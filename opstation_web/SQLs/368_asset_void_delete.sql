-- 368 — Void an asset (anyone who works with assets) or delete it for good
-- (Super Admin only).
--   Void: the asset is taken off the list with a reason and stops being a
--         pending item (supervision, rejection, counters). Kept on record.
--   Delete: removes the asset and its history, files list and maintenance log.
-- Either way, if the asset was made from an asset suggestion, that suggestion
-- opens again so the amount isn't lost (create the right asset, or dismiss it).
-- Safe to run again.

alter table public.assets
  add column if not exists voided_at      timestamptz,
  add column if not exists voided_by      text,
  add column if not exists voided_by_name text,
  add column if not exists void_reason    text;

-- Take an asset off any suggestion it was created from.
create or replace function public._asset_unlink_suggestion(p_asset text, p_cost numeric)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  begin
    update public.asset_suggestions
       set asset_ids = array_remove(asset_ids, p_asset),
           assets_cost = greatest(0, assets_cost - coalesce(p_cost, 0)),
           status = case when status = 'done' then 'pending' else status end,
           decided_at = case when status = 'done' then null else decided_at end,
           decided_by_name = case when status = 'done' then null else decided_by_name end,
           updated_at = now()
     where p_asset = any (asset_ids);
  exception when undefined_table then null;   -- suggestions not set up
  end;
end $$;

create or replace function public.void_asset(p_id text, p_reason text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare a public.assets%rowtype; v_reason text; v_uid text; v_name text;
begin
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then raise exception 'Please give a reason.' using errcode = 'P0001'; end if;
  select * into a from public.assets where id = p_id for update;
  if not found then raise exception 'Asset not found.' using errcode = 'P0001'; end if;
  if not (public._is_org_member(a.org_id) or public._is_super_admin()) then
    raise exception 'Not allowed.' using errcode = 'P0001';
  end if;
  if not coalesce(a.is_active, true) then raise exception 'This asset is already voided.' using errcode = 'P0001'; end if;

  select u.id, u.name into v_uid, v_name from public.users u
   where u.org_id = a.org_id
     and (u.account_id = public.current_account_id()
          or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
   limit 1;
  if v_name is null and public._is_super_admin() then v_name := 'Opstation Admin'; end if;

  update public.assets
     set is_active = false, voided_at = now(), voided_by = v_uid,
         voided_by_name = v_name, void_reason = v_reason
   where id = p_id;

  perform public._asset_unlink_suggestion(p_id, a.purchase_cost);
end $$;

create or replace function public.delete_asset(p_id text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare a public.assets%rowtype;
begin
  if not public._is_super_admin() then
    raise exception 'Only Opstation Super Admin can delete an asset. Void it instead.' using errcode = 'P0001';
  end if;
  select * into a from public.assets where id = p_id for update;
  if not found then raise exception 'Asset not found.' using errcode = 'P0001'; end if;

  perform public._asset_unlink_suggestion(p_id, a.purchase_cost);
  begin delete from public.asset_files       where asset_id = p_id; exception when undefined_table then null; end;
  begin delete from public.asset_maintenance where asset_id = p_id; exception when undefined_table then null; end;
  begin delete from public.asset_assignments where asset_id = p_id; exception when undefined_table then null; end;
  delete from public.assets where id = p_id;
end $$;

revoke all on function public._asset_unlink_suggestion(text, numeric) from public, anon, authenticated;
revoke all on function public.void_asset(text, text) from public, anon;
revoke all on function public.delete_asset(text) from public, anon;
grant execute on function public.void_asset(text, text) to authenticated;
grant execute on function public.delete_asset(text) to authenticated;
