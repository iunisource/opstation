-- 295 — Purchase flow: VOID instead of delete.
--
-- Once a purchase document has been submitted / posted it can no longer be
-- deleted — it is VOIDED: it keeps its number and audit trail, prints with a
-- VOIDED watermark, and its stock + ledger effects are reversed (dated on the
-- voucher's own date so the period nets out). Unposted drafts can still be
-- deleted.
--
--   PO   void_purchase_order          — blocked while an active GRN exists
--   GRN  void_purchase_grn            — blocked while an active PI exists or
--                                       its goods were already sold/consumed;
--                                       stock, cost layers, GL (incl. qty
--                                       corrections) and PO progress reversed
--   PI   void_purchase_invoice        — blocked while an active return note
--                                       references it; GL reversed, GRN layer
--                                       costs reset, GRN released for re-invoicing
--   PRN  void_purchase_return         — blocked while an active return invoice
--                                       exists; returned stock put back
--   PRI  void_purchase_return_invoice — GL + FIFO consumption reversed, PRN
--                                       released for re-invoicing
--
-- A server guard also stops anything (old app versions included) from
-- deleting a posted purchase document.
--
-- Run the WHOLE file once. Safe to run again.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Columns
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.purchase_returns
  add column if not exists is_voided boolean not null default false,
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by text;

alter table public.purchase_orders          add column if not exists void_reason text;
alter table public.purchase_grns            add column if not exists void_reason text,
                                            add column if not exists voided_by_name text;
alter table public.purchase_invoices        add column if not exists void_reason text,
                                            add column if not exists voided_by_name text;
alter table public.purchase_returns         add column if not exists void_reason text,
                                            add column if not exists voided_by_name text;
alter table public.purchase_return_invoices add column if not exists void_reason text,
                                            add column if not exists voided_by_name text;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Helpers
-- ─────────────────────────────────────────────────────────────────────────────
-- Only admins may void. Returns the user's name.
create or replace function public._void_actor(p_org text, p_user text)
returns text
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_name text;
begin
  select name into v_name from public.users
   where id = p_user and org_id = p_org
     and role in ('admin', 'masterAdmin', 'superAdmin')
     and coalesce(is_active, true)
     -- the user id must belong to the person actually signed in
     and (account_id = public.current_account_id()
          or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
  if not found then
    raise exception 'Only an admin can void purchase documents.' using errcode = 'P0001';
  end if;
  return v_name;
end $$;

-- void_voucher() stamps its reversal entries with the void date. Move the ones
-- made in THIS transaction onto the voucher's own date so the period nets out.
create or replace function public._void_align_date(p_org text, p_ref text, p_date date)
returns void
language sql security definer set search_path to 'public'
as $$
  update public.journal_entries
     set entry_date = p_date
   where org_id = p_org and reference_type = 'void' and reference_id = p_ref
     and created_at = now() and p_date is not null;
$$;

-- True if the document has ever posted to the ledger or moved stock.
create or replace function public._doc_has_postings(p_org text, p_id text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (select 1 from public.journal_entries
                  where org_id = p_org and reference_id = p_id)
      or exists (select 1 from public.inventory_movements
                  where org_id = p_org and reference_id = p_id)
      or exists (select 1 from public.inventory_cost_layers
                  where org_id = p_org and source_id = p_id);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. PO
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.void_purchase_order(p_id text, p_user_id text, p_reason text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare po public.purchase_orders%rowtype; v_name text; v_grn text;
begin
  select * into po from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'Purchase order not found.'; end if;
  v_name := public._void_actor(po.org_id, p_user_id);
  if po.voided_at is not null then raise exception 'Purchase order % is already voided.', po.voucher_number; end if;

  select voucher_number into v_grn from public.purchase_grns
   where po_id = p_id and not coalesce(is_voided, false) limit 1;
  if v_grn is not null then
    raise exception 'Cannot void: GRN % is still active against this PO. Void it (or delete it, if still a draft) first.', v_grn
      using errcode = 'P0001';
  end if;

  update public.purchase_orders
     set voided_at = now(), voided_by = p_user_id, voided_by_name = v_name,
         void_reason = nullif(trim(coalesce(p_reason, '')), ''), updated_at = now()
   where id = p_id;

  insert into public.voucher_audit_log(org_id, voucher_id, voucher_type, action, details, performed_by)
  values (po.org_id, p_id, 'PO', 'voided',
          'PO ' || coalesce(po.voucher_number, p_id) || ' voided by ' || coalesce(v_name, '')
          || coalesce(': ' || nullif(trim(coalesce(p_reason, '')), ''), ''), p_user_id);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. GRN
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.void_purchase_grn(p_id text, p_user_id text, p_reason text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare
  g public.purchase_grns%rowtype; v_name text; v_pi text; je record; v_rev text;
  v_all boolean; v_any boolean; v_date date;
begin
  select * into g from public.purchase_grns where id = p_id for update;
  if not found then raise exception 'GRN not found.'; end if;
  v_name := public._void_actor(g.org_id, p_user_id);
  if coalesce(g.is_voided, false) then raise exception 'GRN % is already voided.', g.voucher_number; end if;
  if coalesce(g.status, 'draft') = 'draft' and not public._doc_has_postings(g.org_id, g.id) then
    raise exception 'GRN % is still a draft — delete it instead.', g.voucher_number using errcode = 'P0001';
  end if;

  select voucher_number into v_pi from public.purchase_invoices
   where grn_id = p_id and not coalesce(is_voided, false) limit 1;
  if v_pi is not null then
    raise exception 'Cannot void: purchase invoice % is still active for this GRN. Void it first.', v_pi
      using errcode = 'P0001';
  end if;

  if exists (select 1 from public.inventory_cost_consumption c
               join public.inventory_cost_layers l on l.id = c.layer_id
              where l.org_id = g.org_id and l.source_id = g.id) then
    raise exception 'Cannot void GRN %: some of its goods were already sold or consumed. Reverse those first.', g.voucher_number
      using errcode = 'P0001';
  end if;

  v_date := coalesce(g.voucher_date, current_date);

  -- Flip the flag: the existing void_grn trigger runs void_voucher(), which
  -- reverses the GL, removes the cost layers and puts the stock back (it
  -- refuses if any of the received goods were already sold/consumed).
  update public.purchase_grns
     set is_voided = true, voided_at = now(), voided_by = p_user_id,
         voided_by_name = v_name, void_reason = nullif(trim(coalesce(p_reason, '')), ''),
         updated_at = now()
   where id = p_id;

  -- Post-receipt quantity corrections post under their own reference; reverse them too.
  for je in
    select * from public.journal_entries
     where org_id = g.org_id and reference_type = 'grn_qty_correction'
       and reference_number is not distinct from g.voucher_number
       and branch_id is not distinct from g.branch_id
       and reversed_by is null
  loop
    v_rev := 'je_' || replace(gen_random_uuid()::text, '-', '');
    insert into public.journal_entries(id, org_id, branch_id, entry_number, entry_date, description,
      reference_type, reference_id, reference_number, status, is_system_generated, created_by, created_at, posted_at)
    values (v_rev, je.org_id, je.branch_id, 'VOID-' || coalesce(je.entry_number, ''), v_date,
      'Void of ' || coalesce(je.entry_number, je.id), 'void', g.id, je.reference_number,
      'posted', true, p_user_id, now(), now());
    insert into public.journal_lines(id, entry_id, org_id, branch_id, account_id, debit, credit,
      description, line_order, account_type, account_name, party_id)
    select 'jl_' || replace(gen_random_uuid()::text, '-', ''), v_rev, jl.org_id, jl.branch_id,
      jl.account_id, jl.credit, jl.debit, 'Void: ' || coalesce(jl.description, ''),
      jl.line_order, jl.account_type, jl.account_name, jl.party_id
    from public.journal_lines jl where jl.entry_id = je.id;
    update public.journal_entries set reversed_by = v_rev where id = je.id;
  end loop;

  -- Roll back the PO's received progress.
  if coalesce(g.status, 'draft') <> 'draft' then
    update public.purchase_order_items poi
       set quantity_received = greatest(coalesce(poi.quantity_received, 0) - i.qty_received, 0)
      from public.purchase_grn_items i
     where i.grn_id = g.id and i.po_item_id = poi.id and coalesce(i.qty_received, 0) > 0;
    if g.po_id is not null then
      select bool_and(coalesce(quantity_received, 0) >= coalesce(quantity_ordered, 0)),
             bool_or(coalesce(quantity_received, 0) > 0)
        into v_all, v_any
        from public.purchase_order_items where purchase_order_id = g.po_id;
      update public.purchase_orders
         set status = case when v_all then 'received'
                           when v_any then 'partially_received'
                           else 'ordered' end,
             updated_at = now()
       where id = g.po_id;
    end if;
  end if;

  perform public._void_align_date(g.org_id, g.id, v_date);

  insert into public.voucher_audit_log(org_id, voucher_id, voucher_type, action, details, performed_by)
  values (g.org_id, g.id, 'GRN', 'voided',
          'GRN ' || coalesce(g.voucher_number, g.id) || ' voided by ' || coalesce(v_name, '')
          || ' — stock, cost layers, GL and PO progress reversed'
          || coalesce(': ' || nullif(trim(coalesce(p_reason, '')), ''), ''), p_user_id);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Purchase Invoice
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.void_purchase_invoice(p_id text, p_user_id text, p_reason text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare pi public.purchase_invoices%rowtype; v_name text; v_prn text; v_partial boolean;
begin
  select * into pi from public.purchase_invoices where id = p_id for update;
  if not found then raise exception 'Purchase invoice not found.'; end if;
  v_name := public._void_actor(pi.org_id, p_user_id);
  if coalesce(pi.is_voided, false) then raise exception 'Purchase invoice % is already voided.', pi.voucher_number; end if;
  if not coalesce(pi.is_locked, false) and not public._doc_has_postings(pi.org_id, pi.id) then
    raise exception 'Purchase invoice % is still a draft — delete it instead.', pi.voucher_number using errcode = 'P0001';
  end if;

  select voucher_number into v_prn from public.purchase_returns
   where pi_id = p_id and not coalesce(is_voided, false) limit 1;
  if v_prn is not null then
    raise exception 'Cannot void: purchase return % references this invoice. Void it first.', v_prn
      using errcode = 'P0001';
  end if;

  -- Flip the flag: the existing void_pi trigger reverses its ledger entry.
  update public.purchase_invoices
     set is_voided = true, voided_at = now(), voided_by = p_user_id,
         voided_by_name = v_name, void_reason = nullif(trim(coalesce(p_reason, '')), ''),
         updated_at = now()
   where id = p_id;

  if pi.grn_id is not null then
    -- The invoice trued the GRN's cost layers up to the invoiced price; put
    -- them back to the receipt cost so a new invoice starts clean.
    update public.inventory_cost_layers l
       set unit_cost = case when coalesce(p.is_consignment, false) then 0
                            else coalesce(nullif(poi.unit_cost, 0), p.cost_price, 0) end
      from public.purchase_grn_items gi
      left join public.purchase_order_items poi on poi.id = gi.po_item_id
      left join public.products p on p.id = gi.product_id
     where l.org_id = pi.org_id and l.source_type = 'grn' and l.source_id = pi.grn_id
       and gi.grn_id = pi.grn_id and gi.product_id = l.product_id;

    -- Release the GRN so it can be invoiced again.
    select bool_or(coalesce(qty_received, 0) < coalesce(qty_ordered, 0))
      into v_partial from public.purchase_grn_items where grn_id = pi.grn_id;
    update public.purchase_grns
       set status = case when coalesce(v_partial, false) then 'partially_received' else 'received' end,
           updated_at = now()
     where id = pi.grn_id and not coalesce(is_voided, false);
  end if;

  perform public._void_align_date(pi.org_id, pi.id, coalesce(pi.voucher_date, current_date));

  insert into public.voucher_audit_log(org_id, voucher_id, voucher_type, action, details, performed_by)
  values (pi.org_id, pi.id, 'PI', 'voided',
          'PI ' || coalesce(pi.voucher_number, pi.id) || ' voided by ' || coalesce(v_name, '')
          || ' — ledger reversed, GRN released'
          || coalesce(': ' || nullif(trim(coalesce(p_reason, '')), ''), ''), p_user_id);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Purchase Return Note
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.void_purchase_return(p_id text, p_user_id text, p_reason text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare
  v public.purchase_returns%rowtype; v_name text; v_pri text; r record;
  v_cycle text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  v_moved timestamptz;
begin
  select * into v from public.purchase_returns where id = p_id for update;
  if not found then raise exception 'Purchase return not found.'; end if;
  v_name := public._void_actor(v.org_id, p_user_id);
  if coalesce(v.is_voided, false) then raise exception 'Purchase return % is already voided.', v.voucher_number; end if;
  if coalesce(v.status, 'draft') = 'draft' and not public._doc_has_postings(v.org_id, v.id) then
    raise exception 'Purchase return % is still a draft — delete it instead.', v.voucher_number using errcode = 'P0001';
  end if;

  select voucher_number into v_pri from public.purchase_return_invoices
   where prn_id = p_id and not coalesce(is_voided, false) limit 1;
  if v_pri is not null then
    raise exception 'Cannot void: return invoice % is still active for this note. Void it first.', v_pri
      using errcode = 'P0001';
  end if;

  v_moved := coalesce((v.voucher_date::date + (now() at time zone 'Asia/Karachi')::time) at time zone 'Asia/Karachi', now());

  -- Put the returned stock back (only if the note actually moved it).
  if coalesce(v.status, 'draft') <> 'draft' then
    for r in select * from public.purchase_return_items where return_id = p_id loop
      continue when coalesce(r.quantity, 0) <= 0;
      insert into public.inventory_movements
        (id, org_id, product_id, branch_id, uom_id, quantity, movement_type,
         reference_id, reference_type, moved_at, created_by, source_line_id)
      values ('im_' || r.id || '_void_' || v_cycle, v.org_id, r.product_id, v.branch_id, r.uom_id,
              r.quantity, 'adjustment', p_id, 'purchase_return_voided',
              v_moved, p_user_id, r.id || ':void:' || v_cycle);
      perform public.apply_stock_delta(v.org_id, v.branch_id, r.product_id, r.uom_id, r.quantity);
    end loop;
  end if;

  update public.purchase_returns
     set is_voided = true, voided_at = now(), voided_by = p_user_id,
         voided_by_name = v_name, void_reason = nullif(trim(coalesce(p_reason, '')), ''),
         is_locked = true, updated_at = now()
   where id = p_id;

  insert into public.voucher_audit_log(org_id, voucher_id, voucher_type, action, details, performed_by)
  values (v.org_id, p_id, 'PRN', 'voided',
          'PRN ' || coalesce(v.voucher_number, p_id) || ' voided by ' || coalesce(v_name, '')
          || case when coalesce(v.status, 'draft') <> 'draft' then ' — stock put back' else '' end
          || coalesce(': ' || nullif(trim(coalesce(p_reason, '')), ''), ''), p_user_id);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Purchase Return Invoice
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.void_purchase_return_invoice(p_id text, p_user_id text, p_reason text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare v public.purchase_return_invoices%rowtype; v_name text;
begin
  select * into v from public.purchase_return_invoices where id = p_id for update;
  if not found then raise exception 'Purchase return invoice not found.'; end if;
  v_name := public._void_actor(v.org_id, p_user_id);
  if coalesce(v.is_voided, false) then raise exception 'Return invoice % is already voided.', v.voucher_number; end if;
  if not coalesce(v.is_locked, false) and not public._doc_has_postings(v.org_id, v.id) then
    raise exception 'Return invoice % is still a draft — delete it instead.', v.voucher_number using errcode = 'P0001';
  end if;

  -- Flip the flag: the existing void_pri trigger reverses the ledger entry and
  -- the FIFO cost it consumed.
  update public.purchase_return_invoices
     set is_voided = true, voided_at = now(), voided_by = p_user_id,
         voided_by_name = v_name, void_reason = nullif(trim(coalesce(p_reason, '')), ''),
         updated_at = now()
   where id = p_id;

  -- Release the return note so it can be invoiced again (its stock stays returned).
  if v.prn_id is not null then
    update public.purchase_returns
       set status = 'saved', is_locked = true, updated_at = now()
     where id = v.prn_id and not coalesce(is_voided, false);
  end if;

  perform public._void_align_date(v.org_id, v.id, coalesce(v.voucher_date, current_date));

  insert into public.voucher_audit_log(org_id, voucher_id, voucher_type, action, details, performed_by)
  values (v.org_id, p_id, 'PRI', 'voided',
          'PRI ' || coalesce(v.voucher_number, p_id) || ' voided by ' || coalesce(v_name, '')
          || ' — ledger reversed, return note released'
          || coalesce(': ' || nullif(trim(coalesce(p_reason, '')), ''), ''), p_user_id);
end $$;

revoke all on function public.void_purchase_order(text, text, text) from public, anon;
revoke all on function public.void_purchase_grn(text, text, text) from public, anon;
revoke all on function public.void_purchase_invoice(text, text, text) from public, anon;
revoke all on function public.void_purchase_return(text, text, text) from public, anon;
revoke all on function public.void_purchase_return_invoice(text, text, text) from public, anon;
grant execute on function public.void_purchase_order(text, text, text) to authenticated;
grant execute on function public.void_purchase_grn(text, text, text) to authenticated;
grant execute on function public.void_purchase_invoice(text, text, text) to authenticated;
grant execute on function public.void_purchase_return(text, text, text) to authenticated;
grant execute on function public.void_purchase_return_invoice(text, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Guard: a submitted / posted / voided purchase document cannot be deleted
--    (escape hatch for data clean-up: set local app.allow_posted_delete = 'on')
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.trg_purchase_no_posted_delete()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare o jsonb := to_jsonb(OLD); v_num text; v_block boolean := false;
begin
  if coalesce(current_setting('app.allow_posted_delete', true), '') = 'on' then return OLD; end if;
  v_num := coalesce(o->>'voucher_number', o->>'id');

  if coalesce((o->>'is_voided')::boolean, false) or (o->>'voided_at') is not null then
    raise exception '% is voided and is kept for the record — it cannot be deleted.', v_num using errcode = 'P0001';
  end if;

  if TG_TABLE_NAME = 'purchase_orders' then
    v_block := coalesce((o->>'is_locked')::boolean, false)
            or (o->>'approved_at') is not null
            or (o->>'rejected_at') is not null
            or exists (select 1 from public.purchase_grns where po_id = OLD.id);
  elsif TG_TABLE_NAME in ('purchase_grns', 'purchase_returns') then
    v_block := coalesce(o->>'status', 'draft') <> 'draft'
            or public._doc_has_postings(o->>'org_id', OLD.id);
  else -- purchase_invoices, purchase_return_invoices
    v_block := coalesce((o->>'is_locked')::boolean, false)
            or public._doc_has_postings(o->>'org_id', OLD.id);
  end if;

  if v_block then
    raise exception '% has been submitted/posted — void it instead of deleting.', v_num using errcode = 'P0001';
  end if;
  return OLD;
end $$;

do $$
declare t text;
begin
  foreach t in array array['purchase_orders','purchase_grns','purchase_invoices',
                           'purchase_returns','purchase_return_invoices'] loop
    execute format('drop trigger if exists a_no_posted_delete on public.%I', t);
    execute format('create trigger a_no_posted_delete before delete on public.%I
                    for each row execute function public.trg_purchase_no_posted_delete()', t);
  end loop;
end $$;
