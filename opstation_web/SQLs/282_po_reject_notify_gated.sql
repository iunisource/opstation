-- PO rejection push: gated by Admin Settings.
--   org.po_reject_notify        = 'true'  -> send (else nothing)
--   org.po_approval_required    = 'true'  -> rejection only exists with approvals
--   org.po_reject_notify_users  = csv ids -> the designated recipients
--   (none designated -> fall back to the PO's creator)
create or replace function public.trg_po_rejected_push()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_body text; v_on text; v_appr text; v_csv text; v_users text[];
begin
  begin
    if NEW.rejected_at is null then return NEW; end if;
    if TG_OP = 'UPDATE' and OLD.rejected_at is not distinct from NEW.rejected_at then
      return NEW;
    end if;

    select value into v_on   from app_config where org_id = NEW.org_id and key = 'org.po_reject_notify' limit 1;
    select value into v_appr from app_config where org_id = NEW.org_id and key = 'org.po_approval_required' limit 1;
    if coalesce(v_on,'') <> 'true' or coalesce(v_appr,'') <> 'true' then return NEW; end if;

    select value into v_csv from app_config where org_id = NEW.org_id and key = 'org.po_reject_notify_users' limit 1;
    select array_agg(trim(x)) into v_users
      from unnest(string_to_array(coalesce(v_csv,''), ',')) x
     where trim(x) <> '';
    if v_users is null or array_length(v_users, 1) is null then
      if coalesce(NEW.created_by, '') = '' then return NEW; end if;
      v_users := array[NEW.created_by];
    end if;

    v_body := coalesce(NEW.voucher_number, 'Purchase Order')
              || ' rejected'
              || case when coalesce(NEW.rejected_by_name, '') <> ''
                      then ' by ' || NEW.rejected_by_name else '' end
              || case when coalesce(NEW.reject_reason, '') <> ''
                      then ': ' || NEW.reject_reason else '' end;
    perform push_send(NEW.org_id, v_users,
                      'Purchase Order rejected', v_body,
                      '/erp/purchase?focus=' || NEW.id);
  exception when others then
    null;  -- a push failure must never block the rejection
  end;
  return NEW;
end $function$;
