-- Payment Advice: allow archiving slips (hidden from the default list, shown
-- via the "Show archived" toggle). Non-destructive — an archived slip keeps all
-- its data and can be unarchived.

alter table if exists payment_advices
  add column if not exists is_archived boolean not null default false;
