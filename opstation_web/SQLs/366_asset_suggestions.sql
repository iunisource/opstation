-- 366 — Asset suggestions.
-- Admin Settings → "Suggest assets from accounts" (org.asset_suggest_flow) +
-- the accounts picked there (org.asset_suggest_accounts, e.g. Plant & Machinery).
-- Whenever a NEW posted entry adds value (a debit) to one of those accounts, a
-- suggestion appears on Management → Assets: "Rs X went to <account> on <doc> —
-- create an asset?". Create asset (one or several) or Dismiss with a reason.
--   • New entries only — nothing from before the account was picked.
--   • One suggestion per document + account (a re-save just updates the amount).
--   • Voiding the document removes its waiting suggestion.
--   • It can never block or slow down a posting: any problem is skipped.
-- Notification: asset_suggestion (Admin Settings → Notifications → Assets).
-- Requires 296 (notify_event) and 325 (journal void columns). Safe to run again.

-- ── Tables ──────────────────────────────────────────────────────────────────
create table if not exists public.asset_suggest_watch (
  org_id     text not null,
  account_id text not null,
  added_at   timestamptz not null default now(),   -- only entries after this count
  primary key (org_id, account_id)
);

create table if not exists public.asset_suggestions (
  id              text primary key default 'asug_' || replace(gen_random_uuid()::text, '-', ''),
  org_id          text not null,
  branch_id       text,
  account_id      text not null,
  account_name    text,
  source_type     text not null default '',   -- the document type that posted it
  source_id       text not null,              -- the document id (or entry id)
  entry_id        text,                       -- latest journal entry for it
  source_number   text,                       -- document number shown to users
  entry_date      date,
  narration       text,
  line_desc       text,
  party_name      text,
  amount          numeric not null default 0,
  status          text not null default 'pending', -- pending | done | dismissed | voided | gone
  asset_ids       text[] not null default '{}',
  assets_cost     numeric not null default 0,
  dismiss_reason  text,
  decided_by_name text,
  decided_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (org_id, source_type, source_id, account_id)
);
alter table public.asset_suggestions add column if not exists line_desc text;
create index if not exists idx_asset_sugg_pending on public.asset_suggestions(org_id) where status = 'pending';
create index if not exists idx_asset_sugg_entry   on public.asset_suggestions(entry_id);

alter table public.asset_suggestions   enable row level security;
alter table public.asset_suggest_watch enable row level security;
drop policy if exists asset_sugg_read on public.asset_suggestions;
create policy asset_sugg_read on public.asset_suggestions for select using (public._is_org_member(org_id));
drop policy if exists asset_watch_read on public.asset_suggest_watch;
create policy asset_watch_read on public.asset_suggest_watch for select using (public._is_org_member(org_id));

-- ── Keep the watch list in step with Admin Settings ────────────────────────
create or replace function public._asset_suggest_sync(p_org text, p_restart boolean default false)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare v_list text[];
begin
  select coalesce(array_agg(distinct btrim(x)), '{}') into v_list
    from unnest(string_to_array(coalesce(
           (select value from public.app_config
             where org_id = p_org and key = 'org.asset_suggest_accounts' limit 1), ''), ',')) x
   where btrim(x) <> '';
  delete from public.asset_suggest_watch where org_id = p_org and not (account_id = any (v_list));
  insert into public.asset_suggest_watch(org_id, account_id, added_at)
  select p_org, a, now() from unnest(v_list) a
  on conflict (org_id, account_id) do nothing;
  -- Switched back ON after being off: start counting from now again.
  if p_restart then
    update public.asset_suggest_watch set added_at = now() where org_id = p_org;
  end if;
end $$;

create or replace function public.trg_asset_suggest_cfg()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare v_key text; v_org text; v_restart boolean := false;
begin
  if TG_OP = 'DELETE' then v_key := OLD.key; v_org := OLD.org_id;
  else v_key := NEW.key; v_org := NEW.org_id; end if;
  if v_key not in ('org.asset_suggest_accounts', 'org.asset_suggest_flow') or v_org is null then
    return null;
  end if;
  if TG_OP <> 'DELETE' and v_key = 'org.asset_suggest_flow' and NEW.value = 'true'
     and (TG_OP = 'INSERT' or coalesce(OLD.value, '') <> 'true') then
    v_restart := true;
  end if;
  perform public._asset_suggest_sync(v_org, v_restart);
  return null;
