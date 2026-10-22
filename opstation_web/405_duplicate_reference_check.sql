-- 405 — CRV / CPV: catch a receipt / transaction / cheque number that is already
-- used in another voucher of the same organisation.
--   _ref_tokens(text)        → the reference numbers written in a narration
--                              ("CR# 4521", "Receipt no 0045", "Trx: TX-778", "Chq 123456" …)
--   voucher_ref_duplicates() → other CRV / CPV lines (not voided) carrying any of them
-- Invoice / bill numbers are NOT treated as references (part payments against the
-- same invoice are normal). Read-only. Safe to run again.

create or replace function public._ref_tokens(p text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct t order by t), '{}')
    from (
      select upper(regexp_replace(m[1], '[^A-Za-z0-9]', '', 'g')) as raw,
             nullif(ltrim(upper(regexp_replace(m[1], '[^A-Za-z0-9]', '', 'g')), '0'), '') as t
        from regexp_matches(coalesce(p, ''),
          '\m(?:cr|receipt|rcpt|rct|trx|txn|trans|transaction|tid|ref|reference|chq|cheque|check|slip|utr|rrn|stan|deposit|dep)(?![a-z])\s*(?:#|no\.?|num|number|:|-)?\s*[#:]?\s*([a-z0-9/-]*[0-9][a-z0-9/-]*)',
          'gi') m
    ) x
   where t ~ '[0-9]' and length(raw) >= 3;
$$;

create or replace function public.voucher_ref_duplicates(p_org_id text, p_texts text[], p_exclude_id text default null)
returns table(ref text, voucher_type text, voucher_id text, voucher_number text, voucher_date date,
              status text, account_name text, description text, amount numeric)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._is_org_member(p_org_id) then raise exception 'You do not have access to this organisation.'; end if;
  return query
  with mine as (
    select distinct unnest(public._ref_tokens(t)) as tok from unnest(coalesce(p_texts, '{}')) t
  ),
  lines as (
    select 'CRV'::text typ, v.id::text vid, v.voucher_number::text vno, v.voucher_date::date vdate, v.status::text st,
           l.account_name::text acc, l.description::text descr, l.amount::numeric amt, to_jsonb(v) j
      from public.crv_voucher_lines l join public.crv_vouchers v on v.id = l.voucher_id
     where v.org_id = p_org_id and v.id is distinct from p_exclude_id and l.description ~ '[0-9]'
    union all
    select 'CPV', v.id::text, v.voucher_number::text, v.voucher_date::date, v.status::text,
           l.account_name::text, l.description::text, l.amount::numeric, to_jsonb(v)
      from public.cpv_voucher_lines l join public.cpv_vouchers v on v.id = l.voucher_id
     where v.org_id = p_org_id and v.id is distinct from p_exclude_id and l.description ~ '[0-9]'
  )
  select m.tok, x.typ, x.vid, x.vno, x.vdate, x.st, x.acc, x.descr, x.amt
    from lines x
    cross join lateral unnest(public._ref_tokens(x.descr)) tk(tok)
    join mine m on m.tok = tk.tok
   where coalesce((x.j ->> 'is_voided')::boolean, false) = false
     and coalesce(x.st, '') not ilike 'void%' and coalesce(x.st, '') not ilike 'cancel%'
     and exists (select 1 from mine)
   order by x.vdate desc, x.vno
   limit 50;
end $$;
revoke execute on function public.voucher_ref_duplicates(text, text[], text) from public, anon;
grant execute on function public.voucher_ref_duplicates(text, text[], text) to authenticated, service_role;
grant execute on function public._ref_tokens(text) to authenticated, service_role;

notify pgrst, 'reload schema';

-- Check: what it reads out of a few sample narrations
select t, public._ref_tokens(t) from unnest(array[
  'Received from Ali Traders CR# 4521', 'Receipt no. 0045 cash', 'Trx: TX-778-99 JazzCash',
  'Chq 123456 MCB', 'Payment against INV SI-2026-0012', 'Credit adjustment 5000', 'ref#A12B9']) t;
