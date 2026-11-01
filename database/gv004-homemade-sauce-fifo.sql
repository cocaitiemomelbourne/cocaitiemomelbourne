
create table cct_internal.gv004_state(
 order_token text not null,item_index integer not null,qty numeric not null,sale_date date,
 primary key(order_token,item_index));
create table cct_internal.gv004_allocations(
 order_token text not null,item_index integer not null,batch_id bigint not null references public.cct_production_batches(id),
 quantity_ml numeric not null check(quantity_ml>0),primary key(order_token,item_index,batch_id));
create table cct_internal.gv004_reversals(
 id bigint generated always as identity primary key,order_token text,item_index integer,batch_id bigint,quantity_ml numeric,created_at timestamptz default now());
alter table cct_internal.gv004_state enable row level security;
alter table cct_internal.gv004_allocations enable row level security;
alter table cct_internal.gv004_reversals enable row level security;
revoke all on cct_internal.gv004_state,cct_internal.gv004_allocations,cct_internal.gv004_reversals from public,anon,authenticated;
create function cct_internal.is_gv004(item jsonb) returns boolean language sql stable set search_path=pg_catalog,public as $$
 select coalesce(item->>'id',item->>'product_id','') in(select id::text from public.products where sku='GV-004')
 or lower(trim(coalesce(item->>'name',''))) in('sốt thái đỏ','sot thai do');
$$;
create function cct_internal.gv004_reconcile(token text) returns void language plpgsql security definer
set search_path=pg_catalog,public,cct_internal as $$
declare o record;s record;a record;i record;b record;q numeric;d date;need numeric;take numeric;
begin
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 select * into o from public.order_commits where order_token=token;
 if not found then return;end if;
 d:=coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date);
 for s in select * from cct_internal.gv004_state where order_token=token loop
  if o.status<>'completed' or not coalesce(cct_internal.is_gv004(o.order_items->s.item_index),false)
    or coalesce((o.order_items->s.item_index->>'qty')::numeric,1) is distinct from s.qty or d is distinct from s.sale_date then
   for a in select * from cct_internal.gv004_allocations where order_token=token and item_index=s.item_index loop
    update public.cct_production_batches set used_quantity=used_quantity-a.quantity_ml,
      status=case when status='closed' then 'open' else status end where id=a.batch_id;
    insert into cct_internal.gv004_reversals(order_token,item_index,batch_id,quantity_ml) values(token,s.item_index,a.batch_id,a.quantity_ml);
   end loop;
   delete from cct_internal.gv004_allocations where order_token=token and item_index=s.item_index;
   delete from cct_internal.gv004_state where order_token=token and item_index=s.item_index;
  end if;
 end loop;
 if o.status<>'completed' then return;end if;
 for i in select value item,(ordinality-1)::integer ix from jsonb_array_elements(o.order_items) with ordinality where cct_internal.is_gv004(value) loop
  q:=coalesce((i.item->>'qty')::numeric,1);if q<=0 then continue;end if;
  insert into cct_internal.gv004_state values(token,i.ix,q,d) on conflict do nothing;
  -- Adopt historical sauce allocations without consuming the batch again.
  for a in select * from public.cct_order_sauce_cogs where order_token=token and item_index=i.ix and sauce_sku='SOT-THAI' for update loop
   insert into cct_internal.gv004_allocations values(token,i.ix,a.batch_id,a.quantity_ml)
    on conflict(order_token,item_index,batch_id) do update set quantity_ml=gv004_allocations.quantity_ml+excluded.quantity_ml;
   delete from public.cct_order_sauce_cogs where order_token=token and item_index=i.ix and sauce_sku='SOT-THAI';
  end loop;
  need:=200*q-coalesce((select sum(quantity_ml) from cct_internal.gv004_allocations where order_token=token and item_index=i.ix),0);
  if d is null or need<=0 then continue;end if;
  for b in select pb.* from public.cct_production_batches pb join public.cct_production_recipes r on r.id=pb.recipe_id
   where r.sku='SOT-THAI' and pb.unit='ml' and pb.status='open' and pb.produced_on<=d and pb.quantity>pb.used_quantity
   order by pb.produced_on,pb.id for update of pb loop
   take:=least(need,b.quantity-b.used_quantity);
   update public.cct_production_batches set used_quantity=used_quantity+take,status=case when used_quantity+take>=quantity then 'closed' else status end where id=b.id;
   insert into cct_internal.gv004_allocations values(token,i.ix,b.id,take)
    on conflict(order_token,item_index,batch_id) do update set quantity_ml=gv004_allocations.quantity_ml+excluded.quantity_ml;
   need:=need-take;exit when need<=0;
  end loop;
 end loop;
end $$;
create function cct_internal.gv004_lock() returns trigger language plpgsql security definer
set search_path=pg_catalog,public,cct_internal as $$
begin
 if exists(select 1 from jsonb_array_elements(new.order_items) v where cct_internal.is_gv004(v))
 or exists(select 1 from cct_internal.gv004_state where order_token=new.order_token) then
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);end if;
 return new;
end $$;
create function cct_internal.gv004_order_trigger() returns trigger language plpgsql security definer
set search_path=pg_catalog,public,cct_internal as $$
begin
 if exists(select 1 from jsonb_array_elements(new.order_items) v where cct_internal.is_gv004(v))
 or exists(select 1 from cct_internal.gv004_state where order_token=new.order_token) then perform cct_internal.gv004_reconcile(new.order_token);end if;
 return null;
end $$;
create trigger aaa_cct_gv004_lock before insert or update of status,order_items,pickup_date,delivery_date,fulfilment_method on public.order_commits for each row execute function cct_internal.gv004_lock();
create trigger cct_gv004_auto after insert or update of status,order_items,pickup_date,delivery_date,fulfilment_method on public.order_commits for each row execute function cct_internal.gv004_order_trigger();
create constraint trigger zz_cct_sales_cost_revision after insert or update or delete on cct_internal.gv004_allocations deferrable initially deferred for each row execute function cct_internal.sales_cost_changed();
create function public.cct_gv004_cost_report_v1(p_passcode text) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,cct_internal as $$
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('order_token',s.order_token,'item_index',s.item_index,
 'cost',coalesce(a.cost,0),'quantity_ml',coalesce(a.ml,0),
 'missing',case when s.sale_date is null then jsonb_build_array('Thiếu ngày nhận hàng')
 when coalesce(a.ml,0)<200*s.qty then jsonb_build_array('Sốt Thái Đỏ: thiếu '||(200*s.qty-coalesce(a.ml,0))||'ml từ mẻ hợp lệ theo ngày bán') else '[]'::jsonb end)),'[]'::jsonb)
 from cct_internal.gv004_state s join public.order_commits o on o.order_token=s.order_token and o.status='completed'
 left join lateral(select sum(x.quantity_ml) ml,sum(round(x.quantity_ml*b.total_cost/nullif(b.quantity,0),4)) cost from cct_internal.gv004_allocations x join public.cct_production_batches b on b.id=x.batch_id where x.order_token=s.order_token and x.item_index=s.item_index) a on true);
end $$;
revoke all on function cct_internal.is_gv004(jsonb),cct_internal.gv004_reconcile(text),cct_internal.gv004_lock(),cct_internal.gv004_order_trigger() from public,anon,authenticated;
revoke all on function public.cct_gv004_cost_report_v1(text) from public;
grant execute on function public.cct_gv004_cost_report_v1(text) to anon,authenticated;
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
end $function$
;
select cct_internal.refresh_pending_food_costs();