end $$;

drop trigger if exists zz_asset_suggest_cfg on public.app_config;
create trigger zz_asset_suggest_cfg after insert or update or delete on public.app_config
  for each row execute function public.trg_asset_suggest_cfg();

-- Seed from whatever is already saved.
do $$ declare o text; begin
  for o in select distinct org_id from public.app_config
            where key = 'org.asset_suggest_accounts' and org_id is not null loop
    perform public._asset_suggest_sync(o, false);
  end loop;
end $$;

-- ── Money text for messages: 1,250,000 or 1,250.50 ─────────────────────────
create or replace function public._asset_money(v numeric)
returns text language sql immutable as $$
  select case when v = trunc(v) then to_char(v, 'FM999,999,999,999,990')
              else to_char(v, 'FM999,999,999,999,990.00') end;
$$;

-- ── Recalculate one suggestion from the ledger ─────────────────────────────
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

-- ── Ledger triggers (never block a posting) ────────────────────────────────
create or replace function public.trg_asset_sugg_lines_ins()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare r record;
begin
  begin
    for r in
      select distinct e.org_id, coalesce(e.reference_type, '') as t,
             coalesce(e.reference_id, e.id) as s, n.account_id
        from new_rows n
        join public.asset_suggest_watch w on w.account_id = n.account_id
        join public.journal_entries e on e.id = n.entry_id and e.org_id = w.org_id
       where coalesce(n.debit, 0) > 0
    loop
      perform public._asset_sugg_refresh(r.org_id, r.t, r.s, r.account_id);
    end loop;
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists zz_asset_sugg_lines_ins on public.journal_lines;
create trigger zz_asset_sugg_lines_ins after insert on public.journal_lines
  referencing new table as new_rows
  for each statement execute function public.trg_asset_sugg_lines_ins();

create or replace function public.trg_asset_sugg_lines_del()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare r record;
begin
  begin
    for r in
      select distinct s.org_id, s.source_type, s.source_id, s.account_id
        from public.asset_suggestions s
       where s.status = 'pending'
         and s.entry_id in (select distinct o.entry_id from old_rows o)
    loop
      perform public._asset_sugg_refresh(r.org_id, r.source_type, r.source_id, r.account_id);
    end loop;
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists zz_asset_sugg_lines_del on public.journal_lines;
create trigger zz_asset_sugg_lines_del after delete on public.journal_lines
  referencing old table as old_rows
  for each statement execute function public.trg_asset_sugg_lines_del();

-- Entry posted later (draft → posted), voided, or a void entry for a document.
create or replace function public.trg_asset_sugg_entries()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare r record;
begin
  begin
    if not exists (select 1 from public.asset_suggest_watch where org_id = NEW.org_id) then
      return null;
    end if;

    -- A void of a document: its waiting suggestion goes away.
    if TG_OP = 'INSERT' and coalesce(NEW.reference_type, '') = 'void' and NEW.reference_id is not null then
      update public.asset_suggestions
         set status = 'voided', updated_at = now()
       where org_id = NEW.org_id and source_id = NEW.reference_id and status in ('pending', 'gone');
    end if;

    if TG_OP = 'UPDATE' then
      if coalesce(NEW.is_voided, false) and not coalesce(OLD.is_voided, false) then
        update public.asset_suggestions
           set status = 'voided', updated_at = now()
         where org_id = NEW.org_id and source_type = coalesce(NEW.reference_type, '')
           and source_id = coalesce(NEW.reference_id, NEW.id) and status in ('pending', 'gone');
      elsif NEW.status is distinct from OLD.status then
        for r in
          select distinct l.account_id
            from public.journal_lines l
            join public.asset_suggest_watch w on w.org_id = NEW.org_id and w.account_id = l.account_id
           where l.entry_id = NEW.id and coalesce(l.debit, 0) > 0
        loop
          perform public._asset_sugg_refresh(NEW.org_id, coalesce(NEW.reference_type, ''),
                                             coalesce(NEW.reference_id, NEW.id), r.account_id);
        end loop;
      end if;
    end if;
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists zz_asset_sugg_entries on public.journal_entries;
create trigger zz_asset_sugg_entries after insert or update of status, is_voided on public.journal_entries
  for each row execute function public.trg_asset_sugg_entries();

