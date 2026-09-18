-- JV supervision + support documents. Run once in the Supabase SQL editor.

-- 1) Non-blocking supervise mark on Journal Vouchers.
alter table journal_entries add column if not exists supervised_by text;
alter table journal_entries add column if not exists supervised_at timestamptz;
alter table journal_entries add column if not exists supervised_by_name text;
alter table journal_entries add column if not exists supervised_signature_url text;
alter table journal_entries add column if not exists supervised_stamp_url text;

-- 2) Separate storage bucket for JV support docs (public read, like the other
--    voucher-document buckets). Files are stored as <org_id>/<voucher>_<n>.<ext>.
insert into storage.buckets (id, name, public)
values ('jv-documents', 'jv-documents', true)
on conflict (id) do nothing;

-- 3) Storage policies: anyone can read (public bucket); authenticated users
--    (the app) manage the JV files.
do $$
begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='jv_docs_read') then
    create policy jv_docs_read on storage.objects for select using (bucket_id = 'jv-documents');
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='jv_docs_write') then
    create policy jv_docs_write on storage.objects for insert to authenticated with check (bucket_id = 'jv-documents');
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='jv_docs_update') then
    create policy jv_docs_update on storage.objects for update to authenticated using (bucket_id = 'jv-documents');
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='jv_docs_delete') then
    create policy jv_docs_delete on storage.objects for delete to authenticated using (bucket_id = 'jv-documents');
  end if;
end $$;

-- The voucher_documents registry table already exists (used by GRN/PI) and is
-- generic over voucher_type, so JV rows need no new table.
