-- Transactional integration checks: all synthetic data rolls back.
begin;
-- Adopt existing rows without persisting test effects.
select cct_internal.single_reconcile(o.order_token) from public.order_commits o where o.status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.is_single(v)) order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token;
insert into public.order_commits
select (jsonb_populate_record(null::public.order_commits,to_jsonb(o)||jsonb_build_object(
 'order_token','single-fifo-lifecycle-test','order_number','SINGLE-FIFO-TEST','status','new','contact_email',null,
 'order_items',jsonb_build_array(jsonb_build_object('id',(select id from public.products where sku='SU-001'),'name','Ly Sứa Single','qty',1,'option_text','Đạn Dù, Mắm Nhĩ')),
 'items','[]'::jsonb,'order_text','Single rollback lifecycle test','customer_note',null))).*
from public.order_commits o where o.order_number='CCT-000320';
update public.order_commits set status='confirmed' where order_token='single-fifo-lifecycle-test';
do $$ begin
 if exists(select 1 from public.cct_order_sauce_cogs where order_token='single-fifo-lifecycle-test') or exists(select 1 from cct_internal.single_sauce_lots where order_token='single-fifo-lifecycle-test') then raise exception 'Allocated sauce before completion';end if;
end $$;
update public.order_commits set status='completed' where order_token='single-fifo-lifecycle-test';
create temporary table single_before_lots as select * from cct_ingredient_lots;
create temporary table single_before_batches as select * from cct_production_batches;
do $$ declare a jsonb;n numeric;begin
 if not exists(select 1 from cct_internal.single_line_state where order_token='single-fifo-lifecycle-test' and missing='[]'::jsonb) then raise exception 'New Single not fully allocated';end if;
 if (select sum(grams) from cct_single_fifo_allocations where order_token='single-fifo-lifecycle-test')<>250 then raise exception 'Wrong jelly grams';end if;
 if (select sum(quantity_ml) from cct_internal.single_sauce_lots where order_token='single-fifo-lifecycle-test')<>200 then raise exception 'Wrong sauce ml';end if;
 if exists(select 1 from cct_single_fifo_allocations a join cct_ingredient_catalog c on c.id=a.ingredient_id where a.order_token='single-fifo-lifecycle-test' and c.sku<>'NL-SUA-002') then raise exception 'Dan Du misidentified as Dan';end if;
 perform cct_internal.single_reconcile('single-fifo-lifecycle-test');perform cct_internal.single_reconcile('single-fifo-lifecycle-test');
 if exists(select * from single_before_lots except select * from cct_ingredient_lots) or exists(select * from single_before_batches except select * from cct_production_batches) then raise exception 'Repeated read consumed inventory twice';end if;
 select order_items into a from order_commits where order_token='single-fifo-lifecycle-test';
 update order_commits set order_items=jsonb_set(a,'{0,qty}','2') where order_token='single-fifo-lifecycle-test';
 if (select sum(grams) from cct_single_fifo_allocations where order_token='single-fifo-lifecycle-test')<>500 or (select sum(quantity_ml) from cct_internal.single_sauce_lots where order_token='single-fifo-lifecycle-test')<>400 then raise exception 'Quantity edit failed';end if;
 update order_commits set order_items=jsonb_set(a,'{0,option_text}',to_jsonb('Trân Châu, Mắm Nhĩ'::text)) where order_token='single-fifo-lifecycle-test';
 if exists(select 1 from cct_single_fifo_allocations a join cct_ingredient_catalog c on c.id=a.ingredient_id where a.order_token='single-fifo-lifecycle-test' and c.sku<>'NL-SUA-004') then raise exception 'Species edit failed';end if;
 update order_commits set status='cancelled' where order_token='single-fifo-lifecycle-test';
 if exists(select 1 from cct_single_fifo_allocations where order_token='single-fifo-lifecycle-test') or exists(select 1 from cct_internal.single_sauce_lots where order_token='single-fifo-lifecycle-test') or exists(select 1 from cct_internal.single_packaging_allocations where order_token='single-fifo-lifecycle-test') then raise exception 'Cancellation failed';end if;
 update order_commits set status='completed' where order_token='single-fifo-lifecycle-test';
 if (select sum(grams) from cct_single_fifo_allocations where order_token='single-fifo-lifecycle-test')<>250 then raise exception 'Recompletion failed';end if;
 update order_commits set order_items=jsonb_set(a,'{0,qty}','0') where order_token='single-fifo-lifecycle-test';
 if exists(select 1 from cct_single_fifo_allocations where order_token='single-fifo-lifecycle-test') then raise exception 'Zero quantity release failed';end if;
 update order_commits set order_items='[]',items='[]' where order_token='single-fifo-lifecycle-test';
 if exists(select 1 from cct_internal.single_line_state where order_token='single-fifo-lifecycle-test') then raise exception 'Removed Single retains state';end if;
 begin perform public.cct_single_fifo_cost_report_v2('invalid-single-test-code');raise exception 'Auth bypass';
 exception when raise_exception then if sqlerrm<>'not_authorized' then raise;end if;end;
