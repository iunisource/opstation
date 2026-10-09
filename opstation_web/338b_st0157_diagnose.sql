-- 338b — read-only: everything that touched ST-2026-0157
with t as (
  select * from stock_transfers
   where org_id = 'org_1784655141655' and voucher_number = 'ST-2026-0157'
)
select 'transfer' as what, t.id, t.status, null::numeric as qty,
       fb.name || ' → ' || tb.name as detail,
       t.created_at::text as created, t.dispatched_at::text as dispatched, t.approved_at::text as approved, t.updated_at::text as updated, null::text as created_by
  from t left join branches fb on fb.id = t.from_branch_id left join branches tb on tb.id = t.to_branch_id
union all
select 'item', i.id, case when i.dispatch_costed then 'costed' else 'not costed' end, i.quantity,
       p.name, null, null, null, null, null
  from stock_transfer_items i join t on i.transfer_id = t.id left join products p on p.id = i.product_id
union all
select 'movement', m.id,
       case when m.branch_id = t.to_branch_id then 'at DESTINATION'
            when m.branch_id = t.from_branch_id then 'at SOURCE' else 'other branch' end,
       m.quantity,
       b.name || coalesce(' — ' || m.notes, ''),
       to_jsonb(m)->>'created_at', m.moved_at::text, null, null, m.created_by::text
  from inventory_movements m join t on m.reference_id = t.id left join branches b on b.id = m.branch_id
union all
select 'layer', l.id, l.source_type, l.qty_in,
       b.name || ' · remaining ' || l.qty_remaining || ' @ ' || l.unit_cost,
       l.layer_date::text, null, null, null, null
  from inventory_cost_layers l join t on true
  join stock_transfer_items i on i.transfer_id = t.id and l.source_id in (i.id, t.id)
  left join branches b on b.id = l.branch_id
order by 1 desc, 6;
