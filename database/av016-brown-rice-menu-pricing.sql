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
  current_price numeric;
  final_price numeric;
  chosen_components jsonb;
  priced_items jsonb := '[]'::jsonb;
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

    select case when category='dattruoc' or 'dattruoc'=any(coalesce(categories,'{}'::text[])) then null else stock_qty end,name,is_active,price
      into current_stock,current_name,current_active,current_price
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
    if current_price is null or current_price<0 then raise exception 'product_price_unavailable:%',product_id;end if;
    final_price:=current_price;
    if product_id=142 then
      chosen_components:=cct_internal.crispy_rice_cost_item(item)->'cost_components';
      if jsonb_array_length(chosen_components)>=6 then
        final_price:=current_price+2*(jsonb_array_length(chosen_components)-6);
        if exists(select 1 from jsonb_array_elements(chosen_components) c where c->>'source_id'='27' and c->>'kind'='ingredient')
           and not exists(select 1 from jsonb_array_elements(chosen_components) c where c->>'source_id'='26' and c->>'kind'='ingredient') then
          final_price:=final_price+2;
        end if;
      end if;
    end if;
    priced_items:=priced_items||jsonb_build_array(jsonb_build_object('id',product_id,'qty',requested_qty,'name',current_name,'option_text',left(coalesce(item->>'option_text',''),500),'unit_price',final_price,'menu_price',current_price,'line_total',round(final_price*requested_qty,2),'options','[]'::jsonb));
    committed_items := committed_items || jsonb_build_array(item || jsonb_build_object('stock_deducted',current_stock is not null));
  end loop;

  insert into public.order_commits(order_token,items,order_items)
  values(p_order_token,committed_items,priced_items)
  returning order_number into v_order_number;

  return jsonb_build_object(
    'ok',true,
    'duplicate',false,
    'order_number',v_order_number
  );
end;
$function$
;
update public.products set price=12,option_groups=jsonb_set(option_groups::jsonb,'{0,choices,1}','"Cơm cháy gạo lứt (+$2)"'::jsonb),option_groups_en=jsonb_set(option_groups_en::jsonb,'{0,choices,1}','"Brown rice crisps (+$2)"'::jsonb),description=replace(description,'Chọn cả hai loại','Chọn cơm cháy gạo lứt thêm $2. Chọn cả hai loại'),description_en=replace(description_en,'Both choices','Brown rice crisps add $2. Both choices'),updated_at=now() where id=142 and sku='AV-016';
update public.products_draft set price=12,option_groups=jsonb_set(option_groups::jsonb,'{0,choices,1}','"Cơm cháy gạo lứt (+$2)"'::jsonb),option_groups_en=jsonb_set(option_groups_en::jsonb,'{0,choices,1}','"Brown rice crisps (+$2)"'::jsonb),description=replace(description,'Chọn cả hai loại','Chọn cơm cháy gạo lứt thêm $2. Chọn cả hai loại'),description_en=replace(description_en,'Both choices','Brown rice crisps add $2. Both choices'),updated_at=now() where id=142 and name ilike '%cháy%topping%';