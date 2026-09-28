-- 287 — Payment Advice: free-text parties (party_type = 'other', not linked to
-- a customer/supplier). Drop any old CHECK that limits party_type values.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.payment_advice_lines'::regclass
       and contype in ('c', 'f')
       and pg_get_constraintdef(oid) ilike '%party%'
  loop
    execute format('alter table public.payment_advice_lines drop constraint %I', c.conname);
  end loop;
end $$;
