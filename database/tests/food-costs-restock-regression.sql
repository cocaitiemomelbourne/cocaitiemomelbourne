-- Transactional restock integration tests. All synthetic stock and orders roll back.
begin;
create temporary table original_sauce_costs as select * from public.cct_order_sauce_cogs;
create temporary table original_combo_allocations as select * from public.cct_combo_fifo_allocations;
do $$ begin
 if not exists(select 1 from cct_internal.chicken_line_state s join order_commits o using(order_token) where o.order_number='CCT-000290' and jsonb_array_length(s.missing)>0) then raise exception 'Expected pending sauce before restock';end if;
end $$;
insert into public.cct_production_batches(id,recipe_id,produced_on,quantity,unit,total_cost,notes) overriding system value
select (select least(-1,coalesce(min(id),0)-1) from public.cct_production_batches),r.id,'2026-10-24',100,'ml',1,'Rollback restock regression only' from public.cct_production_recipes r where r.sku='SOT-THAI';
-- Fire the same deferred event that runs automatically at COMMIT; do not invoke any allocator.
set constraints all immediate;
do $$ begin
 if not exists(select 1 from cct_internal.chicken_line_state s join order_commits o using(order_token) where o.order_number='CCT-000290' and s.missing='[]'::jsonb) then raise exception 'Sauce restock did not resolve pending cost';end if;
 if exists(select * from original_sauce_costs except select * from public.cct_order_sauce_cogs) then raise exception 'Existing sauce cost replaced';end if;
 if exists(select * from original_combo_allocations except select * from public.cct_combo_fifo_allocations) then raise exception 'Existing combo allocation replaced';end if;
 if exists(select 1 from cct_production_batches where used_quantity>quantity or used_quantity<0) then raise exception 'Invalid batch consumption';end if;
end $$;
select 'PASS: adding a sauce batch automatically clears order 290 missing cost without changing prior allocations' result;
rollback;

begin;
-- Simulate a selected species and vegetables being unavailable, without altering any saved input after rollback.
update public.cct_ingredient_lots set remaining=0 where ingredient_id in (select id from public.cct_ingredient_catalog where sku in ('NL-SUA-003','NL-RAU-005'));
insert into public.order_commits
select (jsonb_populate_record(null::public.order_commits,to_jsonb(o)||jsonb_build_object(
 'order_token','fifo-restock-rollback-test','order_number','FIFO-RESTOCK-TEST','status','completed','contact_email',null,
 'order_items',jsonb_build_array(jsonb_build_object('id',(select id from public.products where sku='SU-003'),'name','Sứa Trộn Chân Gà Rút Xương – Mề Gà – Trứng Non – Sốt Thái','qty',2,'option_text','Sứa Hồ Ly, không sốt')),
 'items','[]'::jsonb,'order_text','FIFO restock rollback test','customer_note',null))).*
from public.order_commits o where o.order_number='CCT-000315';
do $$ begin
 if not exists(select 1 from cct_internal.chicken_line_state where order_token='fifo-restock-rollback-test' and jsonb_array_length(missing)>=2) then raise exception 'Expected jelly and vegetable shortages';end if;
end $$;
-- Two species lots together satisfy the pending 300g. A separate vegetable lot supplies 30g.
insert into public.cct_ingredient_lots(id,ingredient_id,ingredient_name,received_on,quantity,remaining,unit,total_cost,note) overriding system value
select (select least(-1,coalesce(min(id),0)-1) from public.cct_ingredient_lots)-k.n,c.id,c.name,'2026-10-30',150,150,'g',5,'Rollback restock test only'
from public.cct_ingredient_catalog c cross join (values(0),(1)) k(n) where c.sku='NL-SUA-003';
insert into public.cct_ingredient_lots(id,ingredient_id,ingredient_name,received_on,quantity,remaining,unit,total_cost,note) overriding system value
select (select least(-1,coalesce(min(id),0)-1) from public.cct_ingredient_lots),c.id,c.name,'2026-10-30',30,30,'g',1,'Rollback restock test only'
from public.cct_ingredient_catalog c where c.sku='NL-RAU-005';
set constraints all immediate;
do $$ begin
 if not exists(select 1 from cct_internal.chicken_line_state where order_token='fifo-restock-rollback-test' and missing='[]'::jsonb) then raise exception 'Restocking jelly and vegetables did not resolve costs';end if;
 if (select sum(grams) from public.cct_chicken_mix_jelly_allocations where order_token='fifo-restock-rollback-test')<>300 then raise exception 'Incorrect automatic jelly quantity';end if;
 if (select count(*) from public.cct_chicken_mix_jelly_allocations where order_token='fifo-restock-rollback-test')<>2 then raise exception 'Expected split-lot allocation';end if;
 if exists(select 1 from cct_ingredient_lots where remaining<0) then raise exception 'Inventory overdrawn';end if;
end $$;
select 'PASS: stocking multiple jelly lots and vegetables automatically clears missing cost after the complete stock entry' result;
rollback;