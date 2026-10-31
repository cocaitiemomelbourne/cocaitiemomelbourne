
create table cct_internal.ingredient_lot_edit_audit(
 id bigint generated always as identity primary key,lot_id bigint not null,
 old_received_on date not null,new_received_on date not null,
 old_total_cost numeric not null,new_total_cost numeric not null,
 changed_at timestamptz not null default now()
);
alter table cct_internal.ingredient_lot_edit_audit enable row level security;
revoke all on cct_internal.ingredient_lot_edit_audit from public,anon,authenticated;
create function public.cct_ingredient_lot_edit_v2(p_passcode text,p_lot_id bigint,p_old_date date,p_old_total numeric,p_new_date date,p_new_total numeric) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
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
 ('cct_internal.single_packaging_allocations','quantity',null)
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
  ('cct_internal.single_packaging_allocations','quantity',null)
  ) t(tab,qty_col,unit_col) loop
   if r.unit_col is null then
    execute format('update %s set extended_cost=round(%I*$1,4) where lot_id=$2',r.tab,r.qty_col) using price,l.id;
   else
    execute format('update %s set %I=$1,extended_cost=round(%I*$1,4) where lot_id=$2',r.tab,r.unit_col,r.qty_col) using price,l.id;
   end if;
  end loop;
 end if;
 return jsonb_build_object('id',l.id,'total_cost',p_new_total,'received_on',p_new_date,'quantity',l.quantity,'remaining',l.remaining,'unit_cost',p_new_total/l.quantity);
end $$;
revoke all on function public.cct_ingredient_lot_edit_v2(text,bigint,date,numeric,date,numeric) from public;
grant execute on function public.cct_ingredient_lot_edit_v2(text,bigint,date,numeric,date,numeric) to anon,authenticated;
create function public.cct_retail_lot_edit_v2(p_passcode text,p_batch_id bigint,p_old_date date,p_old_cost numeric,p_new_date date,p_new_cost numeric) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 if p_new_date is null or p_new_date>(now() at time zone 'Australia/Melbourne')::date or p_new_cost is null or p_new_cost<0 or p_new_cost>1000000 or p_new_cost<>round(p_new_cost,2) then raise exception 'Ngày hoặc giá vốn không hợp lệ';end if;
 perform 1 from public.cct_cost_batches where id=p_batch_id and received_on=p_old_date and unit_cost=p_old_cost for update;
 if not found then raise exception 'Lô đã thay đổi. Vui lòng tải lại';end if;
 if p_new_cost is distinct from p_old_cost then perform public.cct_cost_batch_price_edit_v1(p_passcode,p_batch_id,p_old_cost,p_new_cost);end if;
 if p_new_date is distinct from p_old_date then perform public.cct_cost_batch_date_edit_v1(p_passcode,p_batch_id,p_old_date,p_new_date);end if;
 return jsonb_build_object('id',p_batch_id,'unit_cost',p_new_cost,'received_on',p_new_date);
end $$;
revoke all on function public.cct_retail_lot_edit_v2(text,bigint,date,numeric,date,numeric) from public;
grant execute on function public.cct_retail_lot_edit_v2(text,bigint,date,numeric,date,numeric) to anon,authenticated;
