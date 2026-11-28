-- 286 — Payment Advice: void (with who/when/why). Status becomes 'void'.
alter table if exists public.payment_advices
  add column if not exists voided_by      text,
  add column if not exists voided_by_name text,
  add column if not exists voided_at      timestamptz,
  add column if not exists void_reason    text;

-- If an old CHECK constraint limits status values, drop it so 'void' is allowed.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.payment_advices'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format('alter table public.payment_advices drop constraint %I', c.conname);
  end loop;
end $$;
