-- 329 — Payment Advice: short WhatsApp share link with a branded preview card.
--
-- Every advice gets a short share_code (7 letters/digits). The link
--   https://<app>/l/<share_code>
-- is served by the Firebase function "paLink": it gives WhatsApp the preview
-- (org logo + name as title, PA number / amount / status as text) and sends a
-- person straight on to the live read-only page /#/pa/<public_token>.
-- Safe to run again.

create or replace function public._short_code(n int default 7)
returns text language sql volatile as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789',
                           1 + floor(random() * 56)::int, 1), '')
  from generate_series(1, n);
$$;

alter table public.payment_advices add column if not exists share_code text;
update public.payment_advices set share_code = public._short_code(7) where share_code is null;
alter table public.payment_advices alter column share_code set default public._short_code(7);
create unique index if not exists payment_advices_share_code_uq on public.payment_advices(share_code);

-- What the link preview needs — nothing more. No balances.
create or replace function public.pa_share_meta(p_code text)
returns json language plpgsql stable security definer set search_path to 'public' as $$
declare
  a public.payment_advices%rowtype;
  v_org text; v_logo text; v_n int; v_first text;
begin
  if p_code is null or p_code !~ '^[A-Za-z0-9]{6,12}$' then
    return json_build_object('ok', false);
  end if;
  select * into a from payment_advices where share_code = p_code;
  if not found then return json_build_object('ok', false); end if;

  select name into v_org from orgs where id = a.org_id;
  select nullif(trim(value), '') into v_logo from app_config
   where org_id = a.org_id and key = 'org.logo_url' limit 1;
  select count(*), min(party_name) filter (where line_order = (select min(line_order) from payment_advice_lines where advice_id = a.id))
    into v_n, v_first from payment_advice_lines where advice_id = a.id;

  return json_build_object(
    'ok', true,
    'token', a.public_token,
    'org_name', v_org,
    'logo_url', v_logo,
    'advice_number', a.advice_number,
    'advice_date', a.advice_date,
    'status', a.status,
    'grand_total', a.grand_total,
    'payees', v_n,
    'first_payee', v_first
  );
end $$;
grant execute on function public.pa_share_meta(text) to anon, authenticated;
