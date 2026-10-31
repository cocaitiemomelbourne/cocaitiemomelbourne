-- Integration checks run in transactions and roll back order/inventory mutations.
begin;
-- Seed in sale order exactly as the report does, then exercise real order triggers.
do $$ declare r record; begin
 for r in select o.order_token from public.order_commits o where o.status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.is_chicken(v)) order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token loop
  perform cct_internal.chicken_reconcile(r.order_token);
 end loop;
end $$;
create temporary table fifo_before_lots as select * from public.cct_ingredient_lots;
create temporary table fifo_before_batches as select * from public.cct_production_batches;
create temporary table fifo_before_lines as select * from public.cct_chicken_mix_fifo_allocations;
create temporary table fifo_before_jelly as select * from public.cct_chicken_mix_jelly_allocations;
create temporary table fifo_before_boxes as select * from public.cct_chicken_mix_packaging_allocations;
create temporary table fifo_before_sauce as select * from cct_internal.chicken_sauce_lots;
do $$ declare tok text; arr jsonb; n numeric; req jsonb; chosen bigint; source record; p record;
begin
 select order_token,order_items into tok,arr from order_commits where order_number='CCT-000323';
 perform cct_internal.chicken_reconcile(tok); perform cct_internal.chicken_reconcile(tok);
 if exists(select * from fifo_before_lots except select * from cct_ingredient_lots) or exists(select * from fifo_before_batches except select * from cct_production_batches) then raise exception 'Repeated reconcile changed inventory';end if;
 if exists(select 1 from cct_chicken_mix_fifo_allocations a join cct_ingredient_catalog c on c.id=a.ingredient_id where a.order_token=tok and a.item_index=1 and c.name='Mề gà') then raise exception 'Excluded gizzard allocated';end if;
 -- Double only the chicken line; the order also contains Combo, which must be left intact.
 update order_commits set order_items=jsonb_set(arr,'{1,qty}','2') where order_token=tok;
 select sum(grams) into n from cct_chicken_mix_jelly_allocations where order_token=tok and item_index=1;
 if n<>300 then raise exception 'Quantity update failed %',n;end if;
 update order_commits set order_items=jsonb_set(jsonb_set(arr,'{1,qty}','2'),'{1,option_text}',to_jsonb('Sứa Đạn, không Mề gà, không lấy sứa'::text)) where order_token=tok;
 if exists(select 1 from cct_chicken_mix_jelly_allocations where order_token=tok and item_index=1) then raise exception 'No jelly failed';end if;
 update order_commits set order_items=jsonb_set(arr,'{1,option_text}',to_jsonb('Sứa Trân Châu, không Mề gà'::text)) where order_token=tok;
 select a.ingredient_id into chosen from cct_chicken_mix_jelly_allocations a where a.order_token=tok and a.item_index=1 limit 1;
 if chosen is distinct from (select id from cct_ingredient_catalog where sku='NL-SUA-004') then raise exception 'Species switch failed';end if;
 update order_commits set order_items=arr,status='cancelled' where order_token=tok;
 if exists(select 1 from cct_chicken_mix_fifo_allocations where order_token=tok) or exists(select 1 from cct_chicken_mix_jelly_allocations where order_token=tok) or exists(select 1 from cct_chicken_mix_packaging_allocations where order_token=tok) or exists(select 1 from cct_internal.chicken_sauce_lots where order_token=tok) then raise exception 'Cancellation did not return allocations';end if;
 update order_commits set status='completed',order_items=arr where order_token=tok;
 select sum(grams) into n from cct_chicken_mix_jelly_allocations where order_token=tok and item_index=1;
 if n<>150 then raise exception 'Recompletion failed';end if;
 -- A delivery date before receipt must release the original lots and leave a real shortage.
 update order_commits set delivery_date='2026-01-01' where order_token=tok;
 if exists(select 1 from cct_chicken_mix_jelly_allocations where order_token=tok) then raise exception 'Used future stock';end if;
 if not exists(select 1 from cct_internal.chicken_line_state where order_token=tok and jsonb_array_length(missing)>0) then raise exception 'Date shortage hidden';end if;
 -- Wrong password must fail before executing reconciliation.
 begin
  perform public.cct_chicken_mix_cost_report_v1('fifo-test-invalid-code');
  raise exception 'Authorization bypass';
 exception when raise_exception then if sqlerrm<>'not_authorized' then raise;end if;
 end;
end $$;
select 'PASS: idempotency, quantity, no gizzard, no jelly, species change, cancellation, recompletion, date eligibility, authorization' result;
rollback;

begin;
do $$ declare r record; tok text; arr jsonb; n int;
begin
 for r in select o.order_token from order_commits o where o.status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.is_chicken(v)) order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token loop perform cct_internal.chicken_reconcile(r.order_token);end loop;
 select order_token,order_items into tok,arr from order_commits where order_number='CCT-000315';
 select count(*) into n from cct_chicken_mix_fifo_allocations a join cct_ingredient_catalog c on c.id=a.ingredient_id where a.order_token=tok and c.sku='NL-GA-001';
 if n<>2 then raise exception 'Chicken feet did not span oldest two lots %',n;end if;
 select count(*) into n from cct_internal.chicken_sauce_lots a join order_commits o using(order_token) where o.order_number='CCT-000285';
 if n<>2 then raise exception 'Sauce did not span oldest two batches %',n;end if;
 update order_commits set order_items=jsonb_set(arr,'{0,qty}','0') where order_token=tok;
 if exists(select 1 from cct_chicken_mix_fifo_allocations where order_token=tok) or exists(select 1 from cct_chicken_mix_jelly_allocations where order_token=tok) then raise exception 'Zero quantity not reversed';end if;
 update order_commits set order_items=arr where order_token=tok;
 update order_commits set order_items='[]',items='[]' where order_token=tok;
 if exists(select 1 from cct_internal.chicken_line_state where order_token=tok) or exists(select 1 from cct_chicken_mix_packaging_allocations where order_token=tok) or exists(select 1 from cct_internal.chicken_sauce_lots where order_token=tok) then raise exception 'Removed line retains allocations';end if;
 if exists(select 1 from cct_ingredient_lots where remaining<0 or remaining>quantity) or exists(select 1 from cct_production_batches where used_quantity<0 or used_quantity>quantity) then raise exception 'Inventory bounds violated';end if;
end $$;
select 'PASS: split ingredient lots, split sauce batches, zero quantity, removed line, inventory bounds' result;
rollback;