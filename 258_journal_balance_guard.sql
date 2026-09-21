-- 258: THE airtight backstop. A deferred constraint trigger that refuses to
-- commit any POSTED journal entry whose debits != credits — from any code path,
-- present or future (screens, RPCs, server functions, manual SQL). Because it is
-- DEFERRABLE INITIALLY DEFERRED, it checks each entry's FINAL state at COMMIT,
-- so multi-line postings that are momentarily one-sided mid-transaction are fine;
-- only the committed result must balance.
--
-- SAFE TO ENABLE ONLY AFTER migrations 256/257 and the six voucher screens
-- (CPV, CRV, Journal Voucher, Opening Journal, Bank Receipt, PDC) are deployed,
-- because until then those screens still write GL line-by-line across separate
-- transactions and would trip this guard mid-write.
--
-- PRE-FLIGHT — run this first; it MUST return zero rows before enabling the guard
-- (any row is an existing unbalanced posted entry that must be repaired first):
--
--   select je.id, je.entry_number, round(sum(jl.debit)-sum(jl.credit),2) as diff
--   from journal_entries je join journal_lines jl on jl.entry_id = je.id
--   where je.status = 'posted'
--   group by je.id, je.entry_number
--   having abs(sum(jl.debit)-sum(jl.credit)) > 0.01;
--
-- Draft (and any non-posted) entries are exempt — they may be unbalanced while
-- a user is still building them. A posted entry with zero lines nets to 0 = 0
-- and passes (that is a value question, not a balance one).

create or replace function public.enforce_je_balanced_lines()
returns trigger language plpgsql as $function$
declare v_entry text; v_status text; v_dr numeric; v_cr numeric;
begin
  v_entry := coalesce(NEW.entry_id, OLD.entry_id);
  if v_entry is null then return null; end if;
  select status into v_status from journal_entries where id = v_entry;
  if not found then return null; end if;                 -- entry removed in this txn
  if v_status is distinct from 'posted' then return null; end if;
  select coalesce(sum(debit),0), coalesce(sum(credit),0) into v_dr, v_cr
  from journal_lines where entry_id = v_entry;
  if abs(v_dr - v_cr) > 0.01 then
    raise exception 'Journal entry % is UNBALANCED (Dr % vs Cr %, diff %) — refusing to commit',
      v_entry, v_dr, v_cr, (v_dr - v_cr);
  end if;
  return null;
end $function$;

create or replace function public.enforce_je_balanced_entry()
returns trigger language plpgsql as $function$
declare v_dr numeric; v_cr numeric;
begin
  if NEW.status is distinct from 'posted' then return null; end if;
  select coalesce(sum(debit),0), coalesce(sum(credit),0) into v_dr, v_cr
  from journal_lines where entry_id = NEW.id;
  if abs(v_dr - v_cr) > 0.01 then
    raise exception 'Journal entry % is UNBALANCED (Dr % vs Cr %, diff %) — refusing to commit',
      NEW.id, v_dr, v_cr, (v_dr - v_cr);
  end if;
  return null;
end $function$;

drop trigger if exists je_balance_guard_lines on journal_lines;
create constraint trigger je_balance_guard_lines
  after insert or update or delete on journal_lines
  deferrable initially deferred
  for each row execute function enforce_je_balanced_lines();

drop trigger if exists je_balance_guard_entry on journal_entries;
create constraint trigger je_balance_guard_entry
  after insert or update on journal_entries
  deferrable initially deferred
  for each row execute function enforce_je_balanced_entry();
