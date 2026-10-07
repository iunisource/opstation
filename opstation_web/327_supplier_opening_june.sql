-- 327 — Re-import supplier opening balances from the June-2026 Supplier Balances report
-- (as on 30-Jun-2026, posted 01-Jul-2026), replacing OJV-2026-0003-CORR.
--   • Payables  (negative in report) → Cr Accounts Payable (2110), linked to the vendor
--   • Advances  (positive in report) → Dr Advances to Suppliers (1420), linked to the vendor
--   • Difference → Opening Balance Equity (3230)
--   • Balances under Rs. 100 (either way) skipped
--   • Zeeshan Mughal Machinery excluded; "Progressive Enterprises (N)" → Nayyer Industries
--   • Any vendor that already has an opening in ANOTHER opening voucher (e.g. OJV-2026-0003)
--     is skipped, so nothing is counted twice.
-- All-or-nothing: if any name doesn't match a vendor, nothing changes and the error lists it.

do $$
declare
  v_org    text := 'org_1784655141655';
  v_branch text := 'wh_1784662895476';
  v_date   date := '2026-07-01';
  v_corr   text;
  v_ap text; v_adv text; v_obe text;
  v_id text := 'ojv_' || (extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_no text;
  v_bad text; v_skip text;
  v_dr numeric; v_cr numeric; v_n int;
begin
  select id into v_ap  from chart_of_accounts where org_id = v_org and code = '2110';
  select id into v_adv from chart_of_accounts where org_id = v_org and code = '1420';
  select id into v_obe from chart_of_accounts where org_id = v_org and code = '3230';
  if v_ap is null or v_adv is null or v_obe is null then
    raise exception 'Account missing — 2110: %, 1420: %, 3230: %', v_ap, v_adv, v_obe;
  end if;

  select id into v_corr from journal_entries where org_id = v_org and entry_number = 'OJV-2026-0003-CORR';

  create temp table _jun(name text, amount numeric) on commit drop;
  insert into _jun values
    ('SRP Plastic Works', -0.90),
    ('Sultan Blow Moulding', 300.00),
    ('Tang Xuefeng LED', 92500.00),
    ('Tariq Gass Maker', -1000.00),
    ('Umar Filters (Chamber)', 150692.00),
    ('Union Packages', -221819.50),
    ('Unisource China Import', 0.20),
    ('Ustaad Ditta Metal Works', 9093.00),
    ('Yasir Dogar Air Filters', -7690.00),
    ('Yousaf Aslam', 160482.00),
    ('Zafar Filters Factory', -543962.60),
    ('Zain Paper', -6784.50),
    ('Zepto', -0.10),
    ('Zoom Lights', -0.90),
    ('Zubair Chamber Foam', 44329.00),
    ('Abdal Hussain Springs', -76000.00),
    ('Ahmed sb C/O Eco Power', 4994847.25),
    ('Akhtar ali Metal Works', -161764.00),
    ('Al Rehmat Electrical Industries', 33137.80),
    ('AM Printers', -0.80),
    ('Amin Traders', -0.90),
    ('Apple Filters', 1151163.50),
    ('Bawany Polymers', 0.10),
    ('Bi Turbo', 11500.00),
    ('Bilal Paper', 3250.00),
    ('Cash Purchases', 351381.60),
    ('Chughtai Rubber', -0.50),
    ('Excess Material', -50340.60),
    ('Hafiz Bilal Filters', -52893.00),
    ('Hafiz Mould Maker', 169469.00),
    ('Hammad sb LED', -125000.00),
    ('Hamza Chamber Filters', 36675.50),
    ('Ihtisham Moulding', -0.30),
    ('Ijaz Brothers Chemical', 59010.20),
    ('Instaglow Light Parts', 12958.00),
    ('JTF China Order#1', -0.20),
    ('JTF China Order#2', -1.00),
    ('Karachi Shrink', 0.10),
    ('LED Solution', -131650.00),
    ('LED Zone Faisalabad', 0.90),
    ('Malik Asif Filter Parts', -0.10),
    ('Metal Cash Purchases', 0.30),
    ('Mirza Umair Baig', 28979.00),
    ('Mudassir Filters', 68784.80),
    ('Murtaza Khol', -289539.90),
    ('National Paper Mills', 0.50),
    ('Nawaz Printing Press', -698951.00),
    ('One Chance Printers', -165.00),
    ('Parco Pearl Gas (Pvt.) Ltd', 125010.00),
    ('Progressive Enterprises', 250000.00),
    ('Nayyer Industries', -4322270.00),
    ('Qadeer Cabin', 116.50),
    ('Qasim Khol Manufacturer', 0.50),
    ('Saam Enterprises', -0.50),
    ('Salman sb Diecasting', 54230.00),
    ('Shahzad Fuel Filters', 10306.00),
    ('Shahzad Jaali Dhakan', -0.40),
    ('Shan Jaali Dhakan', -0.10),
    ('Smacks Enterprises', 26190.00);

  -- Skip tiny balances: anything under Rs. 100 either way gets no opening.
  delete from _jun where abs(amount) < 100;

  create temp table _map on commit drop as
  select j.name, j.amount,
         (select s.id from suppliers s where s.org_id = v_org and lower(trim(s.name)) = lower(trim(j.name)) limit 1) as sid,
         (select count(*) from suppliers s where s.org_id = v_org and lower(trim(s.name)) = lower(trim(j.name))) as n
  from _jun j;

  select string_agg(name || case when n = 0 then ' (not found)' else ' (' || n || ' vendors with this name)' end, '; ')
    into v_bad from _map where n <> 1;
  if v_bad is not null then raise exception 'Fix these names first, nothing was changed: %', v_bad; end if;

  -- vendors that already have an opening in another opening voucher → skip
  select string_agg(m.name || ' ' || to_char(m.amount, 'FM999,999,990.00'), '; ') into v_skip
  from _map m
  where exists (select 1 from journal_lines l join journal_entries e on e.id = l.entry_id
                where e.org_id = v_org and e.reference_type in ('opening_jv', 'opening_balance')
                  and e.id is distinct from v_corr and l.party_id = m.sid);
  delete from _map m
  where exists (select 1 from journal_lines l join journal_entries e on e.id = l.entry_id
                where e.org_id = v_org and e.reference_type in ('opening_jv', 'opening_balance')
                  and e.id is distinct from v_corr and l.party_id = m.sid);

  -- remove the CORR voucher
  if v_corr is not null then
    update journal_entries set status = 'draft', posted_at = null where id = v_corr;
    delete from journal_lines where entry_id = v_corr;
    delete from journal_entries where id = v_corr;
  end if;

  -- next OJV number
  select 'OJV-2026-' || lpad((coalesce(max(substring(entry_number from '^OJV-2026-(\d{4})$')::int), 0) + 1)::text, 4, '0')
    into v_no from journal_entries where org_id = v_org and reference_type = 'opening_jv';

  insert into journal_entries(id, org_id, branch_id, entry_number, entry_date, description,
                              reference_type, reference_id, reference_number, status,
                              is_system_generated, created_at)
  values (v_id, v_org, v_branch, v_no, v_date, 'Supplier opening balances as on 30-Jun-2026',
          'opening_jv', v_id, v_no, 'draft', false, now());

  insert into journal_lines(id, entry_id, org_id, branch_id, account_id, account_type, account_name,
                            party_id, debit, credit, description, line_order, created_at)
  select v_id || '_' || (row_number() over (order by m.amount desc, m.name) - 1),
         v_id, v_org, v_branch,
         case when m.amount > 0 then v_adv else v_ap end,
         'supplier', m.name, m.sid,
         greatest(m.amount, 0), greatest(-m.amount, 0),
         'Opening balance as on 30-Jun-2026',
         row_number() over (order by m.amount desc, m.name), now()
  from _map m;
  get diagnostics v_n = row_count;

  select sum(debit), sum(credit) into v_dr, v_cr from journal_lines where entry_id = v_id;
  insert into journal_lines(id, entry_id, org_id, branch_id, account_id, account_type, account_name,
                            party_id, debit, credit, description, line_order, created_at)
  values (v_id || '_' || v_n, v_id, v_org, v_branch, v_obe, 'coa', 'Opening Balance Equity', null,
          greatest(v_cr - v_dr, 0), greatest(v_dr - v_cr, 0),
          'Balancing — supplier opening balances', v_n + 1, now());

  update journal_entries set status = 'posted', posted_at = now() where id = v_id;

  raise notice 'Posted % with % vendor lines. Skipped (already in another opening): %', v_no, v_n, coalesce(v_skip, 'none');
end $$;

-- Result
select e.entry_number, e.status, e.entry_date,
       count(*) filter (where l.party_id is not null) as vendor_lines,
       sum(l.debit) as total_dr, sum(l.credit) as total_cr,
       sum(l.debit)  filter (where l.account_type = 'supplier') as advances_dr,
       sum(l.credit) filter (where l.account_type = 'supplier') as payables_cr,
       (select string_agg(x.entry_number, ', ') from journal_entries x
         where x.org_id = e.org_id and x.entry_number = 'OJV-2026-0003-CORR') as corr_still_there,
       (select string_agg(distinct s.name || ' (' || e2.entry_number || ')', ', ')
          from journal_lines l2 join journal_entries e2 on e2.id = l2.entry_id
          join suppliers s on s.id = l2.party_id
         where e2.org_id = e.org_id and e2.reference_type in ('opening_jv', 'opening_balance')
           and e2.id <> e.id) as skipped_vendors_opening_elsewhere
from journal_entries e join journal_lines l on l.entry_id = e.id
where e.org_id = 'org_1784655141655' and e.reference_type = 'opening_jv'
  and e.description = 'Supplier opening balances as on 30-Jun-2026'
group by e.id order by e.created_at;
