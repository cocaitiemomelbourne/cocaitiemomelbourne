-- Persist menu prices at stock commit; keep snapshots when order details omit prices.
begin;
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
    priced_items:=priced_items||jsonb_build_array(jsonb_build_object('id',product_id,'qty',requested_qty,'name',current_name,'option_text',left(coalesce(item->>'option_text',''),500),'unit_price',current_price,'menu_price',current_price,'line_total',round(current_price*requested_qty,2),'options','[]'::jsonb));
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
CREATE OR REPLACE FUNCTION public.save_order_full_v1(p_order_token text, p_customer_name text, p_order_text text, p_details jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  updated_count integer;
  created_ts timestamptz;
  order_no text;
  prior_items jsonb;
begin
  select created_at, order_number, order_items
  into created_ts, order_no, prior_items
  from public.order_commits
  where order_token=p_order_token
  for update;

  if not found then
    return false;
  end if;

  if order_no is null then
    order_no := 'CCT-' || to_char(created_ts at time zone 'Australia/Melbourne','YYMMDD-HH24MISS') || '-' || upper(substr(md5(p_order_token),1,4));
  end if;

  update public.order_commits
  set customer_name = left(coalesce(p_customer_name,''),200),
      order_text = left(coalesce(p_order_text,''),10000),
      order_number = order_no,
      phone = left(coalesce(p_details->>'phone',''),80),
      fulfilment_method = left(coalesce(p_details->>'fulfilment_method',''),40),
      pickup_date = case
        when nullif(p_details->>'pickup_date','') is null then null
        else (p_details->>'pickup_date')::date
      end,
      pickup_time = case
        when nullif(p_details->>'pickup_time','') is null then null
        else (p_details->>'pickup_time')::time
      end,
      recipient_name = left(coalesce(p_details->>'recipient_name',''),200),
      shipping_address = left(coalesce(p_details->>'shipping_address',''),500),
      payment_method = left(coalesce(p_details->>'payment_method',''),40),
      customer_note = left(coalesce(p_details->>'customer_note',''),1000),
      subtotal = case when nullif(p_details->>'subtotal','') is null then null else (p_details->>'subtotal')::numeric end,
      delivery_fee = case when nullif(p_details->>'delivery_fee','') is null then null else (p_details->>'delivery_fee')::numeric end,
      total = case when nullif(p_details->>'total','') is null then null else (p_details->>'total')::numeric end,
      language = left(coalesce(p_details->>'language','vi'),10),
      order_items = case
        when jsonb_typeof(p_details->'order_items')='array' and jsonb_array_length(p_details->'order_items')>0 then
          (select jsonb_agg(coalesce(
            (select old_row from jsonb_array_elements(coalesce(prior_items,'[]'::jsonb)) old_row
             where nullif(incoming.value->>'unit_price','') is null and nullif(incoming.value->>'line_total','') is null
               and old_row->>'id'=incoming.value->>'id'
               and old_row->>'qty'=incoming.value->>'qty'
               and coalesce(old_row->>'option_text','')=coalesce(incoming.value->>'option_text','')
             and (select count(*) from jsonb_array_elements(coalesce(prior_items,'[]'::jsonb)) match_row where match_row->>'id'=incoming.value->>'id' and match_row->>'qty'=incoming.value->>'qty' and coalesce(match_row->>'option_text','')=coalesce(incoming.value->>'option_text',''))=1
             limit 1),'{}'::jsonb)||jsonb_strip_nulls(incoming.value) order by incoming.ordinality)
           from jsonb_array_elements(p_details->'order_items') with ordinality incoming)
        else prior_items
      end,
      updated_at = now()
  where order_token=p_order_token;

  get diagnostics updated_count = row_count;
  return updated_count > 0;
end;
$function$
;
create table if not exists cct_internal.order_price_repair_audit(order_token text primary key,before_items jsonb not null,after_items jsonb not null,reason text not null,changed_at timestamptz default now());
alter table cct_internal.order_price_repair_audit enable row level security;
revoke all on cct_internal.order_price_repair_audit from public,anon,authenticated;
do $$
declare o public.order_commits%rowtype;patched jsonb;
begin
 select * into o from public.order_commits where order_number='CCT-000356' for update;
 if not found then raise exception 'Order 356 missing';end if;
 if exists(select 1 from cct_internal.order_price_repair_audit where order_token=o.order_token) then return;end if;
 if o.subtotal<>85 or jsonb_array_length(o.order_items)<>2 or o.order_items->0->>'id'<>'40' or o.order_items->0->>'qty'<>'2' or o.order_items->1->>'id'<>'39' or o.order_items->1->>'qty'<>'1' or position('(Sứa Đạn) $70' in o.order_text)=0 or position('Sốt XO $15' in o.order_text)=0 then raise exception 'Order changed; review before restoring prices';end if;
 patched:=jsonb_set(o.order_items,'{0}',o.order_items->0||jsonb_build_object('unit_price',35,'line_total',70));
 patched:=jsonb_set(patched,'{1}',o.order_items->1||jsonb_build_object('unit_price',15,'line_total',15));
 insert into cct_internal.order_price_repair_audit(order_token,before_items,after_items,reason) values(o.order_token,o.order_items,patched,'Restore exact historical prices from order text: 2 x $35 = $70; 1 x $15 = $15. Subtotal $85 unchanged.');
 update public.order_commits set order_items=patched,updated_at=clock_timestamp() where order_token=o.order_token;
end $$;
commit;
