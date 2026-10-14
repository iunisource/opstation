-- 367 — Asset suggestions: also keep the LINE description (what the entry line
-- says on the asset account), not only the document narration. Refills the
-- suggestions already waiting. Requires 366. Safe to run again.

alter table public.asset_suggestions add column if not exists line_desc text;

create or replace function public._asset_sugg_refresh(p_org text, p_type text, p_src text, p_acct text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare
  w record; v_e record;
  v_amt numeric; v_party text; v_acct_name text; v_new boolean; v_line_desc text;
begin
  select * into w from public.asset_suggest_watch where org_id = p_org and account_id = p_acct;
  if not found or not public._cfg_on(p_org, 'org.asset_suggest_flow') then return; end if;

  -- Total added to this account by this document: posted, not voided, not a
  -- reversal, and new (made after the account was picked; old documents
  -- re-saved later are ignored when dated over a month before that).
  select coalesce(sum(coalesce(l.debit, 0)), 0) into v_amt
    from public.journal_lines l
    join public.journal_entries e on e.id = l.entry_id
   where e.org_id = p_org
     and coalesce(e.reference_type, '') = p_type
     and coalesce(e.reference_id, e.id) = p_src
     and l.account_id = p_acct
     and e.reverses_id is null
     and not coalesce(e.is_voided, false)
     and coalesce(e.status, 'posted') <> 'draft'
     and coalesce(e.reference_type, '') not in ('void', 'opening_jv')
     and e.created_at >= w.added_at
     and e.entry_date >= ((w.added_at at time zone 'Asia/Karachi')::date - 31);

  -- What the lines on this account say (e.g. "Lathe machine 12in").
  select string_agg(d, ' · ' order by d) into v_line_desc
    from (select distinct nullif(btrim(l.description), '') as d
            from public.journal_lines l
            join public.journal_entries e on e.id = l.entry_id
           where e.org_id = p_org
             and coalesce(e.reference_type, '') = p_type
             and coalesce(e.reference_id, e.id) = p_src
             and l.account_id = p_acct and coalesce(l.debit, 0) > 0
             and e.reverses_id is null and not coalesce(e.is_voided, false)) x
   where d is not null;

  if v_amt <= 0 then
    update public.asset_suggestions
       set amount = 0, status = 'gone', updated_at = now()
     where org_id = p_org and source_type = p_type and source_id = p_src and account_id = p_acct
       and status = 'pending';
    return;
  end if;

  -- Latest entry for the document: its number, date, narration, branch.
  select e2.* into v_e
    from public.journal_entries e2
   where e2.org_id = p_org and coalesce(e2.reference_type, '') = p_type
     and coalesce(e2.reference_id, e2.id) = p_src and e2.reverses_id is null
   order by e2.created_at desc limit 1;

  begin
    select coalesce(s.name, c.name) into v_party
      from public.journal_lines l
      left join public.suppliers s on s.id = l.party_id
      left join public.customers c on c.id = l.party_id
     where l.entry_id = v_e.id and l.party_id is not null
       and coalesce(s.name, c.name) is not null
     limit 1;
  exception when others then v_party := null;
  end;
  begin
    select name into v_acct_name from public.chart_of_accounts where id = p_acct;
  exception when others then v_acct_name := null;
  end;
  if v_acct_name is null then
    select l.account_name into v_acct_name from public.journal_lines l
     where l.entry_id = v_e.id and l.account_id = p_acct limit 1;
  end if;

  insert into public.asset_suggestions as s
    (org_id, branch_id, account_id, account_name, source_type, source_id, entry_id,
     source_number, entry_date, narration, line_desc, party_name, amount)
  values (p_org, v_e.branch_id, p_acct, v_acct_name, p_type, p_src, v_e.id,
          coalesce(nullif(v_e.reference_number, ''), v_e.entry_number), v_e.entry_date,
          nullif(btrim(coalesce(v_e.description, '')), ''), left(v_line_desc, 1000), v_party, v_amt)
  on conflict (org_id, source_type, source_id, account_id) do update
     set amount = excluded.amount, entry_id = excluded.entry_id, branch_id = excluded.branch_id,
         account_name = excluded.account_name, source_number = excluded.source_number,
         entry_date = excluded.entry_date, narration = excluded.narration, line_desc = excluded.line_desc,
         party_name = excluded.party_name, status = 'pending', updated_at = now()
   where s.status in ('pending', 'gone')
  returning (xmax = 0) into v_new;

  if coalesce(v_new, false) then
    begin
      perform public.notify_event(p_org, 'asset_suggestion', v_e.branch_id, null,
        'Asset suggestion',
        'Rs ' || public._asset_money(v_amt) || ' went to ' || coalesce(v_acct_name, 'an asset account')
          || ' on ' || coalesce(nullif(v_e.reference_number, ''), v_e.entry_number, 'a document')
          || coalesce(' (' || v_party || ')', '') || coalesce(' · ' || left(v_line_desc, 120), '')
          || ' — create an asset?',
        '/assets');
    exception when others then null;
    end;
  end if;
end $$;

-- Refill the ones already waiting.
do $$ declare r record; begin
  for r in select org_id, source_type, source_id, account_id
             from public.asset_suggestions where status = 'pending' loop
    perform public._asset_sugg_refresh(r.org_id, r.source_type, r.source_id, r.account_id);
  end loop;
end $$;

revoke all on function public._asset_sugg_refresh(text, text, text, text) from public, anon, authenticated;
