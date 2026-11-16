-- 485 — Reimbursement claims: QR on the print to check it is genuine.
-- Every claim gets an unguessable public_token. Scanning the QR opens
--   https://<app>/#/rc/<token>
-- which calls public_reimb_claim(token) — no login — and shows what the
-- system holds for that claim (who, dates, km, amount, status, approver), so
-- a printed copy can be compared with the real record. Safe to run again.

alter table public.reimb_claims add column if not exists public_token text;

update public.reimb_claims
   set public_token = replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
 where public_token is null;

alter table public.reimb_claims
  alter column public_token set default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));

create unique index if not exists reimb_claims_public_token_uq on public.reimb_claims (public_token);

create or replace function public.public_reimb_claim(p_token text)
returns json language plpgsql stable security definer set search_path to 'public' as $$
declare
  c public.reimb_claims%rowtype;
  v_org text;
  v_days json;
begin
  if p_token is null or length(p_token) < 32 then
    return json_build_object('ok', false);
  end if;
  select * into c from public.reimb_claims where public_token = p_token;
  if not found then
    return json_build_object('ok', false);
  end if;
  select name into v_org from public.orgs where id = c.org_id;
  select coalesce(json_agg(json_build_object('day', d.day, 'km', d.km) order by d.day), '[]'::json)
    into v_days
    from (select day, round(sum(km), 2) km from public.reimb_lines where claim_id = c.id group by day) d;
  return json_build_object(
    'ok',              true,
    'org_name',        v_org,
    'claimant_name',   c.claimant_name,
    'doc_type',        c.doc_type,
    'date_from',       c.date_from,
    'date_to',         c.date_to,
    'km',              c.km,
    'status',          c.status,
    'amount',          c.amount,
    'decided_by_name', case when c.status in ('approved', 'paid') then c.decided_by_name end,
    'decided_at',      case when c.status in ('approved', 'paid') then c.decided_at end,
    'paid_on',         c.paid_on,
    'days',            v_days
  );
end $$;

grant execute on function public.public_reimb_claim(text) to anon, authenticated;

notify pgrst, 'reload schema';

select count(*) filter (where public_token is not null) as claims_with_qr, count(*) as claims from public.reimb_claims;
