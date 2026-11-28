-- 328 — Void flow ON ⇒ a JV that was ever posted (incl. posted-then-unlocked) can't be deleted.
-- Never-posted drafts can still be deleted. Safe to run again.

create or replace function public._jv_ever_posted(e public.journal_entries)
returns boolean language sql stable set search_path to 'public' as $$
  select e.status = 'posted' or e.posted_at is not null
      or coalesce(e.is_voided, false) or e.reverses_id is not null
      or exists (select 1 from jv_audit_trail a where a.entry_id = e.id and a.action in ('posted', 'unlocked', 'voided'));
$$;

create or replace function public._jv_void_flow_on(p_org text)
returns boolean language sql stable set search_path to 'public' as $$
  select exists (select 1 from app_config where org_id = p_org and key = 'org.jv_void_flow' and value = 'true');
$$;

-- App delete: one atomic call (lines + header), refused when void flow forbids it.
create or replace function public.delete_journal_voucher(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare e journal_entries;
begin
  select * into e from journal_entries where id = p_id for update;
  if not found then raise exception 'Journal voucher not found'; end if;
  if not public._is_org_member(e.org_id) then raise exception 'Not allowed'; end if;
  if e.reference_type = 'jv' and public._jv_void_flow_on(e.org_id) and public._jv_ever_posted(e) then
    raise exception '% was posted — with void flow on it can only be voided, not deleted', e.entry_number;
  end if;
  delete from journal_lines where entry_id = e.id;
  delete from journal_entries where id = e.id;
end $$;
grant execute on function public.delete_journal_voucher(text) to authenticated;

-- Backstop: blocks a direct delete of the header from any other path too.
create or replace function public._jv_block_delete()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if old.reference_type = 'jv' and public._jv_void_flow_on(old.org_id) and public._jv_ever_posted(old) then
    raise exception '% was posted — with void flow on it can only be voided, not deleted', old.entry_number;
  end if;
  return old;
end $$;

drop trigger if exists trg_jv_block_delete on public.journal_entries;
create trigger trg_jv_block_delete before delete on public.journal_entries
  for each row execute function public._jv_block_delete();
