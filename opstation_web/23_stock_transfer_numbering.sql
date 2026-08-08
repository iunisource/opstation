-- ============================================================================
-- 23_stock_transfer_numbering.sql
-- Fix duplicate Stock Transfer voucher numbers (e.g. two ST-2026-0022).
--
-- Root cause: the app numbered transfers as COUNT(existing)+1, which collides
-- on concurrent creates and on any gap. This migration:
--   1. Renumbers existing duplicates so current data is clean.
--   2. Adds a UNIQUE index on (org_id, voucher_number) so the DB refuses dupes.
--   3. Adds a per-org counter + next_stock_transfer_number() that hands out
--      numbers atomically (row-locked), so simultaneous creates can't collide.
-- ============================================================================

-- 1) ── Renumber duplicates ─────────────────────────────────────────────────
-- Keep the earliest-created row on each duplicated number; move the rest to a
-- fresh number above the current max for that org+year.
DO $$
DECLARE
  r   record;
  mx  int;
  yr  int;
BEGIN
  FOR r IN
    SELECT id, org_id, voucher_number,
           ROW_NUMBER() OVER (
             PARTITION BY org_id, voucher_number
             ORDER BY created_at NULLS FIRST, id
           ) AS rn
    FROM stock_transfers
    WHERE voucher_number ~ '^ST-[0-9]{4}-[0-9]+$'
  LOOP
    IF r.rn > 1 THEN
      yr := substring(r.voucher_number from 'ST-([0-9]{4})-')::int;
      SELECT COALESCE(MAX((substring(voucher_number from 'ST-[0-9]{4}-([0-9]+)$'))::int), 0)
        INTO mx
        FROM stock_transfers
       WHERE org_id = r.org_id
         AND voucher_number LIKE 'ST-' || yr || '-%';
      UPDATE stock_transfers
         SET voucher_number = 'ST-' || yr || '-' || lpad((mx + 1)::text, 4, '0')
       WHERE id = r.id;
    END IF;
  END LOOP;
END $$;

-- 2) ── Unique index (guards against any future duplicate) ──────────────────
CREATE UNIQUE INDEX IF NOT EXISTS uq_stock_transfers_org_vno
  ON stock_transfers (org_id, voucher_number)
  WHERE voucher_number IS NOT NULL;

-- 3) ── Atomic per-org numbering ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS voucher_counters (
  org_id   text NOT NULL,
  doc_type text NOT NULL,
  yr       int  NOT NULL,
  last_no  int  NOT NULL DEFAULT 0,
  PRIMARY KEY (org_id, doc_type, yr)
);

CREATE OR REPLACE FUNCTION public.next_stock_transfer_number(p_org_id text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_year int := extract(year from now())::int;
  v_no   int;
BEGIN
  -- Seed the counter from the current max the first time we see this org+year,
  -- so we continue the sequence instead of restarting at 1.
  INSERT INTO voucher_counters (org_id, doc_type, yr, last_no)
  SELECT p_org_id, 'ST', v_year,
         COALESCE(MAX((substring(voucher_number from 'ST-[0-9]{4}-([0-9]+)$'))::int), 0)
    FROM stock_transfers
   WHERE org_id = p_org_id
     AND voucher_number LIKE 'ST-' || v_year || '-%'
  ON CONFLICT (org_id, doc_type, yr) DO NOTHING;

  -- Atomic increment: the UPDATE row-locks the counter, so concurrent callers
  -- serialize and each gets a distinct number.
  UPDATE voucher_counters
     SET last_no = last_no + 1
   WHERE org_id = p_org_id AND doc_type = 'ST' AND yr = v_year
  RETURNING last_no INTO v_no;

  RETURN 'ST-' || v_year || '-' || lpad(v_no::text, 4, '0');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.next_stock_transfer_number(text) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
