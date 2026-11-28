-- 291 — Payment Advice: QR code on the print opens a public, read-only copy.
--
-- Every advice gets an unguessable public_token. Scanning the QR opens
--   https://<app>/#/pa/<token>
-- which calls public_payment_advice(token) — no login. It returns only what is
-- needed to verify the slip: number, date, status, parties, bank details,
-- amount to pay, total, who created/approved it and when (plus signature
-- images when "Signatures on Payment Advice print" is on). The party's current
-- balance (Amount due) is NOT exposed.

alter table if exists public.payment_advices
  add column if not exists public_token text;

update public.payment_advices
   set public_token = replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
 where public_token is null;

alter table public.payment_advices
  alter column public_token set default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));

create unique index if not exists payment_advices_public_token_uq
  on public.payment_advices(public_token);

create or replace function public.public_payment_advice(p_token text)
returns json
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  a   public.payment_advices%rowtype;
  v_org_name text;
  v_sigs boolean := false;
  v_lines json;
begin
  if p_token is null or length(p_token) < 32 then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;
  select * into a from public.payment_advices where public_token = p_token;
  if not found then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;

  select name into v_org_name from public.orgs where id = a.org_id;
  select coalesce(value, 'false') = 'true' into v_sigs
    from public.app_config where org_id = a.org_id and key = 'org.pa_signatures' limit 1;

  select coalesce(json_agg(json_build_object(
           'party_name',        l.party_name,
           'party_type',        l.party_type,
           'bank_details',      l.bank_details,
           'amount_to_pay',     l.amount_to_pay,
           'last_payment_date', l.last_payment_date
         ) order by l.line_order), '[]'::json)
    into v_lines
    from public.payment_advice_lines l
   where l.advice_id = a.id;

  return json_build_object(
    'ok',               true,
    'org_name',         v_org_name,
    'advice_number',    a.advice_number,
    'advice_date',      a.advice_date,
    'status',           a.status,
    'note',             a.note,
    'grand_total',      a.grand_total,
    'created_by_name',  a.created_by_name,
    'created_at',       a.created_at,
    'approved_by_name', a.approved_by_name,
    'approved_at',      a.approved_at,
    'rejected_by_name', a.rejected_by_name,
    'rejected_at',      a.rejected_at,
    'voided_by_name',   a.voided_by_name,
    'voided_at',        a.voided_at,
    'void_reason',      a.void_reason,
    'created_signature_url',  case when coalesce(v_sigs, false) then a.created_signature_url end,
    'approved_signature_url', case when coalesce(v_sigs, false) then a.approved_signature_url end,
    'approved_stamp_url',     case when coalesce(v_sigs, false) then a.approved_stamp_url end,
    'lines',            v_lines
  );
end $function$;

grant execute on function public.public_payment_advice(text) to anon, authenticated;