end $$;
select 'PASS: completion, exact species, 250g/200ml, quantity/species changes, idempotency, cancellation, recompletion, zero quantity, removal, authentication' result;
rollback;

begin;
-- Force one selected species to require multiple lots. All changes roll back.
update public.cct_ingredient_lots set remaining=100 where ingredient_id=(select id from public.cct_ingredient_catalog where sku='NL-SUA-002');
insert into public.order_commits
select (jsonb_populate_record(null::public.order_commits,to_jsonb(o)||jsonb_build_object(
 'order_token','single-fifo-restock-test','order_number','SINGLE-RESTOCK-TEST','status','completed','contact_email',null,'pickup_date','2026-07-07','delivery_date',null,'fulfilment_method','pickup',
 'order_items',jsonb_build_array(jsonb_build_object('id',(select id from public.products where sku='SU-001'),'name','Ly Sứa Single','qty',1,'option_text','Đạn Dù, Sốt Thái')),
 'items','[]'::jsonb,'order_text','Single rollback restock test','customer_note',null))).*
from public.order_commits o where o.order_number='CCT-000320';
do $$ begin
 if not exists(select 1 from cct_internal.single_line_state where order_token='single-fifo-restock-test' and jsonb_array_length(missing)>=2) then raise exception 'Expected jelly and sauce shortages';end if;
end $$;
insert into public.cct_ingredient_lots(id,ingredient_id,ingredient_name,received_on,quantity,remaining,unit,total_cost,note) overriding system value
select (select least(-1,coalesce(min(id),0)-1) from public.cct_ingredient_lots)-n,c.id,c.name,'2026-07-07',75,75,'g',2,'Rollback only' from public.cct_ingredient_catalog c cross join (values(0),(1)) v(n) where c.sku='NL-SUA-002';
insert into public.cct_production_batches(id,recipe_id,produced_on,quantity,unit,total_cost,notes) overriding system value
select (select least(-1,coalesce(min(id),0)-1) from public.cct_production_batches)-n,r.id,'2026-07-07',100,'ml',1,'Rollback only' from public.cct_production_recipes r cross join (values(0),(1)) v(n) where r.sku='SOT-THAI';
-- The stock entry's deferred callback must perform allocation without a manual reconcile call.
set constraints all immediate;
do $$ declare d text;r jsonb;expected numeric;begin
 if not exists(select 1 from cct_internal.single_line_state where order_token='single-fifo-restock-test' and missing='[]'::jsonb) then raise exception 'Restock did not resolve Single';end if;
 if (select count(*) from public.cct_single_fifo_allocations where order_token='single-fifo-restock-test')<>3 or (select sum(grams) from public.cct_single_fifo_allocations where order_token='single-fifo-restock-test')<>250 then raise exception 'Split jelly lots incorrect';end if;
 if (select count(*) from cct_internal.single_sauce_lots where order_token='single-fifo-restock-test')<>2 or (select sum(quantity_ml) from cct_internal.single_sauce_lots where order_token='single-fifo-restock-test')<>200 then raise exception 'Split sauce batches incorrect';end if;
 select pg_get_functiondef('public.cct_single_fifo_cost_report_v2(text)'::regprocedure) into d;
 d:=replace(d,'public.cct_single_fifo_cost_report_v2','pg_temp.single_test_report');
 d:=replace(d,'if not public.cct_production_auth_v1(p_passcode) then raise exception ''not_authorized'';end if;','');
 execute d;
 select value into r from jsonb_array_elements(pg_temp.single_test_report('')) where value->>'order_token'='single-fifo-restock-test';
 select sum(v.cost) into expected from (
  select extended_cost cost from public.cct_single_fifo_allocations where order_token='single-fifo-restock-test'
  union all select cost from cct_internal.single_sauce_lots where order_token='single-fifo-restock-test'
  union all select extended_cost from cct_internal.single_packaging_allocations where order_token='single-fifo-restock-test'
 ) v;
 if (r->>'cost')::numeric<>round(expected,4) or jsonb_array_length(r->'missing')<>0 then raise exception 'Report does not sum all split lots: %',r;end if;
 -- Both changed date and changed sauce must invalidate and reevaluate the stored plan.
 update public.order_commits set pickup_date='2026-01-01' where order_token='single-fifo-restock-test';
 if exists(select 1 from public.cct_single_fifo_allocations where order_token='single-fifo-restock-test') or not exists(select 1 from cct_internal.single_line_state where order_token='single-fifo-restock-test' and jsonb_array_length(missing)>0) then raise exception 'Used future ingredient lot';end if;
 if exists(select 1 from public.cct_ingredient_lots where remaining<0) or exists(select 1 from public.cct_production_batches where used_quantity<0 or used_quantity>quantity) then raise exception 'Inventory outside bounds';end if;
end $$;
select 'PASS: automatic restock retry, three jelly lots, two sauce batches, complete report sum, date eligibility' result;
rollback;