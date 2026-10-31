
create table cct_internal.single_line_state (like cct_internal.chicken_line_state including defaults including constraints including indexes);
create table cct_internal.single_sauce_lots (like cct_internal.chicken_sauce_lots including defaults including constraints including indexes);
alter table cct_internal.single_sauce_lots add column sauce_sku text not null;
create table cct_internal.single_ingredient_allocations (like public.cct_chicken_mix_fifo_allocations including defaults including constraints including indexes);
create table cct_internal.single_packaging_allocations (like public.cct_chicken_mix_packaging_allocations including defaults including constraints including indexes);
create table cct_internal.single_reversal_audit (like cct_internal.chicken_reversal_audit including defaults including constraints including identity including indexes);
alter table cct_internal.single_line_state enable row level security;
alter table cct_internal.single_sauce_lots enable row level security;
alter table cct_internal.single_ingredient_allocations enable row level security;
alter table cct_internal.single_packaging_allocations enable row level security;
alter table cct_internal.single_reversal_audit enable row level security;
revoke all on all tables in schema cct_internal from public,anon,authenticated;

;
create function cct_internal.single_normalize(v text) returns text language sql immutable set search_path=pg_catalog,cct_internal as $$select cct_internal.chicken_normalize(v)$$;
CREATE OR REPLACE FUNCTION cct_internal.is_single(v jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
 select coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-001')
 or cct_internal.single_normalize(v->>'name') like 'ly sua single%'
$function$

;

create function cct_internal.single_base(p_token text,p_ix int) returns jsonb
language plpgsql set search_path=pg_catalog,public,cct_internal as $$
declare v jsonb;q numeric;b jsonb;legacy_sauce text;
begin
 select order_items->p_ix into v from public.order_commits where order_token=p_token;
 q:=coalesce(nullif(v->>'qty','')::numeric,1);
 select case when cct_internal.chicken_normalize(a.sauce) like '%mam nhi%' then 'SOT-MAM-NHI'
 when cct_internal.chicken_normalize(a.sauce) like '%thai%' then 'SOT-THAI' end into legacy_sauce
 from public.cct_single_fifo_allocations a where a.order_token=p_token and a.item_index=p_ix limit 1;
 with recipe as (
 select i.ingredient_id,c.name,c.sku,i.unit,i.component_group,sum(i.quantity) per_unit
 from public.cct_standard_recipe_items i join public.products p on p.id=i.product_id
 join public.cct_ingredient_catalog c on c.id=i.ingredient_id
 where p.sku='SU-001' group by i.ingredient_id,c.name,c.sku,i.unit,i.component_group
 ), legacy as (
 select a.ingredient_id,sum(a.grams)/q per_unit from public.cct_single_fifo_allocations a
 where a.order_token=p_token and a.item_index=p_ix group by a.ingredient_id
 ), candidates as (
 select r.ingredient_id,r.name,r.sku,r.unit,r.component_group,
 case when r.component_group='jellyfish' then coalesce(l.per_unit,r.per_unit) else r.per_unit end per_unit,
 (case when r.component_group='jellyfish' then l.ingredient_id is not null when r.component_group='sauce' then r.sku=legacy_sauce else false end) legacy_selected
 from recipe r left join legacy l on l.ingredient_id=r.ingredient_id
 union all
 select l.ingredient_id,c.name,c.sku,'g','jellyfish',l.per_unit,true from legacy l join public.cct_ingredient_catalog c on c.id=l.ingredient_id
 where not exists(select 1 from recipe r where r.ingredient_id=l.ingredient_id)
 )
 select coalesce(jsonb_agg(jsonb_build_object('ingredient_id',ingredient_id,'name',name,'sku',sku,'unit',unit,'group',component_group,'per_unit',per_unit,'legacy_selected',legacy_selected) order by ingredient_id),'[]') into b from candidates;
 return b;
end $$;

;

create function cct_internal.single_requirements(p_item jsonb,p_note text,p_base jsonb) returns jsonb
language plpgsql stable set search_path=pg_catalog,public,cct_internal as $$
declare txt text;rest text;v jsonb;picked jsonb:='[]';sauces jsonb:='[]';result jsonb:='[]';errs jsonb:='[]';key text;q numeric;has_thai bool;has_mam bool;
begin
 q:=coalesce(nullif(p_item->>'qty','')::numeric,1);
 txt:=' '||cct_internal.chicken_normalize(coalesce(p_item->>'option_text','')||' '||coalesce(p_item->>'note','')||' '||coalesce(p_item->>'options','')||' '||coalesce(p_note,''))||' ';
 rest:=txt;
 for v in select value from jsonb_array_elements(p_base) where value->>'group'='jellyfish' order by length(value->>'name') desc loop
  key:=regexp_replace(cct_internal.chicken_normalize(v->>'name'),'^sua ','');
  if position(' '||key||' ' in rest)>0 then
   picked:=picked||jsonb_build_array(v);rest:=replace(rest,' '||key||' ',' ');
  end if;
 end loop;
 if picked='[]'::jsonb then
  select coalesce(jsonb_agg(value),'[]') into picked from jsonb_array_elements(p_base) where value->>'group'='jellyfish' and value->>'legacy_selected'='true';
 end if;
 if jsonb_array_length(picked)<>1 then errs:=errs||jsonb_build_array('Chưa xác định đúng một loại sứa');picked:='[]';end if;
 has_thai:=txt ~ '(^| )thai( |$)';has_mam:=txt ~ '(^| )mam nhi( |$)';
 if has_thai::int+has_mam::int=1 then
  select coalesce(jsonb_agg(value),'[]') into sauces from jsonb_array_elements(p_base)
   where value->>'group'='sauce' and value->>'sku'=case when has_mam then 'SOT-MAM-NHI' else 'SOT-THAI' end;
 elsif not has_thai and not has_mam then
  select coalesce(jsonb_agg(value),'[]') into sauces from jsonb_array_elements(p_base) where value->>'group'='sauce' and value->>'legacy_selected'='true';
 end if;
 if jsonb_array_length(sauces)<>1 then errs:=errs||jsonb_build_array('Chưa xác định đúng một loại sốt');sauces:='[]';end if;
 for v in select value from jsonb_array_elements(p_base) where value->>'group' not in ('jellyfish','sauce')
 union all select value from jsonb_array_elements(picked||sauces)
 loop
  result:=result||jsonb_build_array(v||jsonb_build_object('quantity',(v->>'per_unit')::numeric*q));
 end loop;
 if txt ~ '(them|extra|add on|thay|doi)' or txt ~ '(khong|without) (lay )?(sua|sot|xoai|rau)( |$)' then
  errs:=errs||jsonb_build_array('Ghi chú thêm/bớt/đổi nguyên liệu cần xác định định lượng riêng');
 end if;
 return jsonb_build_object('requirements',result,'missing',errs);
end $$;

;
CREATE OR REPLACE FUNCTION cct_internal.single_release(p_token text, p_ix integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare r record; audit jsonb;
begin
 select jsonb_build_object(
 'ingredients',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from cct_internal.single_ingredient_allocations a where order_token=p_token and item_index=p_ix),
 'jellyfish',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from public.cct_single_fifo_allocations a where order_token=p_token and item_index=p_ix),
 'packaging',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from cct_internal.single_packaging_allocations a where order_token=p_token and item_index=p_ix),
 'sauce',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from cct_internal.single_sauce_lots a where order_token=p_token and item_index=p_ix)
 ) into audit;
 insert into cct_internal.single_reversal_audit(order_token,item_index,allocations) values(p_token,p_ix,audit);
 for r in
  select lot_id,sum(qty) qty from (
   select lot_id,grams qty from cct_internal.single_ingredient_allocations where order_token=p_token and item_index=p_ix
   union all select lot_id,grams from public.cct_single_fifo_allocations where order_token=p_token and item_index=p_ix
   union all select lot_id,quantity from cct_internal.single_packaging_allocations where order_token=p_token and item_index=p_ix
  ) a group by lot_id order by lot_id
 loop
  update public.cct_ingredient_lots set remaining=remaining+r.qty where id=r.lot_id;
 end loop;
 delete from cct_internal.single_ingredient_allocations where order_token=p_token and item_index=p_ix;
 delete from public.cct_single_fifo_allocations where order_token=p_token and item_index=p_ix;
 delete from cct_internal.single_packaging_allocations where order_token=p_token and item_index=p_ix;
 for r in
  select batch_id,sum(qty) qty from (
   select batch_id,quantity_ml qty from public.cct_order_sauce_cogs where order_token=p_token and item_index=p_ix
   union all select batch_id,quantity_ml from cct_internal.single_sauce_lots where order_token=p_token and item_index=p_ix
  ) a group by batch_id order by batch_id
 loop
  update public.cct_production_batches set used_quantity=used_quantity-r.qty,
   status=case when status='closed' and used_quantity-r.qty<quantity then 'open' else status end where id=r.batch_id;
 end loop;
 insert into public.cct_order_sauce_reversal_audit_v1(order_token,item_index,sauce_sku,batch_id,quantity_ml,cost,reason)
 select order_token,item_index,sauce_sku,batch_id,quantity_ml,cost,'Single FIFO line changed' from public.cct_order_sauce_cogs where order_token=p_token and item_index=p_ix;
 delete from public.cct_order_sauce_cogs where order_token=p_token and item_index=p_ix;
 delete from cct_internal.single_sauce_lots where order_token=p_token and item_index=p_ix;
 update public.cct_order_sauce_resolution_v1 set status='stale',note='Single FIFO line changed',updated_at=now() where order_token=p_token and item_index=p_ix;
