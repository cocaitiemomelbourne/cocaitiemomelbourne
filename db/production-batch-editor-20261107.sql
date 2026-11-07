-- Authenticated, audited editing of production batches; existing FIFO allocations stay attached.
create table if not exists cct_internal.production_batch_edits (
 id uuid primary key, batch_id bigint not null references public.cct_production_batches(id),
 changed_at timestamptz not null default clock_timestamp(), reason text not null,
 before_data jsonb not null, after_data jsonb not null, request_data jsonb not null
);
alter table cct_internal.production_batch_edits enable row level security;
revoke all on cct_internal.production_batch_edits from public,anon,authenticated;

create or replace function public.cct_production_batch_edit_v1(p_passcode text,p_action text,p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
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
end $$;
revoke all on function public.cct_production_batch_edit_v1(text,text,jsonb) from public;
grant execute on function public.cct_production_batch_edit_v1(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
