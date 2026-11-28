-- Purchase Order: reject flow with creator acknowledgement.
--   An approver rejects a pending PO with a reason. The PO goes back to draft
--   (unlocked) for the creator to fix and re-confirm. The creator gets an
--   in-app chime + banner, a device push, and a pendency badge that clears only
--   when they acknowledge. Rejection + acknowledgement are logged in the PO
--   audit trail by the app.

alter table if exists public.purchase_orders
  add column if not exists rejected_at       timestamptz,
  add column if not exists rejected_by       text,
  add column if not exists rejected_by_name  text,
  add column if not exists reject_reason     text,
  add column if not exists reject_ack_at     timestamptz,
  add column if not exists reject_ack_by     text;

-- Device push to the PO's creator the moment it is rejected.
create or replace function public.trg_po_rejected_push()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_body text;
begin
  begin
    if NEW.rejected_at is null then return NEW; end if;
    if TG_OP = 'UPDATE' and OLD.rejected_at is not distinct from NEW.rejected_at then
      return NEW;
    end if;
    if coalesce(NEW.created_by, '') = '' then return NEW; end if;
    v_body := coalesce(NEW.voucher_number, 'Purchase Order')
              || ' rejected'
              || case when coalesce(NEW.rejected_by_name, '') <> ''
                      then ' by ' || NEW.rejected_by_name else '' end
              || case when coalesce(NEW.reject_reason, '') <> ''
                      then ': ' || NEW.reject_reason else '' end;
    perform push_send(NEW.org_id, array[NEW.created_by],
                      'Purchase Order rejected', v_body,
                      '/erp/purchase?focus=' || NEW.id);
  exception when others then
    null;  -- a push failure must never block the rejection
  end;
  return NEW;
end $function$;

drop trigger if exists po_rejected_push on public.purchase_orders;
create trigger po_rejected_push
  after update on public.purchase_orders
  for each row execute function public.trg_po_rejected_push();
