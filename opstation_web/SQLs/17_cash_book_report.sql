-- =====================================================================
-- 17_cash_book_report.sql
-- Cash Book Report RPC (Financials menu).
--
-- Returns every POSTED journal line that hits "Cash in Hand" (COA code
-- 1110) or any sub-account beneath it, in an exploded, one-row-per-cash-
-- movement view: each row carries the CONTRA account(s) as "particulars"
-- (what the cash was for), the voucher number, its narration, and the
-- Dr/Cr amount. A synthetic first row (r_kind='opening') carries the
-- opening balance = net cash movement on all posted entries strictly
-- BEFORE p_date_from, so the client can run a live balance forward.
--
-- Branch handling mirrors the other financial reports:
--   p_branch_ids NULL        → organisation-wide (admin only; the client's
--                              BranchScope decides whether NULL is allowed)
--   p_branch_ids ['a','b']   → exactly those branches, consolidated
--
-- Cash accounts are resolved recursively (1110 + descendants) so orgs that
-- add sub-cash accounts under Cash in Hand are covered automatically.
-- Petty Cash (1130) and Bank (1120) are deliberately NOT included.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.rpc_cash_book(
  p_org_id     text,
  p_branch_ids text[] DEFAULT NULL,
  p_date_from  date   DEFAULT NULL,
  p_date_to    date   DEFAULT NULL
)
RETURNS TABLE (
  r_kind      text,
  entry_id    text,
  voucher_no  text,
  ref_type    text,
  entry_date  date,
  particulars text,
  narration   text,
  debit       numeric,
  credit      numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_cash_ids text[];
  v_opening  numeric := 0;
BEGIN
  -- Cash in Hand (code 1110) plus every descendant account.
  WITH RECURSIVE cash_tree AS (
    SELECT id
      FROM chart_of_accounts
     WHERE org_id = p_org_id AND code = '1110'
    UNION ALL
    SELECT c.id
      FROM chart_of_accounts c
      JOIN cash_tree t ON c.parent_id = t.id
     WHERE c.org_id = p_org_id
  )
  SELECT array_agg(id) INTO v_cash_ids FROM cash_tree;

  -- No Cash in Hand account for this org → nothing to report.
  IF v_cash_ids IS NULL THEN
    RETURN;
  END IF;

  -- Opening balance: net cash movement on posted entries before the range.
  IF p_date_from IS NOT NULL THEN
    SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
      INTO v_opening
      FROM journal_lines jl
      JOIN journal_entries je ON je.id = jl.entry_id
     WHERE jl.account_id = ANY (v_cash_ids)
       AND je.org_id = p_org_id
       AND je.status = 'posted'
       AND je.entry_date < p_date_from
       AND (p_branch_ids IS NULL OR jl.branch_id = ANY (p_branch_ids));
  END IF;

  -- Opening row (the running balance starts here).
  RETURN QUERY
    SELECT 'opening'::text,
           NULL::text,
           NULL::text,
           NULL::text,
           p_date_from,
           'Opening Balance'::text,
           NULL::text,
           v_opening,
           0::numeric;

  -- Movement rows, oldest first.
  RETURN QUERY
    SELECT 'movement'::text,
           je.id,
           je.entry_number,
           je.reference_type,
           je.entry_date,
           COALESCE((
             SELECT string_agg(DISTINCT COALESCE(NULLIF(o.account_name, ''), ca.name), ', ')
               FROM journal_lines o
               LEFT JOIN chart_of_accounts ca ON ca.id = o.account_id
              WHERE o.entry_id = je.id
                AND NOT (o.account_id = ANY (v_cash_ids))
           ), '')::text,
           COALESCE(NULLIF(jl.description, ''), je.description)::text,
           jl.debit,
           jl.credit
      FROM journal_lines jl
      JOIN journal_entries je ON je.id = jl.entry_id
     WHERE jl.account_id = ANY (v_cash_ids)
       AND je.org_id = p_org_id
       AND je.status = 'posted'
       AND (p_date_from IS NULL OR je.entry_date >= p_date_from)
       AND (p_date_to   IS NULL OR je.entry_date <= p_date_to)
       AND (p_branch_ids IS NULL OR jl.branch_id = ANY (p_branch_ids))
     ORDER BY je.entry_date, je.entry_number, jl.line_order;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_cash_book(text, text[], date, date) TO authenticated, anon;
