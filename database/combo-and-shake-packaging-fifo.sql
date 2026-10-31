
create table cct_internal.food_packaging_state(
 order_token text not null references public.order_commits(order_token),
 item_index int not null,product_id bigint not null,recipe jsonb not null,
 qty numeric not null,sale_date date,missing jsonb not null default '[]',
 primary key(order_token,item_index)
);
create table cct_internal.food_packaging_allocations(
 order_token text not null references public.order_commits(order_token),item_index int not null,
 lot_id bigint not null references public.cct_ingredient_lots(id),ingredient_id bigint not null references public.cct_ingredient_catalog(id),
 quantity numeric not null check(quantity>0),unit_cost numeric not null check(unit_cost>=0),extended_cost numeric not null check(extended_cost>=0),
 sale_date date not null,primary key(order_token,item_index,lot_id)
);
create table cct_internal.food_packaging_reversals(
 id bigint generated always as identity primary key,order_token text not null,item_index int not null,
 allocations jsonb not null,reversed_at timestamptz not null default now()
);
alter table cct_internal.food_packaging_state enable row level security;
alter table cct_internal.food_packaging_allocations enable row level security;
alter table cct_internal.food_packaging_reversals enable row level security;
revoke all on cct_internal.food_packaging_state,cct_internal.food_packaging_allocations,cct_internal.food_packaging_reversals from public,anon,authenticated;
create function cct_internal.packaging_product(v jsonb) returns bigint
language sql stable set search_path=pg_catalog,public,cct_internal as $$
 select p.id from public.products p where p.sku in ('SU-002','SU-004')
 and (p.id::text=coalesce(v->>'id',v->>'product_id','')
 or (p.sku='SU-002' and cct_internal.chicken_normalize(v->>'name') ~ '^(ly )?sua combo')
 or (p.sku='SU-004' and cct_internal.chicken_normalize(v->>'name') ~ '^(ly )?sua lac xoai'))
 order by (p.id::text=coalesce(v->>'id',v->>'product_id','')) desc limit 1
$$;
create function cct_internal.packaging_release(p_token text,p_ix int) returns void
language plpgsql set search_path=pg_catalog,public,cct_internal as $$
declare r record;
begin
 insert into cct_internal.food_packaging_reversals(order_token,item_index,allocations)
 select p_token,p_ix,jsonb_agg(to_jsonb(a)) from cct_internal.food_packaging_allocations a where a.order_token=p_token and a.item_index=p_ix having count(*)>0;
 for r in select lot_id,sum(quantity) quantity from cct_internal.food_packaging_allocations where order_token=p_token and item_index=p_ix group by lot_id order by lot_id loop
  update public.cct_ingredient_lots set remaining=remaining+r.quantity where id=r.lot_id;
 end loop;
 delete from cct_internal.food_packaging_allocations where order_token=p_token and item_index=p_ix;
end $$;
create function cct_internal.packaging_reconcile(p_token text) returns void
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare ord public.order_commits%rowtype;st cct_internal.food_packaging_state%rowtype;
 it jsonb;ix int;pid bigint;q numeric;sold date;rec jsonb;comp jsonb;errs jsonb;lot record;ing bigint;need numeric;available numeric;taken numeric;
