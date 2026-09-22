-- ============================================================================
-- Enable the new 'operations' and 'intelligence' modules for every EXISTING org,
-- so making these menus module-gated does not hide them from anyone. Admins can
-- then turn either off per org via the super-admin "Manage Modules" dialog.
-- Additive + idempotent (won't override an org's explicit choice).
-- ============================================================================
insert into public.org_modules (org_id, module, is_enabled, updated_at)
select o.id, m.module, true, now()
from public.orgs o
cross join (values ('operations'), ('intelligence')) as m(module)
on conflict (org_id, module) do nothing;
