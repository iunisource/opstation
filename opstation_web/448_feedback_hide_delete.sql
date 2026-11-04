-- 448 — Hide / delete auditor feedback.
--
--  • Admins, master admins (and the super admin) can hide a feedback / audit
--    entry, and unhide it. A hidden entry disappears for everyone else —
--    the auditors' app, badges, filters and reports — but stays in the
--    database with who hid it and why.
--  • Only the super admin can delete an entry permanently.
-- Run after 447. Safe to run again.

alter table public.survey_audits
  add column if not exists hidden_at timestamptz,
  add column if not exists hidden_by text,
  add column if not exists hidden_by_name text,
  add column if not exists hide_reason text;

-- Hidden entries are visible only to admins (to unhide them) and the super admin.
drop policy if exists sa_read on public.survey_audits;
create policy sa_read on public.survey_audits for select
  using ((public._is_org_member(org_id) and (hidden_at is null or public._is_org_admin(org_id)))
         or public._is_super_admin());

create or replace function public.set_survey_audit_hidden(p_id text, p_hide boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a public.survey_audits; v_me text; v_me_name text;
begin
  select * into a from public.survey_audits where id = p_id for update;
  if not found then raise exception 'Feedback not found.'; end if;
  if not (public._is_org_admin(a.org_id) or public._is_super_admin()) then
    raise exception 'Only admins can hide feedback.';
  end if;
  select u.id, u.name into v_me, v_me_name
    from public._acting_user(a.org_id) x join public.users u on u.id = x.id;
  if p_hide then
    update public.survey_audits
       set hidden_at = now(), hidden_by = coalesce(v_me, 'super_admin'),
           hidden_by_name = coalesce(v_me_name, 'Super admin'),
           hide_reason = nullif(btrim(coalesce(p_reason, '')), '')
     where id = p_id;
  else
    update public.survey_audits
       set hidden_at = null, hidden_by = null, hidden_by_name = null, hide_reason = null
     where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.set_survey_audit_hidden(text, boolean, text) from public, anon;
grant execute on function public.set_survey_audit_hidden(text, boolean, text) to authenticated;

-- Permanent delete (super admin). Returns the photo path so the web can
-- remove the photo too.
create or replace function public.delete_survey_audit(p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_photo text;
begin
  if not public._is_super_admin() then raise exception 'Only the super admin can delete feedback.'; end if;
  delete from public.survey_audits where id = p_id returning photo_path into v_photo;
  return jsonb_build_object('ok', true, 'photo_path', v_photo);
end $$;
revoke execute on function public.delete_survey_audit(text) from public, anon;
grant execute on function public.delete_survey_audit(text) to authenticated;

notify pgrst, 'reload schema';
select 'feedback hide / delete ready' as result;