end $function$

;
CREATE OR REPLACE FUNCTION cct_internal.single_reconcile(p_token text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare ord public.order_commits%rowtype; st cct_internal.single_line_state%rowtype;
 it jsonb; ix int; sold date; q numeric; base jsonb; plan jsonb; req jsonb; errs jsonb; r jsonb; lot record;
 actual numeric; need numeric; avail numeric; take_qty numeric; ingredient bigint; table_name text; amount numeric; desired jsonb; sauce_code text;
begin
 perform pg_advisory_xact_lock(321031,2);
 perform pg_advisory_xact_lock(1628018,2);
 select * into ord from public.order_commits where order_token=p_token;
 if not found then return;end if;
 sold:=coalesce(case when lower(ord.fulfilment_method) like '%pickup%' then ord.pickup_date else ord.delivery_date end,ord.delivery_date,ord.pickup_date);
 -- Release every removed or inactive line, but retain its frozen recipe for later recompletion.
 for st in select * from cct_internal.single_line_state where order_token=p_token order by item_index loop
  it:=ord.order_items->st.item_index;
  if ord.status<>'completed' or it is null or not cct_internal.is_single(it) or coalesce(nullif(it->>'qty','')::numeric,1)<=0 then
   if exists(select 1 from cct_internal.single_ingredient_allocations where order_token=p_token and item_index=st.item_index)
    or exists(select 1 from public.cct_single_fifo_allocations where order_token=p_token and item_index=st.item_index)
    or exists(select 1 from cct_internal.single_packaging_allocations where order_token=p_token and item_index=st.item_index)
    or exists(select 1 from cct_internal.single_sauce_lots where order_token=p_token and item_index=st.item_index)
    or exists(select 1 from public.cct_order_sauce_cogs where order_token=p_token and item_index=st.item_index) then
    perform cct_internal.single_release(p_token,st.item_index);
   end if;
   update cct_internal.single_line_state set requirements='[]',missing='[]',qty=coalesce(nullif(it->>'qty','')::numeric,0),updated_at=now() where order_token=p_token and item_index=st.item_index;
   if it is null or not cct_internal.is_single(it) then
    delete from cct_internal.single_line_state where order_token=p_token and item_index=st.item_index;
   end if;
  end if;
 end loop;
 if ord.status<>'completed' then return;end if;
 for it,ix in select value,(ordinality-1)::int from jsonb_array_elements(ord.order_items) with ordinality loop
  if not cct_internal.is_single(it) then continue;end if;
  q:=coalesce(nullif(it->>'qty','')::numeric,1);
  if q<=0 then continue;end if;
  select * into st from cct_internal.single_line_state where order_token=p_token and item_index=ix;
  if not found then
   base:=cct_internal.single_base(p_token,ix);
   insert into cct_internal.single_line_state(order_token,item_index,base_recipe,qty,sale_date)
   values(p_token,ix,base,q,sold);
   select * into st from cct_internal.single_line_state where order_token=p_token and item_index=ix;
  end if;
  plan:=cct_internal.single_requirements(it,ord.customer_note,st.base_recipe);
  req:=plan->'requirements';errs:=plan->'missing';
  -- The original rows are retained on first adoption. Subsequent semantic changes are reversed with audit.
  if st.requirements<>'[]'::jsonb and (st.requirements is distinct from req or st.sale_date is distinct from sold) then
   perform cct_internal.single_release(p_token,ix);
  end if;
  if sold is null then
   errs:=errs||jsonb_build_array('Thiếu ngày nhận hàng; chưa phân bổ FIFO');
  else
   -- Stable row locks protect split-lot allocations against concurrent orders.
   perform l.id from public.cct_ingredient_lots l where l.ingredient_id in (select (v->>'ingredient_id')::bigint from jsonb_array_elements(req) v where v->>'group'<>'sauce') order by l.id for update;
   for r in select value from jsonb_array_elements(req) loop
    ingredient:=(r->>'ingredient_id')::bigint;
    if r->>'group'='sauce' then
     sauce_code:=r->>'sku';
     select coalesce(sum(x.qty),0) into actual from (
      select quantity_ml qty from public.cct_order_sauce_cogs where order_token=p_token and item_index=ix and sauce_sku=sauce_code
      union all select quantity_ml from cct_internal.single_sauce_lots where order_token=p_token and item_index=ix and sauce_sku=sauce_code
     ) x;
     need:=(r->>'quantity')::numeric-actual;
     if need>0 then
      perform b.id from public.cct_production_batches b join public.cct_production_recipes pr on pr.id=b.recipe_id where pr.sku=sauce_code order by b.id for update of b;
      select coalesce(sum(b.quantity-b.used_quantity),0) into avail from public.cct_production_batches b join public.cct_production_recipes pr on pr.id=b.recipe_id where pr.sku=sauce_code and b.produced_on<=sold and b.status in ('open','closed') and b.quantity>0 and b.quantity>b.used_quantity;
      if avail>=need then
       for lot in select b.* from public.cct_production_batches b join public.cct_production_recipes pr on pr.id=b.recipe_id where pr.sku=sauce_code and b.produced_on<=sold and b.status in ('open','closed') and b.quantity>0 and b.quantity>b.used_quantity order by b.produced_on,b.id loop
        exit when need<=0;
        take_qty:=least(need,lot.quantity-lot.used_quantity);
        insert into cct_internal.single_sauce_lots(order_token,item_index,batch_id,sauce_sku,quantity_ml,cost) values(p_token,ix,lot.id,sauce_code,take_qty,round(take_qty*lot.total_cost/lot.quantity,4))
        on conflict(order_token,item_index,batch_id) do update set quantity_ml=single_sauce_lots.quantity_ml+excluded.quantity_ml,cost=single_sauce_lots.cost+excluded.cost;
        update public.cct_production_batches set used_quantity=used_quantity+take_qty,status=case when used_quantity+take_qty>=quantity then 'closed' else status end where id=lot.id;
        need:=need-take_qty;
       end loop;
      end if;
     end if;
    else
     table_name:=case r->>'group' when 'jellyfish' then 'public.cct_single_fifo_allocations' when 'packaging' then 'cct_internal.single_packaging_allocations' else 'cct_internal.single_ingredient_allocations' end;
     if r->>'group'='packaging' then
      select coalesce(sum(a.quantity),0) into actual from cct_internal.single_packaging_allocations a join public.cct_ingredient_lots l on l.id=a.lot_id where a.order_token=p_token and a.item_index=ix and l.ingredient_id=ingredient;
     else
      execute format('select coalesce(sum(grams),0) from %s where order_token=$1 and item_index=$2 and ingredient_id=$3',table_name) into actual using p_token,ix,ingredient;
     end if;
     need:=(r->>'quantity')::numeric-actual;
     if need>0 then
      select coalesce(sum(l.remaining),0) into avail from public.cct_ingredient_lots l where l.ingredient_id=ingredient and l.received_on<=sold and l.unit=r->>'unit' and l.quantity>0 and l.remaining>0;
      if avail>=need then
       for lot in select * from public.cct_ingredient_lots l where l.ingredient_id=ingredient and l.received_on<=sold and l.unit=r->>'unit' and l.quantity>0 and l.remaining>0 order by l.received_on,l.id loop
        exit when need<=0;
        take_qty:=least(need,lot.remaining);
        amount:=round(take_qty*lot.total_cost/lot.quantity,4);
        if r->>'group'='packaging' then
         insert into cct_internal.single_packaging_allocations(order_token,item_index,order_number,sale_date,lot_id,quantity,extended_cost)
         values(p_token,ix,ord.order_number,sold,lot.id,take_qty,amount)
         on conflict(order_token,item_index,lot_id) do update set quantity=single_packaging_allocations.quantity+excluded.quantity,extended_cost=single_packaging_allocations.extended_cost+excluded.extended_cost;
        else
         if r->>'group'='jellyfish' then
         insert into public.cct_single_fifo_allocations as a(order_token,item_index,order_number,sale_date,lot_id,ingredient_id,grams,unit_cost,extended_cost,species,sauce)
         values(p_token,ix,ord.order_number,sold,lot.id,ingredient,take_qty,lot.total_cost/lot.quantity,amount,r->>'name',
          (select v->>'name' from jsonb_array_elements(req) v where v->>'group'='sauce' limit 1))
         on conflict(order_token,item_index,lot_id) do update set grams=a.grams+excluded.grams,extended_cost=a.extended_cost+excluded.extended_cost;
        else
         execute format('insert into %s as a(order_token,item_index,order_number,sale_date,lot_id,ingredient_id,grams,unit_cost,extended_cost) values($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict(order_token,item_index,lot_id) do update set grams=a.grams+excluded.grams,extended_cost=a.extended_cost+excluded.extended_cost',table_name)
         using p_token,ix,ord.order_number,sold,lot.id,ingredient,take_qty,lot.total_cost/lot.quantity,amount;
        end if;
        end if;
        update public.cct_ingredient_lots set remaining=remaining-take_qty where id=lot.id;
        need:=need-take_qty;
       end loop;
      end if;
     end if;
    end if;
    if need<>0 then
     errs:=errs||jsonb_build_array(format('%s: đã phân bổ %s/%s %s',r->>'name',(r->>'quantity')::numeric-need,r->>'quantity',r->>'unit'));
    end if;
   end loop;
  end if;
  update cct_internal.single_line_state set requirements=req,missing=errs,qty=q,sale_date=sold,updated_at=case when requirements is distinct from req or missing is distinct from errs or sale_date is distinct from sold or qty is distinct from q then now() else updated_at end where order_token=p_token and item_index=ix;
 end loop;
end $function$

;
CREATE OR REPLACE FUNCTION cct_internal.single_order_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
begin
 if exists(select 1 from jsonb_array_elements(new.order_items) v where cct_internal.is_single(v))
 or exists(select 1 from cct_internal.single_line_state where order_token=new.order_token) then
  perform cct_internal.single_reconcile(new.order_token);
 end if;
 return null;
end $function$

;
CREATE OR REPLACE FUNCTION cct_internal.single_write_lock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare needed boolean;
begin
 needed:=exists(select 1 from jsonb_array_elements(coalesce(new.order_items,'[]')) v where cct_internal.is_single(v));
 if tg_op='UPDATE' then
  needed:=needed or exists(select 1 from jsonb_array_elements(coalesce(old.order_items,'[]')) v where cct_internal.is_single(v));
 end if;
 if needed then
  -- Acquire before the existing sauce reversal trigger to keep lock order consistent.
  perform pg_advisory_xact_lock(321031,2);
  perform pg_advisory_xact_lock(1628018,2);
 end if;
 return new;
end $function$

;

create or replace function public.cct_single_fifo_cost_report_v2(p_passcode text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare result jsonb;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 perform cct_internal.single_reconcile(o.order_token) from public.order_commits o
 where o.status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.is_single(v))
 order by coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date),o.created_at,o.order_token;
 select coalesce(jsonb_agg(jsonb_build_object(
 'order_token',s.order_token,'order_number',o.order_number,'item_index',s.item_index,'qty',s.qty,'date',s.sale_date,
 'cost',round(c.amount,4),'missing',s.missing,'parts',c.parts,'method','persisted_component_fifo') order by s.sale_date,o.order_number,s.item_index),'[]') into result
 from cct_internal.single_line_state s join public.order_commits o using(order_token)
 cross join lateral (
 select coalesce(sum(x.cost),0) amount,coalesce(jsonb_agg(jsonb_build_object('ingredient',x.name,'cost',x.cost,'quantity',x.quantity,'lot_id',x.source_id)),'[]') parts from (
  select a.species name,a.extended_cost cost,a.grams quantity,a.lot_id source_id from public.cct_single_fifo_allocations a where a.order_token=s.order_token and a.item_index=s.item_index
  union all select l.ingredient_name,a.extended_cost,a.quantity,a.lot_id from cct_internal.single_packaging_allocations a join public.cct_ingredient_lots l on l.id=a.lot_id where a.order_token=s.order_token and a.item_index=s.item_index
  union all select l.ingredient_name,a.extended_cost,a.grams,a.lot_id from cct_internal.single_ingredient_allocations a join public.cct_ingredient_lots l on l.id=a.lot_id where a.order_token=s.order_token and a.item_index=s.item_index
  union all select a.sauce_sku,a.cost,a.quantity_ml,a.batch_id from public.cct_order_sauce_cogs a where a.order_token=s.order_token and a.item_index=s.item_index
  union all select a.sauce_sku,a.cost,a.quantity_ml,a.batch_id from cct_internal.single_sauce_lots a where a.order_token=s.order_token and a.item_index=s.item_index
 ) x) c
 where o.status='completed' and s.qty>0 and cct_internal.is_single(o.order_items->s.item_index);
 return result;
