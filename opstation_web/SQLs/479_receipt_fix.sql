-- 479 — Correct or release a CR# on a collection (admins / master admins).
--  • Correct: the real slip number is known → the collection gets it.
--  • Release: the real slip isn't known → CR# becomes RELEASED (no digits,
--    so it never counts as a slip); the slip is free for its book holder.
--  Both need a reason; the collection's note and receipt_fix_log keep who,
--  when, the old and new number and why. Safe to run again.

create table if not exists public.receipt_fix_log (
  id          bigserial primary key,
  org_id      text not null,
  visit_id    text not null,
  action      text not null,          -- correct | release
  old_receipt text,
  new_receipt text,
  reason      text not null,
  by_name     text,
  at          timestamptz not null default now()
);
create index if not exists receipt_fix_log_org on public.receipt_fix_log (org_id, at desc);
alter table public.receipt_fix_log enable row level security;
drop policy if exists receipt_fix_log_read on public.receipt_fix_log;
create policy receipt_fix_log_read on public.receipt_fix_log for select
  using (public._is_org_member(org_id) or public._is_super_admin());
revoke insert, update, delete on public.receipt_fix_log from anon, authenticated;
grant select on public.receipt_fix_log to authenticated;

create or replace function public.receipt_fix(p_visit text, p_new text, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; v_by text; v_new text; v_action text; v_clash record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select id, org_id, receipt_number, user_name, timestamp, amount into v from visits where id = p_visit;
  if v.id is null then raise exception 'Collection not found.'; end if;
  if not (public._is_org_admin(v.org_id) or public._is_super_admin()) then
    raise exception 'Only admins can correct or release a CR#.';
  end if;
  if v_reason is null then raise exception 'Enter the reason.'; end if;
  v_new := nullif(btrim(coalesce(p_new, '')), '');
  if v_new is null then
    v_action := 'release';
    v_new := 'RELEASED';
  else
    v_action := 'correct';
    if v_new !~ '[0-9]' then raise exception 'Enter the correct slip number.'; end if;
    if v_new = coalesce(v.receipt_number, '') then raise exception 'That is the same number.'; end if;
    -- The new number already on another collection?
    select x.user_name, x.timestamp into v_clash from visits x
     where x.org_id = v.org_id and x.id <> v.id and coalesce(x.amount, 0) > 0
       and btrim(coalesce(x.receipt_number, '')) = v_new
     limit 1;
    if v_clash.user_name is not null or v_clash.timestamp is not null then
      raise exception 'CR# % is already on another collection (% · %). Check the number.',
        v_new, coalesce(v_clash.user_name, '—'), to_char(v_clash.timestamp at time zone 'Asia/Karachi', 'DD Mon YYYY');
    end if;
  end if;
  select a.name into v_by from public._acting_user(v.org_id) a;

  update visits
     set receipt_number = v_new,
         notes = coalesce(nullif(notes, '') || ' · ', '')
                 || case when v_action = 'release' then 'CR# ' || coalesce(v.receipt_number, '') || ' released'
                         else 'CR# corrected from ' || coalesce(v.receipt_number, '') end
                 || ' by ' || coalesce(v_by, 'admin') || ' on ' || to_char(now() at time zone 'Asia/Karachi', 'DD Mon YYYY')
                 || ': ' || v_reason
   where id = v.id;

  insert into receipt_fix_log (org_id, visit_id, action, old_receipt, new_receipt, reason, by_name)
  values (v.org_id, v.id, v_action, v.receipt_number, v_new, v_reason, v_by);

  return jsonb_build_object('action', v_action, 'old', v.receipt_number, 'new', v_new);
end $$;
revoke execute on function public.receipt_fix(text, text, text) from public, anon;
grant execute on function public.receipt_fix(text, text, text) to authenticated;
