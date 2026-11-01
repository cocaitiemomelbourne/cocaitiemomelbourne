create table if not exists cct_internal.confirmed_line_rules(
 order_token text not null references public.order_commits(order_token),item_index integer not null,
 rule_key text not null,display_name text not null,display_sku text not null,requirements jsonb not null,
 approval text not null,applied_signature text,primary key(order_token,item_index));
create table if not exists cct_internal.confirmed_line_allocations(
 order_token text not null,item_index integer not null,lot_id bigint not null references public.cct_ingredient_lots(id),
 quantity numeric not null check(quantity>0),primary key(order_token,item_index,lot_id),
 foreign key(order_token,item_index) references cct_internal.confirmed_line_rules(order_token,item_index));
alter table cct_internal.confirmed_line_rules enable row level security;
alter table cct_internal.confirmed_line_allocations enable row level security;
revoke all on cct_internal.confirmed_line_rules,cct_internal.confirmed_line_allocations from public,anon,authenticated;
create or replace function cct_internal.confirmed_line_reconcile(token text) returns void language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare o public.order_commits%rowtype;r record;alloc_row record;lot_row record;c jsonb;it jsonb;d date;q numeric;sig text;actual numeric;need numeric;take numeric;
begin
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 select * into o from public.order_commits where order_token=token;if not found then return;end if;
 d:=coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date);
 for r in select * from cct_internal.confirmed_line_rules where order_token=token order by item_index loop
  it:=o.order_items->r.item_index;q:=coalesce(nullif(it->>'qty','')::numeric,0);
  sig:=case when o.status='completed' and q>0 and d is not null and it->>'confirmed_component_rule'=r.rule_key then d::text||':'||q::text||':'||r.requirements::text else null end;
  if sig is distinct from r.applied_signature then
   for alloc_row in select * from cct_internal.confirmed_line_allocations where order_token=token and item_index=r.item_index loop
    update public.cct_ingredient_lots set remaining=remaining+alloc_row.quantity where id=alloc_row.lot_id;
   end loop;
   delete from cct_internal.confirmed_line_allocations where order_token=token and item_index=r.item_index;
   update cct_internal.confirmed_line_rules set applied_signature=sig where order_token=token and item_index=r.item_index;
  end if;
  if sig is null then continue;end if;
  for c in select value from jsonb_array_elements(r.requirements) loop
   select coalesce(sum(a.quantity),0) into actual from cct_internal.confirmed_line_allocations a join public.cct_ingredient_lots l on l.id=a.lot_id where a.order_token=token and a.item_index=r.item_index and l.ingredient_id=(c->>'ingredient_id')::bigint;
   need:=(c->>'per_unit')::numeric*q-actual;
   if need<=0 then continue;end if;
   for lot_row in select * from public.cct_ingredient_lots where ingredient_id=(c->>'ingredient_id')::bigint and unit=c->>'unit' and received_on<=d and remaining>0 and quantity>0 order by received_on,id for update loop
    exit when need<=0;take:=least(need,lot_row.remaining);
    insert into cct_internal.confirmed_line_allocations values(token,r.item_index,lot_row.id,take) on conflict(order_token,item_index,lot_id) do update set quantity=confirmed_line_allocations.quantity+excluded.quantity;
    update public.cct_ingredient_lots set remaining=remaining-take where id=lot_row.id;need:=need-take;
   end loop;
  end loop;
 end loop;
