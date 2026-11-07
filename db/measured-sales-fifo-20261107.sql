begin;
-- Flexible measured ingredient / sauce sales. Auth follows the existing admin passcode contract.
create table if not exists cct_internal.measured_line_state (
 order_token text not null references public.order_commits(order_token),item_index integer not null,
 signature text not null,components jsonb not null,qty numeric not null,sale_date date not null,
 primary key(order_token,item_index)
);
create table if not exists cct_internal.measured_line_allocations (
 order_token text not null,item_index integer not null,component_index integer not null,
 kind text not null check(kind in ('ingredient','production')),lot_id bigint not null,
 quantity numeric not null check(quantity>0),
 primary key(order_token,item_index,component_index,kind,lot_id),
 foreign key(order_token,item_index) references cct_internal.measured_line_state(order_token,item_index)
);
create table if not exists cct_internal.measured_conversion_audit (
 order_token text primary key,old_items jsonb not null,new_items jsonb not null,reason text not null,created_at timestamptz not null default now()
);
alter table cct_internal.measured_line_state enable row level security;
alter table cct_internal.measured_line_allocations enable row level security;
alter table cct_internal.measured_conversion_audit enable row level security;
revoke all on cct_internal.measured_line_state,cct_internal.measured_line_allocations,cct_internal.measured_conversion_audit from public,anon,authenticated;

create or replace function cct_internal.measured_item(v jsonb) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,cct_internal as $$
declare c jsonb;arr jsonb:='[]';sid bigint;q numeric;k text;n text;u text;src_sku text;label_text text:='';main_name text;main_sku text;idx integer:=0;
begin
 if v->>'sale_mode' is distinct from 'measured' then raise exception 'invalid_measured_mode';end if;
 if coalesce(v->>'qty','')!~'^[1-9][0-9]{0,4}$' then raise exception 'Số phần bán lẻ phải từ 1 đến 99999';end if;
 if jsonb_typeof(v->'cost_components') is distinct from 'array' then raise exception 'Chọn nguyên liệu và nhập định lượng bán lẻ';end if;
 if jsonb_array_length(v->'cost_components') not between 1 and 20 then raise exception 'Mỗi dòng bán lẻ cần từ 1 đến 20 thành phần';end if;
 for c in select value from jsonb_array_elements(v->'cost_components') loop
  k:=c->>'kind';sid:=(c->>'source_id')::bigint;q:=(c->>'quantity')::numeric;
  if q is null or q<=0 or q>1000000 or q::text in ('NaN','Infinity','-Infinity') then raise exception 'Định lượng phải lớn hơn 0 và không quá 1000000';end if;
  n:=null;u:=null;src_sku:=null;
  if k='ingredient' then
   select ic.name,ic.unit,ic.sku into n,u,src_sku from public.cct_ingredient_catalog ic where ic.id=sid;
   -- Sauce catalog records are represented by their production recipes, never by a second stock pool.
   if exists(select 1 from public.cct_production_recipes pr where pr.sku=src_sku and pr.product_type in ('sauce','prepared')) then raise exception 'Chọn sốt trong nhóm Mẻ sốt / sơ chế để lấy đúng vốn mẻ';end if;
  elsif k='production' then
   select pr.product_name,case when pr.product_type='sauce' then 'ml' else 'g' end,pr.sku into n,u,src_sku from public.cct_production_recipes pr where pr.id=sid and pr.product_type in ('sauce','prepared');
  end if;
  if n is null or u not in ('g','ml','piece') then raise exception 'Không tìm thấy nguồn kho hợp lệ cho thành phần bán lẻ';end if;
  if c->>'unit' is distinct from u then raise exception 'Đơn vị không khớp với nguyên liệu %',n;end if;
  if u='piece' and q<>trunc(q) then raise exception 'Bao bì tính theo số cái nguyên';end if;
  if idx=0 then main_name:=n;main_sku:=src_sku;end if;
  arr:=arr||jsonb_build_array(jsonb_build_object('kind',k,'source_id',sid,'quantity',q,'unit',u,'name',n,'sku',src_sku));
  label_text:=label_text||case when idx>0 then ' + '||n||' ' else '' end||q::text||case when u='piece' then ' cái' else u end;
  idx:=idx+1;
 end loop;
 return v||jsonb_build_object('id',null,'is_custom',true,'name',main_name,'sale_mode','measured','cost_components',arr,'measured_sku',main_sku,'option_text',label_text||case when nullif(btrim(v->>'measured_note'),'') is null then '' else ' · '||left(btrim(v->>'measured_note'),300) end);
end $$;
revoke all on function cct_internal.measured_item(jsonb) from public,anon,authenticated;

create or replace function public.cct_measured_sources_v1(p_passcode text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 return (select coalesce(jsonb_agg(to_jsonb(s) order by s.kind,s.name),'[]') from (
 select 'ingredient'::text kind,c.id source_id,c.name,c.sku,c.unit,c.active from public.cct_ingredient_catalog c where not exists(select 1 from public.cct_production_recipes pr where pr.sku=c.sku and pr.product_type in ('sauce','prepared'))
 union all select 'production',r.id,r.product_name,r.sku,case when r.product_type='sauce' then 'ml' else 'g' end,r.active from public.cct_production_recipes r where r.product_type in ('sauce','prepared')
 )s);
end $$;
revoke all on function public.cct_measured_sources_v1(text) from public;
grant execute on function public.cct_measured_sources_v1(text) to anon,authenticated;

create or replace function cct_internal.measured_reconcile(token text) returns void language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare o public.order_commits%rowtype;s record;a record;it record;comp record;lot_row record;v jsonb;d date;sig text;q numeric;need numeric;actual numeric;take_q numeric;
begin
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 select * into o from public.order_commits where order_token=token;if not found then return;end if;
 d:=coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date);
 -- Release only changed, removed, cancelled, or re-dated measured rows.
 for s in select * from cct_internal.measured_line_state where order_token=token order by item_index loop
  v:=o.order_items->s.item_index;
  sig:=case when o.status='completed' and v->>'sale_mode'='measured' and d is not null then md5(jsonb_build_array(v->'cost_components',v->'qty',d)::text) else null end;
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
 for it in select value item,(ordinality-1)::integer ix from jsonb_array_elements(o.order_items) with ordinality where value->>'sale_mode'='measured' loop
  v:=cct_internal.measured_item(it.item);q:=(v->>'qty')::numeric;
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
end $$;
revoke all on function cct_internal.measured_reconcile(text) from public,anon,authenticated;

