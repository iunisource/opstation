-- 406 — Duplicate reference log (Financials → Duplicate References).
-- Every time the "reference number already used" warning comes up on a CRV / CPV,
-- it is recorded here with what matched and what the user chose. A supervisor
-- reviews it; supervised events move to the archive.
--   org.dupref_supervise_flow  = 'true' → only admins + org.dupref_supervisor_users
--                                         can supervise, and a pending counter shows
--   off                                  → anyone with the page can supervise
-- Safe to run again.

create table if not exists public.duplicate_ref_events (
  id                 text primary key default 'dre_' || replace(gen_random_uuid()::text, '-', ''),
  org_id             text not null,
  branch_id          text,
  voucher_type       text not null,                 -- CRV | CPV
  voucher_id         text,                          -- set once the voucher is saved
  voucher_number     text,
  refs               text[] not null default '{}',
  matches            jsonb not null default '[]',   -- the other vouchers shown in the warning
  outcome            text not null default 'shown', -- shown | saved_anyway | went_back
  raised_by          text,
  raised_by_name     text,
  raised_at          timestamptz not null default now(),
  supervised_at      timestamptz,
  supervised_by      text,
  supervised_by_name text,
  supervise_note     text
);
create index if not exists duplicate_ref_events_org_idx on public.duplicate_ref_events (org_id, supervised_at, raised_at desc);

alter table public.duplicate_ref_events enable row level security;
drop policy if exists dre_read on public.duplicate_ref_events;
create policy dre_read on public.duplicate_ref_events for select to authenticated
  using (public._is_org_member(org_id));
grant select on public.duplicate_ref_events to authenticated;
-- All writes go through the functions below.

create or replace function public._can_supervise_duprefs(p_org text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_id text; v_role text; v_list text;
begin
  if not public._is_org_member(p_org) then return false; end if;
  if not public._cfg_true(p_org, 'org.dupref_supervise_flow') then return true; end if;  -- flow off: anyone with the page
  select u.id, u.role into v_id, v_role from public._acting_user(p_org) a join public.users u on u.id = a.id;
  if v_id is null then return false; end if;
  if v_role in ('admin', 'masterAdmin', 'superAdmin') then return true; end if;
  v_list := (select value from public.app_config where org_id = p_org and key = 'org.dupref_supervisor_users' limit 1);
  return v_id = any (string_to_array(replace(coalesce(v_list, ''), ' ', ''), ','));
end $$;
grant execute on function public._can_supervise_duprefs(text) to authenticated;

create or replace function public.dup_ref_event_log(
  p_org_id text, p_branch_id text, p_type text, p_voucher_id text, p_voucher_number text,
  p_refs text[], p_matches jsonb)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_id text; v_uid text; v_uname text;
begin
  if not public._is_org_member(p_org_id) then raise exception 'You do not have access to this organisation.'; end if;
  select a.id, a.name into v_uid, v_uname from public._acting_user(p_org_id) a;
  insert into public.duplicate_ref_events (org_id, branch_id, voucher_type, voucher_id, voucher_number, refs, matches,
                                           raised_by, raised_by_name)
  values (p_org_id, nullif(p_branch_id, ''), upper(p_type), p_voucher_id, p_voucher_number,
          coalesce(p_refs, '{}'), coalesce(p_matches, '[]'::jsonb), v_uid, v_uname)
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.dup_ref_event_log(text, text, text, text, text, text[], jsonb) to authenticated;

-- The user's choice, and the voucher once it is saved. Only by whoever raised it.
create or replace function public.dup_ref_event_set(
  p_id text, p_outcome text default null, p_voucher_id text default null, p_voucher_number text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare e record; v_uid text;
begin
  select * into e from public.duplicate_ref_events where id = p_id;
  if not found then return; end if;
  if not public._is_org_member(e.org_id) then raise exception 'You do not have access to this organisation.'; end if;
  select a.id into v_uid from public._acting_user(e.org_id) a;
  if e.raised_by is distinct from v_uid or e.supervised_at is not null then return; end if;
  update public.duplicate_ref_events
     set outcome        = coalesce(case when p_outcome in ('saved_anyway', 'went_back') then p_outcome end, outcome),
         voucher_id     = coalesce(p_voucher_id, voucher_id),
         voucher_number = coalesce(p_voucher_number, voucher_number)
   where id = p_id;
end $$;
grant execute on function public.dup_ref_event_set(text, text, text, text) to authenticated;

create or replace function public.dup_ref_event_supervise(p_ids text[], p_note text default null)
returns int language plpgsql security definer set search_path to 'public' as $$
declare v_org text; v_uid text; v_uname text; n int;
begin
  select org_id into v_org from public.duplicate_ref_events where id = any (p_ids) limit 1;
  if v_org is null then return 0; end if;
  if not public._can_supervise_duprefs(v_org) then
    raise exception 'You are not allowed to supervise duplicate references.';
  end if;
  select a.id, a.name into v_uid, v_uname from public._acting_user(v_org) a;
  update public.duplicate_ref_events
     set supervised_at = now(), supervised_by = v_uid, supervised_by_name = v_uname,
         supervise_note = nullif(trim(coalesce(p_note, '')), '')
   where id = any (p_ids) and org_id = v_org and supervised_at is null;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.dup_ref_event_supervise(text[], text) to authenticated;

notify pgrst, 'reload schema';
select count(*) as events from public.duplicate_ref_events;
