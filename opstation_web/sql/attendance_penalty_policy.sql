-- Attendance penalty policy — schema additions
-- Run once in the Supabase SQL editor. Safe to re-run (IF NOT EXISTS).

-- 1) Per-shift policy: penalize unapproved absence, and how many extra absents.
alter table hr_shifts
  add column if not exists penalize_unapproved_absence boolean not null default false;
alter table hr_shifts
  add column if not exists absence_penalty_days integer not null default 1;

-- 2) Attendance row flags used by the Attendance Review screen:
--    review_status : null/'pending' = needs review, 'excused' = approved leave,
--                    'unapproved' = confirmed unapproved absence.
--    is_penalty    : true = system-added penalty absent (punch times may exist
--                    on the row, but the day reports as Absent).
--    penalty_source_date : the original unapproved-absence date that caused it.
alter table hr_attendance
  add column if not exists review_status text;
alter table hr_attendance
  add column if not exists is_penalty boolean not null default false;
alter table hr_attendance
  add column if not exists penalty_source_date date;

-- Helpful for the review scan (org + date range).
create index if not exists hr_attendance_org_date_idx
  on hr_attendance (org_id, att_date);
