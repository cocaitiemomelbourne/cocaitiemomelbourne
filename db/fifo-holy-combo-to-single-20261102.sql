begin;
select pg_advisory_xact_lock(321031,2);
select pg_advisory_xact_lock(1628018,2);
create table if not exists cct_internal.holy_single_swap_20261102(
 order_token text not null,item_index integer not null,before_allocations jsonb not null,
 after_allocations jsonb,grams_replaced numeric not null,reason text not null,
 created_at timestamptz not null default now(),primary key(order_token,item_index));
alter table cct_internal.holy_single_swap_20261102 enable row level security;
revoke all on cct_internal.holy_single_swap_20261102 from public,anon,authenticated;
create temp table qa_holy_swap_before as select id,remaining from public.cct_ingredient_lots;
do $$
declare src record;holy_id bigint;dan_id bigint;newlot public.cct_ingredient_lots%rowtype;
 before_rows jsonb;affected integer;released numeric:=0;q numeric;before_sum numeric;
begin
 select id into strict holy_id from public.cct_ingredient_catalog where sku='NL-SUA-003';
 select id into strict dan_id from public.cct_ingredient_catalog where sku='NL-SUA-001';
 perform id from public.cct_ingredient_lots where ingredient_id in (holy_id,dan_id) order by id for update;
 for src in select a.* from public.cct_combo_fifo_allocations a join public.order_commits o using(order_token)
 where a.ingredient_id=holy_id and o.order_number in ('CCT-000243','CCT-000246','CCT-000251','CCT-000252','CCT-000255','CCT-000260')
 order by a.sale_date,a.order_number,a.item_index for update of a loop
  if exists(select 1 from cct_internal.holy_single_swap_20261102 where order_token=src.order_token and item_index=src.item_index) then continue;end if;
  assert not exists(select 1 from public.cct_combo_fifo_allocations where order_token=src.order_token and item_index=src.item_index and ingredient_id=dan_id),'Replacement must retain five distinct species';
  select (order_items->src.item_index->>'qty')::numeric into q from public.order_commits where order_token=src.order_token;
  assert src.grams=80*q,'Unexpected source grams';
  select jsonb_agg(to_jsonb(a) order by a.ingredient_id,a.lot_id) into before_rows from public.cct_combo_fifo_allocations a where a.order_token=src.order_token and a.item_index=src.item_index;
  select * into newlot from public.cct_ingredient_lots l where l.ingredient_id=dan_id and l.unit='g' and l.quantity>0 and l.remaining>=src.grams and l.received_on<=src.sale_date order by l.received_on,l.id limit 1;
  if not found then raise exception 'No valid replacement lot for %',src.order_number;end if;
  assert (select received_on<='2026-08-22'::date from public.cct_ingredient_lots where id=src.lot_id),'Released Holy lot is later than Single date';
  insert into cct_internal.holy_single_swap_20261102(order_token,item_index,before_allocations,grams_replaced,reason)
  values(src.order_token,src.item_index,before_rows,src.grams,'User 2026-11-02: replace Combo Holy with same-period species to cover 250g Holy Single #211 and #214');
  update public.cct_ingredient_lots set remaining=remaining+src.grams where id=src.lot_id;
  update public.cct_ingredient_lots set remaining=remaining-src.grams where id=newlot.id;
  update public.cct_combo_fifo_allocations set lot_id=newlot.id,ingredient_id=dan_id,unit_cost=newlot.total_cost/newlot.quantity,extended_cost=round(src.grams*newlot.total_cost/newlot.quantity,4)
  where order_token=src.order_token and item_index=src.item_index and lot_id=src.lot_id;
  get diagnostics affected=row_count;assert affected=1,'Unexpected allocation count';
  update cct_internal.holy_single_swap_20261102 au set after_allocations=(select jsonb_agg(to_jsonb(a) order by a.ingredient_id,a.lot_id) from public.cct_combo_fifo_allocations a where a.order_token=src.order_token and a.item_index=src.item_index)
  where au.order_token=src.order_token and au.item_index=src.item_index;
  released:=released+src.grams;
 end loop;
 if released>0 then assert released=560,'Expected 560g freed across seven Combo cups';end if;
 perform cct_internal.single_reconcile(order_token) from public.order_commits where order_number in ('CCT-000211','CCT-000214') order by order_number;
 assert (select sum(a.grams)=500 from public.cct_single_fifo_allocations a join public.order_commits o using(order_token) where o.order_number in ('CCT-000211','CCT-000214') and a.ingredient_id=holy_id),'Singles are not fully covered';
 assert not exists(select 1 from cct_internal.holy_single_swap_20261102 au join public.order_commits o using(order_token) left join public.cct_combo_fifo_allocations a on a.order_token=au.order_token and a.item_index=au.item_index
 group by au.order_token,au.item_index,o.order_items having sum(a.grams)<>400*(o.order_items->au.item_index->>'qty')::numeric or count(distinct a.ingredient_id)<>5),'Invalid Combo composition';
 assert not exists(select 1 from public.cct_ingredient_lots where remaining<0),'Negative inventory';
end $$;
set constraints all immediate;
-- A second reconciliation must preserve the replacements and not consume stock twice.
create temp table qa_holy_swap_after as select id,remaining from public.cct_ingredient_lots;
select cct_internal.combo_reconcile(o.order_token) from public.order_commits o where o.order_token in(select order_token from cct_internal.holy_single_swap_20261102);
select cct_internal.single_reconcile(order_token) from public.order_commits where order_number in ('CCT-000211','CCT-000214');
do $$begin
 assert not exists(select 1 from public.cct_ingredient_lots l join qa_holy_swap_after q using(id) where l.remaining is distinct from q.remaining),'Repeated reconciliation changed stock';
end $$;
commit;