end $$;

CREATE OR REPLACE FUNCTION cct_internal.refresh_pending_food_costs()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare o record;
begin
 perform pg_advisory_xact_lock(321031,2);
 perform pg_advisory_xact_lock(1628018,2);
 -- Preserve stored allocations; each reconciler only fills gaps or reverses an edited line.
 for o in select oc.order_token,
  exists(select 1 from jsonb_array_elements(oc.order_items) v where cct_internal.is_single(v)) has_single,
  exists(select 1 from jsonb_array_elements(oc.order_items) v where cct_internal.is_chicken(v)) has_chicken,
  exists(select 1 from jsonb_array_elements(oc.order_items) v where coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-002') or lower(coalesce(v->>'name','')) like '%sứa combo%') has_combo
 from public.order_commits oc
 where oc.status='completed' and exists(
  select 1 from jsonb_array_elements(oc.order_items) v
  where cct_internal.is_single(v) or cct_internal.is_chicken(v) or coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-002')
     or lower(coalesce(v->>'name','')) like '%sứa combo%')
 order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token
 loop
  if o.has_single then perform cct_internal.single_reconcile(o.order_token);end if;
  if o.has_chicken then perform cct_internal.chicken_reconcile(o.order_token);end if;
  if o.has_combo then perform cct_internal.combo_reconcile(o.order_token);end if;
 end loop;
end $function$

;

do $patch$ declare d text;begin
 select pg_get_functiondef('public.cct_order_sauce_reconcile_v1(text,boolean)'::regprocedure) into d;
 d:=replace(d,'where sku=''SU-003'') then continue;end if;','where sku in (''SU-003'',''SU-001'')) then continue;end if;');
 execute d;
 select pg_get_functiondef('public.cct_capture_sauce_cogs_v1()'::regprocedure) into d;
 d:=replace(d,'v_sauces=array[]::text[];',
 'if cct_internal.is_single(v_item) then v_idx:=v_idx+1;continue;end if;'||chr(10)||'v_sauces=array[]::text[];');
 execute d;
end $patch$;
create trigger aaa_cct_single_fifo_lock before insert or update of status,order_items,customer_note,pickup_date,delivery_date,fulfilment_method,order_text on public.order_commits for each row execute function cct_internal.single_write_lock();
create trigger cct_single_fifo_auto after insert or update of status,order_items,customer_note,pickup_date,delivery_date,fulfilment_method,order_text on public.order_commits for each row execute function cct_internal.single_order_trigger();
revoke all on all functions in schema cct_internal from public,anon,authenticated;
