-- 359 — One owner per route, with easy hand-over.
-- A route belongs to ONE salesperson at a time. Assigning it to someone else
-- (e.g. covering for an absent colleague) MOVES it: the previous owner is
-- removed in the same step, and the hand-over is logged.
--   1) route_assignment_log — who held which route, when, and who moved it
--   2) Clean-up of today's double assignments: the MOST RECENT assignment keeps
--      the route (that is the current cover), older ones are removed & logged
--   3) Trigger: assigning a route takes it from its current owner
--   4) Unique rule: a route can never have two owners again
-- Safe to run again.

create table if not exists public.route_assignment_log (
  id          bigserial primary key,
  org_id      text,
  route_id    text not null,
  route_name  text,
  from_user   text,
  from_name   text,
  to_user     text,
  to_name     text,
  changed_by  text,
  changed_at  timestamptz default now(),
  note        text
);
alter table public.route_assignment_log enable row level security;
drop policy if exists route_assignment_log_read on public.route_assignment_log;
create policy route_assignment_log_read on public.route_assignment_log
  for select to authenticated using (public._is_org_member(org_id));

-- ── 2) Clean up double assignments (keep the most recent) ───────────────────
with ranked as (
  select a.ctid as rid, a.route_id, a.user_id, a.assigned_at,
         row_number() over (partition by a.route_id
                            order by a.assigned_at desc nulls last, a.user_id) as rn
    from public.route_assignments a
),
keep as (select route_id, user_id from ranked where rn = 1),
gone as (
  delete from public.route_assignments a
   using ranked r
   where a.ctid = r.rid and r.rn > 1
  returning a.route_id, a.user_id
)
insert into public.route_assignment_log (org_id, route_id, route_name, from_user, from_name, to_user, to_name, note)
select sr.org_id, g.route_id, sr.name, g.user_id, uf.name, k.user_id, ut.name,
       'Clean-up: route had two owners — kept the most recent assignment'
  from gone g
  join keep k on k.route_id = g.route_id
  left join public.sales_routes sr on sr.id = g.route_id
  left join public.users uf on uf.id = g.user_id
  left join public.users ut on ut.id = k.user_id;

-- ── 3) Assigning a route moves it from its current owner ────────────────────
create or replace function public.trg_route_single_owner()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare r record; v_route text; v_org text; v_to text;
begin
  -- Re-assigning to the same person: nothing to do.
  if exists (select 1 from public.route_assignments where route_id = NEW.route_id and user_id = NEW.user_id) then
    return null;
  end if;
  select name, org_id into v_route, v_org from public.sales_routes where id = NEW.route_id;
  select name into v_to from public.users where id = NEW.user_id;
  for r in
    delete from public.route_assignments
     where route_id = NEW.route_id and user_id is distinct from NEW.user_id
    returning user_id
  loop
    insert into public.route_assignment_log (org_id, route_id, route_name, from_user, from_name, to_user, to_name, changed_by, note)
    values (v_org, NEW.route_id, v_route, r.user_id, (select name from public.users where id = r.user_id),
            NEW.user_id, v_to, NEW.assigned_by, 'Handed over');
  end loop;
  if not found then
    insert into public.route_assignment_log (org_id, route_id, route_name, to_user, to_name, changed_by, note)
    values (v_org, NEW.route_id, v_route, NEW.user_id, v_to, NEW.assigned_by, 'Assigned');
  end if;
  return NEW;
end $$;

drop trigger if exists aa_route_single_owner on public.route_assignments;
create trigger aa_route_single_owner before insert on public.route_assignments
  for each row execute function public.trg_route_single_owner();

-- Un-assigning is logged too.
create or replace function public.trg_route_unassign_log()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  -- Skip deletes done by the hand-over trigger above (already logged).
  if pg_trigger_depth() > 1 then return OLD; end if;
  insert into public.route_assignment_log (org_id, route_id, route_name, from_user, from_name, note)
  select sr.org_id, OLD.route_id, sr.name, OLD.user_id, u.name, 'Unassigned'
    from public.sales_routes sr left join public.users u on u.id = OLD.user_id
   where sr.id = OLD.route_id;
  return OLD;
exception when others then
  return OLD;
end $$;

drop trigger if exists zz_route_unassign_log on public.route_assignments;
create trigger zz_route_unassign_log after delete on public.route_assignments
  for each row execute function public.trg_route_unassign_log();

-- ── 4) Never two owners again ───────────────────────────────────────────────
create unique index if not exists ux_route_assignments_one_owner
  on public.route_assignments(route_id);

-- Result: what the clean-up did
select route_name, from_name as removed, to_name as kept, changed_at
  from public.route_assignment_log
 where note like 'Clean-up%'
 order by changed_at desc, route_name;