begin
 perform pg_advisory_xact_lock(321031,2);
 select * into ord from public.order_commits where order_token=p_token;
 if not found then return;end if;
 sold:=coalesce(case when lower(ord.fulfilment_method) like '%pickup%' then ord.pickup_date else ord.delivery_date end,ord.delivery_date,ord.pickup_date);
 for st in select * from cct_internal.food_packaging_state where order_token=p_token order by item_index loop
  it:=ord.order_items->st.item_index;
  pid:=cct_internal.packaging_product(it);
  q:=coalesce(nullif(it->>'qty','')::numeric,1);
  if ord.status<>'completed' or pid is null or pid<>st.product_id or q<=0 or q<>st.qty or sold is distinct from st.sale_date then
   perform cct_internal.packaging_release(p_token,st.item_index);
   delete from cct_internal.food_packaging_state where order_token=p_token and item_index=st.item_index;
  end if;
 end loop;
 if ord.status<>'completed' then return;end if;
 for it,ix in select value,(ordinality-1)::int from jsonb_array_elements(ord.order_items) with ordinality loop
  pid:=cct_internal.packaging_product(it);
  q:=coalesce(nullif(it->>'qty','')::numeric,1);
  if pid is null or q<=0 then continue;end if;
  select * into st from cct_internal.food_packaging_state where order_token=p_token and item_index=ix;
  if not found then
   select coalesce(jsonb_agg(jsonb_build_object('ingredient_id',r.ingredient_id,'name',r.name,'quantity',r.quantity,'unit',r.unit) order by r.ingredient_id),'[]') into rec
   from (select i.ingredient_id,min(i.ingredient_name) name,sum(i.quantity) quantity,i.unit from public.cct_standard_recipe_items i where i.product_id=pid and i.component_group='packaging' group by i.ingredient_id,i.unit) r;
   insert into cct_internal.food_packaging_state(order_token,item_index,product_id,recipe,qty,sale_date) values(p_token,ix,pid,rec,q,sold);
   select * into st from cct_internal.food_packaging_state where order_token=p_token and item_index=ix;
  end if;
  errs:='[]';
  if st.recipe='[]'::jsonb then errs:=errs||jsonb_build_array('Chưa khai báo định mức bao bì');end if;
  if sold is null then errs:=errs||jsonb_build_array('Thiếu ngày nhận hàng để phân bổ bao bì');
  else
   perform l.id from public.cct_ingredient_lots l where l.ingredient_id in (select (v->>'ingredient_id')::bigint from jsonb_array_elements(st.recipe) v) order by l.id for update;
   for comp in select value from jsonb_array_elements(st.recipe) loop
    ing:=(comp->>'ingredient_id')::bigint;
    need:=(comp->>'quantity')::numeric*q-coalesce((select sum(quantity) from cct_internal.food_packaging_allocations where order_token=p_token and item_index=ix and ingredient_id=ing),0);
    if need>0 then
     select coalesce(sum(remaining),0) into available from public.cct_ingredient_lots where ingredient_id=ing and unit=comp->>'unit' and received_on<=sold and quantity>0 and remaining>0;
     if available>=need then
      for lot in select * from public.cct_ingredient_lots where ingredient_id=ing and unit=comp->>'unit' and received_on<=sold and quantity>0 and remaining>0 order by received_on,id loop
       exit when need<=0;
       taken:=least(need,lot.remaining);
       insert into cct_internal.food_packaging_allocations as a(order_token,item_index,lot_id,ingredient_id,quantity,unit_cost,extended_cost,sale_date)
       values(p_token,ix,lot.id,ing,taken,lot.total_cost/lot.quantity,round(taken*lot.total_cost/lot.quantity,4),sold)
       on conflict(order_token,item_index,lot_id) do update set quantity=a.quantity+excluded.quantity,extended_cost=a.extended_cost+excluded.extended_cost;
       update public.cct_ingredient_lots set remaining=remaining-taken where id=lot.id;
       need:=need-taken;
      end loop;
     end if;
    end if;
    if need<>0 then errs:=errs||jsonb_build_array(format('Bao bì %s: còn thiếu %s %s',comp->>'name',need,comp->>'unit'));end if;
   end loop;
  end if;
  update cct_internal.food_packaging_state set missing=errs where order_token=p_token and item_index=ix;
 end loop;
end $$;
create function cct_internal.packaging_report(p_token text,p_ix int) returns jsonb
language plpgsql stable set search_path=pg_catalog,public,cct_internal as $$
declare st cct_internal.food_packaging_state%rowtype;estimated numeric:=0;actual numeric;comp record;lot record;names jsonb;
begin
 select * into st from cct_internal.food_packaging_state where order_token=p_token and item_index=p_ix;
 if not found then return jsonb_build_object('actual_cost',0,'estimated_cost',0,'missing',jsonb_build_array('Chưa có phân bổ FIFO bao bì'),'names','[]'::jsonb);end if;
 -- Remove exactly the packaging estimate included by the legacy source report.
 for comp in select * from public.cct_standard_recipe_items where product_id=st.product_id and component_group='packaging' loop
  select * into lot from public.cct_ingredient_lots where ingredient_id=comp.ingredient_id and received_on<=st.sale_date and quantity>0 order by received_on,id limit 1;
  if found then estimated:=estimated+round(comp.quantity*st.qty*lot.total_cost/lot.quantity,4);end if;
 end loop;
 select coalesce(sum(extended_cost),0) into actual from cct_internal.food_packaging_allocations where order_token=p_token and item_index=p_ix;
 select coalesce(jsonb_agg(v->>'name'),'[]') into names from jsonb_array_elements(st.recipe) v;
 return jsonb_build_object('actual_cost',actual,'estimated_cost',estimated,'missing',st.missing,'names',names);
