-- Payment Advice: last payment date + suggestions support
-- 1) Store the party's last payment date on each advice line (captured at
--    creation so the printed slip is stable).
-- 2) RPC returning each party's most recent posted payment date, for both the
--    editor display and the "Suggest parties" flow.

alter table if exists payment_advice_lines
  add column if not exists last_payment_date date;

-- Latest posted payment date per party.
--   supplier -> last CPV (cash payment voucher: we paid the supplier)
--   customer -> last CRV (cash receipt voucher: the customer paid us)
-- voucher_date is normally 'yyyy-mm-dd'; fall back to posted_at / created_at.
-- Cast to text so the function works whether voucher_date is a date or text.
create or replace function rpc_party_last_payment(p_org_id text)
returns table(party_key text, last_payment text)
language sql
stable
security definer
as $$
  select 'supplier:' || l.account_id,
         max(coalesce(nullif(v.voucher_date::text, ''),
                      left(v.posted_at::text, 10),
                      left(v.created_at::text, 10)))
  from cpv_voucher_lines l
  join cpv_vouchers v on v.id = l.voucher_id
  where v.org_id = p_org_id
    and v.status = 'posted'
    and l.account_type = 'supplier'
    and l.account_id is not null
  group by l.account_id
  union all
  select 'customer:' || l.account_id,
         max(coalesce(nullif(v.voucher_date::text, ''),
                      left(v.posted_at::text, 10),
                      left(v.created_at::text, 10)))
  from crv_voucher_lines l
  join crv_vouchers v on v.id = l.voucher_id
  where v.org_id = p_org_id
    and v.status = 'posted'
    and l.account_type = 'customer'
    and l.account_id is not null
  group by l.account_id;
$$;

grant execute on function rpc_party_last_payment(text) to authenticated, anon;