-- ── Actions from the Assets screen ─────────────────────────────────────────
create or replace function public._asset_sugg_me(p_org text)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select u.name from public.users u
   where u.org_id = p_org and coalesce(u.is_active, true)
     and (u.account_id = public.current_account_id()
          or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
   limit 1;
$$;

-- An asset was created from the suggestion. Closes it once the assets cover the amount.
create or replace function public.link_asset_suggestion(p_id text, p_asset_id text)
returns text
language plpgsql security definer set search_path to 'public'
as $$
declare s public.asset_suggestions%rowtype; v_cost numeric; v_status text;
begin
  select * into s from public.asset_suggestions where id = p_id for update;
  if not found then raise exception 'Suggestion not found.' using errcode = 'P0001'; end if;
  if not public._is_org_member(s.org_id) then raise exception 'Not allowed.' using errcode = 'P0001'; end if;
  select coalesce(purchase_cost, 0) into v_cost from public.assets
   where id = p_asset_id and org_id = s.org_id;
  if not found then raise exception 'Asset not found.' using errcode = 'P0001'; end if;
  if p_asset_id = any (s.asset_ids) then return s.status; end if;

  v_status := case when s.status = 'pending' and s.assets_cost + v_cost >= s.amount - 0.5
                   then 'done' else s.status end;
  update public.asset_suggestions
     set asset_ids = array_append(asset_ids, p_asset_id),
         assets_cost = assets_cost + v_cost,
         status = v_status,
         decided_at = case when v_status = 'done' and s.status <> 'done' then now() else decided_at end,
         decided_by_name = case when v_status = 'done' and s.status <> 'done'
                                then public._asset_sugg_me(s.org_id) else decided_by_name end,
         updated_at = now()
   where id = p_id;
  return v_status;
end $$;

-- Mark it done (after creating some assets), or dismiss it with a reason.
create or replace function public.close_asset_suggestion(p_id text, p_dismiss boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare s public.asset_suggestions%rowtype; v_reason text;
begin
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  select * into s from public.asset_suggestions where id = p_id for update;
  if not found then raise exception 'Suggestion not found.' using errcode = 'P0001'; end if;
  if not public._is_org_member(s.org_id) then raise exception 'Not allowed.' using errcode = 'P0001'; end if;
  if s.status <> 'pending' then raise exception 'This suggestion is already closed.' using errcode = 'P0001'; end if;
  if p_dismiss and v_reason is null then raise exception 'Please give a reason.' using errcode = 'P0001'; end if;
  if not p_dismiss and cardinality(s.asset_ids) = 0 then
    raise exception 'Create at least one asset first, or dismiss it.' using errcode = 'P0001';
  end if;
  update public.asset_suggestions
     set status = case when p_dismiss then 'dismissed' else 'done' end,
         dismiss_reason = case when p_dismiss then v_reason else null end,
         decided_at = now(), decided_by_name = public._asset_sugg_me(s.org_id), updated_at = now()
   where id = p_id;
end $$;

revoke all on function public.link_asset_suggestion(text, text) from public, anon;
revoke all on function public.close_asset_suggestion(text, boolean, text) from public, anon;
grant execute on function public.link_asset_suggestion(text, text) to authenticated;
grant execute on function public.close_asset_suggestion(text, boolean, text) to authenticated;
revoke all on function public._asset_sugg_refresh(text, text, text, text) from public, anon, authenticated;
revoke all on function public._asset_suggest_sync(text, boolean) from public, anon, authenticated;
revoke all on function public._asset_sugg_me(text) from public, anon, authenticated;

-- Live counter: stream suggestion changes.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public'
                        and tablename = 'asset_suggestions') then
    alter publication supabase_realtime add table public.asset_suggestions;
  end if;
end $$;
