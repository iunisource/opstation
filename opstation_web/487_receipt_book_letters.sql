-- 487 — Receipt books with a letter series, e.g. book "B" 1201–1300 → slips
-- B1201 … B1300 (the letter is printed before the number).
--  • receipt_books.prefix: the book's letter(s), 1–3 capitals; null = a plain
--    numbered book (works exactly as before).
--  • A slip belongs to a lettered book only when the CR# carries that letter
--    ("B1250", "B-1250", "b 1250"); "B1250 & 51" → B1250, B1251.
--  • Letters count only when they are a letter of an issued book, so stray
--    text in old CR#s ("CR# 391") is read as before.
--  • The same number may be issued again with a different letter.
-- Needs 458 / 482. Safe to run again.

alter table public.receipt_books add column if not exists prefix text;
do $$ begin
  alter table public.receipt_books add constraint receipt_books_prefix_chk check (prefix is null or prefix ~ '^[A-Z]{1,3}$');
exception when duplicate_object then null; end $$;

-- Slips on a CR# as (prefix, number). p_known = the org's book letters.
create or replace function public._receipt_slips_p(p_raw text, p_known text[])
returns table(prefix text, n bigint)
language plpgsql immutable as $$
declare
  m text[]; letters text; digits text; v_pre text; prev bigint; prev_pre text; p10 bigint; v bigint; i int;
begin
  if p_raw is null then return; end if;
  for m in select regexp_matches(p_raw, '(?:([A-Za-z]+)[ -]?)?([0-9]+)', 'g') loop
    letters := upper(m[1]);
    digits := m[2];
    if length(digits) > 15 then continue; end if;
    v_pre := case when letters is not null and letters = any (coalesce(p_known, '{}')) then letters end;
    if letters is null then v_pre := prev_pre; end if;  -- "B1250 & 51": 51 is B1251
    if prev is null or length(digits) >= length(prev::text) then
      v := digits::bigint;
    else
      p10 := 1;
      for i in 1..length(digits) loop p10 := p10 * 10; end loop;
      v := (prev - (prev % p10)) + digits::bigint;
    end if;
    prefix := v_pre; n := v;
    prev := v; prev_pre := v_pre;
    return next;
  end loop;
end $$;

create or replace function public._receipt_book_prefixes(p_org text)
returns text[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(distinct prefix), '{}') from public.receipt_books where org_id = p_org and prefix is not null;
$$;

-- Slips of a book used on collections — the letter must match the book's.
create or replace function public._receipt_book_used(p_book text)
returns table(serial bigint, visit_id text, user_id text, user_name text, at timestamp with time zone, amount numeric, customer_id text)
language sql stable security definer set search_path to 'public' as $$
  select s.n, v.id::text, v.user_id::text, v.user_name::text, v.timestamp, v.amount::numeric, v.customer_id::text
    from public.receipt_books b
    join public.visits v on v.org_id = b.org_id
                        and coalesce(v.amount, 0) > 0
                        and v.receipt_number ~ '\d'
                        and v.timestamp >= b.issued_at - interval '120 days'
    cross join lateral public._receipt_slips_p(v.receipt_number, public._receipt_book_prefixes(b.org_id)) s
   where b.id = p_book
     and s.n between b.start_no and b.end_no
     and coalesce(s.prefix, '') = coalesce(b.prefix, '');
$$;

-- Issue: optional letter; the same numbers may be issued again under another letter.
drop function if exists public.receipt_book_issue(text, text, bigint, bigint, text);
create or replace function public.receipt_book_issue(p_org text, p_user text, p_start bigint, p_end bigint,
                                                     p_label text default null, p_prefix text default null)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_uid text; v_uname text; v_name text; v_id text; o record;
        v_label text := nullif(trim(coalesce(p_label, '')), '');
        v_pre text := nullif(upper(regexp_replace(coalesce(p_prefix, ''), '[^A-Za-z]', '', 'g')), '');
begin
  if not public._can_issue_receipt_books(p_org) then raise exception 'You are not allowed to issue receipt books.'; end if;
  perform pg_advisory_xact_lock(hashtext('receipt_books:' || p_org));
  select u.name into v_name from public.users u
   where u.id = p_user and u.org_id = p_org and coalesce(u.is_active, true);
  if not found then raise exception 'Pick an active team member.'; end if;
  if v_label is null then raise exception 'Enter the book number.'; end if;
  if v_pre is not null and length(v_pre) > 3 then raise exception 'The letter can be up to 3 letters, e.g. B.'; end if;
  if p_start is null or p_end is null or p_start <= 0 then raise exception 'Enter the first and last serial of the book.'; end if;
  if p_end < p_start then raise exception 'The last serial must be after the first.'; end if;
  if p_end - p_start >= 1000 then raise exception 'A book can have up to 1000 slips.'; end if;
  select b.label, coalesce(b.user_name, '') as who, b.status into o
    from public.receipt_books b
   where b.org_id = p_org and lower(trim(b.label)) = lower(v_label)
   limit 1;
  if found then
    raise exception 'Book % is already issued to %.', v_label,
      o.who || case when o.status = 'open' then '' else ' (closed book)' end;
  end if;
  select b.start_no, b.end_no, b.prefix, coalesce(b.user_name, '') as who, b.status into o
    from public.receipt_books b
   where b.org_id = p_org and coalesce(b.prefix, '') = coalesce(v_pre, '')
     and b.start_no <= p_end and b.end_no >= p_start
   limit 1;
  if found then
    raise exception 'Serials %–% are already issued to %. Each serial can be issued only once.',
      coalesce(o.prefix, '') || o.start_no, coalesce(o.prefix, '') || o.end_no,
      o.who || case when o.status = 'open' then '' else ' (closed book)' end;
  end if;
  if (select count(*) from public.receipt_books where org_id = p_org and user_id = p_user and status = 'open') >= 2 then
    raise exception '% already has 2 open books. Close one first.', v_name;
  end if;
  select a.id, a.name into v_uid, v_uname from public._acting_user(p_org) a;
  insert into public.receipt_books (org_id, user_id, user_name, start_no, end_no, label, prefix, issued_by, issued_by_name)
  values (p_org, p_user, v_name, p_start, p_end, v_label, v_pre, v_uid, v_uname)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.receipt_book_issue(text, text, bigint, bigint, text, text) from public, anon;
