-- 432 — Each quotation brand has its own quote-number format and series,
-- e.g. AKL-2026-0001 / GLO/0001. Standard quotations stay QT-YYYY-####.
-- Safe to run again.

alter table public.quotation_brands add column if not exists number_prefix text;
alter table public.quotation_brands add column if not exists number_year   boolean not null default true;
alter table public.quotation_brands add column if not exists number_digits int     not null default 4;
alter table public.quotation_brands add column if not exists number_sep    text    not null default '-';

create or replace function public.next_quotation_number(p_org text, p_brand text default null)
returns text language plpgsql security definer set search_path to 'public' as $$
declare
  b public.quotation_brands; v_prefix text; v_sep text; v_year boolean; v_digits int; v_head text; v_n int;
begin
  if not (public._is_org_member(p_org) or public._is_super_admin()) then
    raise exception 'You do not have access to this organisation.';
  end if;
  if p_brand is not null then
    select * into b from public.quotation_brands where id = p_brand and org_id = p_org;
  end if;
  if p_brand is not null and b.id is not null then
    v_prefix := coalesce(nullif(btrim(b.number_prefix), ''),
                         upper(left(regexp_replace(b.name, '[^A-Za-z]', '', 'g'), 3)), 'QB');
    v_sep    := coalesce(nullif(b.number_sep, ''), '-');
    v_year   := coalesce(b.number_year, true);
    v_digits := least(greatest(coalesce(b.number_digits, 4), 3), 8);
  else
    v_prefix := 'QT'; v_sep := '-'; v_year := true; v_digits := 4;
  end if;
  v_head := v_prefix || v_sep || case when v_year then to_char(now() at time zone 'Asia/Karachi', 'YYYY') || v_sep else '' end;
  perform pg_advisory_xact_lock(hashtext('quotation_no:' || p_org || ':' || v_head));
  select coalesce(max(substr(voucher_number, length(v_head) + 1)::int), 0) + 1 into v_n
    from public.quotations
   where org_id = p_org
     and left(voucher_number, length(v_head)) = v_head
     and substr(voucher_number, length(v_head) + 1) ~ '^[0-9]+$';
  return v_head || lpad(v_n::text, v_digits, '0');
end $$;
revoke all on function public.next_quotation_number(text, text) from public, anon;
grant execute on function public.next_quotation_number(text, text) to authenticated;
notify pgrst, 'reload schema';
select 'brand quote numbers ready' as result;
