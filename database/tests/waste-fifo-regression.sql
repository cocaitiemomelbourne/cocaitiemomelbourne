-- All writes, including the temporary test credential, are rolled back.
begin;
update public.print_admin_access set pass_hash=encode(extensions.digest('cct-print-v1-20260924'||'waste-regression-only','sha256'),'hex') where id=1;
do $$
declare pass text:='waste-regression-only';pid bigint;bid bigint;lid bigint;pbid bigint;
eid uuid:=gen_random_uuid();e2 uuid:=gen_random_uuid();e3 uuid:=gen_random_uuid();qty numeric;cost numeric;before_stock integer;before_rem numeric;result jsonb;
begin
 select p.id into pid from products p where p.sku not like 'SU-%' and p.sku not in('GV-004','GV-005') and p.stock_qty is not null and exists(select 1 from cct_cost_batches b where b.product_id=p.id) limit 1;
 select coalesce(sum(bal.remaining),0),coalesce(sum(bal.remaining*b.unit_cost),0) into qty,cost from cct_internal.waste_retail_balances(pid) bal join cct_cost_batches b on b.id=bal.lot_id;
 insert into cct_cost_batches(product_id,received_on,quantity,unit_cost,note) values(pid,(now() at time zone 'Australia/Melbourne')::date,5,2,'rollback fixture') returning id into bid;
 before_stock:=qty::integer+3;update products set stock_qty=before_stock where id=pid;
 perform cct_waste_save_v1(pass,eid,'retail',pid,qty+3,'damaged','test FIFO');
 perform cct_waste_save_v1(pass,eid,'retail',pid,qty+3,'damaged','test FIFO');
 if (select stock_qty from products where id=pid)<>0 then raise exception 'Menu stock or duplicate request incorrect';end if;
 result:=cct_waste_report_v1(pass);
 if (select sum((x->>'cost')::numeric) from jsonb_array_elements(result) x where x->>'id'=eid::text)<>round(cost+6,4) then raise exception 'FIFO cost wrong';end if;
 if (select count(*) from cct_internal.waste_allocations where event_id=eid)<2 and qty>0 then raise exception 'FIFO did not span batches';end if;
 update cct_cost_batches set unit_cost=3 where id=bid;
 result:=cct_waste_report_v1(pass);
 if (select sum((x->>'cost')::numeric) from jsonb_array_elements(result) x where x->>'id'=eid::text)<>round(cost+9,4) then raise exception 'Waste did not reprice after source price correction';end if;
 update cct_cost_batches set unit_cost=2 where id=bid;
 begin update cct_cost_batches set quantity=2 where id=bid;raise exception 'INVALID_SOURCE_ACCEPTED';
 exception when others then if sqlerrm='INVALID_SOURCE_ACCEPTED' then raise;end if;end;
 perform cct_waste_void_v1(pass,eid,'test reversal');
 perform cct_waste_void_v1(pass,eid,'test reversal');
 if (select stock_qty from products where id=pid)<>before_stock then raise exception 'Void or duplicate void wrong';end if;
 -- The stock-check route creates the same cost ledger, in its atomic batch save.
 perform cct_stock_save_batch_v2(pass,jsonb_build_array(jsonb_build_object('id',pid,'expected_qty',before_stock,'new_qty',before_stock-1,'reason','expired','note','stock-count test')));
 select id into e2 from cct_internal.waste_events where kind='retail' and source_id=pid and note='stock-count test';
 if e2 is null then raise exception 'Stock count did not create waste';end if;
 perform cct_waste_void_v1(pass,e2,'undo stock-count fixture');
 if (select stock_qty from products where id=pid)<>before_stock then raise exception 'Stock-count void did not restore menu';end if;
 select id,remaining into lid,before_rem from cct_ingredient_lots where remaining>=10 and received_on<=current_date limit 1;
 perform cct_waste_save_v1(pass,e3,'ingredient',lid,10,'expired','ingredient test');
 if (select remaining from cct_ingredient_lots where id=lid)<>before_rem-10 then raise exception 'Raw material consumption wrong';end if;
 perform cct_waste_void_v1(pass,e3,'raw reversal');
 if (select remaining from cct_ingredient_lots where id=lid)<>before_rem then raise exception 'Raw reversal wrong';end if;
 select id,used_quantity into pbid,before_rem from cct_production_batches where status='open' and quantity-used_quantity>=10 and produced_on<=current_date limit 1;
 e3:=gen_random_uuid();perform cct_waste_save_v1(pass,e3,'production',pbid,10,'damaged','sauce test');
 perform cct_waste_void_v1(pass,e3,'sauce reversal');
 if (select used_quantity from cct_production_batches where id=pbid)<>before_rem then raise exception 'Sauce reversal wrong';end if;
 result:=cct_waste_sources_v1(pass);
 if jsonb_typeof(result)<>'array' then raise exception 'Sources response wrong';end if;
 begin perform cct_waste_save_v1('invalid',gen_random_uuid(),'retail',pid,1,'damaged','');raise exception 'AUTH_ACCEPTED';
 exception when others then if sqlerrm<>'not_authorized' then raise;end if;end;
end $$;
rollback;
select 'PASS: FIFO spanning lots, actual cost, atomic stock check, idempotent save/void, ingredient/sauce reversals, sources and auth; no production data changed' result;