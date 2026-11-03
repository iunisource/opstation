-- 442 — Survey audits: allow a third result, 'feedback' (a note on the shop
-- without a Matches / Issue verdict). Safe to run again.
alter table public.survey_audits drop constraint if exists survey_audits_result_check;
alter table public.survey_audits
  add constraint survey_audits_result_check check (result in ('ok', 'issue', 'feedback'));
select 'feedback allowed' as result;