end $$;
create function cct_internal.packaging_order_lock() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare needed bool;
begin
 needed:=exists(select 1 from jsonb_array_elements(new.order_items) v where cct_internal.packaging_product(v) is not null);
 if tg_op='UPDATE' then needed:=needed or exists(select 1 from jsonb_array_elements(old.order_items) v where cct_internal.packaging_product(v) is not null);end if;
 if needed then perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);end if;
 return new;
end $$;
create function cct_internal.packaging_order_trigger() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
begin
 if exists(select 1 from jsonb_array_elements(new.order_items) v where cct_internal.packaging_product(v) is not null) or exists(select 1 from cct_internal.food_packaging_state where order_token=new.order_token) then
  perform cct_internal.packaging_reconcile(new.order_token);
 end if;
 return null;
end $$;
create trigger aaa_cct_food_packaging_lock before insert or update of status,order_items,pickup_date,delivery_date,fulfilment_method,order_text on public.order_commits for each row execute function cct_internal.packaging_order_lock();
create trigger cct_food_packaging_auto after insert or update of status,order_items,pickup_date,delivery_date,fulfilment_method,order_text on public.order_commits for each row execute function cct_internal.packaging_order_trigger();
revoke all on all functions in schema cct_internal from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.cct_combo_fifo_cost_report_v2(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare source jsonb; item jsonb; result jsonb:='[]'::jsonb; qty_cost numeric; picked jsonb; adjusted_missing jsonb; missing_item jsonb; pack jsonb;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized'; end if;
 perform cct_internal.combo_reconcile(o.order_token) from public.order_commits o where o.status='completed' order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token;
 perform cct_internal.packaging_reconcile(o.order_token) from public.order_commits o where o.status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.packaging_product(v) is not null) order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token;
 source:=public.cct_combo5_cost_report_v1(p_passcode);
 for item in select value from jsonb_array_elements(source) loop
  pack:=cct_internal.packaging_report(item->>'order_token',(item->>'item_index')::int);
  item:=jsonb_set(item,'{extra_cost}',to_jsonb(coalesce((item->>'extra_cost')::numeric,0)-(pack->>'estimated_cost')::numeric+(pack->>'actual_cost')::numeric));
  item:=jsonb_set(item,'{packaging_cost}',pack->'actual_cost');
  select sum(a.extended_cost),jsonb_agg(jsonb_build_object('name',c.name,'lot_id',a.lot_id,'grams',a.grams,'cost',a.extended_cost) order by c.name)
   into qty_cost,picked from public.cct_combo_fifo_allocations a
   join public.cct_ingredient_catalog c on c.id=a.ingredient_id
   where a.order_token=item->>'order_token' and a.item_index=(item->>'item_index')::integer;
  adjusted_missing:='[]'::jsonb;
  for missing_item in select value from jsonb_array_elements(coalesce(item->'missing','[]'::jsonb)) loop
   if missing_item#>>'{}' not like 'Không có đủ 5 loại sứa%' and not exists(select 1 from jsonb_array_elements_text(pack->'names') n where missing_item#>>'{}'='Thiếu lô: '||n) then
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
  item:=jsonb_set(item,'{missing}',adjusted_missing||(pack->'missing'));
  item:=jsonb_set(item,'{method}',to_jsonb('persisted_fifo_by_order_and_lot'::text));
  result:=result||jsonb_build_array(item);
 end loop;
 return result;
