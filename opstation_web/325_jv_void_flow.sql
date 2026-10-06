-- 325 — Journal Vouchers: Void flow (Admin Settings ▸ Financials ▸ "Void instead of delete").
--
-- Voiding a POSTED JV keeps it on record (marked VOIDED, with who / when / why)
-- and posts a mirror-image reversal "JV-…-VOID" on the SAME date, so ledgers
-- for that period net to zero as if the JV never happened. Draft JVs can still
-- be deleted (they never touched the books).
--
-- Safe to run again. Run the two ALTER lines on their own first if the editor
-- reports a lock/deadlock (journal_entries is a busy table).

alter table public.journal_entries add column if not exists is_voided      boolean not null default false;
alter table public.journal_entries add column if not exists voided_at      timestamptz;
alter table public.journal_entries add column if not exists voided_by      text;
alter table public.journal_entries add column if not exists voided_by_name text;
alter table public.journal_entries add column if not exists void_reason    text;
alter table public.journal_entries add column if not exists reverses_id    text;  -- set on the reversal, points to the voided JV
alter table public.journal_entries add column if not exists reversed_by    text;  -- set on the voided JV, points to its reversal

create or replace function public.void_journal_voucher(p_id text, p_reason text,
                                                       p_user text default null, p_user_name text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  e   public.journal_entries;
  v_id text := 'je_' || replace(gen_random_uuid()::text, '-', '');
  v_no text;
  n_lines int;
begin
  select * into e from journal_entries where id = p_id for update;
  if not found then raise exception 'Journal voucher not found'; end if;
  if not public._is_org_member(e.org_id) then raise exception 'Not allowed'; end if;
  if e.reference_type <> 'jv' then raise exception 'Only journal vouchers can be voided here'; end if;
  if e.reverses_id is not null then raise exception 'This entry is itself a reversal'; end if;
  if coalesce(e.is_voided, false) then raise exception '% is already voided', e.entry_number; end if;
  if coalesce(e.status, '') <> 'posted' then raise exception 'Only posted JVs are voided — delete a draft instead'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'A reason is required to void'; end if;

  v_no := e.entry_number || '-VOID';

  insert into journal_entries(id, org_id, branch_id, entry_number, entry_date, description,
                              reference_type, reference_id, reference_number, status,
                              is_system_generated, posted_at, reverses_id)
  values (v_id, e.org_id, e.branch_id, v_no, e.entry_date,
          'Void of ' || e.entry_number || ' — ' || trim(p_reason),
          'jv', v_id, v_no, 'posted', true, now(), e.id);

  -- Optional columns (present when the approval / supervision / audit columns exist).
  begin execute 'update journal_entries set approval_status = ''approved'' where id = $1' using v_id; exception when others then null; end;
  begin execute 'update journal_entries set supervised_at = now() where id = $1' using v_id; exception when others then null; end;
  begin execute 'update journal_entries set created_by = $2 where id = $1' using v_id, p_user; exception when others then null; end;

  -- Mirror image: every debit becomes a credit and vice versa.
  insert into journal_lines(id, entry_id, org_id, branch_id, account_id, debit, credit,
                            description, line_order, account_type, account_name, party_id)
  select 'jl_' || replace(gen_random_uuid()::text, '-', ''), v_id, l.org_id, l.branch_id, l.account_id,
         coalesce(l.credit, 0), coalesce(l.debit, 0),
         'Void: ' || coalesce(nullif(l.description, ''), e.entry_number), l.line_order,
         l.account_type, l.account_name, l.party_id
    from journal_lines l where l.entry_id = e.id;
  get diagnostics n_lines = row_count;
  if n_lines = 0 then raise exception '% has no lines to reverse', e.entry_number; end if;

  update journal_entries
     set is_voided = true, voided_at = now(), voided_by = p_user, voided_by_name = p_user_name,
         void_reason = trim(p_reason), reversed_by = v_id
   where id = e.id;

  return v_no;
end $$;

grant execute on function public.void_journal_voucher(text, text, text, text) to authenticated;
