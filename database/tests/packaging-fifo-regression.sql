-- All integration tests roll back data mutations.
begin;
CREATE OR REPLACE FUNCTION pg_temp.combo_source(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare o record; it jsonb; ix int; sold date; qty numeric; x record; picks jsonb; n int; jelly_cost numeric; extras numeric; missing jsonb; breakdown jsonb; lines jsonb:='[]'::jsonb; sauce_code text; cost_sauce numeric; recipe_id bigint; component record; lot record; sauce_batch record;
begin
 
 select id into recipe_id from public.products where sku='SU-002';
 for o in select * from public.order_commits where status='completed' order by coalesce(delivery_date,pickup_date,(created_at at time zone 'Australia/Melbourne')::date),order_token loop
 sold:=coalesce(case when o.fulfilment_method='delivery' then o.delivery_date else o.pickup_date end,o.delivery_date,o.pickup_date,(o.created_at at time zone 'Australia/Melbourne')::date);
 for it,ix in select value,(ordinality-1)::int from jsonb_array_elements(coalesce(o.order_items,'[]'::jsonb)) with ordinality loop
 if lower(coalesce(it->>'name','')) not like '%sứa combo 5%' and lower(coalesce(it->>'name','')) not like '%sứa combo%' then continue;end if;

 qty:=coalesce(nullif(it->>'qty','')::numeric,1);if qty<=0 then continue;end if;
 jelly_cost:=0;extras:=0;n:=0;missing:='[]'::jsonb;breakdown:='[]'::jsonb;picks:='[]'::jsonb;
 -- Read each unique species' oldest eligible lot, then choose five lowest unit-cost species.
 for x in
 select z.ingredient_id,z.ingredient_name,z.total_cost/z.quantity unit_cost,z.quantity,z.remaining,z.received_on,z.id lot_id
 from (select distinct on (l.ingredient_id) l.ingredient_id,c.name ingredient_name,l.quantity,l.remaining,l.total_cost,l.received_on,l.id
 from public.cct_ingredient_lots l join public.cct_ingredient_catalog c on c.id=l.ingredient_id
 where c.sku like 'NL-SUA-%' and l.received_on<=sold and l.quantity>0 and l.remaining>=80*qty
 order by l.ingredient_id,l.received_on,l.id) z
 order by z.total_cost/z.quantity,z.ingredient_name,z.id limit 5
 loop
 n:=n+1;jelly_cost:=jelly_cost+round(x.unit_cost*80*qty,4);
 picks:=picks||jsonb_build_array(jsonb_build_object('name',x.ingredient_name,'lot_id',x.lot_id,'cost',round(x.unit_cost*80*qty,4)));
 end loop;
 if n<5 then missing:=missing||jsonb_build_array('Không có đủ 5 loại sứa có lô hợp lệ');end if;
 for component in select i.* from public.cct_standard_recipe_items i where i.product_id=recipe_id and i.component_group in ('sauce','vegetable','packaging') order by i.id loop
  if component.component_group='sauce' then
   sauce_code:=case when lower(component.ingredient_name) like '%mắm nhĩ%' then 'SOT-MAM-NHI' when lower(component.ingredient_name) like '%thái%' then 'SOT-THAI' else null end;
   cost_sauce:=component.quantity*qty;
if lower(coalesce(it->>'option_text','')) ~ 'only[[:space:]]+(sốt[[:space:]]+)?(thái|thai)' then
 if sauce_code<>'SOT-THAI' then continue; end if; cost_sauce:=400*qty;
elsif lower(coalesce(it->>'option_text','')) ~ 'only[[:space:]]+(sốt[[:space:]]+)?(mắm[[:space:]]+nhĩ|mam[[:space:]]+nhi)' then
 if sauce_code<>'SOT-MAM-NHI' then continue; end if; cost_sauce:=400*qty;
end if;
if exists(select 1 from public.cct_order_sauce_cogs a where a.order_token=o.order_token and a.item_index=ix and a.sauce_sku=sauce_code and a.quantity_ml=cost_sauce) then
 select extras+sum(a.cost) into extras from public.cct_order_sauce_cogs a where a.order_token=o.order_token and a.item_index=ix and a.sauce_sku=sauce_code;
 continue;
end if;
select b.* into sauce_batch from public.cct_production_batches b join public.cct_production_recipes r on r.id=b.recipe_id where r.sku=sauce_code and b.produced_on<=sold and b.quantity>0 order by b.produced_on,b.id limit 1;
   if o.order_number='CCT-000107' and sauce_code='SOT-MAM-NHI' then continue; end if; if not found then missing:=missing||jsonb_build_array('Thiếu mẻ sốt: '||component.ingredient_name);
   else extras:=extras+round(cost_sauce*case when o.order_number='CCT-000107' and sauce_code='SOT-THAI' then 2 else 1 end*sauce_batch.total_cost/sauce_batch.quantity,4);end if;
  else
   select l.* into lot from public.cct_ingredient_lots l where lower(l.ingredient_name)=lower(component.ingredient_name) and l.received_on<=sold and l.quantity>0 order by l.received_on,l.id limit 1;
   if not found then missing:=missing||jsonb_build_array('Thiếu lô: '||component.ingredient_name);
   else extras:=extras+round(component.quantity*qty*lot.total_cost/lot.quantity,4);end if;
  end if;
 end loop;
 lines:=lines||jsonb_build_array(jsonb_build_object('order_token',o.order_token,'order_number',o.order_number,'item_index',ix,'date',sold,'qty',qty,'jelly_cost',jelly_cost,'extra_cost',extras,'cost',round(jelly_cost+extras,4),'missing',missing,'selected_species',picks,'method','estimated_5_cheapest_available_at_sale_date'));
 end loop;end loop;
 return lines;
end $function$
;
CREATE OR REPLACE FUNCTION pg_temp.combo_before(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare source jsonb; item jsonb; result jsonb:='[]'::jsonb; qty_cost numeric; picked jsonb; adjusted_missing jsonb; missing_item jsonb;
begin
 
 perform cct_internal.combo_reconcile(o.order_token) from public.order_commits o where o.status='completed' order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token;
 source:=pg_temp.combo_source(p_passcode);
 for item in select value from jsonb_array_elements(source) loop
  select sum(a.extended_cost),jsonb_agg(jsonb_build_object('name',c.name,'lot_id',a.lot_id,'grams',a.grams,'cost',a.extended_cost) order by c.name)
   into qty_cost,picked from public.cct_combo_fifo_allocations a
   join public.cct_ingredient_catalog c on c.id=a.ingredient_id
   where a.order_token=item->>'order_token' and a.item_index=(item->>'item_index')::integer;
  adjusted_missing:='[]'::jsonb;
  for missing_item in select value from jsonb_array_elements(coalesce(item->'missing','[]'::jsonb)) loop
   if missing_item#>>'{}' not like 'Không có đủ 5 loại sứa%' then
     adjusted_missing:=adjusted_missing||jsonb_build_array(missing_item);
   end if;
  end loop;
  if qty_cost is null or not (select count(distinct a.ingredient_id)=5 and sum(a.grams)=400*(item->>'qty')::numeric and not exists(select 1 from public.cct_combo_fifo_allocations b where b.order_token=item->>'order_token' and b.item_index=(item->>'item_index')::int group by b.ingredient_id having sum(b.grams)<>80*(item->>'qty')::numeric) from public.cct_combo_fifo_allocations a where a.order_token=item->>'order_token' and a.item_index=(item->>'item_index')::int) then
   adjusted_missing:=adjusted_missing||jsonb_build_array('Chưa có phân bổ FIFO sứa lưu theo dòng đơn');
   qty_cost:=0;
  end if;
  item:=jsonb_set(item,'{jelly_cost}',to_jsonb(round(qty_cost,4)));
  item:=jsonb_set(item,'{cost}',to_jsonb(round(qty_cost+coalesce((item->>'extra_cost')::numeric,0),4)));
  item:=jsonb_set(item,'{selected_species}',coalesce(picked,'[]'::jsonb));
  item:=jsonb_set(item,'{missing}',adjusted_missing);
  item:=jsonb_set(item,'{method}',to_jsonb('persisted_fifo_by_order_and_lot'::text));
  result:=result||jsonb_build_array(item);
 end loop;
 return result;
end $function$
;
CREATE OR REPLACE FUNCTION pg_temp.shake_before(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r record; sau record; mango record; cup record; out_rows jsonb:='[]'::jsonb; miss jsonb; cost_amt numeric;
begin
 
 for r in select * from public.cct_mango_shake_fifo_allocations order by sale_date,order_number loop
 miss:='[]'::jsonb;cost_amt:=r.extended_cost;
 select l.* into mango from public.cct_ingredient_lots l where l.ingredient_id=15 and l.received_on<=r.sale_date and l.quantity>0 order by l.received_on,l.id limit 1;
 if not found then miss:=miss||jsonb_build_array('Thiếu lô xoài');else
 cost_amt:=cost_amt+round(100*mango.total_cost/mango.quantity,4);
 if not exists(select 1 from public.cct_mango_fifo_allocations ma where ma.order_token=r.order_token and ma.item_index=r.item_index and ma.lot_id=mango.id and ma.grams=100) then miss:=miss||jsonb_build_array('Chưa phân bổ FIFO xoài 100g cho đơn');end if;
 end if;
 select l.* into cup from public.cct_ingredient_lots l where l.ingredient_id=19 and l.received_on<=r.sale_date and l.quantity>0 order by l.received_on,l.id limit 1;
 if not found then miss:=miss||jsonb_build_array('Thiếu lô ly');else cost_amt:=cost_amt+round(cup.total_cost/cup.quantity,4);end if;
 select b.* into sau from public.cct_production_batches b join public.cct_production_recipes p on p.id=b.recipe_id where p.sku='SOT-THAI' and b.produced_on<=r.sale_date and b.quantity>0 order by b.produced_on,b.id limit 1;
 if not found then miss:=miss||jsonb_build_array('Thiếu mẻ sốt Thái');else cost_amt:=cost_amt+round(300*sau.total_cost/sau.quantity,4);end if;
 out_rows:=out_rows||jsonb_build_array(jsonb_build_object('order_token',r.order_token,'order_number',r.order_number,'item_index',r.item_index,'cost',round(cost_amt,4),'missing',miss,'date',r.sale_date));
 end loop;
 return out_rows;
end $function$
;

create temporary table old_combo_costs as select value->>'order_token' tok,(value->>'item_index')::int ix,(value->>'cost')::numeric cost from jsonb_array_elements(pg_temp.combo_before(''));
create temporary table old_shake_costs as select value->>'order_token' tok,(value->>'item_index')::int ix,(value->>'cost')::numeric cost from jsonb_array_elements(pg_temp.shake_before(''));
select cct_internal.packaging_reconcile(o.order_token) from public.order_commits o where status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.packaging_product(v) is not null) order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token;
do $$ declare d text;begin
 select pg_get_functiondef('public.cct_combo_fifo_cost_report_v2(text)'::regprocedure) into d;
 d:=replace(d,'public.cct_combo_fifo_cost_report_v2','pg_temp.combo_after');
 d:=replace(d,'public.cct_combo5_cost_report_v1','pg_temp.combo_source');
 d:=replace(d,'if not public.cct_production_auth_v1(p_passcode) then raise exception ''not_authorized''; end if;','');execute d;
 select pg_get_functiondef('public.cct_mango_shake_cost_report_v1(text)'::regprocedure) into d;
 d:=replace(d,'public.cct_mango_shake_cost_report_v1','pg_temp.shake_after');
 d:=replace(d,'if not public.cct_production_auth_v1(p_passcode) then raise exception ''not_authorized'';end if;','');execute d;
 if exists(select 1 from jsonb_array_elements(pg_temp.combo_after('')) x join old_combo_costs o on o.tok=x->>'order_token' and o.ix=(x->>'item_index')::int where (x->>'cost')::numeric<>o.cost) then raise exception 'Combo packaging double-counted or cost changed';end if;
 if exists(select 1 from jsonb_array_elements(pg_temp.shake_after('')) x join old_shake_costs o on o.tok=x->>'order_token' and o.ix=(x->>'item_index')::int where (x->>'cost')::numeric<>o.cost) then raise exception 'Shake packaging double-counted or cost changed';end if;
 if exists(select 1 from cct_internal.food_packaging_state where missing<>'[]'::jsonb) then raise exception 'Unexpected missing packaging';end if;
end $$;
select c.sku,l.quantity,l.quantity-l.remaining used,l.remaining from public.cct_ingredient_lots l join public.cct_ingredient_catalog c on c.id=l.ingredient_id where c.sku in ('LY-SUA','BAO-BI-03','BAO-BI-02');
rollback;
begin;
select cct_internal.packaging_reconcile(o.order_token) from public.order_commits o where status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.packaging_product(v) is not null) order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token;
create temporary table packages_before as select * from public.cct_ingredient_lots where ingredient_id in (select id from cct_ingredient_catalog where sku in ('LY-SUA','BAO-BI-03','BAO-BI-02'));
do $$ declare tok text;a jsonb;begin
 select order_token,order_items into tok,a from public.order_commits where order_number='CCT-000317';
 perform cct_internal.packaging_reconcile(tok);perform cct_internal.packaging_reconcile(tok);
 if exists(select * from packages_before except select * from public.cct_ingredient_lots) then raise exception 'Double consumption on repeat';end if;
 update public.order_commits set order_items=jsonb_set(a,'{0,qty}','3') where order_token=tok;
 if (select sum(quantity) from cct_internal.food_packaging_allocations x join cct_ingredient_catalog c on c.id=x.ingredient_id where x.order_token=tok and c.sku='LY-SUA')<>3 then raise exception 'Cup quantity edit failed';end if;
 if (select sum(quantity) from cct_internal.food_packaging_allocations x join cct_ingredient_catalog c on c.id=x.ingredient_id where x.order_token=tok and c.sku='BAO-BI-02')<>6 then raise exception 'Sauce box quantity edit failed';end if;
 update public.order_commits set status='cancelled' where order_token=tok;
 if exists(select 1 from cct_internal.food_packaging_allocations where order_token=tok) then raise exception 'Cancellation failed';end if;
 update public.order_commits set status='completed',order_items=a where order_token=tok;
 if (select sum(quantity) from cct_internal.food_packaging_allocations x join cct_ingredient_catalog c on c.id=x.ingredient_id where x.order_token=tok and c.sku='LY-SUA')<>2 then raise exception 'Recompletion failed';end if;
 update public.order_commits set order_items=jsonb_set(a,'{0,qty}','0') where order_token=tok;
 if exists(select 1 from cct_internal.food_packaging_allocations where order_token=tok) then raise exception 'Zero quantity not returned';end if;
end $$;
select 'PASS: repeated reads, quantity edits, cancellation, recompletion and zero quantity' result;
rollback;
begin;
select cct_internal.packaging_reconcile(o.order_token) from public.order_commits o where status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.packaging_product(v) is not null) order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token;
update public.cct_ingredient_lots set remaining=0 where ingredient_id=(select id from cct_ingredient_catalog where sku='LY-SUA');
insert into public.order_commits
select (jsonb_populate_record(null::public.order_commits,to_jsonb(o)||jsonb_build_object(
 'order_token','packaging-restock-rollback-test','order_number','PACKAGING-RESTOCK-TEST','status','completed','contact_email',null,
 'pickup_date','2026-07-01','delivery_date',null,'fulfilment_method','pickup','customer_note',null,'order_text','Packaging rollback test','items','[]'::jsonb,
 'order_items',jsonb_build_array(jsonb_build_object('id',(select id from products where sku='SU-004'),'name','Sứa Lắc Xoài','qty',1,'option_text','Sứa Đạn, Sốt Thái'))
 ))).*
from public.order_commits o where o.order_number='CCT-000317';
do $$ begin
 if not exists(select 1 from cct_internal.food_packaging_state where order_token='packaging-restock-rollback-test' and missing<>'[]'::jsonb) then raise exception 'Shortage not detected';end if;
end $$;
insert into public.cct_ingredient_lots(id,ingredient_id,ingredient_name,received_on,quantity,remaining,unit,total_cost,note) overriding system value
select (select least(-1,coalesce(min(id),0)-1) from cct_ingredient_lots),id,name,'2026-07-01',1,1,'piece',0.05,'Rollback packaging restock test' from cct_ingredient_catalog where sku='LY-SUA';
set constraints all immediate;
do $$ begin
 if not exists(select 1 from cct_internal.food_packaging_state where order_token='packaging-restock-rollback-test' and missing='[]'::jsonb) then raise exception 'Packaging not automatically allocated after restock';end if;
 if (select sum(quantity) from cct_internal.food_packaging_allocations where order_token='packaging-restock-rollback-test')<>1 then raise exception 'Expected exactly one cup';end if;
end $$;
select 'PASS: missing shake cup automatically allocated after a new valid lot is received' result;
rollback;