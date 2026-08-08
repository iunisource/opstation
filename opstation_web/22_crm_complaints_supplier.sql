-- ============================================================================
-- 22_crm_complaints_supplier.sql
-- Let complaints be logged against a supplier (not just a customer), so the new
-- Supplier Profile's Complaints tab works. customer_id was NOT NULL before, so
-- we relax it and add a supplier_id, mirroring how customer_activities already
-- carries both.
-- ============================================================================

ALTER TABLE crm_complaints
  ADD COLUMN IF NOT EXISTS supplier_id text;

-- customer_id must become nullable so a supplier-only complaint can be stored.
ALTER TABLE crm_complaints
  ALTER COLUMN customer_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_crm_complaints_supplier
  ON crm_complaints (supplier_id);

NOTIFY pgrst, 'reload schema';
