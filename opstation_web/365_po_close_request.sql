-- 365 — "Request close" on Purchase Orders.
-- A non-admin can't void a PO. Now they can ask for it: "Request close" with a
-- reason. Admins get notified (Admin Settings → Notifications → "PO close
-- requested"), open the PO and Approve (the PO is voided) or Decline (with a
-- reason). The requester is notified either way. Everything is kept in the
-- PO's history. Requires 295 (void_purchase_order) and 296 (notify_event).
-- Safe to run again.

alter table public.purchase_orders
  add column if not exists close_req_status        text,        -- pending | approved | declined | withdrawn
  add column if not exists close_req_at            timestamptz,
  add column if not exists close_req_by            text,
  add column if not exists close_req_by_name       text,
  add column if not exists close_req_reason        text,
  add column if not exists close_req_decided_at    timestamptz,
  add column if not exists close_req_decided_by_name text,
  add column if not exists close_req_decline_reason text;

create index if not exists idx_po_close_req_pending
  on public.purchase_orders(org_id) where close_req_status = 'pending';

-- The signed-in person's user row in an org.
create or replace function public._po_me(p_org text)
returns table(id text, name text, role text)
language sql stable security definer set search_path to 'public'
as $$
  select u.id, u.name, u.role::text
    from public.users u
   where u.org_id = p_org and coalesce(u.is_active, true)
     and (u.account_id = public.current_account_id()
          or lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
   limit 1;
$$;

-- Guard: the close_req_* fields can only change through the functions below.
create or replace function public.trg_po_close_req_guard()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('opstation.po_close_rpc', true), '') <> '1'
     and auth.uid() is not null
     and (NEW.close_req_status        is distinct from OLD.close_req_status
       or NEW.close_req_at            is distinct from OLD.close_req_at
       or NEW.close_req_by            is distinct from OLD.close_req_by
       or NEW.close_req_reason        is distinct from OLD.close_req_reason
       or NEW.close_req_decided_at    is distinct from OLD.close_req_decided_at
       or NEW.close_req_decline_reason is distinct from OLD.close_req_decline_reason) then
    raise exception 'Close requests can only be changed from the Purchase Order screen.' using errcode = 'P0001';
  end if;
  return NEW;
end $$;

drop trigger if exists aa_po_close_req_guard on public.purchase_orders;
create trigger aa_po_close_req_guard before update on public.purchase_orders
  for each row execute function public.trg_po_close_req_guard();

