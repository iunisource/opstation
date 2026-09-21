-- 256: post_cpv / post_crv now carry each voucher line's description and
-- account_name onto the GL line (parity with the old client-side posters, so
-- the P&L drill-down keeps showing the narration and real account label).
-- Balance guard and all other logic unchanged. This is a prerequisite for
-- routing the web CPV/CRV screens through these atomic, balance-guarded RPCs.

CREATE OR REPLACE FUNCTION public.post_cpv(p_voucher_id text)
 RETURNS text LANGUAGE plpgsql AS $function$
declare
  v_org text; v_branch text; v_date date; v_num text; v_status text; v_cash text; v_total numeric;
  v_entry text; r record; v_acc text; v_party text; v_ord int:=1;
  v_ap text; v_ar text; v_comm text;
  v_tot_dr numeric:=0; v_tot_cr numeric:=0;
begin
  select org_id, branch_id, voucher_date, voucher_number, status, cash_account_id, total_amount
    into v_org, v_branch, v_date, v_num, v_status, v_cash, v_total
  from cpv_vouchers where id = p_voucher_id;
  if not found then raise exception 'CPV % not found', p_voucher_id; end if;
  if v_status <> 'posted' then return format('CPV %s skipped (not posted)', v_num); end if;
  if v_cash is null then raise exception 'CPV % has no cash account', v_num; end if;

  v_ap   := 'coa_'||v_org||'_2110';
  v_ar   := 'coa_'||v_org||'_1210';
  v_comm := 'coa_'||v_org||'_2150';
  v_entry := 'je_cpv_'||p_voucher_id;

  delete from journal_lines where entry_id in (
    select id from journal_entries where org_id=v_org and reference_type='cpv' and reference_id=p_voucher_id
  );
  delete from journal_lines where entry_id = v_entry;
  delete from journal_entries where org_id=v_org and reference_type='cpv' and reference_id=p_voucher_id;
  delete from journal_entries where id = v_entry;

  insert into journal_entries(id,org_id,branch_id,entry_number,entry_date,description,reference_type,reference_id,reference_number,status,is_system_generated,created_at,posted_at)
  values (v_entry,v_org,v_branch,'CPV-'||v_num,v_date,'Cash Payment: '||v_num,'cpv',p_voucher_id,v_num,'posted',true,now(),now());

  insert into journal_lines(id,entry_id,org_id,branch_id,account_id,debit,credit,line_order)
  values (v_entry||'_0',v_entry,v_org,v_branch,v_cash,0,v_total,0);

  for r in
    select account_type, account_id, amount, description, account_name
    from cpv_voucher_lines
    where voucher_id = p_voucher_id and coalesce(amount,0) <> 0
    order by line_order
  loop
    v_acc := case r.account_type
               when 'supplier' then v_ap
               when 'customer' then v_ar
               when 'promoter' then v_comm
               else coalesce(r.account_id, v_ap)
             end;
    v_party := case when r.account_type in ('supplier','customer','promoter') then r.account_id else null end;
    insert into journal_lines(id,entry_id,org_id,branch_id,account_id,debit,credit,line_order,party_id,description,account_name)
    values (v_entry||'_'||v_ord, v_entry, v_org, v_branch, v_acc, r.amount, 0, v_ord, v_party, r.description, r.account_name);
    v_ord := v_ord + 1;
  end loop;

  select coalesce(sum(debit),0), coalesce(sum(credit),0) into v_tot_dr, v_tot_cr
  from journal_lines where entry_id = v_entry;
  if abs(v_tot_dr - v_tot_cr) > 0.01 then
    raise exception 'CPV % would post UNBALANCED (Dr % vs Cr %, diff %) — aborting',
      v_num, v_tot_dr, v_tot_cr, (v_tot_dr - v_tot_cr);
  end if;

  return format('CPV %s posted (Dr=%s Cr=%s)', v_num, v_tot_dr, v_tot_cr);
end $function$;

CREATE OR REPLACE FUNCTION public.post_crv(p_voucher_id text)
 RETURNS text LANGUAGE plpgsql AS $function$
declare
  v_org text; v_branch text; v_date text; v_num text; v_status text; v_cash text; v_total numeric;
  v_entry text; r record; v_acc text; v_party text; v_ord int:=1;
  v_ap text; v_ar text; v_comm text;
  v_tot_dr numeric:=0; v_tot_cr numeric:=0;
begin
  select org_id, branch_id, voucher_date, voucher_number, status, cash_account_id, total_amount
    into v_org, v_branch, v_date, v_num, v_status, v_cash, v_total
  from crv_vouchers where id = p_voucher_id;
  if not found then raise exception 'CRV % not found', p_voucher_id; end if;
  if v_status <> 'posted' then return format('CRV %s skipped (not posted)', v_num); end if;
  if v_cash is null then raise exception 'CRV % has no cash account', v_num; end if;

  v_ap   := 'coa_'||v_org||'_2110';
  v_ar   := 'coa_'||v_org||'_1210';
  v_comm := 'coa_'||v_org||'_2150';
  v_entry := 'je_crv_'||p_voucher_id;

  delete from journal_lines where entry_id in (
    select id from journal_entries where org_id=v_org and reference_type='crv' and reference_id=p_voucher_id
  );
  delete from journal_lines where entry_id = v_entry;
  delete from journal_entries where org_id=v_org and reference_type='crv' and reference_id=p_voucher_id;
  delete from journal_entries where id = v_entry;

  insert into journal_entries(id,org_id,branch_id,entry_number,entry_date,description,reference_type,reference_id,reference_number,status,is_system_generated,created_at,posted_at)
  values (v_entry,v_org,v_branch,'CRV-'||v_num,v_date::date,'Cash Receipt: '||v_num,'crv',p_voucher_id,v_num,'posted',true,now(),now());

  insert into journal_lines(id,entry_id,org_id,branch_id,account_id,debit,credit,line_order)
  values (v_entry||'_0',v_entry,v_org,v_branch,v_cash,v_total,0,0);

  for r in
    select account_type, account_id, amount, description, account_name
    from crv_voucher_lines
    where voucher_id = p_voucher_id and coalesce(amount,0) <> 0
    order by line_order
  loop
    v_acc := case r.account_type
               when 'customer' then v_ar
               when 'supplier' then v_ap
               when 'promoter' then v_comm
               else coalesce(r.account_id, v_ar)
             end;
    v_party := case when r.account_type in ('supplier','customer','promoter') then r.account_id else null end;
    insert into journal_lines(id,entry_id,org_id,branch_id,account_id,debit,credit,line_order,party_id,description,account_name)
    values (v_entry||'_'||v_ord, v_entry, v_org, v_branch, v_acc, 0, r.amount, v_ord, v_party, r.description, r.account_name);
    v_ord := v_ord + 1;
  end loop;

  select coalesce(sum(debit),0), coalesce(sum(credit),0) into v_tot_dr, v_tot_cr
  from journal_lines where entry_id = v_entry;
  if abs(v_tot_dr - v_tot_cr) > 0.01 then
    raise exception 'CRV % would post UNBALANCED (Dr % vs Cr %, diff %) — aborting',
      v_num, v_tot_dr, v_tot_cr, (v_tot_dr - v_tot_cr);
  end if;

  return format('CRV %s posted (Dr=%s Cr=%s)', v_num, v_tot_dr, v_tot_cr);
end $function$;
