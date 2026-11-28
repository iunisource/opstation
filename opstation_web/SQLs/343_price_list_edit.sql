-- 343 — Saved price lists / cost sheets can be edited and updated.
-- • updated_at / updated_by / edit_count on the saved list
-- • every update keeps the previous version in price_list_snapshot_history
--   (name, notes, settings, lines — exactly as they were), with who replaced it
-- Safe to run again.

set lock_timeout = '5s';

alter table public.price_list_snapshots
  add column if not exists updated_at      timestamptz,
  add column if not exists updated_by      text,
  add column if not exists updated_by_name text,
  add column if not exists edit_count      int not null default 0;

create table if not exists public.price_list_snapshot_history (
  id              bigserial primary key,
  snapshot_id     text not null,
  org_id          text not null,
  version         jsonb not null,          -- the previous saved copy, as it was
  replaced_at     timestamptz not null default now(),
  replaced_by     text,
  replaced_by_name text
);
create index if not exists idx_plsh_snap on public.price_list_snapshot_history(snapshot_id, replaced_at desc);

alter table public.price_list_snapshot_history enable row level security;
drop policy if exists plsh_read on public.price_list_snapshot_history;
create policy plsh_read on public.price_list_snapshot_history
  for select to authenticated using (public._is_org_member(org_id));
grant select on public.price_list_snapshot_history to authenticated;

create or replace function public._pls_keep_version()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if (new.lines, new.settings, new.name, new.notes, new.title)
     is distinct from (old.lines, old.settings, old.name, old.notes, old.title) then
    insert into price_list_snapshot_history(snapshot_id, org_id, version, replaced_by, replaced_by_name)
    values (old.id, old.org_id,
            jsonb_build_object('title', old.title, 'name', old.name, 'notes', old.notes,
                               'settings', old.settings, 'lines', old.lines,
                               'item_count', old.item_count, 'edited_count', old.edited_count,
                               'saved_at', coalesce(old.updated_at, old.created_at),
                               'saved_by_name', coalesce(old.updated_by_name, old.created_by_name)),
            new.updated_by, new.updated_by_name);
    new.edit_count := coalesce(old.edit_count, 0) + 1;
    new.updated_at := coalesce(new.updated_at, now());
  end if;
  return new;
end $$;

drop trigger if exists trg_pls_keep_version on public.price_list_snapshots;
create trigger trg_pls_keep_version before update on public.price_list_snapshots
  for each row execute function public._pls_keep_version();

reset lock_timeout;

select count(*) as saved_lists from public.price_list_snapshots;
