-- ============================================================================
-- 21_cash_book_exploded.sql
-- Detailed (exploded) Cash Book — matches the old software's layout.
--
-- Instead of one row per cash voucher, this returns ONE ROW PER CONTRA LINE of
-- every posted voucher that touches Cash in Hand (code 1110 + sub-accounts).
-- Each row shows what that line was for (its own description), which account it
-- hit (particulars), and the cash effect:
--     Receipt (debit)  = the contra line's credit  (cash came in)
--     Payment (credit) = the contra line's debit   (cash went out)
-- so a Cash Payment voucher with 15 expense lines shows as 15 rows, each with
-- its narration and running balance — exactly like the old Cash Book Report.
--
-- Signature/return columns are unchanged, so the existing screen keeps working.
-- ============================================================================

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
  WITH RECURSIVE cash_tree AS (
    SELECT id FROM chart_of_accounts
     WHERE org_id = p_org_id AND code = '1110'
    UNION ALL
    SELECT c.id FROM chart_of_accounts c
      JOIN cash_tree t ON c.parent_id = t.id
     WHERE c.org_id = p_org_id
  )
  SELECT array_agg(id) INTO v_cash_ids FROM cash_tree;

  IF v_cash_ids IS NULL THEN
    RETURN;
  END IF;

  -- Opening balance = net cash movement on posted entries before the range.
  IF p_date_from IS NOT NULL THEN
    SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
      INTO v_opening
      FROM journal_lines jl
      JOIN journal_entries je ON je.id = jl.entry_id
     WHERE jl.account_id = ANY (v_cash_ids)
       AND je.org_id = p_org_id
       AND je.status = 'posted'
       AND je.entry_date::date < p_date_from
       AND (p_branch_ids IS NULL OR jl.branch_id = ANY (p_branch_ids));
  END IF;

  RETURN QUERY
    SELECT 'opening'::text, NULL::text, NULL::text, NULL::text,
           p_date_from, 'Opening Balance'::text, NULL::text, v_opening, 0::numeric;

  -- Entries (posted, in range/branch) that touch a cash account.
  RETURN QUERY
  WITH qualifying AS (
    SELECT DISTINCT je.id, je.entry_number, je.reference_type, je.entry_date
      FROM journal_lines jl
      JOIN journal_entries je ON je.id = jl.entry_id
     WHERE jl.account_id = ANY (v_cash_ids)
       AND je.org_id = p_org_id
       AND je.status = 'posted'
       AND (p_date_from IS NULL OR je.entry_date::date >= p_date_from)
       AND (p_date_to   IS NULL OR je.entry_date::date <= p_date_to)
       AND (p_branch_ids IS NULL OR jl.branch_id = ANY (p_branch_ids))
  )
  SELECT 'movement'::text,
         q.id,
         q.entry_number,
         q.reference_type,
         q.entry_date::date,
         COALESCE(NULLIF(o.account_name, ''), ca.name, '')::text          AS particulars,
         COALESCE(NULLIF(o.description, ''), q.entry_number)::text         AS narration,
         o.credit                                                         AS debit,
         o.debit                                                          AS credit
    FROM qualifying q
    JOIN journal_lines o ON o.entry_id = q.id
    LEFT JOIN chart_of_accounts ca ON ca.id = o.account_id
   WHERE NOT (o.account_id = ANY (v_cash_ids))          -- contra (non-cash) lines only
   ORDER BY q.entry_date::date, q.entry_number, o.line_order;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_cash_book(text, text[], date, date) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
