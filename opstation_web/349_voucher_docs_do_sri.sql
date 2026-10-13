-- 349 — Support documents on Delivery Orders and Sales Return Invoices
-- (supervision flow). Files go to the existing 'si-documents' bucket and the
-- existing voucher_documents table, with voucher_type 'DO' / 'SRI'.
-- If voucher_documents has a check constraint limiting voucher_type, this
-- widens it to also allow DO and SRI (keeping every type already allowed).
-- If there is no such constraint, nothing changes. Safe to run again.
do $$
declare
  c record;
  vals text[];
begin
  for c in
    select con.conname, pg_get_constraintdef(con.oid) as def
      from pg_constraint con
     where con.conrelid = 'public.voucher_documents'::regclass
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%voucher_type%'
  loop
    -- quoted values, either 'SI' style or one '{SI,PI}' array literal
    select array_agg(distinct btrim(v, ' "')) into vals
      from regexp_matches(c.def, '''([^'']+)''', 'g') m,
           unnest(string_to_array(btrim(m[1], '{}'), ',')) v;
    vals := array(select distinct unnest(coalesce(vals, '{}') || array['DO', 'SRI']));
    execute format('alter table public.voucher_documents drop constraint %I', c.conname);
    execute format('alter table public.voucher_documents add constraint %I check (voucher_type = any (%L::text[]))',
                   c.conname, vals);
    raise notice 'Widened %: %', c.conname, vals;
  end loop;
end $$;

-- Check: which voucher types have documents today
select voucher_type, count(*) from public.voucher_documents group by 1 order by 1;
