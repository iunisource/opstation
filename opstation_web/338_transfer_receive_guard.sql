-- 338 — Stop a stock transfer being RECEIVED more than once  (+ show what is duplicated)
--
-- Why ST-2026-0157 came in 3×: the "Approve & Receive" step runs the server function
-- receive_stock_transfer. That function adds the stock at the destination but never
-- checks, under a lock, "has this transfer already been received?". So each call adds
-- the goods again. The screen keeps the button up when the reply doesn't make it back
-- (slow network or timeout: the server finished but the app showed "That did not save"),
-- and a stale screen or a second user can press it again. The same gap caused the
-- triple "Reject" in 318.
--
-- Fix: the existing function is renamed to _receive_stock_transfer_core (its body is
-- not touched). A new receive_stock_transfer in front of it:
--   1. locks the transfer row, so two clicks queue instead of running side by side;
--   2. refuses if the status is no longer in_transit, or if goods for this transfer
--      already landed at the destination;
--   3. only then calls the original.
-- Safe to run again.

set lock_timeout = '3s';

do $$
declare
  v_core oid; v_ia text; v_args text; v_res text; v_names text[]; v_call text; v_body text;
begin
  if not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                   and proname = '_receive_stock_transfer_core') then
    select pg_get_function_identity_arguments(oid) into v_ia
      from pg_proc where pronamespace = 'public'::regnamespace and proname = 'receive_stock_transfer';
    if v_ia is null then raise exception 'receive_stock_transfer not found'; end if;
    execute format('alter function public.receive_stock_transfer(%s) rename to _receive_stock_transfer_core', v_ia);
  end if;

  select oid, pg_get_function_arguments(oid), pg_get_function_identity_arguments(oid),
         pg_get_function_result(oid), proargnames
    into v_core, v_args, v_ia, v_res, v_names
    from pg_proc where pronamespace = 'public'::regnamespace and proname = '_receive_stock_transfer_core';

  if not ('p_transfer_id' = any (v_names)) then
    raise exception 'Unexpected signature: %', v_ia;
  end if;

  select string_agg(format('%1$I => %1$I', n), ', ') into v_call from unnest(v_names) n;
  v_call := format('public._receive_stock_transfer_core(%s)', v_call);

  v_body := format($f$
create or replace function public.receive_stock_transfer(%1$s)
returns %2$s language plpgsql security definer set search_path = public as $b$
declare
  v_st record;
begin
  select id, status, to_branch_id into v_st
    from stock_transfers where id = p_transfer_id
    for update;                         -- second click waits here, then sees the result
  if not found then
    raise exception 'Transfer not found';
  end if;
  if v_st.status is distinct from 'in_transit' then
    raise exception 'This transfer is already %% — it cannot be received again.',
      replace(coalesce(v_st.status, 'closed'), '_', ' ');
  end if;
  if exists (select 1 from inventory_movements m
              where m.reference_type = 'stock_transfer' and m.reference_id = p_transfer_id
                and m.branch_id = v_st.to_branch_id and m.quantity > 0) then
    raise exception 'This transfer has already been received — nothing changed.';
  end if;
  %3$s
  update stock_transfers set status = 'completed', updated_at = now()
   where id = p_transfer_id and status = 'in_transit';
end $b$;$f$,
    v_args, v_res,
    case when v_res = 'void' then 'perform ' || v_call || ';'
         else 'declare_result_placeholder' end);

  if v_res <> 'void' then
    -- non-void original: keep its return value
    v_body := replace(v_body, 'declare
  v_st record;', 'declare
  v_st record;
  v_ret ' || v_res || ';');
    v_body := replace(v_body, 'declare_result_placeholder', 'v_ret := ' || v_call || ';');
    v_body := replace(v_body, '
end $b$;', '
  return v_ret;
end $b$;');
  end if;

  execute v_body;
  execute format('revoke all on function public._receive_stock_transfer_core(%s) from public, anon, authenticated', v_ia);
  execute format('grant execute on function public.receive_stock_transfer(%s) to authenticated', v_ia);
end $$;

reset lock_timeout;

-- ── What is duplicated today (all transfers, all orgs) ────────────────────────
-- received_qty should equal sent_qty. Anything above is an extra receive.
with sent as (
  select i.transfer_id, i.product_id, sum(i.quantity) as qty
    from stock_transfer_items i group by 1, 2
), got as (
  select m.reference_id as transfer_id, m.product_id,
         sum(m.quantity) as qty, count(*) as receive_rows,
         string_agg(to_char(m.moved_at at time zone 'Asia/Karachi', 'DD Mon HH24:MI'), ', ' order by m.moved_at) as times
    from inventory_movements m join stock_transfers t on t.id = m.reference_id
   where m.reference_type = 'stock_transfer' and m.branch_id = t.to_branch_id and m.quantity > 0
   group by 1, 2
)
select coalesce(to_jsonb(t)->>'voucher_number', t.id) as transfer, t.status, p.name as product,
       s.qty as sent_qty, g.qty as received_qty, g.qty - s.qty as extra, g.receive_rows, g.times,
       (select count(*) from inventory_cost_layers l where l.source_id like t.id || '%' and to_jsonb(l)->>'product_id' = g.product_id) as cost_layers
  from got g
  join sent s using (transfer_id, product_id)
  join stock_transfers t on t.id = g.transfer_id
  left join products p on p.id = g.product_id
 where g.qty - s.qty > 0.0001
 order by t.created_at, p.name;
