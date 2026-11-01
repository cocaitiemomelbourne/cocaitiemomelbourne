begin;
select pg_advisory_xact_lock(321031,2);
select pg_advisory_xact_lock(1628018,2);
create table if not exists cct_internal.fifo_confirmation_audit_20261102(order_token text primary key,before_items jsonb not null,after_items jsonb,approved_note text not null,changed_at timestamptz not null default now());
alter table cct_internal.fifo_confirmation_audit_20261102 enable row level security;
revoke all on cct_internal.fifo_confirmation_audit_20261102 from public,anon,authenticated;
insert into cct_internal.fifo_confirmation_audit_20261102(order_token,before_items,approved_note)
select order_token,order_items,'User confirmed 2026-11-02: species, no-jelly #234; extra jelly 250g as Single; GV-004 200ml; BAO-BI-03; mango 200g; yolks 50g; chicken 1kg from ingredient lots' from public.order_commits
where order_number in ('CCT-000208','CCT-000209','CCT-000211','CCT-000212','CCT-000213','CCT-000214','CCT-000216','CCT-000217','CCT-000220','CCT-000221','CCT-000222','CCT-000233','CCT-000234','CCT-000236','CCT-000243','CCT-000244','CCT-000251','CCT-000252') on conflict do nothing;
-- Per-line ingredient rules preserve the original sales names, quantities and revenue.
insert into cct_internal.confirmed_line_rules(order_token,item_index,rule_key,display_name,display_sku,requirements,approval)
select o.order_token,j.ix-1,'approved-20261102-'||o.order_number||'-'||(j.ix-1),
case when o.order_number='CCT-000208' then 'Chân gà rút xương 1kg' when o.order_number='CCT-000209' then 'Đóng gói Sứa' when o.order_number in ('CCT-000217','CCT-000251') then 'Xoài thêm 200g' else 'Trứng non thêm 50g' end,
case when o.order_number='CCT-000208' then 'AV-007' when o.order_number='CCT-000209' then 'BAO-BI-03' when o.order_number in ('CCT-000217','CCT-000251') then 'NL-RAU-001' else 'NL-GA-003' end,
jsonb_build_array(jsonb_build_object('ingredient_id',c.id,'unit',c.unit,'per_unit',case when o.order_number='CCT-000208' then 1000 when o.order_number='CCT-000209' then 1 when o.order_number in ('CCT-000217','CCT-000251') then 200 else 50 end)),
'User confirmation 2026-11-02'
from public.order_commits o cross join lateral jsonb_array_elements(o.order_items) with ordinality j(item,ix)
join public.cct_ingredient_catalog c on c.sku=case when o.order_number='CCT-000208' then 'NL-GA-001' when o.order_number='CCT-000209' then 'BAO-BI-03' when o.order_number in ('CCT-000217','CCT-000251') then 'NL-RAU-001' else 'NL-GA-003' end
where (o.order_number='CCT-000208' and j.item->>'name'='Chân Gà Rút Xương 1kg') or (o.order_number='CCT-000209' and j.item->>'name'='set 2 hộp')
or (o.order_number in ('CCT-000217','CCT-000251') and lower(j.item->>'name') like '%xoài%')
or (o.order_number in ('CCT-000221','CCT-000222','CCT-000252') and lower(j.item->>'name') like '%trứng non%')
on conflict(order_token,item_index) do update set requirements=excluded.requirements,approval=excluded.approval;
do $$ declare o record;v jsonb;item jsonb;ix integer;patch jsonb;sku_id bigint;new_items jsonb;r record;opt text;
begin
for o in select * from public.order_commits where order_token in(select order_token from cct_internal.fifo_confirmation_audit_20261102) order by coalesce(pickup_date,delivery_date),order_number loop
 new_items:='[]';
 for item,ix in select value,(ordinality-1)::int from jsonb_array_elements(o.order_items) with ordinality loop
 patch:='{}';
 if o.order_number in ('CCT-000212','CCT-000213','CCT-000214','CCT-000216','CCT-000233','CCT-000234','CCT-000236','CCT-000243','CCT-000244') and (cct_internal.is_chicken(item) or (o.order_number='CCT-000234' and item->>'name'='Chân gà sốt thái')) then
  select id into sku_id from public.products where sku='SU-003';
  opt:=case when o.order_number='CCT-000234' then 'Không sứa • Sốt Thái Đỏ' when o.order_number='CCT-000212' then 'Sứa Cánh Tiên • Sốt Thái Đỏ' else 'Sứa Đạn • Sốt Thái Đỏ' end;
  patch:=jsonb_build_object('id',sku_id,'option_text',opt,'fifo_confirmed_note','User 2026-11-02');
 elsif o.order_number in ('CCT-000211','CCT-000214','CCT-000220') and lower(item->>'name') like 'extra sứa%' then
  select id into sku_id from public.products where sku='SU-001';
  opt:=case when lower(item->>'name') like '%hồ ly%' then 'Sứa Hồ Ly' when lower(item->>'name') like '%trân châu%' then 'Sứa Trân Châu' else 'Sứa Đạn' end;
  patch:=jsonb_build_object('id',sku_id,'name','Ly Sứa Single','original_name',coalesce(item->>'original_name',item->>'name'),'option_text',opt||' • 250g','fifo_confirmed_note','User: 250g, sold as Single; sauce choice not specified');
 elsif o.order_number='CCT-000220' and item->>'name'='Extra sauce' then
  select id into sku_id from public.products where sku='GV-004';
  patch:=jsonb_build_object('id',sku_id,'option_text','Sốt Thái Đỏ • 200ml','fifo_confirmed_note','User 2026-11-02');
 end if;
 select * into r from cct_internal.confirmed_line_rules where order_token=o.order_token and item_index=ix;
 if found then patch:=patch||jsonb_build_object('confirmed_component_rule',r.rule_key);end if;
 new_items:=new_items||jsonb_build_array(item||patch);
 end loop;
 if new_items is distinct from o.order_items then update public.order_commits set order_items=new_items where order_token=o.order_token;end if;
 update cct_internal.fifo_confirmation_audit_20261102 set after_items=new_items where order_token=o.order_token;
end loop;
end $$;
select cct_internal.confirmed_line_reconcile(o.order_token) from public.order_commits o where exists(select 1 from cct_internal.confirmed_line_rules r where r.order_token=o.order_token) order by coalesce(o.pickup_date,o.delivery_date),o.created_at;
-- Explicit SKU now makes the existing automatic FIFO handlers recognize historical lines.
select cct_internal.chicken_reconcile(o.order_token) from public.order_commits o where o.order_token in(select order_token from cct_internal.fifo_confirmation_audit_20261102) order by coalesce(o.pickup_date,o.delivery_date),o.created_at;
select cct_internal.single_reconcile(o.order_token) from public.order_commits o where o.order_number in ('CCT-000211','CCT-000214','CCT-000220') order by coalesce(o.pickup_date,o.delivery_date),o.created_at;
select cct_internal.gv004_reconcile(order_token) from public.order_commits where order_number='CCT-000220';
commit;