create or replace function cct_internal.measured_order_trigger() returns trigger language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
begin perform cct_internal.measured_reconcile(new.order_token);return null;end $$;
revoke all on function cct_internal.measured_order_trigger() from public,anon,authenticated;
drop trigger if exists z_cct_measured_fifo on public.order_commits;
create trigger z_cct_measured_fifo after insert or update of status,order_items,pickup_date,delivery_date,fulfilment_method on public.order_commits for each row execute function cct_internal.measured_order_trigger();

create or replace function public.cct_measured_cost_report_v1(p_passcode text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare outv jsonb:='[]';o record;it record;comp record;parts jsonb;miss jsonb;costq numeric;actual numeric;need numeric;amount numeric;d date;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 for o in select oc.* from public.order_commits oc where oc.status='completed' and exists(select 1 from jsonb_array_elements(oc.order_items)x where x->>'sale_mode'='measured') order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token loop
  perform cct_internal.measured_reconcile(o.order_token);
  d:=coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date);
  for it in select value item,(ordinality-1)::integer ix from jsonb_array_elements(o.order_items) with ordinality where value->>'sale_mode'='measured' loop
   costq:=0;miss:='[]';parts:='[]';
   for comp in select value c,(ordinality-1)::integer ix from jsonb_array_elements(it.item->'cost_components') with ordinality loop
    select coalesce(sum(x.quantity),0),coalesce(sum(round(x.quantity*case when x.kind='ingredient' then l.total_cost/nullif(l.quantity,0) else b.total_cost/nullif(b.quantity,0) end,4)),0) into actual,amount from cct_internal.measured_line_allocations x left join public.cct_ingredient_lots l on x.kind='ingredient' and l.id=x.lot_id left join public.cct_production_batches b on x.kind='production' and b.id=x.lot_id where x.order_token=o.order_token and x.item_index=it.ix and x.component_index=comp.ix;
    need:=(comp.c->>'quantity')::numeric*(it.item->>'qty')::numeric;costq:=costq+amount;
    parts:=parts||jsonb_build_array(jsonb_build_object('name',comp.c->>'name','quantity',actual,'required',need,'unit',comp.c->>'unit','cost',amount));
    if actual<need then miss:=miss||jsonb_build_array((comp.c->>'name')||': đã phân bổ '||actual||'/'||need||' '||(comp.c->>'unit')||' từ lô không muộn hơn ngày bán');end if;
   end loop;
   if d is null then miss:=miss||jsonb_build_array('Chưa có ngày nhận hàng để phân bổ FIFO');end if;
   outv:=outv||jsonb_build_array(jsonb_build_object('order_token',o.order_token,'item_index',it.ix,'display_name',(it.item->>'name')||' · Bán lẻ','display_sku','LE-'||(it.item->>'measured_sku'),'cost',costq,'missing',miss,'parts',parts));
  end loop;
 end loop;
 return outv;
end $$;
revoke all on function public.cct_measured_cost_report_v1(text) from public;
grant execute on function public.cct_measured_cost_report_v1(text) to anon,authenticated;

