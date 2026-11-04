-- 447 — Private storage for auditor feedback photos.
--
-- Bucket "survey-feedback" (not public). Files are stored as
-- <org id>/<feedback id>.jpg. Only members of that organisation (and the
-- super admin) can upload or view them; viewing uses short-lived links.
-- Nobody but the super admin can delete. Older audit photos stay where they
-- are (opstation-photos/survey-audits/...).
-- Safe to run again.

insert into storage.buckets (id, name, public)
values ('survey-feedback', 'survey-feedback', false)
on conflict (id) do update set public = false;

drop policy if exists survey_feedback_read on storage.objects;
create policy survey_feedback_read on storage.objects for select to authenticated
  using (bucket_id = 'survey-feedback'
         and (public._is_org_member((storage.foldername(name))[1]) or public._is_super_admin()));

drop policy if exists survey_feedback_insert on storage.objects;
create policy survey_feedback_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'survey-feedback'
              and (public._is_org_member((storage.foldername(name))[1]) or public._is_super_admin()));

-- Re-sending the same photo after a lost connection overwrites it.
drop policy if exists survey_feedback_update on storage.objects;
create policy survey_feedback_update on storage.objects for update to authenticated
  using (bucket_id = 'survey-feedback'
         and (public._is_org_member((storage.foldername(name))[1]) or public._is_super_admin()))
  with check (bucket_id = 'survey-feedback'
              and (public._is_org_member((storage.foldername(name))[1]) or public._is_super_admin()));

drop policy if exists survey_feedback_delete on storage.objects;
create policy survey_feedback_delete on storage.objects for delete to authenticated
  using (bucket_id = 'survey-feedback' and public._is_super_admin());

select 'survey feedback photos ready' as result;
