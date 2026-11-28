-- 380 — Product barcode: still generated automatically, now editable.
-- Empty on save → generated (new) / kept (existing). A typed barcode must be
-- unique in the organisation. Changes are recorded in product history (the
-- existing history trigger already tracks the barcode). Safe to run again.
CREATE OR REPLACE FUNCTION public._products_barcode_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
  if tg_op = 'INSERT' then
    if new.barcode is null then
      new.barcode := public.next_product_barcode();
    end if;
  else -- UPDATE
    if new.barcode is null then
      -- Cleared / not sent: keep the current one (or generate if it never had one).
      new.barcode := coalesce(nullif(btrim(coalesce(old.barcode, '')), ''), public.next_product_barcode());
    end if;
  end if;
  -- One barcode = one product within the organisation.
  if new.barcode is distinct from (case when tg_op = 'UPDATE' then old.barcode end)
     and exists (select 1 from public.products p
                  where p.org_id = new.org_id and p.barcode = new.barcode and p.id <> new.id) then
    raise exception 'Barcode % is already used by another product', new.barcode;
  end if;
  return new;
end;
$function$;
