-- 257: save_journal_entry — one atomic, balance-guarded writer for manual GL
-- entries (Journal Voucher, Opening Journal, Bank Receipt, PDC). Replaces the
-- client-side "insert header, then insert each line in a loop" pattern that
-- could half-write an unbalanced entry. The whole function is one transaction:
-- it upserts the entry header, replaces its lines, and — when posting — RAISES
-- if debits != credits, so a partial/unbalanced manual entry is impossible.
--
-- The caller resolves each line to its final account_id / debit / credit /
-- party (presentation logic stays in the screen); this function only persists
-- them atomically and enforces the balance.

create or replace function public.save_journal_entry(p_entry jsonb, p_lines jsonb)
returns text language plpgsql as $function$
declare
  v_id     text := p_entry->>'id';
  v_org    text := p_entry->>'org_id';
  v_branch text := p_entry->>'branch_id';
  v_status text := coalesce(p_entry->>'status','draft');
  v_dr numeric; v_cr numeric; r jsonb; v_ord int := 0;
begin
  if v_id is null or v_org is null then
    raise exception 'save_journal_entry: entry id and org_id are required';
  end if;

  insert into journal_entries(
    id, org_id, branch_id, entry_number, entry_date, description,
    reference_type, reference_id, reference_number, status,
    is_system_generated, created_by, posted_at,
    approval_status, approved_by, approved_by_name, approved_at, created_at)
  values (
    v_id, v_org, v_branch, p_entry->>'entry_number',
    (p_entry->>'entry_date')::date, p_entry->>'description',
    p_entry->>'reference_type', coalesce(p_entry->>'reference_id', v_id),
    p_entry->>'reference_number', v_status,
    coalesce((p_entry->>'is_system_generated')::boolean, false),
    p_entry->>'created_by',
    case when v_status='posted' then now() else null end,
    p_entry->>'approval_status', p_entry->>'approved_by', p_entry->>'approved_by_name',
    case when p_entry->>'approved_at' is not null then (p_entry->>'approved_at')::timestamptz else null end,
    now())
  on conflict (id) do update set
    branch_id        = excluded.branch_id,
    entry_date       = excluded.entry_date,
    description      = excluded.description,
    status           = excluded.status,
    posted_at        = case when excluded.status='posted' then now() else null end,
    approval_status  = excluded.approval_status,
    approved_by      = excluded.approved_by,
    approved_by_name = excluded.approved_by_name,
    approved_at      = excluded.approved_at;

  delete from journal_lines where entry_id = v_id;

  for r in select value from jsonb_array_elements(p_lines) loop
    insert into journal_lines(
      id, entry_id, org_id, branch_id, account_id, account_type,
      account_name, party_id, debit, credit, description, line_order, created_at)
    values (
      v_id || '_' || v_ord, v_id, v_org, v_branch,
      r->>'account_id', r->>'account_type', r->>'account_name', r->>'party_id',
      coalesce((r->>'debit')::numeric, 0), coalesce((r->>'credit')::numeric, 0),
      r->>'description', coalesce((r->>'line_order')::int, v_ord), now());
    v_ord := v_ord + 1;
  end loop;

  if v_status = 'posted' then
    select coalesce(sum(debit),0), coalesce(sum(credit),0) into v_dr, v_cr
    from journal_lines where entry_id = v_id;
    if abs(v_dr - v_cr) > 0.01 then
      raise exception 'Journal entry % would post UNBALANCED (Dr % vs Cr %, diff %) — aborting',
        coalesce(p_entry->>'entry_number', v_id), v_dr, v_cr, (v_dr - v_cr);
    end if;
  end if;

  return coalesce(p_entry->>'entry_number', v_id);
end $function$;
