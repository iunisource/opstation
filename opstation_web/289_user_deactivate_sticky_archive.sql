-- 289 — Users: deactivation is sticky + archive.
--
-- Problem: deactivated users came back "Active" on their own. Anything that
-- re-saved a user row (older mobile-app versions re-uploading their cached
-- copy on sync, user-creation functions upserting, etc.) wrote is_active=true
-- back over an admin's deactivation.
--
-- Fix: a guard trigger. Once a user is inactive (or archived), a plain UPDATE
-- or upsert can no longer flip them back. Only the admin actions below
-- (Activate / Unarchive in the Users screens) can restore them.

alter table if exists public.users
  add column if not exists deactivated_at timestamptz,
  add column if not exists deactivated_by text,
  add column if not exists is_archived    boolean not null default false,
  add column if not exists archived_at    timestamptz,
  add column if not exists archived_by    text;

-- ── guard ────────────────────────────────────────────────────────────────
create or replace function public.trg_users_sticky_status()
returns trigger
language plpgsql
as $function$
declare
  v_allowed boolean := coalesce(current_setting('opstation.user_status_change', true), '') = 'on';
begin
  if not v_allowed then
    -- Inactive stays inactive unless restored through set_user_active().
    if coalesce(OLD.is_active, true) = false and coalesce(NEW.is_active, true) = true then
      NEW.is_active := false;
    end if;
    -- Archived stays archived unless restored through set_user_archived().
    if coalesce(OLD.is_archived, false) = true and coalesce(NEW.is_archived, false) = false then
      NEW.is_archived := true;
    end if;
    NEW.deactivated_at := OLD.deactivated_at;
    NEW.deactivated_by := OLD.deactivated_by;
    NEW.archived_at    := OLD.archived_at;
    NEW.archived_by    := OLD.archived_by;
  end if;
  return NEW;
end $function$;

drop trigger if exists users_sticky_status on public.users;
create trigger users_sticky_status
  before update on public.users
  for each row execute function public.trg_users_sticky_status();

-- ── caller must be an admin of the target user's org ─────────────────────
create or replace function public._can_manage_user(p_user text)
returns boolean
language sql stable security definer set search_path to 'public'
as $function$
  select exists (
    select 1
      from public.users t
      join public.users me
        on me.account_id = public.current_account_id()
       and (me.org_id = t.org_id or me.role = 'superAdmin')
     where t.id = p_user
       and me.role in ('admin', 'masterAdmin', 'superAdmin')
       and coalesce(me.is_active, true) = true
  );
$function$;

-- ── Activate / Deactivate ────────────────────────────────────────────────
create or replace function public.set_user_active(p_user text, p_active boolean)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public._can_manage_user(p_user) then
    raise exception 'Only an admin of this organization can change a user''s status.' using errcode = 'P0001';
  end if;
  perform set_config('opstation.user_status_change', 'on', true);
  update public.users
     set is_active      = p_active,
         deactivated_at = case when p_active then null else now() end,
         deactivated_by = case when p_active then null else public.current_account_id() end,
         -- Activating an archived user brings them back fully.
         is_archived    = case when p_active then false else is_archived end,
         archived_at    = case when p_active then null else archived_at end,
         archived_by    = case when p_active then null else archived_by end,
         updated_at     = now()
   where id = p_user;
end $function$;

-- ── Archive / Unarchive (archive also deactivates) ───────────────────────
create or replace function public.set_user_archived(p_user text, p_archived boolean)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public._can_manage_user(p_user) then
    raise exception 'Only an admin of this organization can archive a user.' using errcode = 'P0001';
  end if;
  perform set_config('opstation.user_status_change', 'on', true);
  if p_archived then
    update public.users
       set is_archived    = true,
           archived_at    = now(),
           archived_by    = public.current_account_id(),
           is_active      = false,
           deactivated_at = coalesce(deactivated_at, now()),
           deactivated_by = coalesce(deactivated_by, public.current_account_id()),
           updated_at     = now()
     where id = p_user;
  else
    -- Unarchive only brings the user back into the list; they stay inactive
    -- until an admin activates them.
    update public.users
       set is_archived = false, archived_at = null, archived_by = null,
           updated_at  = now()
     where id = p_user;
  end if;
end $function$;

grant execute on function public.set_user_active(text, boolean)   to authenticated;
grant execute on function public.set_user_archived(text, boolean) to authenticated;

-- Who is currently inactive (for a quick check after running this):
select name, email, role, is_active, is_archived
  from public.users
 where coalesce(is_active, true) = false
 order by name;
