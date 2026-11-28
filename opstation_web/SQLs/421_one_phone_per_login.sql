-- 421 — One phone per login runs the routes.
-- Signing in on a phone makes it the login's route phone and moves any open
-- route to it. Trip uploads from any other phone with the same login are then
-- ignored (older app versions don't send a phone id and are not affected).
-- Safe to run again.

alter table public.users add column if not exists active_device_id text;
alter table public.users add column if not exists active_device_at timestamptz;
alter table public.trips add column if not exists device_id text;

-- The signed-in person's users rows (one per organisation they belong to).
create or replace function public._my_user_ids()
returns text[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(u.id), '{}') from public.users u
   where coalesce(u.is_active, true)
     and (u.account_id = public.current_account_id()
          or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

create or replace function public.claim_trip_device(p_device text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_ids text[] := public._my_user_ids();
begin
  if coalesce(p_device, '') = '' or coalesce(array_length(v_ids, 1), 0) = 0 then return; end if;
  update public.users set active_device_id = p_device, active_device_at = now()
   where id = any (v_ids);
  perform set_config('opstation.device_claim', '1', true);
  update public.trips set device_id = p_device
   where user_id = any (v_ids) and ended_at is null;
  perform set_config('opstation.device_claim', '', true);
end $$;
revoke execute on function public.claim_trip_device(text) from public, anon;
grant execute on function public.claim_trip_device(text) to authenticated;

create or replace function public.my_trip_device()
returns text language sql stable security definer set search_path to 'public' as $$
  select u.active_device_id from public.users u
   where u.id = any (public._my_user_ids()) and u.active_device_id is not null
   order by u.active_device_at desc nulls last
   limit 1;
$$;
revoke execute on function public.my_trip_device() from public, anon;
grant execute on function public.my_trip_device() to authenticated;

-- A trip belongs to the phone that runs it: an upload from another phone of
-- the same login is ignored (kept as it is).
create or replace function public.trg_trip_device_owner()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('opstation.device_claim', true), '') = '1' then
    return NEW;
  end if;
  if OLD.device_id is not null and NEW.device_id is not null
     and NEW.device_id <> OLD.device_id then
    return OLD;
  end if;
  if NEW.device_id is null then NEW.device_id := OLD.device_id; end if;
  return NEW;
end $$;

drop trigger if exists trip_a0_device_owner on public.trips;
create trigger trip_a0_device_owner before update on public.trips
  for each row execute function public.trg_trip_device_owner();

notify pgrst, 'reload schema';
select 'one phone per login ready' as status;