end $$;
revoke all on function cct_internal.confirmed_line_reconcile(text) from public,anon,authenticated;
create or replace function cct_internal.confirmed_line_order_trigger() returns trigger language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
begin if exists(select 1 from cct_internal.confirmed_line_rules where order_token=new.order_token) then perform cct_internal.confirmed_line_reconcile(new.order_token);end if;return new;end $$;
revoke all on function cct_internal.confirmed_line_order_trigger() from public,anon,authenticated;
drop trigger if exists cct_confirmed_line_fifo on public.order_commits;
create trigger cct_confirmed_line_fifo after insert or update of status,order_items,pickup_date,delivery_date,fulfilment_method on public.order_commits for each row execute function cct_internal.confirmed_line_order_trigger();
create or replace function public.cct_confirmed_line_cost_report_v1(p_passcode text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare outv jsonb;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 perform cct_internal.confirmed_line_reconcile(o.order_token) from public.order_commits o where exists(select 1 from cct_internal.confirmed_line_rules r where r.order_token=o.order_token) order by coalesce(o.pickup_date,o.delivery_date),o.created_at,o.order_token;
 select coalesce(jsonb_agg(jsonb_build_object('order_token',r.order_token,'item_index',r.item_index,'display_name',r.display_name,'display_sku',r.display_sku,
 'cost',coalesce(a.amount,0),'missing',coalesce(m.errs,'[]'::jsonb),'parts',coalesce(a.parts,'[]'::jsonb))),'[]'::jsonb) into outv
 from cct_internal.confirmed_line_rules r join public.order_commits o on o.order_token=r.order_token
 cross join lateral (select coalesce(nullif(o.order_items->r.item_index->>'qty','')::numeric,0) q) q
 left join lateral(select sum(round(x.quantity*l.total_cost/nullif(l.quantity,0),4)) amount,jsonb_agg(jsonb_build_object('lot_id',l.id,'ingredient',l.ingredient_name,'quantity',x.quantity,'unit',l.unit)) parts from cct_internal.confirmed_line_allocations x join public.cct_ingredient_lots l on l.id=x.lot_id where x.order_token=r.order_token and x.item_index=r.item_index) a on true
 left join lateral(select jsonb_agg(c.name||': đã phân bổ '||coalesce(g.actual,0)||'/'||((req->>'per_unit')::numeric*q.q)||' '||c.unit||' từ lô không muộn hơn ngày bán') errs from jsonb_array_elements(r.requirements) req join public.cct_ingredient_catalog c on c.id=(req->>'ingredient_id')::bigint
 left join lateral(select sum(x.quantity) actual from cct_internal.confirmed_line_allocations x join public.cct_ingredient_lots l on l.id=x.lot_id where x.order_token=r.order_token and x.item_index=r.item_index and l.ingredient_id=c.id) g on true
 where coalesce(g.actual,0)<(req->>'per_unit')::numeric*q.q) m on true
 where o.status='completed' and q.q>0 and o.order_items->r.item_index->>'confirmed_component_rule'=r.rule_key;
 return outv;
end $$;
revoke all on function public.cct_confirmed_line_cost_report_v1(text) from public;
grant execute on function public.cct_confirmed_line_cost_report_v1(text) to anon,authenticated;

CREATE OR REPLACE FUNCTION cct_internal.chicken_requirements(p_item jsonb, p_note text, p_base jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare txt text; rest text; c record; v jsonb; result jsonb:='[]'; errors jsonb:='[]'; selected_ids bigint[]:='{}'; selected_names text[]:='{}'; key text; group_name text; no_jelly bool; jelly jsonb; q numeric;
begin
 q:=coalesce(nullif(p_item->>'qty','')::numeric,1);
 txt:=' '||cct_internal.chicken_normalize(coalesce(p_item->>'option_text','')||' '||coalesce(p_item->>'name','')||' '||coalesce(p_item->>'note','')||' '||coalesce(p_note,''))||' ';
 rest:=txt;
 no_jelly:=txt ~ '(khong|bo|no|without) (lay )?sua( |$)';
 if not no_jelly then
  for c in select id,name,cct_internal.chicken_normalize(name) normalized from public.cct_ingredient_catalog where sku like 'NL-SUA-%' order by length(name) desc,id loop
   if position(' '||c.normalized||' ' in rest)>0 then
    selected_ids:=array_append(selected_ids,c.id);selected_names:=array_append(selected_names,c.name);
    rest:=replace(rest,' '||c.normalized||' ',' ');
   end if;
  end loop;
  if cardinality(selected_ids)=1 then
   jelly:=jsonb_build_array(jsonb_build_object('ingredient_id',selected_ids[1],'name',selected_names[1],'unit','g','group','jellyfish','per_unit',150));
   -- Existing special multi-species allocation remains the baseline until the choice changes.
   if exists(select 1 from jsonb_array_elements(p_base) z where z->>'group'='jellyfish' and (z->>'ingredient_id')::bigint=selected_ids[1]) then
    select jsonb_agg(z order by z->>'ingredient_id') into jelly from jsonb_array_elements(p_base) z where z->>'group'='jellyfish';
   end if;
  elsif cardinality(selected_ids)>1 then
   errors:=errors||jsonb_build_array('Cần xác định định lượng khi chọn nhiều loại sứa');
  else
   select jsonb_agg(z order by z->>'ingredient_id') into jelly from jsonb_array_elements(p_base) z where z->>'group'='jellyfish';
   if jelly is null then errors:=errors||jsonb_build_array('Chưa xác định loại sứa khách chọn');end if;
  end if;
 end if;
 for v in select value from jsonb_array_elements(p_base||coalesce(jelly,'[]')) loop
  group_name:=v->>'group';
  if group_name='jellyfish' then continue;end if;
  key:=case
   when cct_internal.chicken_normalize(v->>'name') like 'chan ga%' then 'chan ga'
   when cct_internal.chicken_normalize(v->>'name') like 'me ga%' then 'me( ga)?'
   when cct_internal.chicken_normalize(v->>'name') like 'trung non%' then 'trung( non)?'
   when cct_internal.chicken_normalize(v->>'name') like '%tac%' then '(trai )?tac'
   when group_name='vegetable' then 'rau'
   when group_name='sauce' then 'sot( thai)?'
   else null end;
  if key is not null and txt ~ ('(khong|bo|no|without) (lay )?'||key||'( |$)') then continue;end if;
  if group_name='sauce' and txt ~ '(mam nhi|sot tac)' then
   errors:=errors||jsonb_build_array('Yêu cầu đổi sốt cần xác định công thức riêng'); continue;
  end if;
  result:=result||jsonb_build_array(v||jsonb_build_object('quantity',(v->>'per_unit')::numeric*q));
 end loop;
 if not no_jelly then
  for v in select value from jsonb_array_elements(coalesce(jelly,'[]')) loop
   result:=result||jsonb_build_array(v||jsonb_build_object('quantity',(v->>'per_unit')::numeric*q));
  end loop;
 end if;
 if txt ~ '(them|extra|add on|thay|doi)' then
  errors:=errors||jsonb_build_array('Ghi chú thêm/đổi nguyên liệu cần xác định định lượng riêng');
 end if;
 return jsonb_build_object('requirements',result,'missing',errors);
end $function$
;CREATE OR REPLACE FUNCTION cct_internal.is_chicken(v jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
 select coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-003')
 or cct_internal.chicken_normalize(v->>'name') like 'sua tron chan ga%'
 or cct_internal.chicken_normalize(v->>'name') ~ '^chan ga (tron sua|mix sua)( |$)'
$function$
;;
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
end $function$
;
