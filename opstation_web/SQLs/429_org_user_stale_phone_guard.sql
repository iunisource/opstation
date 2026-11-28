-- 429 — Old phones must not overwrite the organisation or users.
-- The field app re-sent its stored copy of the org (name, owner, active) and
-- of every user on each sync, which put back old values (e.g. an org rename).
-- Safe to run again.

-- Orgs: only a super admin can change name / owner / active state directly.
create or replace function public.trg_org_stale_guard()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if current_user in ('authenticated', 'anon') and not public._is_super_admin() then
    NEW.name            := OLD.name;
    NEW.master_admin_id := OLD.master_admin_id;
    NEW.is_active       := OLD.is_active;
    NEW.created_at      := OLD.created_at;
  end if;
  return NEW;
end $$;
drop trigger if exists a0_org_stale_guard on public.orgs;
create trigger a0_org_stale_guard before update on public.orgs
  for each row execute function public.trg_org_stale_guard();

-- Users: an update carrying an older "updated" time than the server's is an
-- old copy — ignore it.
create or replace function public.trg_user_stale_guard()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if current_user in ('authenticated', 'anon')
     and OLD.updated_at is not null and NEW.updated_at is not null
     and NEW.updated_at < OLD.updated_at then
    return null;
  end if;
  return NEW;
end $$;
drop trigger if exists a0_user_stale_guard on public.users;
create trigger a0_user_stale_guard before update on public.users
  for each row execute function public.trg_user_stale_guard();

-- Put the name back.
update public.orgs set name = 'Unisource Lahore'
 where id = 'org_1784655141655' and name = 'Unisource'
returning id, name;