end $function$
;
CREATE OR REPLACE FUNCTION public.cct_mango_shake_cost_report_v1(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r record; sau record; mango record; cup record; out_rows jsonb:='[]'::jsonb; miss jsonb; cost_amt numeric; pack jsonb;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 for r in select * from public.cct_mango_shake_fifo_allocations order by sale_date,order_number loop
 miss:='[]'::jsonb;cost_amt:=r.extended_cost;
 select l.* into mango from public.cct_ingredient_lots l where l.ingredient_id=15 and l.received_on<=r.sale_date and l.quantity>0 order by l.received_on,l.id limit 1;
 if not found then miss:=miss||jsonb_build_array('Thiếu lô xoài');else
 cost_amt:=cost_amt+round(100*mango.total_cost/mango.quantity,4);
 if not exists(select 1 from public.cct_mango_fifo_allocations ma where ma.order_token=r.order_token and ma.item_index=r.item_index and ma.lot_id=mango.id and ma.grams=100) then miss:=miss||jsonb_build_array('Chưa phân bổ FIFO xoài 100g cho đơn');end if;
 end if;
 perform cct_internal.packaging_reconcile(r.order_token);
 pack:=cct_internal.packaging_report(r.order_token,r.item_index);
 cost_amt:=cost_amt+(pack->>'actual_cost')::numeric;miss:=miss||(pack->'missing');
 select b.* into sau from public.cct_production_batches b join public.cct_production_recipes p on p.id=b.recipe_id where p.sku='SOT-THAI' and b.produced_on<=r.sale_date and b.quantity>0 order by b.produced_on,b.id limit 1;
 if not found then miss:=miss||jsonb_build_array('Thiếu mẻ sốt Thái');else cost_amt:=cost_amt+round(300*sau.total_cost/sau.quantity,4);end if;
 out_rows:=out_rows||jsonb_build_array(jsonb_build_object('order_token',r.order_token,'order_number',r.order_number,'item_index',r.item_index,'cost',round(cost_amt,4),'missing',miss,'date',r.sale_date));
 end loop;
 return out_rows;
end $function$
;
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
  exists(select 1 from jsonb_array_elements(oc.order_items) v where cct_internal.packaging_product(v) is not null) has_packaging,
  exists(select 1 from jsonb_array_elements(oc.order_items) v where cct_internal.is_single(v)) has_single,
  exists(select 1 from jsonb_array_elements(oc.order_items) v where cct_internal.is_chicken(v)) has_chicken,
  exists(select 1 from jsonb_array_elements(oc.order_items) v where coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-002') or lower(coalesce(v->>'name','')) like '%sứa combo%') has_combo
 from public.order_commits oc
 where oc.status='completed' and exists(
  select 1 from jsonb_array_elements(oc.order_items) v
  where cct_internal.packaging_product(v) is not null or cct_internal.is_single(v) or cct_internal.is_chicken(v) or coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-002')
     or lower(coalesce(v->>'name','')) like '%sứa combo%')
 order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token
 loop
  if o.has_packaging then perform cct_internal.packaging_reconcile(o.order_token);end if;
  if o.has_single then perform cct_internal.single_reconcile(o.order_token);end if;
  if o.has_chicken then perform cct_internal.chicken_reconcile(o.order_token);end if;
  if o.has_combo then perform cct_internal.combo_reconcile(o.order_token);end if;
 end loop;
end $function$
;
CREATE OR REPLACE FUNCTION public.cct_ingredient_lot_edit_v2(p_passcode text, p_lot_id bigint, p_old_date date, p_old_total numeric, p_new_date date, p_new_total numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare l public.cct_ingredient_lots%rowtype;r record;earliest date;d date;price numeric;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 if p_new_date is null or p_new_date>(now() at time zone 'Australia/Melbourne')::date or p_new_total is null or p_new_total<0 or p_new_total>10000000 or p_new_total<>round(p_new_total,2) then raise exception 'Ngày hoặc tổng vốn không hợp lệ';end if;
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 select * into l from public.cct_ingredient_lots where id=p_lot_id for update;
 if not found then raise exception 'Không tìm thấy lô nhập';end if;
 if l.received_on is distinct from p_old_date or l.total_cost is distinct from p_old_total then raise exception 'Lô đã được cập nhật ở nơi khác. Vui lòng tải lại';end if;
 if p_new_total<>l.total_cost and exists(select 1 from public.cct_production_fifo_allocations where ingredient_lot_id=l.id) then
  raise exception 'Lô đã dùng sản xuất sốt. Cần đối soát giá vốn mẻ sản xuất trước khi sửa giá nguyên liệu';
 end if;
 for r in select * from (values
 ('public.cct_combo_fifo_allocations','grams','unit_cost'),
 ('public.cct_single_fifo_allocations','grams','unit_cost'),
 ('public.cct_chicken_mix_fifo_allocations','grams','unit_cost'),
 ('public.cct_chicken_mix_jelly_allocations','grams','unit_cost'),
 ('public.cct_mango_shake_fifo_allocations','grams','unit_cost'),
 ('public.cct_mango_fifo_allocations','grams','unit_cost_per_g'),
 ('cct_internal.single_ingredient_allocations','grams','unit_cost'),
 ('public.cct_chicken_mix_packaging_allocations','quantity',null),
 ('cct_internal.single_packaging_allocations','quantity',null),
 ('cct_internal.food_packaging_allocations','quantity','unit_cost')
 ) t(tab,qty_col,unit_col) loop
  execute format('select min(sale_date) from %s where lot_id=$1',r.tab) into d using l.id;
  earliest:=least(earliest,d);
 end loop;
 select min(b.produced_on) into d from public.cct_production_fifo_allocations a join public.cct_production_batches b on b.id=a.production_batch_id where a.ingredient_lot_id=l.id;
 earliest:=least(earliest,d);
 if p_new_date is distinct from l.received_on and p_new_date>earliest then raise exception 'Ngày nhận mới sau ngày lô đã được sử dụng (%). Cần kiểm tra lại phân bổ trước',to_char(earliest,'DD/MM/YYYY');end if;
 insert into cct_internal.ingredient_lot_edit_audit(lot_id,old_received_on,new_received_on,old_total_cost,new_total_cost) values(l.id,l.received_on,p_new_date,l.total_cost,p_new_total);
 update public.cct_ingredient_lots set received_on=p_new_date,total_cost=p_new_total where id=l.id;
 if p_new_total<>l.total_cost then
  price:=p_new_total/l.quantity;
  for r in select * from (values
  ('public.cct_combo_fifo_allocations','grams','unit_cost'),
  ('public.cct_single_fifo_allocations','grams','unit_cost'),
  ('public.cct_chicken_mix_fifo_allocations','grams','unit_cost'),
  ('public.cct_chicken_mix_jelly_allocations','grams','unit_cost'),
  ('public.cct_mango_shake_fifo_allocations','grams','unit_cost'),
  ('public.cct_mango_fifo_allocations','grams','unit_cost_per_g'),
  ('cct_internal.single_ingredient_allocations','grams','unit_cost'),
  ('public.cct_chicken_mix_packaging_allocations','quantity',null),
  ('cct_internal.single_packaging_allocations','quantity',null),
 ('cct_internal.food_packaging_allocations','quantity','unit_cost')
  ) t(tab,qty_col,unit_col) loop
   if r.unit_col is null then
    execute format('update %s set extended_cost=round(%I*$1,4) where lot_id=$2',r.tab,r.qty_col) using price,l.id;
   else
    execute format('update %s set %I=$1,extended_cost=round(%I*$1,4) where lot_id=$2',r.tab,r.unit_col,r.qty_col) using price,l.id;
   end if;
  end loop;
 end if;
 return jsonb_build_object('id',l.id,'total_cost',p_new_total,'received_on',p_new_date,'quantity',l.quantity,'remaining',l.remaining,'unit_cost',p_new_total/l.quantity);
end $function$
;

do $$ declare d text;begin
 select pg_get_functiondef('cct_internal.packaging_report(text,integer)'::regprocedure) into d;
 d:=replace(d,'where ingredient_id=comp.ingredient_id and received_on<=st.sale_date','where lower(ingredient_name)=lower(comp.ingredient_name) and received_on<=st.sale_date');
 execute d;
end $$;