grant execute on function public.receipt_book_issue(text, text, bigint, bigint, text, text) to authenticated;

-- Status: + prefix (last column).
drop function if exists public.receipt_books_status(text, text);
create or replace function public.receipt_books_status(p_org text, p_user text default null::text)
 returns table(id text, user_id text, user_name text, start_no bigint, end_no bigint, label text, status text,
               issued_at timestamp with time zone, issued_by_name text, closed_at timestamp with time zone,
               closed_by_name text, close_note text, used jsonb, cancelled jsonb, prefix text)
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
                     from public.receipt_slip_cancels c where c.book_id = b.id), '[]'::jsonb),
         b.prefix
    from public.receipt_books b
   where b.org_id = p_org and (p_user is null or b.user_id = p_user)
   order by (b.status = 'open') desc, b.issued_at desc;
end $function$;
grant execute on function public.receipt_books_status(text, text) to authenticated;

-- The app's copy: + prefix.
create or replace function public.receipt_books_mine(p_org text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v_uid text;
begin
  if not public._is_org_member(p_org) then raise exception 'You do not have access to this organisation.'; end if;
  select a.id into v_uid from public._acting_user(p_org) a;
  return jsonb_build_object(
    'on', public._cfg_true(p_org, 'org.receipt_books_flow'),
    'user_id', v_uid,
    'books', coalesce((select jsonb_agg(jsonb_build_object(
               'id', s.id, 'start', s.start_no, 'end', s.end_no, 'label', s.label, 'prefix', s.prefix,
               'used', (select coalesce(jsonb_agg(distinct (u->>'serial')::bigint), '[]'::jsonb) from jsonb_array_elements(s.used) u),
               'cancelled', (select coalesce(jsonb_agg((c->>'serial')::bigint), '[]'::jsonb) from jsonb_array_elements(s.cancelled) c))
               order by s.prefix nulls first, s.start_no)
             from public.receipt_books_status(p_org, v_uid) s where s.status = 'open'), '[]'::jsonb));
end $function$;

-- Release: find the book by the slip's letter as well as its number.
create or replace function public.receipt_slip_release(p_visit text, p_serial bigint, p_reason text, p_verified boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; b record; v_by text; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_pre text;
begin
  select id, org_id, receipt_number into v from visits where id = p_visit;
  if v.id is null then raise exception 'Collection not found.'; end if;
  if not (public._is_org_admin(v.org_id) or public._is_super_admin()) then
    raise exception 'Only admins can release a slip.';
  end if;
  if v_reason is null then raise exception 'Enter the reason.'; end if;
  if not coalesce(p_verified, false) then raise exception 'Check the physical slip book first, then confirm it.'; end if;
  select s.prefix into v_pre
    from public._receipt_slips_p(v.receipt_number, public._receipt_book_prefixes(v.org_id)) s
   where s.n = p_serial limit 1;
  if not found then raise exception 'Slip % is not on this collection.', p_serial; end if;
  select id, start_no, end_no into b from receipt_books
   where org_id = v.org_id and p_serial between start_no and end_no and coalesce(prefix, '') = coalesce(v_pre, '')
   order by (status = 'open') desc, issued_at desc limit 1;
  if b.id is null then raise exception 'Slip % is not from any issued book.', coalesce(v_pre, '') || p_serial; end if;
  select a.name into v_by from public._acting_user(v.org_id) a;
  insert into receipt_slip_releases (org_id, book_id, serial, visit_id, reason, verified, by_name)
  values (v.org_id, b.id, p_serial, v.id, v_reason, true, v_by)
  on conflict (book_id, serial, visit_id) do update set reason = excluded.reason, by_name = excluded.by_name, at = now();
  return jsonb_build_object('book', b.id, 'serial', p_serial);
end $$;

-- Skipped-receipts "checked" marks store a lettered slip as a larger number.
do $$ begin
  alter table public.skipped_receipt_clearances alter column serial_number type bigint;
exception when others then null; end $$;

notify pgrst, 'reload schema';

select 'receipt books: letters ready' as status;