CREATE OR REPLACE FUNCTION public.update_order_items_v3(p_passcode text, p_order_token text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  h text;
  old_items jsonb;
  old_item jsonb;
  new_item jsonb;
  product_id bigint;
  qty integer;
  old_qty integer;
  current_stock integer;
  product_name text;
  menu_price numeric;
  effective_price numeric;
  option_text text;
  normalized_items jsonb := '[]'::jsonb;
  stock_items jsonb := '[]'::jsonb;
  subtotal_value numeric := 0;
  delivery_value numeric;
  fulfil text;
  dtype text;
  dvalue numeric;
  disc numeric := 0;
  rowdata jsonb;
begin
  select pass_hash into h from public.print_admin_access where id=1;
  if h is null
     or encode(
          extensions.digest(
            ('cct-print-v1-20260924' || coalesce(p_passcode,''))::text,
            'sha256'::text
          ),
          'hex'
        ) <> h
  then
    raise exception 'not_authorized';
  end if;

  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items)=0
     or jsonb_array_length(p_items)>50
  then
    raise exception 'empty_order';
  end if;

  select items, delivery_fee, fulfilment_method, discount_type, discount_value
  into old_items, delivery_value, fulfil, dtype, dvalue
  from public.order_commits
  where order_token=p_order_token
  for update;

  if not found then raise exception 'order_not_found'; end if;
  old_items := coalesce(old_items,'[]'::jsonb);

  -- Return finite stock previously committed by this order.
  for old_item in select * from jsonb_array_elements(old_items)
  loop
    product_id := nullif(old_item->>'id','')::bigint;
    old_qty := greatest(coalesce(nullif(old_item->>'qty','')::integer,0),0);
    if product_id is null then continue; end if;

    select stock_qty into current_stock
    from public.products
    where id=product_id
    for update;

    if found and current_stock is not null and old_qty>0 and old_item->>'stock_deducted' is distinct from 'false' then
      update public.products
      set stock_qty=stock_qty+old_qty, updated_at=now()
      where id=product_id;

      update public.products_draft d
      set stock_qty=p.stock_qty, updated_at=now()
      from public.products p
      where d.id=product_id and p.id=product_id;
    end if;
  end loop;

  -- Validate new rows, deduct stock, and preserve per-order price overrides.
  for new_item in select * from jsonb_array_elements(p_items)
  loop
    if new_item->>'is_custom'='true' then
      if coalesce(new_item->>'qty','') !~ '^[1-9][0-9]{0,4}$'
         or coalesce(new_item->>'unit_price','') !~ '^[0-9]{1,7}([.][0-9]{1,2})?$'
      then raise exception 'invalid_custom_item'; end if;

      qty := (new_item->>'qty')::integer;
      if new_item->>'sale_mode'='measured' then new_item:=cct_internal.measured_item(new_item);end if;
      product_name := btrim(coalesce(new_item->>'name',''));
      effective_price := (new_item->>'unit_price')::numeric;
      option_text := left(coalesce(new_item->>'option_text',''),500);

      if length(product_name)=0 or length(product_name)>200
         or effective_price<0 or effective_price>1000000
      then raise exception 'invalid_custom_item'; end if;

      normalized_items := normalized_items || jsonb_build_array(
        jsonb_build_object(
          'id',null,'is_custom',true,'qty',qty,'name',product_name,
          'unit_price',effective_price,'line_total',effective_price*qty,
          'option_text',option_text,'options','[]'::jsonb
        ) || case when new_item->>'sale_mode'='measured' then jsonb_build_object('sale_mode','measured','cost_components',new_item->'cost_components','measured_sku',new_item->>'measured_sku','measured_note',left(coalesce(new_item->>'measured_note',''),300)) else '{}'::jsonb end
      );
      subtotal_value := subtotal_value + effective_price*qty;
      continue;
    end if;

    if coalesce(new_item->>'id','') !~ '^[0-9]+$'
       or coalesce(new_item->>'qty','') !~ '^[1-9][0-9]{0,4}$'
    then raise exception 'invalid_item'; end if;

    product_id := (new_item->>'id')::bigint;
    qty := (new_item->>'qty')::integer;
    option_text := left(coalesce(new_item->>'option_text',''),500);

    select name,price,case when category='dattruoc' or 'dattruoc'=any(coalesce(categories,'{}'::text[])) then null else stock_qty end
    into product_name,menu_price,current_stock
    from public.products
    where id=product_id and (is_active=true or cost_only=true)
    for update;

    if not found then raise exception 'product_unavailable:%',product_id; end if;
    if current_stock is not null and current_stock<qty then
      raise exception 'insufficient_stock:%:%:%',product_id,product_name,current_stock;
    end if;

    if nullif(btrim(coalesce(new_item->>'unit_price','')),'') is null then
      effective_price := menu_price;
    else
      if (new_item->>'unit_price') !~ '^[0-9]{1,7}([.][0-9]{1,2})?$'
      then raise exception 'invalid_item_price'; end if;
      effective_price := (new_item->>'unit_price')::numeric;
      if effective_price<0 or effective_price>1000000 then raise exception 'invalid_item_price'; end if;
    end if;

    if current_stock is not null then
      update public.products
      set stock_qty=stock_qty-qty, updated_at=now()
      where id=product_id;

      update public.products_draft d
      set stock_qty=p.stock_qty, updated_at=now()
      from public.products p
      where d.id=product_id and p.id=product_id;
    end if;

    subtotal_value := subtotal_value + effective_price*qty;

    normalized_items := normalized_items || jsonb_build_array(
      jsonb_build_object(
        'id',product_id,'qty',qty,'name',product_name,
        'unit_price',effective_price,'menu_price',menu_price,
        'price_overridden',(effective_price<>menu_price),
        'line_total',effective_price*qty,
        'option_text',option_text,'options','[]'::jsonb
      )
    );

    stock_items := stock_items || jsonb_build_array(
      jsonb_build_object('id',product_id,'qty',qty,'stock_deducted',current_stock is not null)
    );
  end loop;

  if dtype='percent' then
    disc := round(subtotal_value*coalesce(dvalue,0)/100,2);
  elsif dtype='amount' then
    disc := least(round(coalesce(dvalue,0),2),subtotal_value);
  end if;

  update public.order_commits
  set items=stock_items,
      order_items=normalized_items,
      subtotal=subtotal_value,
      discount_amount=disc,
      total=case
        when fulfil in ('delivery','auspost') and delivery_value is null then null
        else greatest(0,subtotal_value+coalesce(delivery_value,0)-disc)
      end,
      updated_at=now()
  where order_token=p_order_token
  returning to_jsonb(public.order_commits.*) into rowdata;

  return rowdata;
end;
$function$