-- ── 1. Ask ──────────────────────────────────────────────────────────────────
create or replace function public.request_po_close(p_id text, p_reason text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare po public.purchase_orders%rowtype; me record; v_grn text; v_reason text;
begin
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then raise exception 'Please give a reason.' using errcode = 'P0001'; end if;

  select * into po from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'Purchase order not found.' using errcode = 'P0001'; end if;
  select * into me from public._po_me(po.org_id);
  if me.id is null then raise exception 'You are not a member of this organisation.' using errcode = 'P0001'; end if;

  if po.voided_at is not null then raise exception 'This PO is already voided.' using errcode = 'P0001'; end if;
  if po.close_req_status = 'pending' then
    raise exception 'A close request is already waiting for an admin.' using errcode = 'P0001';
  end if;
  if coalesce(po.status, '') in ('received', 'invoiced') then
    raise exception 'This PO is already closed.' using errcode = 'P0001';
  end if;
  select voucher_number into v_grn from public.purchase_grns
   where po_id = p_id and not coalesce(is_voided, false) limit 1;
  if v_grn is not null then
    raise exception 'Goods were already received on %. Use "Close remaining" instead.', v_grn using errcode = 'P0001';
  end if;

  perform set_config('opstation.po_close_rpc', '1', true);
  update public.purchase_orders
     set close_req_status = 'pending', close_req_at = now(),
         close_req_by = me.id, close_req_by_name = me.name, close_req_reason = v_reason,
         close_req_decided_at = null, close_req_decided_by_name = null, close_req_decline_reason = null,
         updated_at = now()
   where id = p_id;
  perform set_config('opstation.po_close_rpc', '', true);

  insert into public.voucher_audit_log(org_id, voucher_id, voucher_type, action, details, performed_by)
  values (po.org_id, p_id, 'PO', 'close_requested',
          'Close requested by ' || coalesce(me.name, '') || ': ' || v_reason, me.id);

  begin
    perform public.notify_event(po.org_id, 'po_close_request', po.branch_id, me.id,
      'PO close requested',
      coalesce(po.voucher_number, 'Purchase Order') || ' — ' || coalesce(me.name, 'Someone')
        || ' asked to close it: ' || v_reason,
      '/erp/purchase?focus=' || p_id);
  exception when others then null;
  end;
end $$;

-- ── 2. Withdraw (the person who asked, or an admin) ────────────────────────
create or replace function public.withdraw_po_close(p_id text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare po public.purchase_orders%rowtype; me record;
begin
  select * into po from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'Purchase order not found.' using errcode = 'P0001'; end if;
  select * into me from public._po_me(po.org_id);
  if me.id is null then raise exception 'You are not a member of this organisation.' using errcode = 'P0001'; end if;
  if coalesce(po.close_req_status, '') <> 'pending' then
    raise exception 'There is no close request waiting on this PO.' using errcode = 'P0001';
  end if;
  if me.id is distinct from po.close_req_by and me.role not in ('admin', 'masterAdmin', 'superAdmin') then
    raise exception 'Only the person who asked can withdraw this request.' using errcode = 'P0001';
  end if;

  perform set_config('opstation.po_close_rpc', '1', true);
  update public.purchase_orders
     set close_req_status = 'withdrawn', close_req_decided_at = now(),
         close_req_decided_by_name = me.name, updated_at = now()
   where id = p_id;
  perform set_config('opstation.po_close_rpc', '', true);

  insert into public.voucher_audit_log(org_id, voucher_id, voucher_type, action, details, performed_by)
  values (po.org_id, p_id, 'PO', 'close_request_withdrawn',
          'Close request withdrawn by ' || coalesce(me.name, ''), me.id);
end $$;

-- ── 3. Decide (admins only) ────────────────────────────────────────────────
create or replace function public.decide_po_close(p_id text, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare po public.purchase_orders%rowtype; me record; v_note text;
begin
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  select * into po from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'Purchase order not found.' using errcode = 'P0001'; end if;
  select * into me from public._po_me(po.org_id);
  if me.id is null or me.role not in ('admin', 'masterAdmin', 'superAdmin') then
    raise exception 'Only an admin can approve or decline a close request.' using errcode = 'P0001';
  end if;
  if coalesce(po.close_req_status, '') <> 'pending' then
    raise exception 'There is no close request waiting on this PO.' using errcode = 'P0001';
  end if;
  if not p_approve and v_note is null then
    raise exception 'Please give a reason for declining.' using errcode = 'P0001';
  end if;

  if p_approve then
    -- Voids the PO (fails cleanly if goods arrived in the meantime).
    perform public.void_purchase_order(p_id, me.id,
      'Close requested by ' || coalesce(po.close_req_by_name, '') || ': ' || coalesce(po.close_req_reason, '')
      || coalesce(' · ' || v_note, ''));
  end if;

  perform set_config('opstation.po_close_rpc', '1', true);
  update public.purchase_orders
     set close_req_status = case when p_approve then 'approved' else 'declined' end,
         close_req_decided_at = now(), close_req_decided_by_name = me.name,
         close_req_decline_reason = case when p_approve then null else v_note end,
         updated_at = now()
   where id = p_id;
  perform set_config('opstation.po_close_rpc', '', true);

  insert into public.voucher_audit_log(org_id, voucher_id, voucher_type, action, details, performed_by)
  values (po.org_id, p_id, 'PO',
          case when p_approve then 'close_request_approved' else 'close_request_declined' end,
          case when p_approve then 'Close request approved by ' || coalesce(me.name, '') || ' — PO voided'
               else 'Close request declined by ' || coalesce(me.name, '') || ': ' || v_note end,
          me.id);

  begin
    perform public.notify_event(po.org_id, 'po_close_decided', po.branch_id, po.close_req_by,
      case when p_approve then 'PO close approved' else 'PO close declined' end,
      coalesce(po.voucher_number, 'Purchase Order')
        || case when p_approve then ' was closed (voided) by ' || coalesce(me.name, 'an admin')
                else ' — ' || coalesce(me.name, 'an admin') || ' declined your close request: ' || v_note end,
      '/erp/purchase?focus=' || p_id);
  exception when others then null;
  end;
end $$;

revoke all on function public.request_po_close(text, text) from public, anon;
revoke all on function public.withdraw_po_close(text) from public, anon;
revoke all on function public.decide_po_close(text, boolean, text) from public, anon;
grant execute on function public.request_po_close(text, text) to authenticated;
grant execute on function public.withdraw_po_close(text) to authenticated;
grant execute on function public.decide_po_close(text, boolean, text) to authenticated;
revoke all on function public._po_me(text) from public, anon, authenticated;
