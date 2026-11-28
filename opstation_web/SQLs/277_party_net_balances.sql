-- Current net balance per party, straight from the posted GL.
--   net = sum(credit - debit) over every posted journal line tagged with the
--   party. For a SUPPLIER a positive net is what we still owe (payable minus any
--   advance/prepayment already naturally netted, because advance lines are
--   party-tagged too). For a CUSTOMER, negate it to get what they owe us.
-- This replaces the aging/period RPCs for Payment Advice, which returned the
-- AP-control figure as of the last activity and hid prepayments (a fully-paid
-- supplier still showed its old payable).

create or replace function rpc_party_net_balances(p_org text)
returns table(party_id text, net numeric)
language sql
stable
security definer
as $$
  select jl.party_id,
         sum(coalesce(jl.credit,0) - coalesce(jl.debit,0))
  from journal_lines jl
  join journal_entries je on je.id = jl.entry_id
  where jl.org_id = p_org
    and coalesce(je.status,'') <> 'draft'   -- posted + system void reversals
    and jl.party_id is not null
  group by jl.party_id;
$$;

grant execute on function rpc_party_net_balances(text) to authenticated, anon;
