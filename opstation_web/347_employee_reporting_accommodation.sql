-- 347 — Employee profile: Reporting to (free text) and Accommodation
-- accommodation: 'personal' (Personal / Private) | 'company' (Company provided)
-- Safe to run again.
alter table public.hr_employees add column if not exists reports_to text;
alter table public.hr_employees add column if not exists accommodation text;
alter table public.hr_employees add column if not exists blood_group text;   -- (346, in case not run)
select count(*) as employees from public.hr_employees;
