-- 346 — Employee profile: blood group
-- Safe to run again.
alter table public.hr_employees add column if not exists blood_group text;

-- Count of current employees by blood group (Unisource Lahore)
select coalesce(nullif(trim(blood_group), ''), 'Not recorded') as blood_group, count(*) as employees
  from public.hr_employees
 where org_id = 'org_1784655141655'
   and coalesce(status, 'active') <> 'left'
   and coalesce(is_voided, false) = false
 group by 1
 order by 1;
