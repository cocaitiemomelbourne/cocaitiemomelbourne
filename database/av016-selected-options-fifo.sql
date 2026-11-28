
create or replace function cct_internal.is_crispy_rice(item jsonb) returns boolean
language sql stable set search_path=pg_catalog,public,cct_internal as $$
 select coalesce(item->>'sale_mode','') <> 'measured' and exists (
   select 1 from public.products p where p.sku='AV-016'
     and p.id::text=coalesce(item->>'id',item->>'product_id')
 )
$$;
revoke all on function cct_internal.is_crispy_rice(jsonb) from public,anon,authenticated;

create or replace function cct_internal.crispy_rice_cost_item(item jsonb) returns jsonb
language plpgsql stable set search_path=pg_catalog,public,cct_internal as $$
declare
 choices text[];
 selected_skus text[];
 missing jsonb:='[]';
 components jsonb;
 expected integer;
begin
 if not cct_internal.is_crispy_rice(item) then return item;end if;
 select array_agg(distinct cct_internal.chicken_normalize(regexp_replace(part,'^.*:\s*','')))
 into choices
 from regexp_split_to_table(
   regexp_replace(coalesce(nullif(item->>'option_text',''),(
     select string_agg(x->>'choice',' • ') from jsonb_array_elements(
       case when jsonb_typeof(item->'options')='array' then item->'options' else '[]'::jsonb end
     ) x
   ),''),'\([^)]*\$[^)]*\)','','g'),
   '[•+|;]+'
 ) part;
 select coalesce(array_agg(sku),array[]::text[]) into selected_skus
 from (values
   ('NL-COMCHAY-01',array['com chay','com chay mam hanh','crispy rice','crispy rice with scallion fish sauce']),
   ('NL-COMCHAY-02',array['com chay gao lut','brown rice crisps','brown crispy rice']),
   ('NL-COMCHAY-07',array['cha bong heo','pork floss']),
   ('NL-COMCHAY-08',array['kho ga la chanh','cha bong ga','chicken floss','lime leaf chicken jerky']),
   ('SOT-MAM-NHI',array['sot mam nhi','sot mam nhi nhi','premium fish sauce']),
   ('SOT-THAI',array['sot thai do','sot thai','red thai sauce'])
 ) labels(sku,names)
 where labels.names && choices;
 if not selected_skus && array['NL-COMCHAY-01','NL-COMCHAY-02'] then missing:=missing||jsonb_build_array('Thiếu lựa chọn loại cơm cháy');end if;
 if not selected_skus && array['NL-COMCHAY-07','NL-COMCHAY-08'] then missing:=missing||jsonb_build_array('Thiếu lựa chọn chà bông hoặc khô gà');end if;
 if not selected_skus && array['SOT-MAM-NHI','SOT-THAI'] then missing:=missing||jsonb_build_array('Thiếu lựa chọn sốt');end if;
 selected_skus:=selected_skus||array['NL-COMCHAY-03','NL-COMCHAY-04','NL-COMCHAY-06'];
 expected:=cardinality(selected_skus);
 select coalesce(jsonb_agg(jsonb_build_object(
   'kind',case when i.component_group='sauce' then 'production' else 'ingredient' end,
   'source_id',case when i.component_group='sauce' then pr.id else c.id end,
   'name',c.name,'unit',i.unit,'quantity',i.quantity
 ) order by i.id),'[]'::jsonb) into components
 from public.cct_standard_recipe_items i
 join public.products p on p.id=i.product_id and p.sku='AV-016'
 join public.cct_ingredient_catalog c on c.id=i.ingredient_id and c.sku=any(selected_skus)
 left join public.cct_production_recipes pr on i.component_group='sauce' and pr.sku=c.sku and pr.product_type='sauce'
 where i.component_group<>'sauce' or pr.id is not null;
 if jsonb_array_length(components)<>expected then missing:=missing||jsonb_build_array('Công thức cơm cháy thiếu SKU hoặc định lượng');end if;
 return item||jsonb_build_object('sale_mode','crispy_rice_cost','cost_components',
 case when missing='[]'::jsonb then components else '[]'::jsonb end,'cost_missing',missing);
