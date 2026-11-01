-- Applied 2026-11-01. Menu controls preserve physical stock; preorder items record stock_deducted=false.
CREATE OR REPLACE FUNCTION public.cct_stock_count_list_v1(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare h text; result jsonb;
begin
  select pass_hash into h from public.print_admin_access where id=1;
  if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'::text),'hex') <> h then
    raise exception 'not_authorized';
  end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb) into result
  from (select id,sku,name,category,categories,stock_qty,is_active,cost_only,updated_at from public.products) t;
  return result;
end $function$
;
create or replace function public.cct_stock_menu_save_v1(p_passcode text,p_product_id bigint,p_expected_updated_at timestamptz,p_preorder boolean default null,p_visible boolean default null)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare h text; p public.products%rowtype; cats text[]; base text;
begin
select pass_hash into h from public.print_admin_access where id=1;
if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'::text),'hex') <> h then raise exception 'not_authorized'; end if;
if p_preorder is null and p_visible is null then raise exception 'no_changes'; end if;
select * into p from public.products where id=p_product_id for update;
if not found then raise exception 'product_not_found'; end if;
if p.updated_at is distinct from p_expected_updated_at then raise exception 'product_changed_reload'; end if;
if p_visible is true and p.cost_only then raise exception 'cost_only_product'; end if;
if p_preorder is false and p.stock_qty=0 then raise exception 'zero_stock_use_preorder'; end if;
cats:=coalesce(p.categories,array[]::text[]); base:=p.category;
if p_preorder is not null then
 cats:=array_remove(cats,'dattruoc');
 if base='dattruoc' then
  base:=coalesce((select c from unnest(cats) c where c<>'dattruoc' limit 1),
   case split_part(p.sku,'-',1) when 'BT' then 'banhtrang' when 'KH' then 'kho' when 'MM' then 'mam' when 'TC' then 'traicaysay' when 'SU' then 'sua' when 'HS' then 'haisan' else 'khac' end);
 end if;
 if coalesce(array_length(cats,1),0)=0 then cats:=array[coalesce(base,'khac')]; end if;
 if p_preorder then cats:=array_append(cats,'dattruoc'); end if;
