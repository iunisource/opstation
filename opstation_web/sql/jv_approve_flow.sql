-- JV blocking approval flow (org.jv_approve_flow). Run once in the SQL editor.
-- Independent of the supervision flow; both can be on at the same time.

alter table journal_entries add column if not exists approval_status text; -- null / 'pending' / 'approved'
alter table journal_entries add column if not exists approved_by text;
alter table journal_entries add column if not exists approved_by_name text;
alter table journal_entries add column if not exists approved_at timestamptz;
