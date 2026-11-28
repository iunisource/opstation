-- 341 — Payment Advice: optional "Paid" mark
-- An approved advice can be marked Paid (date + optional cheque / transaction ref)
-- so nobody pays it twice. Non-financial, like the advice itself — nothing posts.
-- Rules enforced in the database too:
--   • only an APPROVED advice can carry a Paid mark;
--   • a Paid advice can't be voided or rejected until the Paid mark is removed.
-- Safe to run again.

set lock_timeout = '5s';

alter table public.payment_advices
  add column if not exists paid_at      timestamptz,
  add column if not exists paid_by      text,
  add column if not exists paid_by_name text,
  add column if not exists paid_ref     text;

create or replace function public._pa_paid_guard()
returns trigger language plpgsql as $$
begin
  if new.paid_at is not null and coalesce(new.status, '') <> 'approved' then
    if old.paid_at is not null then
      raise exception 'This payment advice is marked Paid — remove the Paid mark before changing its status.';
    end if;
    raise exception 'Only an approved payment advice can be marked Paid.';
  end if;
  return new;
end $$;

drop trigger if exists trg_pa_paid_guard on public.payment_advices;
create trigger trg_pa_paid_guard
  before insert or update of paid_at, status on public.payment_advices
  for each row execute function public._pa_paid_guard();

-- Public link / QR page: the Paid mark (no login, by token).
create or replace function public.public_payment_advice_paid(p_token text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('paid_at', a.paid_at, 'paid_ref', a.paid_ref)
    from public.payment_advices a
   where p_token is not null and length(p_token) >= 32
     and a.public_token = p_token and a.status = 'approved'
$$;
grant execute on function public.public_payment_advice_paid(text) to anon, authenticated;

reset lock_timeout;

select count(*) filter (where status = 'approved') as approved_advices,
       count(*) filter (where paid_at is not null) as marked_paid
  from public.payment_advices;
