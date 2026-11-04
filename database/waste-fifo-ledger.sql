
-- Waste is recorded separately from sales and original received quantities.
create table cct_internal.waste_events(
 id uuid primary key,kind text not null check(kind in ('retail','ingredient','production')),
 source_id bigint not null,quantity numeric not null check(quantity>0),unit text not null,
 occurred_on date not null,reason text not null check(reason in ('damaged','expired')),
 note text not null default '',menu_reduced boolean not null default false,
 created_at timestamptz not null default clock_timestamp(),voided_at timestamptz,void_note text);
create table cct_internal.waste_allocations(
 event_id uuid not null references cct_internal.waste_events(id),lot_id bigint not null,
 quantity numeric not null check(quantity>0),unit_cost_snapshot numeric not null,
 primary key(event_id,lot_id));
alter table cct_internal.waste_events enable row level security;
alter table cct_internal.waste_allocations enable row level security;
revoke all on cct_internal.waste_events,cct_internal.waste_allocations from public,anon,authenticated;

CREATE OR REPLACE FUNCTION cct_internal.waste_item_product(v jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare pid bigint;n text:=cct_internal.chicken_normalize(v->>'name');
begin
 if coalesce(v->>'id',v->>'product_id','') ~ '^[0-9]{1,15}$' then
 pid:=coalesce(v->>'id',v->>'product_id')::bigint;
 if exists(select 1 from public.products where id=pid) then return pid;end if;end if;
 if n ~ '^(banh trang )?bo toi( chua cay)?( duy best)?$' then return (select id from products where id=5);end if;
 if n='banh trang xi ke' then return (select id from products where id=3);end if;
 if n ~ '^(set( 3)? )?banh trang (sate( tom( hanh)?)?|tom hanh)$' then return (select id from products where id=4);end if;
 if n ~ '^com chay( cha bong)?( 500g)?$' then return (select id from products where id=10);end if;
 if n ~ '^ghe (sua|non) rim( gion)?$' then return (select id from products where id=11);end if;
 select min(product_id) into pid from public.cct_product_aliases where cct_internal.chicken_normalize(alias_name)=n having count(distinct product_id)=1;
 if pid is not null then return pid;end if;
 return (select min(id) from public.products where cct_internal.chicken_normalize(name)=n having count(*)=1);
end $function$
;
CREATE OR REPLACE FUNCTION cct_internal.waste_retail_balances(pid bigint)
 RETURNS TABLE(lot_id bigint, remaining numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare balances jsonb:='{}';b record;o record;left_qty numeric;available numeric;taken numeric;
begin
 if not exists(select 1 from public.cct_cost_batches where product_id=pid) then return;end if;
 for b in select cb.id,cb.quantity-coalesce((select sum(a.quantity) from cct_internal.waste_allocations a join cct_internal.waste_events e on e.id=a.event_id where e.kind='retail' and e.voided_at is null and a.lot_id=cb.id),0) qty from public.cct_cost_batches cb where cb.product_id=pid loop
 balances:=jsonb_set(balances,array[b.id::text],to_jsonb(b.qty));end loop;
 for o in select v.value item,coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date) as sale_day
 from public.order_commits oc cross join lateral jsonb_array_elements(coalesce(oc.order_items,'[]')) v
 where oc.status='completed' and (
 coalesce(v.value->>'id',v.value->>'product_id','')=pid::text
 or (case when coalesce(v.value->>'id',v.value->>'product_id','') ~ '^[0-9]{1,15}$'
 then not exists(select 1 from public.products where id=coalesce(v.value->>'id',v.value->>'product_id')::bigint)
 else true end and cct_internal.waste_item_product(v.value)=pid))
 and not exists(select 1 from cct_internal.confirmed_line_rules cr where cr.order_token=oc.order_token and v.value->>'confirmed_component_rule'=cr.rule_key)
 order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token
 loop
 left_qty:=coalesce((o.item->>'qty')::numeric,0);if left_qty<=0 or o.sale_day is null then continue;end if;
 for b in select * from public.cct_cost_batches where product_id=pid and received_on<=o.sale_day order by received_on,id loop
 available:=greatest(0,coalesce((balances->>b.id::text)::numeric,0));taken:=least(left_qty,available);
 balances:=jsonb_set(balances,array[b.id::text],to_jsonb(available-taken));left_qty:=left_qty-taken;exit when left_qty<=0;
 end loop;end loop;
 return query select cb.id,greatest(0,coalesce((balances->>cb.id::text)::numeric,0)) from public.cct_cost_batches cb where cb.product_id=pid order by cb.received_on,cb.id;
end $function$
;
CREATE OR REPLACE FUNCTION cct_internal.waste_all_retail_balances()
 RETURNS TABLE(lot_id bigint, remaining numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare balances jsonb:='{}';b record;o record;left_qty numeric;available numeric;taken numeric;matched_pid bigint;
begin
 for b in select cb.id,cb.quantity-coalesce((select sum(a.quantity) from cct_internal.waste_allocations a join cct_internal.waste_events e on e.id=a.event_id where e.kind='retail' and e.voided_at is null and a.lot_id=cb.id),0) qty from public.cct_cost_batches cb loop
 balances:=jsonb_set(balances,array[b.id::text],to_jsonb(b.qty));end loop;
 for o in select v.value item,coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date) as sale_day
 from public.order_commits oc cross join lateral jsonb_array_elements(coalesce(oc.order_items,'[]')) v
 where oc.status='completed' and not exists(select 1 from cct_internal.confirmed_line_rules cr where cr.order_token=oc.order_token and v.value->>'confirmed_component_rule'=cr.rule_key)
 order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token
 loop
 matched_pid:=cct_internal.waste_item_product(o.item);if matched_pid is null then continue;end if;
 left_qty:=coalesce((o.item->>'qty')::numeric,0);if left_qty<=0 or o.sale_day is null then continue;end if;
 for b in select * from public.cct_cost_batches where product_id=matched_pid and received_on<=o.sale_day order by received_on,id loop
 available:=greatest(0,coalesce((balances->>b.id::text)::numeric,0));taken:=least(left_qty,available);
 balances:=jsonb_set(balances,array[b.id::text],to_jsonb(available-taken));left_qty:=left_qty-taken;exit when left_qty<=0;
 end loop;end loop;
 return query select cb.id,greatest(0,coalesce((balances->>cb.id::text)::numeric,0)) from public.cct_cost_batches cb order by cb.received_on,cb.id;
end $function$
;
CREATE OR REPLACE FUNCTION cct_internal.waste_record(request_id uuid, k text, source bigint, q numeric, why text, memo text, reduce_menu boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare e cct_internal.waste_events%rowtype;p public.products%rowtype;l public.cct_ingredient_lots%rowtype;
pb public.cct_production_batches%rowtype;b record;need numeric:=q;take numeric;today date:=(now() at time zone 'Australia/Melbourne')::date;u text;
begin
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 if request_id is null or k not in ('retail','ingredient','production') or source is null or q is null or q<=0 or q>1000000000 or q::text in('NaN','Infinity','-Infinity') or why not in('damaged','expired') or why is null or length(coalesce(memo,''))>1000 then raise exception 'Thông tin hàng bỏ không hợp lệ';end if;
 select * into e from cct_internal.waste_events where id=request_id;
 if found then
 if e.kind is distinct from k or e.source_id is distinct from source or e.quantity is distinct from q or e.reason is distinct from why or e.note is distinct from coalesce(memo,'') or e.menu_reduced is distinct from (reduce_menu and k='retail') then raise exception 'Mã phiếu đã được dùng cho nội dung khác';end if;
 return e.id;end if;
 if k='retail' then
 if q<>trunc(q) then raise exception 'Số phần phải là số nguyên';end if;
 select * into p from public.products where id=source for update;
 if not found then raise exception 'Không tìm thấy sản phẩm';end if;
 if p.sku like 'SU-%' or p.sku in('GV-004','GV-005') or not exists(select 1 from cct_cost_batches where product_id=p.id) then raise exception 'Món này dùng nguyên liệu/mẻ sản xuất. Mở Hàng hỏng để ghi từng nguyên liệu hoặc mẻ bị bỏ';end if;
 if reduce_menu and p.stock_qty is not null and p.stock_qty<q then raise exception 'Số bỏ vượt tồn bán. Hãy kiểm tra lại số thực tế';end if;
 perform 1 from public.cct_cost_batches where product_id=source order by id for update;
 u:='piece';
 elsif k='ingredient' then
 select * into l from public.cct_ingredient_lots where id=source for update;
 if not found or l.received_on>today or l.remaining<q then raise exception 'Lô không hợp lệ hoặc số bỏ vượt lượng còn trong lô';end if;
 u:=l.unit;if u='piece' and q<>trunc(q) then raise exception 'Số cái phải là số nguyên';end if;
 elsif k='production' then
 select * into pb from public.cct_production_batches where id=source for update;
 if not found or pb.produced_on>today or pb.status not in('open','closed') or pb.quantity-pb.used_quantity<q then raise exception 'Mẻ không hợp lệ hoặc số bỏ vượt lượng còn';end if;
 u:=pb.unit;
 end if;
 insert into cct_internal.waste_events(id,kind,source_id,quantity,unit,occurred_on,reason,note,menu_reduced)
 values(request_id,k,source,q,u,today,why,coalesce(memo,''),reduce_menu and k='retail');
 if k='retail' then
 for b in select cb.*,bal.remaining from cct_internal.waste_retail_balances(source) bal join public.cct_cost_batches cb on cb.id=bal.lot_id where cb.received_on<=today and bal.remaining>0 order by cb.received_on,cb.id loop
 take:=least(need,b.remaining);
 insert into cct_internal.waste_allocations values(request_id,b.id,take,b.unit_cost);need:=need-take;exit when need<=0;
 end loop;
 if need>0 then raise exception 'Thiếu lô FIFO cho % phần. Chưa ghi nhận hao hụt; kiểm tra lô nhập trước',need;end if;
 if reduce_menu then
 update public.products set stock_qty=case when stock_qty is null then null else stock_qty-q::integer end,updated_at=clock_timestamp() where id=source;
 update public.products_draft set stock_qty=case when p.stock_qty is null then null else p.stock_qty-q::integer end,updated_at=clock_timestamp() where id=source;
 insert into public.cct_stock_audit(product_id,product_name,old_qty,new_qty,action,reason,note)
 values(source,p.name,p.stock_qty,case when p.stock_qty is null then null else p.stock_qty-q::integer end,'count',why,'Phiếu hao hụt '||request_id||' · '||coalesce(memo,''));
 end if;
 elsif k='ingredient' then
 insert into cct_internal.waste_allocations values(request_id,source,q,l.total_cost/l.quantity);
 update public.cct_ingredient_lots set remaining=remaining-q where id=source;
 else
 insert into cct_internal.waste_allocations values(request_id,source,q,pb.total_cost/pb.quantity);
 update public.cct_production_batches set used_quantity=used_quantity+q,status=case when used_quantity+q>=quantity then 'closed' else status end where id=source;
 end if;
 return request_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.cct_waste_save_v1(p_passcode text, p_request_id uuid, p_kind text, p_source_id bigint, p_quantity numeric, p_reason text, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 return jsonb_build_object('id',cct_internal.waste_record(p_request_id,p_kind,p_source_id,p_quantity,p_reason,p_note,true));
end $function$
;
CREATE OR REPLACE FUNCTION public.cct_waste_report_v1(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 return (select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc),'[]') from (
 select e.*,a.lot_id,a.quantity allocation_quantity,
 coalesce(p.name,l.ingredient_name,r.product_name) name,coalesce(p.sku,ig.sku,r.sku) sku,
 round(a.quantity*case e.kind when 'retail' then cb.unit_cost when 'ingredient' then l.total_cost/nullif(l.quantity,0) else pb.total_cost/nullif(pb.quantity,0) end,4) cost
 from cct_internal.waste_events e join cct_internal.waste_allocations a on a.event_id=e.id
 left join public.products p on e.kind='retail' and p.id=e.source_id
 left join public.cct_cost_batches cb on e.kind='retail' and cb.id=a.lot_id
 left join public.cct_ingredient_lots l on e.kind='ingredient' and l.id=a.lot_id
 left join public.cct_ingredient_catalog ig on ig.id=l.ingredient_id
 left join public.cct_production_batches pb on e.kind='production' and pb.id=a.lot_id
 left join public.cct_production_recipes r on r.id=pb.recipe_id) t);
end $function$
;
CREATE OR REPLACE FUNCTION public.cct_waste_sources_v1(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 return (with balances as materialized(select * from cct_internal.waste_all_retail_balances()) select coalesce(jsonb_agg(to_jsonb(t) order by name,received_on,source_id),'[]') from(
 select 'retail' kind,p.id source_id,p.name,p.sku,'piece' unit,sum(b.remaining) available,null::date received_on,p.stock_qty menu_stock
 from balances b join public.cct_cost_batches cb on cb.id=b.lot_id join public.products p on p.id=cb.product_id
 where p.sku not like 'SU-%' and p.sku not in('GV-004','GV-005') and cb.received_on<=(now() at time zone 'Australia/Melbourne')::date
 group by p.id having sum(b.remaining)>0
 union all
 select 'ingredient',l.id,l.ingredient_name,i.sku,l.unit,l.remaining,l.received_on,null::integer from public.cct_ingredient_lots l left join public.cct_ingredient_catalog i on i.id=l.ingredient_id where l.remaining>0 and l.received_on<=(now() at time zone 'Australia/Melbourne')::date
 union all
 select 'production',b.id,r.product_name,r.sku,b.unit,b.quantity-b.used_quantity,b.produced_on,null::integer from public.cct_production_batches b join public.cct_production_recipes r on r.id=b.recipe_id where b.status='open' and b.quantity>b.used_quantity and b.produced_on<=(now() at time zone 'Australia/Melbourne')::date
 ) t);
end $function$
;
CREATE OR REPLACE FUNCTION public.cct_waste_void_v1(p_passcode text, p_id uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare e cct_internal.waste_events%rowtype;a record;p public.products%rowtype;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 if length(trim(coalesce(p_note,'')))<3 or length(p_note)>1000 then raise exception 'Ghi lý do hủy phiếu';end if;
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 select * into e from cct_internal.waste_events where id=p_id for update;
 if not found then raise exception 'Không tìm thấy phiếu';end if;
 if e.voided_at is not null then return jsonb_build_object('id',e.id);end if;
 for a in select * from cct_internal.waste_allocations where event_id=e.id loop
 if e.kind='ingredient' then update public.cct_ingredient_lots set remaining=remaining+a.quantity where id=a.lot_id;
 elsif e.kind='production' then update public.cct_production_batches set used_quantity=used_quantity-a.quantity,status=case when status='closed' then 'open' else status end where id=a.lot_id;end if;end loop;
 if e.kind='retail' and e.menu_reduced then
 select * into p from public.products where id=e.source_id for update;
 update public.products set stock_qty=case when stock_qty is null then null else stock_qty+e.quantity::integer end,updated_at=clock_timestamp() where id=e.source_id;
 update public.products_draft set stock_qty=case when p.stock_qty is null then null else p.stock_qty+e.quantity::integer end,updated_at=clock_timestamp() where id=e.source_id;
 insert into public.cct_stock_audit(product_id,product_name,old_qty,new_qty,action,reason,note) values(p.id,p.name,p.stock_qty,case when p.stock_qty is null then null else p.stock_qty+e.quantity::integer end,'count','recount','Hủy phiếu hao hụt '||e.id||' · '||p_note);
 end if;
 update cct_internal.waste_events set voided_at=clock_timestamp(),void_note=p_note where id=e.id;
 return jsonb_build_object('id',e.id);
end $function$
;
CREATE OR REPLACE FUNCTION cct_internal.waste_source_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare k text:=case tg_table_name when 'cct_cost_batches' then 'retail' when 'cct_ingredient_lots' then 'ingredient' else 'production' end;w numeric;d date;
begin
 select sum(a.quantity),min(e.occurred_on) into w,d from cct_internal.waste_allocations a join cct_internal.waste_events e on e.id=a.event_id where e.kind=k and a.lot_id=old.id and e.voided_at is null;
 if w is null then return coalesce(new,old);end if;
 if tg_op='DELETE' then raise exception 'Lô có phiếu hao hụt. Hủy phiếu ghi nhầm trước khi xóa lô';end if;
 if new.quantity<w then raise exception 'Số nhập không được thấp hơn số đã ghi nhận hao hụt (%)',w;end if;
 if (case when k='production' then (to_jsonb(new)->>'produced_on')::date else (to_jsonb(new)->>'received_on')::date end)>d then raise exception 'Ngày lô không được sau ngày ghi nhận hao hụt';end if;
 return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.cct_stock_save_batch_v2(p_passcode text, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare h text; x jsonb; p public.products%rowtype; n integer; result jsonb:='[]'; r text; note_value text;
begin select pass_hash into h from public.print_admin_access where id=1;
if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized'; end if;
if p_changes is null or jsonb_typeof(p_changes)<>'array' or jsonb_array_length(p_changes) not between 1 and 500 then raise exception 'invalid_changes'; end if;
if (select count(distinct a.value->>'id') from jsonb_array_elements(p_changes) as a(value))<>jsonb_array_length(p_changes) then raise exception 'duplicate_product'; end if;
perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
for x in select value from jsonb_array_elements(p_changes) order by (value->>'id')::bigint loop
 if coalesce(x->>'new_qty','') !~ '^[0-9]{1,7}$' then raise exception 'invalid_count'; end if;
 n:=(x->>'new_qty')::integer; r:=x->>'reason'; note_value:=btrim(coalesce(x->>'note',''));
 if n>1000000 or length(note_value)>1000 then raise exception 'invalid_count_or_note'; end if;
 if r is null or r not in ('recount','offline_sale','damaged','expired','gift','other') then raise exception 'reason_required'; end if;
 if r='other' and length(note_value)=0 then raise exception 'note_required'; end if;
 select * into p from public.products where id=(x->>'id')::bigint for update;
 if not found then raise exception 'product_not_found'; end if;
 if p.stock_qty is distinct from (x->>'expected_qty')::integer then raise exception 'stock_changed_reload:%',p.name; end if;
 if p.stock_qty is distinct from n then
  if r in ('damaged','expired') then
   if p.stock_qty is null or n>=p.stock_qty then raise exception 'Hàng hỏng/hết hạn cần số tồn thực tế thấp hơn tồn hiện tại';end if;
   declare wid uuid:=gen_random_uuid();begin
    perform cct_internal.waste_record(wid,'retail',p.id,p.stock_qty-n,r,note_value,false);
    update cct_internal.waste_events set menu_reduced=true where id=wid;
   end;
  end if;
  update public.products set stock_qty=n,updated_at=clock_timestamp() where id=p.id;
  update public.products_draft set stock_qty=n,updated_at=clock_timestamp() where id=p.id;
  insert into public.cct_stock_audit(product_id,product_name,old_qty,new_qty,action,reason,note) values(p.id,p.name,p.stock_qty,n,'count',r,nullif(note_value,''));
 end if;
 result:=result||jsonb_build_array((select to_jsonb(t) from(select id,stock_qty,updated_at from public.products where id=p.id)t));
end loop;
return result; end $function$
;
create trigger cct_waste_source_guard before update or delete on public.cct_cost_batches for each row execute function cct_internal.waste_source_guard();
create trigger cct_waste_source_guard before update or delete on public.cct_ingredient_lots for each row execute function cct_internal.waste_source_guard();
create trigger cct_waste_source_guard before update or delete on public.cct_production_batches for each row execute function cct_internal.waste_source_guard();
create constraint trigger zz_cct_sales_cost_revision after insert or update or delete on cct_internal.waste_events deferrable initially deferred for each row execute function cct_internal.sales_cost_changed();
revoke all on function cct_internal.waste_item_product(jsonb),cct_internal.waste_retail_balances(bigint),cct_internal.waste_record(uuid,text,bigint,numeric,text,text,boolean),cct_internal.waste_source_guard() from public,anon,authenticated;
revoke all on function public.cct_waste_save_v1(text,uuid,text,bigint,numeric,text,text),public.cct_waste_report_v1(text),public.cct_waste_sources_v1(text),public.cct_waste_void_v1(text,uuid,text) from public;
grant execute on function public.cct_waste_save_v1(text,uuid,text,bigint,numeric,text,text),public.cct_waste_report_v1(text),public.cct_waste_sources_v1(text),public.cct_waste_void_v1(text,uuid,text) to anon,authenticated;


revoke all on function cct_internal.waste_all_retail_balances() from public,anon,authenticated;
