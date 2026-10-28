-- 431 — Admins can delete quotations (with their lines). Safe to run again.
create or replace function public.delete_quotation(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_org text;
begin
  select org_id into v_org from public.quotations where id = p_id;
  if v_org is null then return; end if;
  if not public._is_org_admin(v_org) then
    raise exception 'Only an admin can delete a quotation.';
  end if;
  delete from public.quotation_items where quotation_id = p_id;
  delete from public.quotations where id = p_id;
end $$;
revoke all on function public.delete_quotation(text) from public, anon;
grant execute on function public.delete_quotation(text) to authenticated;
notify pgrst, 'reload schema';
select 'quotation delete ready' as result;

-- Quotation lifecycle: every step (created, edited, printed, status change,
-- exported, deleted) with who and when. Kept even after a quotation is deleted.
create table if not exists public.quotation_events (
  id             text primary key default ('qe_' || replace(gen_random_uuid()::text, '-', '')),
  org_id         text not null,
  quotation_id   text not null,
  voucher_number text,
  event          text not null,
  detail         text,
  by_id          text,
  by_name        text,
  at             timestamptz not null default now()
);
create index if not exists quotation_events_q_idx on public.quotation_events (quotation_id, at);
alter table public.quotation_events enable row level security;
drop policy if exists qe_read on public.quotation_events;
create policy qe_read on public.quotation_events for select
  using (public._is_org_member(org_id) or public._is_super_admin());
drop policy if exists qe_add on public.quotation_events;
create policy qe_add on public.quotation_events for insert
  with check (public._is_org_member(org_id));
grant select, insert on public.quotation_events to authenticated;

-- Delete now also records who deleted it.
create or replace function public.delete_quotation(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare q record; v_uid text; v_uname text;
begin
  select id, org_id, voucher_number, status into q from public.quotations where id = p_id;
  if q.id is null then return; end if;
  if not public._is_org_admin(q.org_id) then
    raise exception 'Only an admin can delete a quotation.';
  end if;
  select id, name into v_uid, v_uname from public._acting_user(q.org_id);
  insert into public.quotation_events (org_id, quotation_id, voucher_number, event, detail, by_id, by_name)
  values (q.org_id, q.id, q.voucher_number, 'deleted', 'Status was ' || coalesce(q.status, 'saved'), v_uid, v_uname);
  delete from public.quotation_items where quotation_id = p_id;
  delete from public.quotations where id = p_id;
end $$;
revoke all on function public.delete_quotation(text) from public, anon;
grant execute on function public.delete_quotation(text) to authenticated;
notify pgrst, 'reload schema';
select 'quotation lifecycle ready' as result;
