-- 482 — Release a receipt slip for re-use WITHOUT changing the old entry.
--  • The old collection keeps its CR# exactly as entered (still searchable).
--  • receipt_slip_releases records that slip N of a book is free again for
--    its holder, with who / when / why and a "slip book checked" confirmation.
--  • Receipt Books and the app's slip check ignore a released use, so the
--    book holder can use that slip.
--  • receipt_fix (479) now only CORRECTS a number; releasing goes here.
-- Needs 458 / 479. Safe to run again.

create table if not exists public.receipt_slip_releases (
  id           bigserial primary key,
  org_id       text not null,
  book_id      text not null,
  serial       bigint not null,
  visit_id     text not null,          -- the earlier collection whose use is released
  reason       text not null,
  verified     boolean not null default true,
  by_name      text,
  at           timestamptz not null default now(),
  unique (book_id, serial, visit_id)
);
alter table public.receipt_slip_releases enable row level security;
drop policy if exists receipt_slip_releases_read on public.receipt_slip_releases;
create policy receipt_slip_releases_read on public.receipt_slip_releases for select
  using (public._is_org_member(org_id) or public._is_super_admin());
revoke insert, update, delete on public.receipt_slip_releases from anon, authenticated;
grant select on public.receipt_slip_releases to authenticated;

create or replace function public.receipt_slip_release(p_visit text, p_serial bigint, p_reason text, p_verified boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; b record; v_by text; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select id, org_id, receipt_number into v from visits where id = p_visit;
  if v.id is null then raise exception 'Collection not found.'; end if;
  if not (public._is_org_admin(v.org_id) or public._is_super_admin()) then
    raise exception 'Only admins can release a slip.';
  end if;
  if v_reason is null then raise exception 'Enter the reason.'; end if;
  if not coalesce(p_verified, false) then raise exception 'Check the physical slip book first, then confirm it.'; end if;
  if coalesce(v.receipt_number, '') !~ ('(^|[^0-9])' || p_serial || '([^0-9]|$)') then
    raise exception 'Slip % is not on this collection.', p_serial;
  end if;
  select id, start_no, end_no into b from receipt_books
   where org_id = v.org_id and p_serial between start_no and end_no
   order by (status = 'open') desc, issued_at desc limit 1;
  if b.id is null then raise exception 'Slip % is not from any issued book.', p_serial; end if;
  select a.name into v_by from public._acting_user(v.org_id) a;
  insert into receipt_slip_releases (org_id, book_id, serial, visit_id, reason, verified, by_name)
  values (v.org_id, b.id, p_serial, v.id, v_reason, true, v_by)
  on conflict (book_id, serial, visit_id) do update set reason = excluded.reason, by_name = excluded.by_name, at = now();
  return jsonb_build_object('book', b.id, 'serial', p_serial);
end $$;
revoke execute on function public.receipt_slip_release(text, bigint, text, boolean) from public, anon;
grant execute on function public.receipt_slip_release(text, bigint, text, boolean) to authenticated;

create or replace function public.receipt_slip_unrelease(p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  select * into r from receipt_slip_releases where id = p_id;
  if r.id is null then return; end if;
  if not (public._is_org_admin(r.org_id) or public._is_super_admin()) then raise exception 'Only admins can undo a release.'; end if;
  delete from receipt_slip_releases where id = p_id;
end $$;
revoke execute on function public.receipt_slip_unrelease(bigint) from public, anon;
grant execute on function public.receipt_slip_unrelease(bigint) to authenticated;

-- Book status: a released use no longer counts as "used" (the app's check
-- reads this through receipt_books_mine).
create or replace function public.receipt_books_status(p_org text, p_user text default null::text)
 returns table(id text, user_id text, user_name text, start_no bigint, end_no bigint, label text, status text,
               issued_at timestamp with time zone, issued_by_name text, closed_at timestamp with time zone,
               closed_by_name text, close_note text, used jsonb, cancelled jsonb)
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not public._is_org_member(p_org) then raise exception 'You do not have access to this organisation.'; end if;
  return query
  select b.id, b.user_id, b.user_name, b.start_no, b.end_no, b.label, b.status,
         b.issued_at, b.issued_by_name, b.closed_at, b.closed_by_name, b.close_note,
         coalesce((select jsonb_agg(jsonb_build_object('serial', u.serial, 'visit_id', u.visit_id, 'user_id', u.user_id,
                                   'user_name', u.user_name, 'at', u.at, 'amount', u.amount, 'customer_id', u.customer_id)
                                   order by u.at)
                     from public._receipt_book_used(b.id) u
                    where not exists (select 1 from public.receipt_slip_releases r
                                       where r.book_id = b.id and r.serial = u.serial and r.visit_id = u.visit_id)), '[]'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'serial', c.serial, 'reason', c.reason,
                                   'by', c.cancelled_by_name, 'at', c.cancelled_at,
                                   'reviewed_at', c.reviewed_at, 'reviewed_by', c.reviewed_by_name,
                                   'review_note', c.review_note) order by c.serial)
                     from public.receipt_slip_cancels c where c.book_id = b.id), '[]'::jsonb)
    from public.receipt_books b
   where b.org_id = p_org and (p_user is null or b.user_id = p_user)
   order by (b.status = 'open') desc, b.issued_at desc;
end $function$;

-- receipt_fix: correcting only (releasing is receipt_slip_release).
create or replace function public.receipt_fix(p_visit text, p_new text, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; v_by text; v_new text; v_clash record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select id, org_id, receipt_number, user_name, timestamp, amount into v from visits where id = p_visit;
  if v.id is null then raise exception 'Collection not found.'; end if;
  if not (public._is_org_admin(v.org_id) or public._is_super_admin()) then
    raise exception 'Only admins can correct a CR#.';
  end if;
  if v_reason is null then raise exception 'Enter the reason.'; end if;
  v_new := nullif(btrim(coalesce(p_new, '')), '');
  if v_new is null or v_new !~ '[0-9]' then raise exception 'Enter the correct slip number.'; end if;
  if v_new = coalesce(v.receipt_number, '') then raise exception 'That is the same number.'; end if;
  select x.user_name, x.timestamp into v_clash from visits x
   where x.org_id = v.org_id and x.id <> v.id and coalesce(x.amount, 0) > 0
     and btrim(coalesce(x.receipt_number, '')) = v_new
   limit 1;
  if v_clash.user_name is not null or v_clash.timestamp is not null then
    raise exception 'CR# % is already on another collection (% · %). Check the number.',
      v_new, coalesce(v_clash.user_name, '—'), to_char(v_clash.timestamp at time zone 'Asia/Karachi', 'DD Mon YYYY');
  end if;
  select a.name into v_by from public._acting_user(v.org_id) a;
  update visits
     set receipt_number = v_new,
         notes = coalesce(nullif(notes, '') || ' · ', '') || 'CR# corrected from ' || coalesce(v.receipt_number, '')
                 || ' by ' || coalesce(v_by, 'admin') || ' on ' || to_char(now() at time zone 'Asia/Karachi', 'DD Mon YYYY')
                 || ': ' || v_reason
   where id = v.id;
  insert into receipt_fix_log (org_id, visit_id, action, old_receipt, new_receipt, reason, by_name)
  values (v.org_id, v.id, 'correct', v.receipt_number, v_new, v_reason, v_by);
  return jsonb_build_object('action', 'correct', 'old', v.receipt_number, 'new', v_new);
end $$;
revoke execute on function public.receipt_fix(text, text, text) from public, anon;
grant execute on function public.receipt_fix(text, text, text) to authenticated;
