-- 405b — Duplicate reference check: don't flag the other half of a cash transfer.
-- A CRV and a CPV on the SAME date for the SAME amount with the same reference
-- (e.g. a cheque received and then deposited / moved) is a normal pair, not a
-- duplicate. Everything else is still flagged. Safe to run again.
drop function if exists public.voucher_ref_duplicates(text, text[], text);
create or replace function public.voucher_ref_duplicates(
  p_org_id text, p_texts text[], p_exclude_id text default null,
  p_type text default null, p_date date default null, p_amounts numeric[] default null)
returns table(ref text, voucher_type text, voucher_id text, voucher_number text, voucher_date date,
              status text, account_name text, description text, amount numeric)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._is_org_member(p_org_id) then raise exception 'You do not have access to this organisation.'; end if;
  return query
  with src as (
    select t, a from unnest(coalesce(p_texts, '{}'), coalesce(p_amounts, '{}')) u(t, a) where t is not null
  ),
  mine as (
    select distinct tk as tok, src.a as amt from src cross join lateral unnest(public._ref_tokens(src.t)) tk
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
  select distinct on (x.vid, x.descr, m.tok) m.tok, x.typ, x.vid, x.vno, x.vdate, x.st, x.acc, x.descr, x.amt
    from lines x
    cross join lateral unnest(public._ref_tokens(x.descr)) tk(tok)
    join mine m on m.tok = tk.tok
   where coalesce((x.j ->> 'is_voided')::boolean, false) = false
     and coalesce(x.st, '') not ilike 'void%' and coalesce(x.st, '') not ilike 'cancel%'
     -- the other half of a transfer: opposite voucher type, same day, same amount
     and not (p_type is not null and x.typ <> upper(p_type) and x.vdate = p_date
              and m.amt is not null and round(x.amt, 2) = round(m.amt, 2))
   order by x.vid, x.descr, m.tok
   limit 50;
end $$;
revoke execute on function public.voucher_ref_duplicates(text, text[], text, text, date, numeric[]) from public, anon;
grant execute on function public.voucher_ref_duplicates(text, text[], text, text, date, numeric[]) to authenticated, service_role;
notify pgrst, 'reload schema';

-- What would be flagged from your existing vouchers now (read-only)
with l as (
  select v.org_id::text org_id, 'CRV'::text t, v.id::text id, v.voucher_number::text n, v.voucher_date::date d,
         x.description::text description, x.amount::numeric amount, to_jsonb(v) j, v.status::text status
    from crv_voucher_lines x join crv_vouchers v on v.id = x.voucher_id where x.description ~ '[0-9]'
  union all
  select v.org_id::text, 'CPV'::text, v.id::text, v.voucher_number::text, v.voucher_date::date,
         x.description::text, x.amount::numeric, to_jsonb(v), v.status::text
    from cpv_voucher_lines x join cpv_vouchers v on v.id = x.voucher_id where x.description ~ '[0-9]'
), r as (
  select l.*, tok from l cross join lateral unnest(public._ref_tokens(l.description)) tok
   where coalesce((j ->> 'is_voided')::boolean, false) = false and coalesce(status, '') not ilike 'void%'
)
select o.name as org, a.tok as reference,
       a.t || ' ' || a.n || ' (' || a.d || ', Rs ' || round(a.amount) || ')' as voucher,
       b.t || ' ' || b.n || ' (' || b.d || ', Rs ' || round(b.amount) || ')' as also_in
  from r a join r b on b.org_id = a.org_id and b.tok = a.tok and b.id <> a.id and (b.d, b.n) < (a.d, a.n)
  join orgs o on o.id = a.org_id
 where not (a.t <> b.t and a.d = b.d and round(a.amount, 2) = round(b.amount, 2))
 order by o.name, a.d, a.n;