end $$;
revoke all on function cct_internal.crispy_rice_cost_item(jsonb) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION cct_internal.measured_reconcile(token text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare o public.order_commits%rowtype;s record;a record;it record;comp record;lot_row record;v jsonb;d date;sig text;q numeric;need numeric;actual numeric;take_q numeric;
begin
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 select * into o from public.order_commits where order_token=token;if not found then return;end if;
 d:=coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date);
 -- Release only changed, removed, cancelled, or re-dated measured rows.
 for s in select * from cct_internal.measured_line_state where order_token=token order by item_index loop
  v:=cct_internal.crispy_rice_cost_item(o.order_items->s.item_index);
  sig:=case when o.status='completed' and v->>'sale_mode' in ('measured','crispy_rice_cost') and d is not null then md5(jsonb_build_array(v->'cost_components',v->'qty',d)::text) else null end;
  if sig is distinct from s.signature then
   for a in select * from cct_internal.measured_line_allocations where order_token=token and item_index=s.item_index order by kind,lot_id loop
    delete from cct_internal.measured_line_allocations where order_token=token and item_index=s.item_index and component_index=a.component_index and kind=a.kind and lot_id=a.lot_id;
    if a.kind='ingredient' then update public.cct_ingredient_lots set remaining=remaining+a.quantity where id=a.lot_id;
    else update public.cct_production_batches set used_quantity=used_quantity-a.quantity,status=case when status='closed' then 'open' else status end where id=a.lot_id;end if;
   end loop;
   delete from cct_internal.measured_line_allocations where order_token=token and item_index=s.item_index;
   delete from cct_internal.measured_line_state where order_token=token and item_index=s.item_index;
  end if;
 end loop;
 if o.status<>'completed' or d is null then return;end if;
 for it in select cct_internal.crispy_rice_cost_item(value) item,(ordinality-1)::integer ix from jsonb_array_elements(o.order_items) with ordinality where value->>'sale_mode'='measured' or cct_internal.is_crispy_rice(value) loop
  v:=case when it.item->>'sale_mode'='measured' then cct_internal.measured_item(it.item) else it.item end;
  q:=(v->>'qty')::numeric;
  if coalesce(q,0)<=0 then continue;end if;
  sig:=md5(jsonb_build_array(it.item->'cost_components',it.item->'qty',d)::text);
  insert into cct_internal.measured_line_state values(token,it.ix,sig,v->'cost_components',q,d) on conflict do nothing;
  for comp in select value c,(ordinality-1)::integer ix from jsonb_array_elements(v->'cost_components') with ordinality loop
   select coalesce(sum(x.quantity),0) into actual from cct_internal.measured_line_allocations x where x.order_token=token and x.item_index=it.ix and x.component_index=comp.ix;
   need:=(comp.c->>'quantity')::numeric*q-actual;
   if need<=0 then continue;end if;
   if comp.c->>'kind'='ingredient' then
    for lot_row in select * from public.cct_ingredient_lots where ingredient_id=(comp.c->>'source_id')::bigint and unit=comp.c->>'unit' and received_on<=d and remaining>0 and quantity>0 order by received_on,id for update loop
     exit when need<=0;take_q:=least(need,lot_row.remaining);
     insert into cct_internal.measured_line_allocations values(token,it.ix,comp.ix,'ingredient',lot_row.id,take_q) on conflict(order_token,item_index,component_index,kind,lot_id) do update set quantity=measured_line_allocations.quantity+excluded.quantity;
     update public.cct_ingredient_lots set remaining=remaining-take_q where id=lot_row.id;need:=need-take_q;
    end loop;
   else
    for lot_row in select * from public.cct_production_batches where recipe_id=(comp.c->>'source_id')::bigint and unit=comp.c->>'unit' and produced_on<=d and status='open' and quantity>used_quantity order by produced_on,id for update loop
     exit when need<=0;take_q:=least(need,lot_row.quantity-lot_row.used_quantity);
     insert into cct_internal.measured_line_allocations values(token,it.ix,comp.ix,'production',lot_row.id,take_q) on conflict(order_token,item_index,component_index,kind,lot_id) do update set quantity=measured_line_allocations.quantity+excluded.quantity;
     update public.cct_production_batches set used_quantity=used_quantity+take_q,status=case when used_quantity+take_q>=quantity then 'closed' else status end where id=lot_row.id;need:=need-take_q;
    end loop;
   end if;
  end loop;
 end loop;
end $function$
;
CREATE OR REPLACE FUNCTION public.cct_measured_cost_report_v1(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare outv jsonb:='[]';o record;it record;comp record;parts jsonb;miss jsonb;costq numeric;actual numeric;need numeric;amount numeric;d date;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 for o in select oc.* from public.order_commits oc where oc.status='completed' and exists(select 1 from jsonb_array_elements(oc.order_items)x where x->>'sale_mode'='measured' or cct_internal.is_crispy_rice(x)) order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token loop
  perform cct_internal.measured_reconcile(o.order_token);
  d:=coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date);
  for it in select cct_internal.crispy_rice_cost_item(value) item,(ordinality-1)::integer ix from jsonb_array_elements(o.order_items) with ordinality where value->>'sale_mode'='measured' or cct_internal.is_crispy_rice(value) loop
   if coalesce((it.item->>'qty')::numeric,0)<=0 then continue;end if;
   costq:=0;miss:=coalesce(it.item->'cost_missing','[]');parts:='[]';
   for comp in select value c,(ordinality-1)::integer ix from jsonb_array_elements(it.item->'cost_components') with ordinality loop
    select coalesce(sum(x.quantity),0),coalesce(sum(round(x.quantity*case when x.kind='ingredient' then l.total_cost/nullif(l.quantity,0) else b.total_cost/nullif(b.quantity,0) end,4)),0) into actual,amount from cct_internal.measured_line_allocations x left join public.cct_ingredient_lots l on x.kind='ingredient' and l.id=x.lot_id left join public.cct_production_batches b on x.kind='production' and b.id=x.lot_id where x.order_token=o.order_token and x.item_index=it.ix and x.component_index=comp.ix;
    need:=(comp.c->>'quantity')::numeric*(it.item->>'qty')::numeric;costq:=costq+amount;
    parts:=parts||jsonb_build_array(jsonb_build_object('name',comp.c->>'name','quantity',actual,'required',need,'unit',comp.c->>'unit','cost',amount));
    if actual<need then miss:=miss||jsonb_build_array((comp.c->>'name')||': đã phân bổ '||actual||'/'||need||' '||(comp.c->>'unit')||' từ lô không muộn hơn ngày bán');end if;
   end loop;
   if d is null then miss:=miss||jsonb_build_array('Chưa có ngày nhận hàng để phân bổ FIFO');end if;
   outv:=outv||jsonb_build_array(jsonb_build_object('order_token',o.order_token,'item_index',it.ix,'display_name',case when it.item->>'sale_mode'='crispy_rice_cost' then 'Cơm Cháy Full Topping' else (it.item->>'name')||' · Bán lẻ' end,'display_sku',case when it.item->>'sale_mode'='crispy_rice_cost' then 'AV-016' else 'LE-'||(it.item->>'measured_sku') end,'cost',costq,'missing',miss,'parts',parts));
  end loop;
 end loop;
 return outv;
end $function$
;
