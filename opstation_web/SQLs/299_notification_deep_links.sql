-- 299 — Notifications open the exact document.
-- Every notification now carries a link to the record itself (leave request,
-- journal voucher, field / retailer order, sales return invoice, payroll run —
-- the others already did). Requires 296 and 297. Safe to run again.

create or replace function public.trg_notify_events()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  n jsonb := to_jsonb(NEW);
  o jsonb := case when TG_OP = 'UPDATE' then to_jsonb(OLD) else '{}'::jsonb end;
  v_org text := n->>'org_id';
  v_id text := n->>'id';
  v_br text := n->>'branch_id';
  v_by text := n->>'created_by';
  v_num text := coalesce(n->>'voucher_number', n->>'advice_number', n->>'entry_number', '');
  v_sup text; v_amt text;
begin
  begin
    if v_org is null then return NEW; end if;

    if TG_TABLE_NAME = 'purchase_orders' then
      -- Submitted for approval
      if _became_locked(n, o) and n->>'approved_at' is null and n->>'voided_at' is null
         and _cfg_on(v_org, 'org.po_approval_required') then
        select name into v_sup from suppliers where id = n->>'supplier_id';
        select _rs(coalesce(sum(coalesce(quantity_ordered, 0) * coalesce(unit_cost, 0)), 0)) into v_amt
          from purchase_order_items where purchase_order_id = v_id;
        perform notify_event(v_org, 'po_submitted', v_br, v_by, 'Purchase Order pending approval',
          v_num || coalesce(' · ' || v_sup, '') || case when v_amt <> 'Rs 0' then ' · ' || v_amt else '' end,
          '/erp/purchase?focus=' || v_id, 'po', v_id);
      end if;
      -- Approved
      if n->>'approved_at' is not null and o->>'approved_at' is null and TG_OP = 'UPDATE' then
        perform notify_event(v_org, 'po_approved', v_br, v_by, 'Purchase Order approved',
          v_num || ' approved' || coalesce(' by ' || nullif(n->>'approved_by_name', ''), ''),
          '/erp/purchase?focus=' || v_id);
      end if;
      -- Rejected
      if n->>'rejected_at' is not null and (n->>'rejected_at') is distinct from (o->>'rejected_at') then
        perform notify_event(v_org, 'po_rejected', v_br, v_by, 'Purchase Order rejected',
          v_num || ' rejected' || coalesce(' by ' || nullif(n->>'rejected_by_name', ''), '')
                || coalesce(': ' || nullif(n->>'reject_reason', ''), ''),
          '/erp/purchase?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'payment_advices' then
      if TG_OP = 'UPDATE' and coalesce(o->>'status', '') = 'pending' then
        if _became(n, o, 'status', 'approved') then
          perform notify_event(v_org, 'pa_approved', null, v_by, 'Payment Advice approved',
            v_num || ' approved' || coalesce(' by ' || nullif(n->>'approved_by_name', ''), ''),
            '/financials/payment-advice?focus=' || v_id);
        elsif _became(n, o, 'status', 'rejected') then
          perform notify_event(v_org, 'pa_rejected', null, v_by, 'Payment Advice rejected',
            v_num || ' rejected' || coalesce(' by ' || nullif(n->>'rejected_by_name', ''), '')
                  || coalesce(': ' || nullif(n->>'reject_reason', ''), ''),
            '/financials/payment-advice?focus=' || v_id);
        end if;
      end if;

    elsif TG_TABLE_NAME = 'purchase_grns' then
      if coalesce(o->>'status', 'draft') = 'draft' and coalesce(n->>'status', 'draft') <> 'draft'
         and not coalesce((n->>'is_voided')::boolean, false) then
        if _cfg_on(v_org, 'org.grn_supervise_flow') and n->>'supervised_at' is null then
          perform notify_event(v_org, 'grn_supervise', v_br, v_by, 'GRN needs supervision', v_num,
            '/erp/grn?focus=' || v_id);
        end if;
        perform notify_event(v_org, 'grn_ready_invoice', v_br, v_by, 'GRN received — ready to invoice', v_num,
          '/erp/grn?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME in ('purchase_invoices', 'purchase_return_invoices', 'sales_invoices') then
      declare
        k text := case TG_TABLE_NAME when 'purchase_invoices' then 'pi'
                                     when 'purchase_return_invoices' then 'pri' else 'si' end;
        lbl text := case TG_TABLE_NAME when 'purchase_invoices' then 'Purchase Invoice'
                                       when 'purchase_return_invoices' then 'Purchase Return Invoice' else 'Sales Invoice' end;
        pth text := case TG_TABLE_NAME when 'purchase_invoices' then '/erp/purchase-invoices?focus='
                                       when 'purchase_return_invoices' then '/erp/purchase-return-vouchers?focus='
                                       else '/erp/sales-invoices?focus=' end || v_id;
        amt text := case when n ? 'grand_total' then ' · ' || _rs((n->>'grand_total')::numeric) else '' end;
      begin
        if _became(n, o, 'review_status', 'pending') then
          perform notify_event(v_org, k || '_review', v_br, v_by, lbl || ' needs review', v_num || amt, pth);
        elsif _became(n, o, 'review_status', 'rejected') then
          perform notify_event(v_org, k || '_review_rejected', v_br, v_by, lbl || ' review rejected',
            v_num || coalesce(' — ' || nullif(n->>'review_reason', ''), ''), pth);
        end if;
        if k in ('pi', 'si') and _became_locked(n, o) and n->>'supervised_at' is null
           and not coalesce((n->>'is_voided')::boolean, false)
           and _cfg_on(v_org, 'org.' || k || '_supervise_flow') then
          perform notify_event(v_org, k || '_supervise', v_br, v_by, lbl || ' needs supervision', v_num || amt, pth);
        end if;
      end;

    elsif TG_TABLE_NAME = 'sales_return_invoices' then
      if _became_locked(n, o) and n->>'supervised_at' is null
         and not coalesce((n->>'is_voided')::boolean, false)
         and _cfg_on(v_org, 'org.sri_supervise_flow') then
        perform notify_event(v_org, 'sri_supervise', v_br, v_by, 'Sales Return Invoice needs supervision', v_num,
          '/erp/sales-return-invoices?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'delivery_orders' then
      if (_became_locked(n, o) or _became(n, o, 'status', 'saved')) and n->>'supervised_at' is null
         and not coalesce((n->>'is_voided')::boolean, false)
         and _cfg_on(v_org, 'org.do_supervise_flow') then
        perform notify_event(v_org, 'do_supervise', v_br, v_by, 'Delivery Order needs supervision', v_num,
          '/erp/delivery-orders?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'journal_entries' then
      if coalesce(n->>'reference_type', '') = 'jv' then
        if _became(n, o, 'approval_status', 'pending') then
          perform notify_event(v_org, 'jv_approval', v_br, v_by, 'Journal Voucher needs approval', v_num,
            '/financials/journal-vouchers?focus=' || v_id);
        end if;
        if _became(n, o, 'status', 'posted') and n->>'supervised_at' is null
           and _cfg_on(v_org, 'org.jv_supervise_flow') then
          perform notify_event(v_org, 'jv_supervise', v_br, v_by, 'Journal Voucher needs supervision', v_num,
            '/financials/journal-vouchers?focus=' || v_id);
        end if;
      end if;

    elsif TG_TABLE_NAME = 'field_orders' then
      if _became(n, o, 'status', 'submitted') then
        perform notify_event(v_org, 'field_order', v_br, v_by, 'Field order submitted',
          coalesce(nullif(v_num, ''), nullif(n->>'order_number', ''), 'New field order'), '/erp/field-orders?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'retailer_orders' then
      if _became(n, o, 'status', 'submitted') then
        perform notify_event(v_org, 'retailer_order', v_br, v_by, 'Retailer order received',
          coalesce(nullif(v_num, ''), nullif(n->>'order_number', ''), 'New retailer order'), '/erp/retailer-orders?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'customers' then
      if TG_OP = 'INSERT' and n->>'supervised_at' is null and _cfg_on(v_org, 'org.customer_supervise_flow') then
        perform notify_event(v_org, 'customer_supervise', null, v_by, 'New customer needs supervision',
          coalesce(n->>'shop_name', n->>'name', ''), '/customers?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'products' then
      if TG_OP = 'INSERT' and n->>'supervised_at' is null and _cfg_on(v_org, 'org.product_supervise_flow') then
        perform notify_event(v_org, 'product_supervise', null, v_by, 'New product needs supervision',
          coalesce(n->>'name', ''), '/erp/products?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'stock_transfers' then
      if _became(n, o, 'status', 'in_transit') then
        perform notify_event(v_org, 'transfer_dispatch', n->>'to_branch_id', v_by, 'Stock transfer to receive',
          v_num || ' — awaiting receipt at your branch', '/erp/stock-transfers?focus=' || v_id);
      end if;
    end if;
  exception when others then
    null;  -- a notification must never block saving a document
  end;
  return NEW;
end $$;

create or replace function public.trg_notify_hr_events()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare
  n jsonb := to_jsonb(NEW);
  o jsonb := case when TG_OP = 'UPDATE' then to_jsonb(OLD) else '{}'::jsonb end;
  v_org text := n->>'org_id';
  v_id text := n->>'id';
  v_emp record; v_type text; v_period text; v_body text;
begin
  begin
    if v_org is null then return NEW; end if;

    if TG_TABLE_NAME = 'hr_leave_requests' then
      select full_name, branch_id into v_emp from hr_employees where id = n->>'employee_id';
      select name into v_type from hr_leave_types where id = n->>'leave_type_id';
      v_body := coalesce(v_emp.full_name, 'Employee') || coalesce(' · ' || v_type, '')
             || ' · ' || coalesce(to_char((n->>'from_date')::date, 'DD Mon'), '')
             || case when coalesce(n->>'to_date', '') <> '' and n->>'to_date' <> n->>'from_date'
                     then ' – ' || to_char((n->>'to_date')::date, 'DD Mon') else '' end
             || coalesce(' (' || nullif(n->>'days', '') || ' day' || case when n->>'days' = '1' then '' else 's' end || ')', '');
      if _became(n, o, 'status', 'pending') then
        perform notify_event(v_org, 'hr_leave_pending', v_emp.branch_id, n->>'applied_by',
          'Leave request waiting for approval',
          v_body || coalesce(E'\nReason: ' || nullif(n->>'reason', ''), ''), '/hr/leave?focus=' || v_id);
      elsif TG_OP = 'UPDATE' and coalesce(o->>'status', '') = 'pending' and _became(n, o, 'status', 'approved') then
        perform notify_event(v_org, 'hr_leave_approved', v_emp.branch_id, n->>'applied_by',
          'Leave approved', v_body, '/hr/leave?focus=' || v_id);
      elsif TG_OP = 'UPDATE' and coalesce(o->>'status', '') = 'pending' and _became(n, o, 'status', 'rejected') then
        perform notify_event(v_org, 'hr_leave_rejected', v_emp.branch_id, n->>'applied_by',
          'Leave rejected', v_body, '/hr/leave?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'hr_employees' then
      if _became(n, o, 'approval_status', 'pending') then
        perform notify_event(v_org, 'hr_employee_pending', n->>'branch_id', n->>'created_by',
          'New employee waiting for approval',
          coalesce(n->>'full_name', '') || coalesce(' · ' || nullif(n->>'employee_code', ''), ''),
          '/hr/employees?focus=' || v_id);
      end if;

    elsif TG_TABLE_NAME = 'hr_payroll_runs' then
      v_period := coalesce(to_char(to_date((n->>'period') || '-01', 'YYYY-MM-DD'), 'Mon YYYY'), n->>'period', '');
      if _became(n, o, 'status', 'finalized') then
        perform notify_event(v_org, 'payroll_finalized', n->>'branch_id', n->>'created_by',
          'Payroll finalized — ready for payment', 'Payroll for ' || v_period || ' was finalized.', '/hr/payroll?focus=' || v_id);
      elsif _became(n, o, 'status', 'paid') then
        perform notify_event(v_org, 'payroll_paid', n->>'branch_id', n->>'created_by',
          'Payroll marked paid', 'Payroll for ' || v_period || ' was marked paid.', '/hr/payroll?focus=' || v_id);
      end if;
    end if;
  exception when others then
    null;  -- never block HR saves
  end;
  return NEW;
end $$;
