-- 345 — Route Roster: Standing roster + change history
-- • route_roster_standing: the "Standing" roster type — one plan per salesperson
--   per weekday (Mon…Sun), no dates, valid until changed.
-- • route_roster_log: every change to either roster type (who, when, which
--   salesperson / day, routes and note before → after), written by triggers so
--   nothing can skip it. Shown under Route Roster ▸ History.
-- Safe to run again.

set lock_timeout = '5s';

create table if not exists public.route_roster_standing (
  org_id          text not null,
  user_id         text not null,
  weekday         int  not null check (weekday between 1 and 7),   -- 1 = Monday … 7 = Sunday
  route_ids       text[] not null default '{}',
  note            text,
  updated_at      timestamptz not null default now(),
  updated_by      text,
  updated_by_name text,
  primary key (org_id, user_id, weekday)
);

alter table public.route_roster_standing enable row level security;
drop policy if exists rrs_org_rw on public.route_roster_standing;
create policy rrs_org_rw on public.route_roster_standing
  for all to authenticated
  using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));
grant select, insert, update, delete on public.route_roster_standing to authenticated;

create table if not exists public.route_roster_log (
  id              bigserial primary key,
  org_id          text not null,
  kind            text not null,            -- dated | standing | setting
  action          text not null,            -- set | cleared | setting
  user_id         text,                     -- salesperson
  day             date,                     -- dated roster
  weekday         int,                      -- standing roster
  old_routes      text[],
  new_routes      text[],
  old_note        text,
  new_note        text,
  detail          text,                     -- setting changes
  changed_at      timestamptz not null default now(),
  changed_by      text,
  changed_by_name text
);
create index if not exists idx_rrl_org on public.route_roster_log(org_id, changed_at desc);

alter table public.route_roster_log enable row level security;
drop policy if exists rrl_read on public.route_roster_log;
create policy rrl_read on public.route_roster_log
  for select to authenticated using (public._is_org_member(org_id));
-- the app logs setting changes (roster type, auto-carry) itself
drop policy if exists rrl_insert_setting on public.route_roster_log;
create policy rrl_insert_setting on public.route_roster_log
  for insert to authenticated with check (public._is_org_member(org_id) and kind = 'setting');
grant select, insert on public.route_roster_log to authenticated;
grant usage on sequence public.route_roster_log_id_seq to authenticated;

create or replace function public._rr_log()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  r record;
  v_uid text; v_name text;
  v_kind text := case when TG_TABLE_NAME = 'route_roster_standing' then 'standing' else 'dated' end;
begin
  begin
    r := coalesce(NEW, OLD);
    if TG_OP = 'DELETE' then
      select u.id, u.name into v_uid, v_name
        from users u
       where u.org_id = OLD.org_id
         and (u.account_id = public.current_account_id()
              or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
       limit 1;
    else
      v_uid := NEW.updated_by; v_name := NEW.updated_by_name;
    end if;
    if TG_OP = 'UPDATE' and NEW.route_ids is not distinct from OLD.route_ids
       and coalesce(NEW.note, '') = coalesce(OLD.note, '') then
      return NEW;
    end if;
    insert into route_roster_log(org_id, kind, action, user_id, day, weekday,
                                 old_routes, new_routes, old_note, new_note, changed_by, changed_by_name)
    values (r.org_id, v_kind,
            case when TG_OP = 'DELETE'
                   or (cardinality(NEW.route_ids) = 0 and coalesce(NEW.note, '') = '') then 'cleared' else 'set' end,
            r.user_id,
            case when v_kind = 'dated' then (to_jsonb(r) ->> 'day')::date end,
            case when v_kind = 'standing' then (to_jsonb(r) ->> 'weekday')::int end,
            case when TG_OP <> 'INSERT' then OLD.route_ids end,
            case when TG_OP <> 'DELETE' then NEW.route_ids end,
            case when TG_OP <> 'INSERT' then OLD.note end,
            case when TG_OP <> 'DELETE' then NEW.note end,
            v_uid, coalesce(v_name, case when auth.uid() is null then 'System' end));
  exception when others then
    null; -- never block a roster save
  end;
  return coalesce(NEW, OLD);
end $$;

drop trigger if exists trg_rr_log on public.route_roster;
create trigger trg_rr_log after insert or update or delete on public.route_roster
  for each row execute function public._rr_log();
drop trigger if exists trg_rrs_log on public.route_roster_standing;
create trigger trg_rrs_log after insert or update or delete on public.route_roster_standing
  for each row execute function public._rr_log();

reset lock_timeout;

select (select count(*) from public.route_roster) as dated_cells,
       (select count(*) from public.route_roster_standing) as standing_cells,
       (select count(*) from public.route_roster_log) as log_rows;
