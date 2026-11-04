create function cct_internal.waste_balances_fast(wanted bigint default null)
returns table(lot_id bigint,remaining numeric) language plpgsql stable security definer
set search_path=pg_catalog,public,cct_internal set jit=off as $$
declare ids jsonb; names jsonb; aliases jsonb; rules jsonb; pools jsonb; balances jsonb;
o record;b jsonb;pid bigint;raw_id text;n text;need numeric;avail numeric;take numeric;bid text;pool jsonb;
begin
 select coalesce(jsonb_object_agg(id::text,id),'{}') into ids from public.products;
 select coalesce(jsonb_object_agg(k,id),'{}') into names from (select cct_internal.chicken_normalize(name) k,min(id) id from products group by 1 having count(*)=1) s;
 select coalesce(jsonb_object_agg(k,id),'{}') into aliases from (select cct_internal.chicken_normalize(alias_name) k,min(product_id) id from cct_product_aliases group by 1 having count(distinct product_id)=1) s;
 select coalesce(jsonb_object_agg(order_token||':'||rule_key,true),'{}') into rules from cct_internal.confirmed_line_rules;
 select coalesce(jsonb_object_agg(product_id::text,lots),'{}') into pools from(
 select product_id,jsonb_agg(jsonb_build_object('id',id,'date',received_on) order by received_on,id) lots from cct_cost_batches where wanted is null or product_id=wanted group by product_id) p;
 select coalesce(jsonb_object_agg(cb.id::text,cb.quantity-coalesce(w.qty,0)),'{}') into balances
 from cct_cost_batches cb left join(select a.lot_id,sum(a.quantity) qty from cct_internal.waste_allocations a join cct_internal.waste_events e on e.id=a.event_id where e.kind='retail' and e.voided_at is null group by a.lot_id) w on w.lot_id=cb.id
 where wanted is null or cb.product_id=wanted;
 if pools='{}' then return;end if;
 for o in select oc.order_token,v.value item,coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date) sale_date
 from order_commits oc cross join lateral jsonb_array_elements(coalesce(oc.order_items,'[]')) with ordinality v(value,ix)
 where oc.status='completed'
 order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token,v.ix
 loop
 if rules ? (o.order_token||':'||coalesce(o.item->>'confirmed_component_rule','')) then continue;end if;
 need:=coalesce((o.item->>'qty')::numeric,0);if need<=0 or o.sale_date is null then continue;end if;
 raw_id:=coalesce(o.item->>'id',o.item->>'product_id','');pid:=null;
 if ids ? raw_id then pid:=(ids->>raw_id)::bigint;
 else
 n:=cct_internal.chicken_normalize(o.item->>'name');
 if n ~ '^(banh trang )?bo toi( chua cay)?( duy best)?$' then pid:=5;
 elsif n='banh trang xi ke' then pid:=3;
 elsif n ~ '^(set( 3)? )?banh trang (sate( tom( hanh)?)?|tom hanh)$' then pid:=4;
 elsif n ~ '^com chay( cha bong)?( 500g)?$' then pid:=10;
 elsif n ~ '^ghe (sua|non) rim( gion)?$' then pid:=11;
 else pid:=coalesce(aliases->>n,names->>n)::bigint;end if;
 end if;
 if pid is null or (wanted is not null and pid<>wanted) then continue;end if;
 pool:=pools->pid::text;if pool is null then continue;end if;
 for b in select value from jsonb_array_elements(pool) loop
 if (b->>'date')::date>o.sale_date then continue;end if;
 bid:=b->>'id';avail:=greatest(0,(balances->>bid)::numeric);take:=least(need,avail);
 balances:=jsonb_set(balances,array[bid],to_jsonb(avail-take));need:=need-take;exit when need<=0;
 end loop;
 end loop;
 return query select cb.id,greatest(0,(balances->>cb.id::text)::numeric) from cct_cost_batches cb where wanted is null or cb.product_id=wanted order by cb.received_on,cb.id;
end $$;
revoke all on function cct_internal.waste_balances_fast(bigint) from public,anon,authenticated;
create or replace function cct_internal.waste_retail_balances(pid bigint) returns table(lot_id bigint,remaining numeric)
language sql stable security definer set search_path=pg_catalog,cct_internal set jit=off as $$select * from cct_internal.waste_balances_fast(pid)$$;
create or replace function cct_internal.waste_all_retail_balances() returns table(lot_id bigint,remaining numeric)
language sql stable security definer set search_path=pg_catalog,cct_internal set jit=off as $$select * from cct_internal.waste_balances_fast(null)$$;
