-- 334 — A Sales Return Invoice can only be issued if it carries EVERY line of its
-- return note (SRN) at the same quantity. Stops a repeat of SRI-2026-0049, where
-- 7 lines were lost and the customer was under-credited. Safe to run again.

create or replace function public._sri_guard_complete()
returns trigger language plpgsql as $$
declare v_bad int;
begin
  if coalesce(new.is_locked, false) and not coalesce(old.is_locked, false) and new.srn_id is not null then
    select count(*) into v_bad
      from sales_return_items i
     where i.return_id = new.srn_id and coalesce(i.quantity, 0) > 0
       and coalesce((select sum(x.quantity) from sales_return_invoice_items x
                      where x.invoice_id = new.id and x.srn_item_id = i.id), 0) <> i.quantity;
    if v_bad > 0 then
      raise exception '% cannot be issued: % line(s) of its return note are missing or have a different quantity. Delete this draft invoice and generate it again from the return note.',
        coalesce(new.voucher_number, new.id), v_bad using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_sri_guard_complete on public.sales_return_invoices;
create trigger trg_sri_guard_complete before update on public.sales_return_invoices
  for each row execute function public._sri_guard_complete();

-- Check: any issued SRI that is still short of its SRN (should be none now).
select i.voucher_number, i.org_id,
       (select count(*) from sales_return_items s where s.return_id = i.srn_id and coalesce(s.quantity, 0) > 0
          and coalesce((select sum(x.quantity) from sales_return_invoice_items x
                         where x.invoice_id = i.id and x.srn_item_id = s.id), 0) <> s.quantity) as short_lines
from sales_return_invoices i
where coalesce(i.is_locked, false) and not coalesce(i.is_voided, false) and i.srn_id is not null
  and exists (select 1 from sales_return_items s where s.return_id = i.srn_id and coalesce(s.quantity, 0) > 0
                and coalesce((select sum(x.quantity) from sales_return_invoice_items x
                               where x.invoice_id = i.id and x.srn_item_id = s.id), 0) <> s.quantity);
