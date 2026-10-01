-- 304 — Employee advances: link each employee to their advance GL account.
alter table public.hr_employees
  add column if not exists advance_account_id text,
  add column if not exists advance_installment numeric;
alter table public.hr_payroll_items
  add column if not exists advance_balance numeric,
  add column if not exists advance_account_id text;

-- Link the advance accounts that clearly match current employees (safe to re-run; only fills blanks).
update public.hr_employees e set advance_account_id = m.acct
  from (values
    ('emp_1787056031004', 'coa_org_1784655141655_11000103'),  -- Nadeem Ali      → Advance Against Salary - M. Nadeem
    ('emp_1790841033704', 'coa_aed2fe1f83e04199a3c4faebc76ff862'), -- Hamza Ahmad Ilyas → Advance Against Salary - Hamza Ilyas
    ('emp_1790052508477', 'coa_4c7a9707140542cab819077b02cf58e0'), -- Nazim Ali       → Employee Advances - Nazim (Factory)
    ('emp_1787055975342', 'coa_4aa994412c1a476db2505f1d558f7933'), -- Fiaz Umar       → Advances to Staff - Fayyaz
    ('emp_1787056151030', 'coa_f29e94c9322544b2bdacc8d7930c9668'), -- Allah Wasaya    → Advances to Staff - Allah Wasaya (Factory)
    ('emp_1787054225006', 'coa_aacb89916a2c4769bdf0cbd29cb565dc'), -- Sultan Wahab    → Advances to Staff - Sultan (Factory)
    ('emp_1787824594646', 'coa_1785568729981'),                    -- Rizwan Latif    → Advances to Staff - Rizwan (Factory)
    ('emp_1787054137861', 'coa_1789801741831')                     -- Ammar Ali Asghar → Advances to Staff - Ammar Asghar
  ) as m(emp, acct)
 where e.id = m.emp and e.org_id = 'org_1784655141655' and e.advance_account_id is null;
