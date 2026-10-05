-- Atomic admin-only manual orders. Uses the existing item/stock validator.
create or replace function public.create_manual_order_v1(
  p_passcode text, p_order_token text, p_items jsonb, p_details jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  h text; existing public.order_commits%rowtype; saved public.order_commits%rowtype;
  method text; name_value text; phone_value text; address_value text;
  fee numeric; item jsonb; text_value text; shipping boolean;
  resend_key text; req_id bigint; email_error text;
begin
  select pass_hash into h from public.print_admin_access where id=1;
  if h is null or encode(extensions.digest('cct-print-v1-20260924'||coalesce(p_passcode,''),'sha256'),'hex')<>h then
    raise exception 'not_authorized';
  end if;
  if coalesce(p_order_token,'') !~ '^manual-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'invalid_order_token';
  end if;
  -- Serialize retries, including concurrent requests, before deducting any stock.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_order_token,0));
  select * into existing from public.order_commits where order_token=p_order_token for update;
  if not found then
    if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>50 then
      raise exception 'invalid_items';
    end if;
    for item in select * from jsonb_array_elements(p_items) loop
      if coalesce(item->>'qty','') !~ '^[1-9][0-9]{0,4}$' then raise exception 'invalid_quantity'; end if;
    end loop;
    if p_details is null or jsonb_typeof(p_details)<>'object' then raise exception 'invalid_details'; end if;
    name_value:=btrim(coalesce(p_details->>'customer_name',''));
    phone_value:=btrim(coalesce(p_details->>'phone',''));
    method:=coalesce(p_details->>'fulfilment_method','');
    address_value:=btrim(coalesce(p_details->>'shipping_address',''));
    if length(name_value)<1 or length(name_value)>200 then raise exception 'customer_name_required'; end if;
    if length(phone_value)>40 or length(regexp_replace(phone_value,'[^0-9]','','g')) not between 8 and 15 then raise exception 'invalid_phone'; end if;
    if method not in ('pickup','delivery','auspost') then raise exception 'invalid_fulfilment'; end if;
    if method<>'pickup' and (length(address_value)<3 or length(address_value)>1000) then raise exception 'shipping_address_required'; end if;
    if length(coalesce(p_details->>'customer_note',''))>1000 or length(coalesce(p_details->>'recipient_name',''))>200
       or coalesce(p_details->>'payment_method','Cash') not in ('Cash','PayID','Bank Transfer') then raise exception 'invalid_details'; end if;
    if method='pickup' then fee:=0;
    elsif nullif(btrim(coalesce(p_details->>'delivery_fee','')),'') is null then fee:=null;
    else
      if (p_details->>'delivery_fee') !~ '^[0-9]{1,6}([.][0-9]{1,2})?$' then raise exception 'invalid_delivery_fee'; end if;
      fee:=(p_details->>'delivery_fee')::numeric;
    end if;
    insert into public.order_commits(order_token,items,customer_name,phone,fulfilment_method,
      shipping_address,recipient_name,pickup_date,pickup_time,payment_method,customer_note,
      subtotal,delivery_fee,language)
    values(p_order_token,'[]',name_value,phone_value,method,
      case when method='pickup' then null else address_value end,
      nullif(btrim(coalesce(p_details->>'recipient_name','')),''),
      case when method='pickup' then nullif(p_details->>'pickup_date','')::date else null end,
      case when method='pickup' then nullif(p_details->>'pickup_time','')::time else null end,
      coalesce(p_details->>'payment_method','Cash'),nullif(btrim(coalesce(p_details->>'customer_note','')),''),0,fee,'vi');
    -- If any item is invalid or lacks stock, this whole request rolls back.
    perform public.update_order_items_v1(p_passcode,p_order_token,p_items);
    select * into saved from public.order_commits where order_token=p_order_token;
    text_value:=saved.customer_name;
    for item in select * from jsonb_array_elements(saved.order_items) loop
      text_value:=text_value||E'\n'||(item->>'qty')||' x '||regexp_replace(item->>'name',E'[\r\n]+',' ','g')||
        case when coalesce(item->>'option_text','')<>'' then ' ('||regexp_replace(item->>'option_text',E'[\r\n]+',' ','g')||')' else '' end||
        ' $'||regexp_replace(item->>'line_total','\.00$','');
    end loop;
    text_value:=text_value||
      case when method<>'pickup' and fee is null then E'\nTạm tính: $'||regexp_replace(saved.subtotal::text,'\.00$','')
        else E'\nTổng: $'||regexp_replace(saved.total::text,'\.00$','') end||
      E'\nNhận hàng: '||case method when 'pickup' then 'Pick up Springvale' when 'delivery' then 'Delivery Melbourne' else 'AusPost' end;
    if saved.pickup_date is not null then text_value:=text_value||E'\nNgày pick up: '||to_char(saved.pickup_date,'DD/MM/YY'); end if;
    if saved.pickup_time is not null then text_value:=text_value||E'\nGiờ pick up: '||left(saved.pickup_time::text,5); end if;
    if method<>'pickup' then
      text_value:=text_value||E'\nPhí giao hàng: '||case when fee is null then 'Chờ báo giá' else '$'||regexp_replace(fee::text,'\.00$','') end||
        E'\nĐịa chỉ: '||saved.shipping_address;
    end if;
    if saved.recipient_name is not null then text_value:=text_value||E'\nTên người nhận: '||saved.recipient_name; end if;
    text_value:=text_value||E'\nSđt: '||saved.phone||
      E'\nGhi chú: '||coalesce(nullif(saved.customer_note,'Không có'),'');
    if length(text_value)>10000 then raise exception 'order_text_too_long'; end if;
    update public.order_commits set order_text=text_value where order_token=p_order_token;
  end if;
  select * into saved from public.order_commits where order_token=p_order_token for update;
  -- pg_net sends only after transaction commit. A queued email is never queued twice.
  if saved.email_queued_at is null then
    begin
      select decrypted_secret into resend_key from vault.decrypted_secrets where name='resend_api_key' limit 1;
      if nullif(resend_key,'') is null then raise exception 'email_not_configured'; end if;
      select net.http_post(
        url:='https://api.resend.com/emails',
        headers:=jsonb_build_object('Authorization','Bearer '||resend_key,'Content-Type','application/json',
          'Idempotency-Key','cct-'||p_order_token),
        body:=jsonb_build_object('from','Có Cái Tiệm <onboarding@resend.dev>',
          'to',jsonb_build_array('daohaibinh82@gmail.com'),
          'subject','Đơn mới - Có Cái Tiệm - '||saved.order_number||' - '||regexp_replace(saved.customer_name,E'[\r\n]+',' ','g'),
          'text',saved.order_text)
      ) into req_id;
      update public.order_commits set email_request_id=req_id,email_queued_at=now() where order_token=p_order_token;
    exception when others then
      email_error:='Không xếp hàng gửi email được. Đơn đã lưu; có thể thử lại mà không tạo trùng.';
    end;
  end if;
  select * into saved from public.order_commits where order_token=p_order_token;
  return jsonb_build_object('order',to_jsonb(saved),'duplicate',existing.order_token is not null,
    'email_queued',saved.email_queued_at is not null,'email_error',email_error);
end;
$$;
revoke all on function public.create_manual_order_v1(text,text,jsonb,jsonb) from public;
grant execute on function public.create_manual_order_v1(text,text,jsonb,jsonb) to anon,authenticated;

