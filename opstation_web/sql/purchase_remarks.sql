-- Carry-forward Remarks for PO → GRN → PI. Run once in the Supabase SQL editor.

alter table purchase_orders   add column if not exists remarks text;
alter table purchase_orders   add column if not exists copy_remarks boolean not null default false;

alter table purchase_grns     add column if not exists remarks text;
alter table purchase_grns     add column if not exists copy_remarks boolean not null default false;

alter table purchase_invoices add column if not exists remarks text;
