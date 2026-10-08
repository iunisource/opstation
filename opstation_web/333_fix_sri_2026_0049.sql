-- 333 — Repair SRI-2026-0049 (Unisource Lahore): 7 lines of SRN-2026-0049 never made it
-- onto the return invoice (saved one-by-one; 7 saves failed silently on 5 Oct).
-- Stock already came back via the SRN; this adds the missing invoice side:
--   1. the 7 invoice lines at Rs 569 each (21 units = Rs 11,949)
--   2. their FIFO cost layers + "Inventory returned / COGS reversed" entry,
--      costed exactly like post_sales_return_inventory() does
--   3. invoice total 38,692 → 50,641; the app's own re-price trigger
--      (sri_repost_money) then re-posts the customer credit at the new total.
-- All-or-nothing; verifies the customer credit at the end. Safe to run again.

do $$
declare
  v_sri  text := 'sri_1791201064836';
  v_srn  text := 'sr_1791200788760';
  s      record;
  r      record;
  v_inv text; v_cogs text; v_in text; v_cn text;
  v_cost numeric; v_total_cost numeric := 0; v_add numeric := 0; v_lines int := 0;
  v_entry text; v_ar_now numeric;
begin
  select * into s from sales_return_invoices where id = v_sri and srn_id = v_srn and org_id = 'org_1784655141655';
  if not found then raise exception 'SRI-2026-0049 not found'; end if;
  if coalesce(s.is_voided, false) then raise exception 'SRI-2026-0049 is voided — nothing to repair'; end if;

  if exists (select 1 from sales_return_invoice_items where id like 'srii_fix_%' and invoice_id = v_sri) then
    raise notice 'Already repaired — nothing to do.';
    return;
  end if;

  select inventory_account_id, cogs_account_id into v_inv, v_cogs from inventory_settings where org_id = s.org_id;
  select name into v_in from chart_of_accounts where id = v_inv;
  select name into v_cn from chart_of_accounts where id = v_cogs;

  -- the SRN lines that have no invoice line
  for r in
    select i.* from sales_return_items i
     where i.return_id = v_srn and coalesce(i.quantity, 0) > 0
       and not exists (select 1 from sales_return_invoice_items x
                        where x.invoice_id = v_sri and x.srn_item_id = i.id)
  loop
    insert into sales_return_invoice_items(id, invoice_id, product_id, uom_id, quantity, unit_price, discount, line_total, srn_item_id, created_at)
    values ('srii_fix_' || r.id, v_sri, r.product_id, r.uom_id, r.quantity, 569, 0, r.quantity * 569, r.id, now());

    v_cost := coalesce(nullif(current_unit_cost(s.org_id, s.branch_id, r.product_id), 0),
                       (select cost_price from products where id = r.product_id), 0);
    insert into inventory_cost_layers(id, org_id, branch_id, product_id, source_type, source_id, layer_date, qty_in, qty_remaining, unit_cost)
    values ('lyr_' || replace(gen_random_uuid()::text, '-', ''), s.org_id, s.branch_id, r.product_id,
            'sales_return', v_sri, s.voucher_date::timestamptz, r.quantity, r.quantity, v_cost);

    v_total_cost := v_total_cost + r.quantity * v_cost;
    v_add := v_add + r.quantity * 569;
    v_lines := v_lines + 1;
  end loop;

  if v_lines <> 7 or v_add <> 11949 then
    raise exception 'Expected 7 missing lines / Rs 11,949 — found % / % . Nothing changed.', v_lines, v_add;
  end if;

  -- cost side for the 7 lines (same accounts / wording as the original posting)
  v_total_cost := round(v_total_cost, 2);
  v_entry := 'je_' || replace(gen_random_uuid()::text, '-', '');
  insert into journal_entries(id, org_id, branch_id, entry_number, entry_date, description, reference_type,
                              reference_id, reference_number, status, is_system_generated, posted_at)
  values (v_entry, s.org_id, s.branch_id, 'SRET-INV-' || s.voucher_number || '-FIX', s.voucher_date,
          'Sales return to stock ' || s.voucher_number || ' — 7 lines missed on 5 Oct',
          'sales_return_cogs', v_sri, s.voucher_number, 'posted', true, now());
  insert into journal_lines(id, entry_id, org_id, branch_id, account_id, debit, credit, description, line_order, account_type, account_name)
  values ('jl_' || replace(gen_random_uuid()::text, '-', ''), v_entry, s.org_id, s.branch_id, v_inv, v_total_cost, 0,
          'Inventory returned to stock', 0, 'asset', v_in),
         ('jl_' || replace(gen_random_uuid()::text, '-', ''), v_entry, s.org_id, s.branch_id, v_cogs, 0, v_total_cost,
          'COGS reversed on sales return', 1, 'expense', v_cn);

  -- new totals → the re-price trigger re-posts the customer credit
  update sales_return_invoices
     set subtotal = coalesce(subtotal, 0) + v_add,
         grand_total = coalesce(grand_total, 0) + v_add,
         updated_at = now()
   where id = v_sri;

  -- verify: customer credit on this invoice must now equal the new total
  with mine as (select id, reversed_by from journal_entries where org_id = s.org_id and reference_id = v_sri and coalesce(status, '') <> 'draft'),
       alle as (select id from mine union select reversed_by from mine where reversed_by is not null)
  select round(coalesce(sum(coalesce(credit, 0) - coalesce(debit, 0)), 0), 2) into v_ar_now
    from journal_lines where entry_id in (select id from alle) and party_id = s.customer_id;
  if v_ar_now <> round(s.grand_total + v_add, 2) then
    raise exception 'Customer credit is % but should be % — rolled back, nothing changed.', v_ar_now, s.grand_total + v_add;
  end if;

  insert into voucher_audit_log (org_id, voucher_id, voucher_type, action, details, performed_by)
  values (s.org_id, v_sri, 'SRI', 'repaired',
          '7 lines missed on 5 Oct added (21 units @ 569 = 11,949); cost ' || v_total_cost, null);
end $$;

-- Result
select i.voucher_number, i.grand_total,
       (select count(*) from sales_return_invoice_items where invoice_id = i.id) as lines,
       (select sum(quantity) from sales_return_invoice_items where invoice_id = i.id) as units,
       (select count(*) from inventory_cost_layers where source_type = 'sales_return' and source_id = i.id) as layers,
       (select string_agg(e.entry_number || ' ' || e.reference_type, ', ' order by e.created_at)
          from journal_entries e where e.reference_id = i.id) as entries
from sales_return_invoices i where i.id = 'sri_1791201064836';