;
CREATE OR REPLACE FUNCTION cct_internal.is_chicken(v jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
 select coalesce(v->>'sale_mode','')<>'measured' and (coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-003')
 or cct_internal.chicken_normalize(v->>'name') like 'sua tron chan ga%'
 or cct_internal.chicken_normalize(v->>'name') ~ '^chan ga (tron sua|mix sua)( |$)')
$function$

;
CREATE OR REPLACE FUNCTION cct_internal.is_single(v jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
 select coalesce(v->>'sale_mode','')<>'measured' and (coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-001')
 or cct_internal.single_normalize(v->>'name') like 'ly sua single%')
$function$

;
CREATE OR REPLACE FUNCTION public.cct_order_sauce_reconcile_v1(p_order_token text, p_preview boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare o record; itm jsonb; idx int; v_id bigint; v_name text; v_qty numeric; v_date date; r record; b record; v_count int:=0; v_unknown int:=0; v_sku text; v_ml numeric; v_status text; v_note text; v_has_sauce int;
begin
 select * into o from public.order_commits where order_token=p_order_token for update;
 if not found then raise exception 'order_not_found';end if;
 if o.status<>'completed' then return jsonb_build_object('status','not_completed');end if;
 v_date:=coalesce(case when o.fulfilment_method='delivery' then o.delivery_date else o.pickup_date end,o.delivery_date,o.pickup_date,(o.created_at at time zone 'Australia/Melbourne')::date);
 perform pg_advisory_xact_lock(1628018,2);
 for itm,idx in select value,(ordinality-1)::int from jsonb_array_elements(coalesce(o.order_items,'[]'::jsonb)) with ordinality loop
  if itm->>'sale_mode'='measured' then continue;end if;
  v_id:=nullif(itm->>'id','')::bigint;
  v_name:=lower(coalesce(itm->>'name',''));
  v_qty:=coalesce(nullif(itm->>'qty','')::numeric,1);
  if v_qty<=0 then continue;end if;
  -- Only use a real product ID if name corroborates it (legacy IDs may be reused).
  if v_id is not null and exists(select 1 from public.products p where p.id=v_id and (lower(p.name)=v_name or lower(p.name) like '%'||v_name||'%')) then null;
  elsif v_name like '%ly sứa combo%' or v_name like '%ly sua combo%' then v_id=(select id from public.products where sku='SU-002');
  elsif v_name like '%ly sứa single%' or v_name like '%ly sua single%' then v_id=(select id from public.products where sku='SU-001');
  elsif v_name like '%sứa trộn chân gà%' then v_id=(select id from public.products where sku='SU-003');
  elsif v_name like '%sứa lắc xoài%' then v_id=(select id from public.products where sku='SU-004');
  else v_id=null;end if;
  if v_id is null then continue;end if;
  -- Standalone extra sauce sold as an item: 200 ml for every unit.
  if cct_internal.is_gv004(itm) then continue;end if;
  if v_id in (98) then
    v_sku:=case when v_id=97 then 'SOT-THAI' else 'SOT-MAM-NHI' end;
    v_ml:=200*v_qty;
    if not exists(select 1 from public.cct_order_sauce_cogs where order_token=p_order_token and item_index=idx and sauce_sku=v_sku) then
      select pb.* into b from public.cct_production_batches pb join public.cct_production_recipes pr on pr.id=pb.recipe_id
       where pr.sku=v_sku and pb.produced_on<=v_date and pb.status='open' and pb.quantity-pb.used_quantity>=v_ml
       order by pb.produced_on,pb.id limit 1 for update of pb;
      if found then
        v_count:=v_count+1;
        if not p_preview then
          update public.cct_production_batches set used_quantity=used_quantity+v_ml,status=case when used_quantity+v_ml>=quantity then 'closed' else status end where id=b.id;
          insert into public.cct_order_sauce_cogs(order_token,item_index,sauce_sku,batch_id,quantity_ml,cost)
          values(p_order_token,idx,v_sku,b.id,v_ml,round(v_ml*b.total_cost/b.quantity,4));
        end if;
      else
        v_unknown:=v_unknown+1;
      end if;
    end if;
    continue;
  end if;
  if not exists(select 1 from public.products where id=v_id and sku like 'SU-%') then continue;end if;
  select count(*) into v_has_sauce from public.cct_standard_recipe_items where product_id=v_id and component_group='sauce';
  if v_id in (select id from public.products where sku in ('SU-003','SU-001')) then continue;end if;
if v_has_sauce=0 then
    if not p_preview and not exists(select 1 from public.cct_order_sauce_cogs where order_token=p_order_token and item_index=idx) then
      insert into public.cct_order_sauce_resolution_v1(order_token,item_index,sauce_sku,status,note,order_date)
      values(p_order_token,idx,'UNKNOWN','unknown','Standard Recipe chưa khai báo định lượng sốt',v_date)
      on conflict(order_token,item_index,sauce_sku) do update set status='unknown',note=excluded.note,order_date=excluded.order_date,updated_at=now();
    end if;
    v_unknown:=v_unknown+1;continue;
  end if;
  -- Variable sauce: require exactly one explicitly selected sauce before allocating.
  if v_id in (select id from public.products where sku in ('SU-001','SU-004')) then
   if ((lower(coalesce(itm->>'option_text','')||' '||coalesce(itm->>'name','')) ~ '(mắm nhĩ|mam nhi)')::int
     +(lower(coalesce(itm->>'option_text','')||' '||coalesce(itm->>'name','')) ~ '(thái|thai)')::int)<>1 then
    v_unknown:=v_unknown+1;
    if not p_preview then
     insert into public.cct_order_sauce_resolution_v1(order_token,item_index,sauce_sku,status,note,order_date)
      values(p_order_token,idx,'UNKNOWN','unknown','Chưa xác định đúng một lựa chọn sốt của khách',v_date)
      on conflict(order_token,item_index,sauce_sku) do update set status='unknown',note=excluded.note,order_date=excluded.order_date,updated_at=now();
    end if;
    continue;
   end if;
  end if;
  for r in select ingredient_name,quantity from public.cct_standard_recipe_items where product_id=v_id and component_group='sauce' order by id loop
   v_sku:=case when lower(r.ingredient_name) like '%mắm nhĩ%' then 'SOT-MAM-NHI' when lower(r.ingredient_name) like '%thái%' then 'SOT-THAI' else 'UNKNOWN' end;
   v_ml:=r.quantity*v_qty;
   if v_id=(select id from public.products where sku='SU-002') then
    if lower(coalesce(itm->>'option_text','')) ~ 'only[[:space:]]+(sốt[[:space:]]+)?(thái|thai)' then
     if v_sku<>'SOT-THAI' then continue; end if;
     v_ml:=400*v_qty;
    elsif lower(coalesce(itm->>'option_text','')) ~ 'only[[:space:]]+(sốt[[:space:]]+)?(mắm[[:space:]]+nhĩ|mam[[:space:]]+nhi)' then
     if v_sku<>'SOT-MAM-NHI' then continue; end if;
     v_ml:=400*v_qty;
    end if;
   end if;
   -- Combo double sauce: two 200ml containers of the requested sauce, no other sauce.
   if v_id=(select id from public.products where sku='SU-002') then
      if lower(coalesce(itm->>'option_text','')) ~ '(thái|thai)\s*x\s*2' then
        if v_sku<>'SOT-THAI' then continue; end if;
        v_ml:=400*v_qty;
      elsif lower(coalesce(itm->>'option_text','')) ~ '(mắm nhĩ|mam nhi)\s*x\s*2' then
        if v_sku<>'SOT-MAM-NHI' then continue; end if;
        v_ml:=400*v_qty;
      end if;
   end if;
   v_note:=null;
   if v_sku='UNKNOWN' then v_note:='Chưa khớp mã sốt trong công thức';end if;
   -- For a configurable single-sauce SKU, only allocate the customer's selection.
   if v_id in (select id from public.products where sku in ('SU-001','SU-004')) and v_note is null then
    if lower(coalesce(itm->>'option_text','')||' '||coalesce(itm->>'name','')) !~ (case when v_sku='SOT-MAM-NHI' then '(mắm nhĩ|mam nhi)' else '(thái|thai)' end) then continue;end if;
   end if;
   if exists(select 1 from public.cct_order_sauce_cogs where order_token=p_order_token and item_index=idx and sauce_sku=v_sku) then continue;end if;
   if v_note is null then
    select pb.* into b from public.cct_production_batches pb join public.cct_production_recipes pr on pr.id=pb.recipe_id
    where pr.sku=v_sku and pb.produced_on<=v_date and pb.status='open' and pb.quantity-pb.used_quantity>=v_ml
    order by pb.produced_on,pb.id limit 1 for update of pb;
    if not found then v_note:='Không có mẻ đủ sốt hợp lệ vào ngày đơn hàng';end if;
   end if;
   if v_note is not null then
    v_unknown:=v_unknown+1;
    if not p_preview then
      insert into public.cct_order_sauce_resolution_v1(order_token,item_index,sauce_sku,status,quantity_ml,note,order_date)
      values(p_order_token,idx,v_sku,'unknown',v_ml,v_note,v_date)
      on conflict(order_token,item_index,sauce_sku) do update set status='unknown',quantity_ml=excluded.quantity_ml,note=excluded.note,order_date=excluded.order_date,updated_at=now();
    end if;
   else
    v_count:=v_count+1;
    if not p_preview then
      update public.cct_production_batches set used_quantity=used_quantity+v_ml,status=case when used_quantity+v_ml>=quantity then 'closed' else status end where id=b.id;
      insert into public.cct_order_sauce_cogs(order_token,item_index,sauce_sku,batch_id,quantity_ml,cost)
      values(p_order_token,idx,v_sku,b.id,v_ml,round(v_ml*b.total_cost/b.quantity,4));
      insert into public.cct_order_sauce_resolution_v1(order_token,item_index,sauce_sku,status,quantity_ml,note,order_date)
      values(p_order_token,idx,v_sku,'allocated',v_ml,'Theo Standard Recipe',v_date)
      on conflict(order_token,item_index,sauce_sku) do update set status='allocated',quantity_ml=excluded.quantity_ml,note=excluded.note,order_date=excluded.order_date,updated_at=now();
    end if;
   end if;
  end loop;
 end loop;
 return jsonb_build_object('status',case when p_preview then 'preview' else 'processed' end,'allocated',v_count,'unknown',v_unknown);
end $function$

;
CREATE OR REPLACE FUNCTION public.cct_capture_sauce_cogs_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_item jsonb;v_idx int:=0;v_sku text;v_qty numeric;v_batch record;v_text text;v_sauces text[];v_s text;v_require numeric;v_ok boolean;v_alloc record;
begin
if new.created_at<'2026-10-18'::timestamptz or new.order_token like 'legacy-%' or jsonb_typeof(new.order_items)<>'array' then return new;end if;
for v_item in select value from jsonb_array_elements(new.order_items) loop
if v_item->>'sale_mode'='measured' then v_idx:=v_idx+1;continue;end if;
v_text=lower(coalesce(v_item->>'name','')||' '||coalesce(v_item->>'option_text',''));
v_qty=coalesce(nullif(v_item->>'qty','')::numeric,1);
if v_qty<=0 then v_idx=v_idx+1;continue;end if;
if cct_internal.is_single(v_item) then v_idx:=v_idx+1;continue;end if;
v_sauces=array[]::text[];
if (v_item->>'id')='2' or v_text like '%ly sứa combo%' then
if v_text ~ 'only[[:space:]]+(sốt[[:space:]]+)?(thái|thai)' then v_sauces=array['SOT-THAI','SOT-THAI'];
elsif v_text ~ 'only[[:space:]]+(sốt[[:space:]]+)?(mắm[[:space:]]+nhĩ|mam[[:space:]]+nhi)' then v_sauces=array['SOT-MAM-NHI','SOT-MAM-NHI'];
elsif v_text like '%thái x2%' then v_sauces=array['SOT-THAI','SOT-THAI'];
elsif v_text like '%mắm nhĩ x2%' then v_sauces=array['SOT-MAM-NHI','SOT-MAM-NHI'];
else v_sauces=array['SOT-THAI','SOT-MAM-NHI'];end if;
elsif (v_item->>'id')='1' or v_text like '%ly sứa single%' then
if v_text like '%mắm nhĩ%' then v_sauces=array['SOT-MAM-NHI'];
elsif v_text like '%sốt thái%' or v_text like '%sot thai%' then v_sauces=array['SOT-THAI'];end if;
end if;
if cardinality(v_sauces)=0 then v_idx=v_idx+1;continue;end if;
if exists(select 1 from public.cct_order_sauce_cogs where order_token=new.order_token and item_index=v_idx) then v_idx=v_idx+1;continue;end if;
v_ok=true;
for v_s,v_require in select sauce, count(*)*200*v_qty from unnest(v_sauces) sauce group by sauce loop
if not exists(select 1 from public.cct_production_batches b join public.cct_production_recipes r on r.id=b.recipe_id where r.sku=v_s and b.status='open' and b.quantity-b.used_quantity>=v_require) then v_ok=false;end if;
end loop;
if not v_ok then v_idx=v_idx+1;continue;end if;
for v_s,v_require in select sauce,count(*)*200*v_qty from unnest(v_sauces) sauce group by sauce loop
select b.id,b.quantity,b.total_cost into v_batch from public.cct_production_batches b join public.cct_production_recipes r on r.id=b.recipe_id where r.sku=v_s and b.status='open' and b.quantity-b.used_quantity>=v_require order by b.produced_on,b.id limit 1 for update of b;
if not found then raise exception 'Sauce batch changed; retry';end if;
update public.cct_production_batches set used_quantity=used_quantity+v_require,status=case when used_quantity+v_require>=quantity then 'closed' else status end where id=v_batch.id;
insert into public.cct_order_sauce_cogs(order_token,item_index,sauce_sku,batch_id,quantity_ml,cost) values(new.order_token,v_idx,v_s,v_batch.id,v_require,round(v_require*v_batch.total_cost/v_batch.quantity,6));
end loop;
v_idx=v_idx+1;
end loop;
return new;
end $function$

;
CREATE OR REPLACE FUNCTION cct_internal.packaging_product(v jsonb)
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
 select p.id from public.products p where coalesce(v->>'sale_mode','')<>'measured' and p.sku in ('SU-002','SU-004')
 and (p.id::text=coalesce(v->>'id',v->>'product_id','')
 or (p.sku='SU-002' and cct_internal.chicken_normalize(v->>'name') ~ '^(ly )?sua combo')
 or (p.sku='SU-004' and cct_internal.chicken_normalize(v->>'name') ~ '^(ly )?sua lac xoai'))
 order by (p.id::text=coalesce(v->>'id',v->>'product_id','')) desc limit 1
$function$

;
CREATE OR REPLACE FUNCTION cct_internal.is_gv004(item jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
 select coalesce(item->>'sale_mode','')<>'measured' and (coalesce(item->>'id',item->>'product_id','') in(select id::text from public.products where sku='GV-004')
 or lower(trim(coalesce(item->>'name',''))) in('sốt thái đỏ','sot thai do'))
$function$

;
CREATE OR REPLACE FUNCTION public.cct_production_batch_edit_v1(p_passcode text, p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare
 b public.cct_production_batches%rowtype; saved public.cct_production_batches%rowtype;
 arr jsonb; snap jsonb; after_snap jsonb; ver text; q numeric; usedq numeric; total numeric;
 rid bigint; typ text; newunit text; dt date; st text; memo text; why text; req uuid;
 linked numeric; tracked numeric; wasted numeric; first_use date; raw_date date; fifo_count integer;
 prior cct_internal.production_batch_edits%rowtype;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 select * into b from public.cct_production_batches where id=(p_payload->>'id')::bigint for update;
 if not found then raise exception 'Không tìm thấy mẻ';end if;
 if p_action='history' then
 return (select coalesce(jsonb_agg(jsonb_build_object('changed_at',a.changed_at,'reason',a.reason,'before',a.before_data,'after',a.after_data) order by a.changed_at desc),'[]') from cct_internal.production_batch_edits a where a.batch_id=b.id);
 end if;
 select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]') into arr from public.cct_production_batch_inputs i where i.batch_id=b.id;
 snap:=jsonb_build_object('batch',to_jsonb(b),'inputs',arr);ver:=md5(snap::text);
 select coalesce(sum(a.quantity_ml),0),min(coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date)) into linked,first_use from (
 select order_token,quantity_ml from public.cct_order_sauce_cogs where batch_id=b.id
 union all select order_token,quantity_ml from cct_internal.single_sauce_lots where batch_id=b.id
 union all select order_token,quantity_ml from cct_internal.chicken_sauce_lots where batch_id=b.id
 union all select order_token,quantity_ml from cct_internal.gv004_allocations where batch_id=b.id
 union all select order_token,quantity from cct_internal.measured_line_allocations where kind='production' and lot_id=b.id
 )a left join public.order_commits o using(order_token);
 select coalesce(sum(u.quantity),0),least(first_use,min(u.used_on)) into tracked,first_use from public.cct_production_usage u where u.batch_id=b.id;
 select coalesce(sum(a.quantity),0),least(first_use,min(e.occurred_on)) into wasted,first_use from cct_internal.waste_allocations a join cct_internal.waste_events e on e.id=a.event_id where e.kind='production' and a.lot_id=b.id and e.voided_at is null;
 select count(*),max(l.received_on) into fifo_count,raw_date from public.cct_production_fifo_allocations a join public.cct_ingredient_lots l on l.id=a.ingredient_lot_id where a.production_batch_id=b.id;
 if p_action='inspect' then return snap||jsonb_build_object('version',ver,'protected_used',linked+tracked+wasted,'linked_used',linked,'tracked_used',tracked,'waste_used',wasted,'first_use',first_use,'raw_date',raw_date,'fifo_count',fifo_count);end if;
 if p_action<>'save' then raise exception 'invalid_action';end if;
 req:=(p_payload->>'request_id')::uuid;
 if req is null then raise exception 'Thiếu mã thao tác';end if;
 select * into prior from cct_internal.production_batch_edits a where a.id=req;
 if found then
 if prior.request_data is distinct from p_payload then raise exception 'Mã thao tác đã được dùng';end if;
 return jsonb_build_object('id',b.id,'saved',true);
 end if;
 if ver is distinct from p_payload->>'expected_version' then raise exception 'Mẻ đã thay đổi. Đóng biểu mẫu và mở lại để lấy dữ liệu mới nhất';end if;
 why:=btrim(coalesce(p_payload->>'reason',''));memo:=coalesce(p_payload->>'notes','');
 if length(why) not between 3 and 500 or length(memo)>500 then raise exception 'Nhập lý do sửa (3–500 ký tự), ghi chú tối đa 500 ký tự';end if;
 rid:=(p_payload->>'recipe_id')::bigint;q:=(p_payload->>'quantity')::numeric;usedq:=(p_payload->>'used_quantity')::numeric;dt:=(p_payload->>'produced_on')::date;st:=p_payload->>'status';
 select product_type into typ from public.cct_production_recipes where id=rid;
 if typ is null or typ not in ('sauce','prepared') then raise exception 'Chọn loại sốt hoặc nguyên liệu sơ chế';end if;
 newunit:=case when typ='sauce' then 'ml' else 'g' end;
 if q is null or usedq is null or q<=0 or q>1000000000 or usedq<0 or usedq>q or q::text in ('NaN','Infinity','-Infinity') or usedq::text in ('NaN','Infinity','-Infinity') or dt is null or st is null or st not in ('open','closed') then raise exception 'Ngày, sản lượng hoặc lượng đã dùng không hợp lệ';end if;
 if usedq<linked+tracked+wasted then raise exception 'Đã có % % gắn với đơn bán / tiêu hao / phiếu hao hụt. Không thể giảm lượng đã dùng thấp hơn mức này',linked+tracked+wasted,b.unit;end if;
 if (rid<>b.recipe_id or newunit<>b.unit) and (linked+tracked+wasted>0 or fifo_count>0) then raise exception 'Mẻ đã có phân bổ hoặc tiêu hao, không thể đổi loại vì sẽ làm sai đơn cũ. Chị tạo mẻ đúng loại riêng';end if;
 if first_use is not null and dt>first_use then raise exception 'Ngày làm không thể sau ngày đã sử dụng đầu tiên (%)',to_char(first_use,'DD/MM/YYYY');end if;
 if raw_date is not null and dt<raw_date then raise exception 'Ngày làm không thể trước ngày nhập nguyên liệu (%)',to_char(raw_date,'DD/MM/YYYY');end if;
 arr:=p_payload->'inputs';
 if arr is null or jsonb_typeof(arr)<>'array' then raise exception 'Danh sách nguyên liệu không hợp lệ';end if;
 if jsonb_array_length(arr) not between 1 and 80 then raise exception 'Cần từ 1 đến 80 nguyên liệu';end if;
 if exists(select 1 from jsonb_array_elements(arr) x where length(btrim(coalesce(x->>'name',''))) not between 1 and 150 or coalesce(x->>'unit','') not in ('g','ml','piece') or coalesce((x->>'quantity')::numeric,0)<=0 or (x->>'quantity')::numeric>1000000000 or coalesce((x->>'cost')::numeric,-1)<0 or (x->>'cost')::numeric>1000000000 or x->>'quantity' in ('NaN','Infinity','-Infinity') or x->>'cost' in ('NaN','Infinity','-Infinity')) then raise exception 'Kiểm tra tên, số lượng, đơn vị và vốn của từng nguyên liệu';end if;
 if fifo_count>0 and arr is distinct from (select jsonb_agg(jsonb_build_object('name',i.ingredient_name,'quantity',i.quantity,'unit',i.unit,'cost',i.cost) order by i.id) from public.cct_production_batch_inputs i where i.batch_id=b.id) then raise exception 'Mẻ đã trừ kho nguyên liệu FIFO. Cần đối soát phân bổ trước khi thay nguyên liệu';end if;
 select round(sum((x->>'cost')::numeric),2) into total from jsonb_array_elements(arr) x;
 if st='open' and usedq=q then raise exception 'Mẻ đã dùng hết không thể mở lại; tăng sản lượng thực tế hoặc giữ Đã kết thúc';end if;
 update public.cct_production_batches set recipe_id=rid,produced_on=dt,quantity=q,used_quantity=usedq,unit=newunit,total_cost=total,status=st,notes=memo where id=b.id returning * into saved;
 if fifo_count=0 then
 delete from public.cct_production_batch_inputs where batch_id=b.id;
 insert into public.cct_production_batch_inputs(batch_id,ingredient_name,quantity,unit,cost) select b.id,btrim(x->>'name'),(x->>'quantity')::numeric,x->>'unit',(x->>'cost')::numeric from jsonb_array_elements(arr) x;
 end if;
 -- Refresh stored costs as well as the reports which calculate from current batch cost.
 update public.cct_order_sauce_cogs set cost=round(quantity_ml*total/q,4) where batch_id=b.id;
 update cct_internal.single_sauce_lots set cost=round(quantity_ml*total/q,4) where batch_id=b.id;
 update cct_internal.chicken_sauce_lots set cost=round(quantity_ml*total/q,4) where batch_id=b.id;
 select jsonb_build_object('batch',to_jsonb(saved),'inputs',(select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]') from public.cct_production_batch_inputs i where i.batch_id=b.id)) into after_snap;
 insert into cct_internal.production_batch_edits values(req,b.id,clock_timestamp(),why,snap,after_snap,p_payload);
 return jsonb_build_object('id',b.id,'saved',true,'total_cost',total,'remaining',q-usedq);
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
 for o in select oc.order_token from public.order_commits oc
 where oc.status='completed' and exists(select 1 from jsonb_array_elements(oc.order_items) v where cct_internal.is_gv004(v))
 order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token
 loop perform cct_internal.gv004_reconcile(o.order_token);end loop;
 perform cct_internal.confirmed_line_reconcile(oc2.order_token) from public.order_commits oc2
 where exists(select 1 from cct_internal.confirmed_line_rules r where r.order_token=oc2.order_token)
 order by coalesce(oc2.pickup_date,oc2.delivery_date),oc2.created_at,oc2.order_token;
 perform cct_internal.measured_reconcile(mx.order_token) from public.order_commits mx where exists(select 1 from jsonb_array_elements(mx.order_items) v where v->>'sale_mode'='measured') or exists(select 1 from cct_internal.measured_line_state ms where ms.order_token=mx.order_token) order by coalesce(case when lower(mx.fulfilment_method) like '%pickup%' then mx.pickup_date else mx.delivery_date end,mx.delivery_date,mx.pickup_date),mx.created_at,mx.order_token;
end $function$

;
CREATE OR REPLACE FUNCTION cct_internal.combo_reconcile(p_token text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
#variable_conflict use_column
declare o public.order_commits%rowtype; it jsonb; ix int; sold date; q numeric; x record; l record; need numeric; take numeric; chosen bigint[]; got numeric; species int;
begin
 perform pg_advisory_xact_lock(321031,2);
 select * into o from public.order_commits where order_token=p_token;
 if not found then return; end if;
 sold:=coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date);
 -- Return allocations only for a changed/removed line, changed date, or reversed completion.
 for x in select a.item_index from public.cct_combo_fifo_allocations a where a.order_token=p_token group by a.item_index loop
  it:=o.order_items->x.item_index;
  q:=coalesce(nullif(it->>'qty','')::numeric,1);
  if o.status<>'completed' or sold is null or it is null or it->>'sale_mode'='measured' or
    not (coalesce(it->>'id',it->>'product_id','')='2' or lower(coalesce(it->>'name','')) like '%sứa combo%') or
    (select sum(a.grams)<>400*q or count(distinct a.ingredient_id)<>5 or bool_or(a.sale_date<>sold) from public.cct_combo_fifo_allocations a where a.order_token=p_token and a.item_index=x.item_index) then
   for l in select lot_id,sum(grams) grams from public.cct_combo_fifo_allocations where order_token=p_token and item_index=x.item_index group by lot_id order by lot_id loop
    update public.cct_ingredient_lots set remaining=remaining+l.grams where id=l.lot_id;
   end loop;
   delete from public.cct_combo_fifo_allocations where order_token=p_token and item_index=x.item_index;
  end if;
 end loop;
 if o.status<>'completed' or sold is null then return; end if;
 -- Lock the pool in a stable order, shared by every invocation.
 perform l.id from public.cct_ingredient_lots l join public.cct_ingredient_catalog c on c.id=l.ingredient_id where c.sku like 'NL-SUA-%' order by l.id for update of l;
 for it,ix in select value,(ordinality-1)::int from jsonb_array_elements(o.order_items) with ordinality loop
  if it->>'sale_mode'='measured' then continue;end if;
  if not (coalesce(it->>'id',it->>'product_id','')='2' or lower(coalesce(it->>'name','')) like '%sứa combo%') then continue; end if;
  q:=coalesce(nullif(it->>'qty','')::numeric,1);
  if q<=0 or exists(select 1 from public.cct_combo_fifo_allocations where order_token=p_token and item_index=ix) then continue; end if;
  -- Cheapest five species; price each species using its oldest available lot.
  select array_agg(z.ingredient_id order by z.unit_cost,z.ingredient_id) into chosen from (
   select h.ingredient_id,h.unit_cost from (
    select distinct on(l.ingredient_id) l.ingredient_id,l.total_cost/l.quantity unit_cost
    from public.cct_ingredient_lots l join public.cct_ingredient_catalog c on c.id=l.ingredient_id
    where c.sku like 'NL-SUA-%' and l.received_on<=sold and l.remaining>0 and l.quantity>0 and l.unit='g'
      and (select sum(v.remaining) from public.cct_ingredient_lots v where v.ingredient_id=l.ingredient_id and v.received_on<=sold and v.unit='g' and v.quantity>0 and v.remaining>0)>=80*q
    order by l.ingredient_id,l.received_on,l.id
   ) h order by h.unit_cost,h.ingredient_id limit 5
  ) z;
  if coalesce(array_length(chosen,1),0)<>5 then continue; end if;
  foreach species in array chosen loop
   need:=80*q;
   for l in select * from public.cct_ingredient_lots where ingredient_id=species and received_on<=sold and remaining>0 and quantity>0 and unit='g' order by received_on,id loop
    exit when need<=0;
    take:=least(need,l.remaining);
    insert into public.cct_combo_fifo_allocations(order_token,item_index,order_number,sale_date,lot_id,ingredient_id,grams,unit_cost,extended_cost)
      values(p_token,ix,o.order_number,sold,l.id,species,take,l.total_cost/l.quantity,round(take*l.total_cost/l.quantity,4));
    update public.cct_ingredient_lots set remaining=remaining-take where id=l.id;
    need:=need-take;
   end loop;
   if need<>0 then raise exception 'combo_fifo_concurrent_shortage'; end if;
  end loop;
 end loop;
end $function$
;
create or replace function cct_internal.measured_source_guard() returns trigger language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare k text:=case when tg_table_name='cct_ingredient_lots' then 'ingredient' else 'production' end;q numeric;first_date date;
begin
 select sum(a.quantity),min(s.sale_date) into q,first_date from cct_internal.measured_line_allocations a join cct_internal.measured_line_state s using(order_token,item_index) where a.kind=k and a.lot_id=old.id;
 if q is null then return coalesce(new,old);end if;
 if tg_op='DELETE' then raise exception 'Lô/mẻ đã có phân bổ bán theo gram/ml; sửa hoặc hủy dòng bán trước khi xóa nguồn';end if;
 if new.id<>old.id or new.unit<>old.unit or new.quantity<q then raise exception 'Lô/mẻ phải giữ mã, đơn vị và đủ lượng đã bán theo gram/ml';end if;
 if k='ingredient' then
  if new.ingredient_id is distinct from old.ingredient_id or new.received_on>first_date then raise exception 'Không thể đổi nguyên liệu hoặc ngày nhập sau ngày đã bán theo gram/ml';end if;
 else
  if new.recipe_id is distinct from old.recipe_id or new.produced_on>first_date or new.used_quantity<q then raise exception 'Thông tin mẻ mâu thuẫn với lượng đã bán theo gram/ml';end if;
 end if;
 return new;
end $$;
revoke all on function cct_internal.measured_source_guard() from public,anon,authenticated;
drop trigger if exists cct_measured_source_guard on public.cct_ingredient_lots;
create trigger cct_measured_source_guard before delete or update on public.cct_ingredient_lots for each row execute function cct_internal.measured_source_guard();
drop trigger if exists cct_measured_source_guard on public.cct_production_batches;
create trigger cct_measured_source_guard before delete or update on public.cct_production_batches for each row execute function cct_internal.measured_source_guard();
notify pgrst,'reload schema';
commit;