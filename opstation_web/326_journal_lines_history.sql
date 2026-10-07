-- 326 — Journal line history: every time journal lines are deleted (which is
-- what happens on each JV / Opening JV save — old lines are replaced), keep a
-- full copy of the old lines. Lets us undo a bad re-save in one step.
-- Safe to run again.

create table if not exists public.journal_lines_history (
  hist_id      bigint generated always as identity primary key,
  entry_id     text,
  org_id       text,
  entry_number text,
  line         jsonb not null,          -- the complete old line, as it was
  removed_at   timestamptz not null default now(),
  removed_by   uuid default auth.uid()
);
create index if not exists jlh_entry_idx on public.journal_lines_history(entry_id, removed_at desc);
create index if not exists jlh_org_idx   on public.journal_lines_history(org_id, removed_at desc);

alter table public.journal_lines_history enable row level security;
drop policy if exists jlh_read on public.journal_lines_history;
create policy jlh_read on public.journal_lines_history
  for select using (public._is_org_member(org_id));

create or replace function public._jl_keep_history()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  insert into journal_lines_history(entry_id, org_id, entry_number, line)
  select o.entry_id, o.org_id, e.entry_number, to_jsonb(o)
    from old_rows o
    left join journal_entries e on e.id = o.entry_id;
  return null;
end $$;

drop trigger if exists trg_jl_keep_history on public.journal_lines;
create trigger trg_jl_keep_history
  after delete on public.journal_lines
  referencing old table as old_rows
  for each statement execute function public._jl_keep_history();