end if;
update public.products set category=base,categories=cats,is_active=coalesce(p_visible,is_active),updated_at=clock_timestamp() where id=p.id;
update public.products_draft d set category=q.category,categories=q.categories,is_active=q.is_active,updated_at=q.updated_at from public.products q where q.id=p.id and d.id=q.id;
return (select to_jsonb(t) from (select id,sku,name,category,categories,stock_qty,is_active,cost_only,updated_at from public.products where id=p.id)t);
end $$;
revoke all on function public.cct_stock_menu_save_v1(text,bigint,timestamptz,boolean,boolean) from public;
grant execute on function public.cct_stock_menu_save_v1(text,bigint,timestamptz,boolean,boolean) to anon,authenticated;
CREATE OR REPLACE FUNCTION public.commit_order_stock(p_order_token text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  item jsonb;
  product_id bigint;
  requested_qty integer;
  current_stock integer;
  current_name text;
  current_active boolean;
  v_order_number text;
  committed_items jsonb := '[]'::jsonb;
begin
  if p_order_token is null or length(trim(p_order_token)) < 8 then
    raise exception 'invalid_order_token';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'empty_order';
  end if;

  select order_number
    into v_order_number
  from public.order_commits
  where order_token=p_order_token;

  if found then
    return jsonb_build_object(
      'ok',true,
      'duplicate',true,
      'order_number',v_order_number
    );
  end if;

  for item in select * from jsonb_array_elements(p_items)
  loop
    product_id := (item->>'id')::bigint;
    requested_qty := (item->>'qty')::integer;

    if product_id is null or requested_qty is null or requested_qty <= 0 then
      raise exception 'invalid_item';
    end if;

    select case when category='dattruoc' or 'dattruoc'=any(coalesce(categories,'{}'::text[])) then null else stock_qty end,name,is_active
      into current_stock,current_name,current_active
    from public.products
    where id=product_id
    for update;

    if not found or current_active is not true then
      raise exception 'product_unavailable';
    end if;

    if current_stock is not null and current_stock < requested_qty then
      raise exception 'insufficient_stock:%:%:%', product_id, current_name, current_stock;
    end if;

    if current_stock is not null then
      update public.products
      set stock_qty = stock_qty - requested_qty,
          updated_at = now()
      where id=product_id;

      update public.products_draft
      set stock_qty = greatest(coalesce(stock_qty,current_stock) - requested_qty,0),
          updated_at = now()
      where id=product_id;
    end if;
    committed_items := committed_items || jsonb_build_array(item || jsonb_build_object('stock_deducted',current_stock is not null));
  end loop;

  insert into public.order_commits(order_token,items)
  values(p_order_token,committed_items)
  returning order_number into v_order_number;

  return jsonb_build_object(
    'ok',true,
    'duplicate',false,
    'order_number',v_order_number
  );
end;
$function$
;CREATE OR REPLACE FUNCTION public.update_order_items_v1(p_passcode text, p_order_token text, p_items jsonb)
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
  new_qty integer;
  current_stock integer;
  product_name text;
  product_price numeric;
  option_text text;
  normalized_items jsonb := '[]'::jsonb;
  stock_items jsonb := '[]'::jsonb;
  subtotal_value numeric := 0;
  delivery_value numeric;
  fulfil text;
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
  then
    raise exception 'empty_order';
  end if;

  select items, delivery_fee, fulfilment_method
  into old_items, delivery_value, fulfil
  from public.order_commits
  where order_token=p_order_token
  for update;

  if not found then
    raise exception 'order_not_found';
  end if;

  old_items := coalesce(old_items,'[]'::jsonb);

  -- Return previously committed finite stock first.
  for old_item in select * from jsonb_array_elements(old_items)
  loop
    product_id := (old_item->>'id')::bigint;
    old_qty := greatest(coalesce((old_item->>'qty')::integer,0),0);

    select stock_qty
    into current_stock
    from public.products
    where id=product_id
    for update;

    if found and current_stock is not null and old_qty > 0 and old_item->>'stock_deducted' is distinct from 'false' then
      update public.products
      set stock_qty = stock_qty + old_qty,
          updated_at = now()
      where id=product_id;

      update public.products_draft d
      set stock_qty = p.stock_qty,
          updated_at = now()
      from public.products p
      where d.id=product_id and p.id=product_id;
    end if;
  end loop;

  -- Validate and deduct new stock, building authoritative order rows.
  for new_item in select * from jsonb_array_elements(p_items)
  loop

    -- Manual items are order-only and never participate in stock bookkeeping.
    if new_item->>'is_custom' = 'true' then
      if coalesce(new_item->>'qty','') !~ '^[1-9][0-9]{0,4}$'
         or coalesce(new_item->>'unit_price','') !~ '^[0-9]{1,7}([.][0-9]{1,2})?$' then
        raise exception 'invalid_custom_item';
      end if;
      qty := (new_item->>'qty')::integer;
      product_name := btrim(coalesce(new_item->>'name',''));
      product_price := (new_item->>'unit_price')::numeric;
      option_text := left(coalesce(new_item->>'option_text',''),500);
      if length(product_name)=0 or length(product_name)>200
         or product_price<0 or product_price>1000000 then
        raise exception 'invalid_custom_item';
      end if;
      normalized_items := normalized_items || jsonb_build_array(
        jsonb_build_object('id',null,'is_custom',true,'qty',qty,
          'name',product_name,'unit_price',product_price,
          'line_total',product_price*qty,'option_text',option_text,'options','[]'::jsonb)
      );
      subtotal_value := subtotal_value + product_price*qty;
      continue;
    end if;

    product_id := (new_item->>'id')::bigint;
    qty := (new_item->>'qty')::integer;
    option_text := left(coalesce(new_item->>'option_text',''),500);

    if product_id is null or qty is null or qty <= 0 then
      raise exception 'invalid_item';
    end if;

    select name,price,case when category='dattruoc' or 'dattruoc'=any(coalesce(categories,'{}'::text[])) then null else stock_qty end
    into product_name,product_price,current_stock
    from public.products
    where id=product_id and (is_active=true or cost_only=true)
    for update;

    if not found then
      raise exception 'product_unavailable:%', product_id;
    end if;

    if current_stock is not null and current_stock < qty then
      raise exception 'insufficient_stock:%:%:%', product_id, product_name, current_stock;
    end if;

    if current_stock is not null then
      update public.products
      set stock_qty = stock_qty - qty,
          updated_at = now()
      where id=product_id;

      update public.products_draft d
      set stock_qty = p.stock_qty,
          updated_at = now()
      from public.products p
      where d.id=product_id and p.id=product_id;
    end if;

    subtotal_value := subtotal_value + (product_price * qty);

    normalized_items := normalized_items || jsonb_build_array(
      jsonb_build_object(
        'id',product_id,
        'qty',qty,
        'name',product_name,
        'unit_price',product_price,
        'line_total',product_price*qty,
        'option_text',option_text,
        'options','[]'::jsonb
      )
    );

    stock_items := stock_items || jsonb_build_array(
      jsonb_build_object('id',product_id,'qty',qty,'stock_deducted',current_stock is not null)
    );
  end loop;

  update public.order_commits
  set items = stock_items,
      order_items = normalized_items,
      subtotal = subtotal_value,
      total = case
        when fulfil in ('delivery','auspost') then
          case when delivery_value is null then null else subtotal_value + delivery_value end
        else subtotal_value
      end,
      updated_at = now()
  where order_token=p_order_token
  returning to_jsonb(public.order_commits.*) into rowdata;

  return rowdata;
end;
$function$
;CREATE OR REPLACE FUNCTION public.update_order_items_v3(p_passcode text, p_order_token text, p_items jsonb)
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
        )
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