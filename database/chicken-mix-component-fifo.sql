
-- Private bookkeeping: no Data API access.
create table cct_internal.chicken_line_state(
 order_token text not null references public.order_commits(order_token),
 item_index integer not null,
 base_recipe jsonb not null,
 requirements jsonb not null default '[]',
 missing jsonb not null default '[]',
 sale_date date,
 qty numeric not null,
 updated_at timestamptz not null default now(),
 primary key(order_token,item_index)
);
alter table cct_internal.chicken_line_state enable row level security;
create table cct_internal.chicken_sauce_lots(
 order_token text not null references public.order_commits(order_token),
 item_index integer not null,
 batch_id bigint not null references public.cct_production_batches(id),
 quantity_ml numeric not null check(quantity_ml>0),
 cost numeric not null check(cost>=0),
 primary key(order_token,item_index,batch_id)
);
alter table cct_internal.chicken_sauce_lots enable row level security;
create table cct_internal.chicken_reversal_audit(
 id bigint generated always as identity primary key,
 order_token text not null,
 item_index integer not null,
 allocations jsonb not null,
 reversed_at timestamptz not null default now()
);
alter table cct_internal.chicken_reversal_audit enable row level security;
revoke all on all tables in schema cct_internal from public,anon,authenticated;

create function cct_internal.chicken_normalize(v text) returns text
language sql immutable set search_path=pg_catalog as $$
 select trim(regexp_replace(translate(lower(coalesce(v,'')),'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ','aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd'),'[^a-z0-9]+',' ','g'))
$$;
create function cct_internal.is_chicken(v jsonb) returns boolean
language sql stable set search_path=pg_catalog,public,cct_internal as $$
 select coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-003')
 or cct_internal.chicken_normalize(v->>'name') like 'sua tron chan ga%'
$$;

create function cct_internal.chicken_base(p_token text,p_ix int) returns jsonb
language plpgsql set search_path=pg_catalog,public,cct_internal as $$
declare v jsonb; q numeric; b jsonb; j jsonb;
begin
 select order_items->p_ix into v from public.order_commits where order_token=p_token;
 q:=coalesce(nullif(v->>'qty','')::numeric,1);
 select coalesce(jsonb_agg(jsonb_build_object('ingredient_id',t.ingredient_id,'name',t.ingredient_name,'unit',t.unit,'group',t.component_group,'per_unit',t.quantity) order by t.ingredient_id),'[]')
 into b from (
  select i.ingredient_id,min(i.ingredient_name) ingredient_name,i.unit,i.component_group,sum(i.quantity) quantity
  from public.cct_standard_recipe_items i join public.products p on p.id=i.product_id
  where p.sku='SU-003' and i.ingredient_id is not null
  group by i.ingredient_id,i.unit,i.component_group
 ) t;
 -- Preserve verified historical species/extra grams, even when old order text was blank.
 select jsonb_agg(jsonb_build_object('ingredient_id',a.ingredient_id,'name',c.name,'unit','g','group','jellyfish','per_unit',a.grams/q) order by a.ingredient_id)
 into j from (select ingredient_id,sum(grams) grams from public.cct_chicken_mix_jelly_allocations where order_token=p_token and item_index=p_ix group by ingredient_id) a join public.cct_ingredient_catalog c on c.id=a.ingredient_id;
 return b||coalesce(j,'[]');
end $$;

create function cct_internal.chicken_requirements(p_item jsonb,p_note text,p_base jsonb) returns jsonb
language plpgsql stable set search_path=pg_catalog,public,cct_internal as $$
declare txt text; rest text; c record; v jsonb; result jsonb:='[]'; errors jsonb:='[]'; selected_ids bigint[]:='{}'; selected_names text[]:='{}'; key text; group_name text; no_jelly bool; jelly jsonb; q numeric;
begin
 q:=coalesce(nullif(p_item->>'qty','')::numeric,1);
 txt:=' '||cct_internal.chicken_normalize(coalesce(p_item->>'option_text','')||' '||coalesce(p_item->>'note','')||' '||coalesce(p_note,''))||' ';
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
end $$;

create function cct_internal.chicken_release(p_token text,p_ix int) returns void
language plpgsql set search_path=pg_catalog,public,cct_internal as $$
declare r record; audit jsonb;
begin
 select jsonb_build_object(
 'ingredients',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from public.cct_chicken_mix_fifo_allocations a where order_token=p_token and item_index=p_ix),
 'jellyfish',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from public.cct_chicken_mix_jelly_allocations a where order_token=p_token and item_index=p_ix),
 'packaging',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from public.cct_chicken_mix_packaging_allocations a where order_token=p_token and item_index=p_ix),
 'sauce',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from cct_internal.chicken_sauce_lots a where order_token=p_token and item_index=p_ix)
 ) into audit;
 insert into cct_internal.chicken_reversal_audit(order_token,item_index,allocations) values(p_token,p_ix,audit);
 for r in
  select lot_id,sum(qty) qty from (
   select lot_id,grams qty from public.cct_chicken_mix_fifo_allocations where order_token=p_token and item_index=p_ix
   union all select lot_id,grams from public.cct_chicken_mix_jelly_allocations where order_token=p_token and item_index=p_ix
   union all select lot_id,quantity from public.cct_chicken_mix_packaging_allocations where order_token=p_token and item_index=p_ix
  ) a group by lot_id order by lot_id
 loop
  update public.cct_ingredient_lots set remaining=remaining+r.qty where id=r.lot_id;
 end loop;
 delete from public.cct_chicken_mix_fifo_allocations where order_token=p_token and item_index=p_ix;
 delete from public.cct_chicken_mix_jelly_allocations where order_token=p_token and item_index=p_ix;
 delete from public.cct_chicken_mix_packaging_allocations where order_token=p_token and item_index=p_ix;
 for r in
  select batch_id,sum(qty) qty from (
   select batch_id,quantity_ml qty from public.cct_order_sauce_cogs where order_token=p_token and item_index=p_ix
   union all select batch_id,quantity_ml from cct_internal.chicken_sauce_lots where order_token=p_token and item_index=p_ix
  ) a group by batch_id order by batch_id
 loop
  update public.cct_production_batches set used_quantity=used_quantity-r.qty,
   status=case when status='closed' and used_quantity-r.qty<quantity then 'open' else status end where id=r.batch_id;
 end loop;
 insert into public.cct_order_sauce_reversal_audit_v1(order_token,item_index,sauce_sku,batch_id,quantity_ml,cost,reason)
 select order_token,item_index,sauce_sku,batch_id,quantity_ml,cost,'Chicken FIFO line changed' from public.cct_order_sauce_cogs where order_token=p_token and item_index=p_ix;
 delete from public.cct_order_sauce_cogs where order_token=p_token and item_index=p_ix;
 delete from cct_internal.chicken_sauce_lots where order_token=p_token and item_index=p_ix;
 update public.cct_order_sauce_resolution_v1 set status='stale',note='Chicken FIFO line changed',updated_at=now() where order_token=p_token and item_index=p_ix;
end $$;

create function cct_internal.chicken_reconcile(p_token text) returns void
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare ord public.order_commits%rowtype; st cct_internal.chicken_line_state%rowtype;
 it jsonb; ix int; sold date; q numeric; base jsonb; plan jsonb; req jsonb; errs jsonb; r jsonb; lot record;
 actual numeric; need numeric; avail numeric; take_qty numeric; ingredient bigint; table_name text; amount numeric; desired jsonb;
begin
 perform pg_advisory_xact_lock(321031,2);
 perform pg_advisory_xact_lock(1628018,2);
 select * into ord from public.order_commits where order_token=p_token;
 if not found then return;end if;
 sold:=coalesce(case when lower(ord.fulfilment_method) like '%pickup%' then ord.pickup_date else ord.delivery_date end,ord.delivery_date,ord.pickup_date);
 -- Release every removed or inactive line, but retain its frozen recipe for later recompletion.
 for st in select * from cct_internal.chicken_line_state where order_token=p_token order by item_index loop
  it:=ord.order_items->st.item_index;
  if ord.status<>'completed' or it is null or not cct_internal.is_chicken(it) then
   if exists(select 1 from public.cct_chicken_mix_fifo_allocations where order_token=p_token and item_index=st.item_index)
    or exists(select 1 from public.cct_chicken_mix_jelly_allocations where order_token=p_token and item_index=st.item_index)
    or exists(select 1 from public.cct_chicken_mix_packaging_allocations where order_token=p_token and item_index=st.item_index)
    or exists(select 1 from cct_internal.chicken_sauce_lots where order_token=p_token and item_index=st.item_index)
    or exists(select 1 from public.cct_order_sauce_cogs where order_token=p_token and item_index=st.item_index) then
    perform cct_internal.chicken_release(p_token,st.item_index);
   end if;
   update cct_internal.chicken_line_state set requirements='[]',missing='[]',updated_at=now() where order_token=p_token and item_index=st.item_index;
   if it is null or not cct_internal.is_chicken(it) then
    delete from cct_internal.chicken_line_state where order_token=p_token and item_index=st.item_index;
   end if;
  end if;
 end loop;
 if ord.status<>'completed' then return;end if;
 for it,ix in select value,(ordinality-1)::int from jsonb_array_elements(ord.order_items) with ordinality loop
  if not cct_internal.is_chicken(it) then continue;end if;
  q:=coalesce(nullif(it->>'qty','')::numeric,1);
  if q<=0 then continue;end if;
  select * into st from cct_internal.chicken_line_state where order_token=p_token and item_index=ix;
  if not found then
   base:=cct_internal.chicken_base(p_token,ix);
   insert into cct_internal.chicken_line_state(order_token,item_index,base_recipe,qty,sale_date)
   values(p_token,ix,base,q,sold);
   select * into st from cct_internal.chicken_line_state where order_token=p_token and item_index=ix;
  end if;
  plan:=cct_internal.chicken_requirements(it,ord.customer_note,st.base_recipe);
  req:=plan->'requirements';errs:=plan->'missing';
  -- The original rows are retained on first adoption. Subsequent semantic changes are reversed with audit.
  if st.requirements<>'[]'::jsonb and (st.requirements is distinct from req or st.sale_date is distinct from sold) then
   perform cct_internal.chicken_release(p_token,ix);
  end if;
  if sold is null then
   errs:=errs||jsonb_build_array('Thiếu ngày nhận hàng; chưa phân bổ FIFO');
  else
   -- Stable row locks protect split-lot allocations against concurrent orders.
   perform l.id from public.cct_ingredient_lots l where l.ingredient_id in (select (v->>'ingredient_id')::bigint from jsonb_array_elements(req) v where v->>'group'<>'sauce') order by l.id for update;
   for r in select value from jsonb_array_elements(req) loop
    ingredient:=(r->>'ingredient_id')::bigint;
    if r->>'group'='sauce' then
     select coalesce(sum(x.qty),0) into actual from (
      select quantity_ml qty from public.cct_order_sauce_cogs where order_token=p_token and item_index=ix and sauce_sku='SOT-THAI'
      union all select quantity_ml from cct_internal.chicken_sauce_lots where order_token=p_token and item_index=ix
     ) x;
     need:=(r->>'quantity')::numeric-actual;
     if need>0 then
      perform b.id from public.cct_production_batches b join public.cct_production_recipes pr on pr.id=b.recipe_id where pr.sku='SOT-THAI' order by b.id for update of b;
      select coalesce(sum(b.quantity-b.used_quantity),0) into avail from public.cct_production_batches b join public.cct_production_recipes pr on pr.id=b.recipe_id where pr.sku='SOT-THAI' and b.produced_on<=sold and b.status in ('open','closed') and b.quantity>0 and b.quantity>b.used_quantity;
      if avail>=need then
       for lot in select b.* from public.cct_production_batches b join public.cct_production_recipes pr on pr.id=b.recipe_id where pr.sku='SOT-THAI' and b.produced_on<=sold and b.status in ('open','closed') and b.quantity>0 and b.quantity>b.used_quantity order by b.produced_on,b.id loop
        exit when need<=0;
        take_qty:=least(need,lot.quantity-lot.used_quantity);
        insert into cct_internal.chicken_sauce_lots(order_token,item_index,batch_id,quantity_ml,cost) values(p_token,ix,lot.id,take_qty,round(take_qty*lot.total_cost/lot.quantity,4))
        on conflict(order_token,item_index,batch_id) do update set quantity_ml=chicken_sauce_lots.quantity_ml+excluded.quantity_ml,cost=chicken_sauce_lots.cost+excluded.cost;
        update public.cct_production_batches set used_quantity=used_quantity+take_qty,status=case when used_quantity+take_qty>=quantity then 'closed' else status end where id=lot.id;
        need:=need-take_qty;
       end loop;
      end if;
     end if;
    else
     table_name:=case r->>'group' when 'jellyfish' then 'cct_chicken_mix_jelly_allocations' when 'packaging' then 'cct_chicken_mix_packaging_allocations' else 'cct_chicken_mix_fifo_allocations' end;
     if r->>'group'='packaging' then
      select coalesce(sum(a.quantity),0) into actual from public.cct_chicken_mix_packaging_allocations a join public.cct_ingredient_lots l on l.id=a.lot_id where a.order_token=p_token and a.item_index=ix and l.ingredient_id=ingredient;
     else
      execute format('select coalesce(sum(grams),0) from public.%I where order_token=$1 and item_index=$2 and ingredient_id=$3',table_name) into actual using p_token,ix,ingredient;
     end if;
     need:=(r->>'quantity')::numeric-actual;
     if need>0 then
      select coalesce(sum(l.remaining),0) into avail from public.cct_ingredient_lots l where l.ingredient_id=ingredient and l.received_on<=sold and l.unit=r->>'unit' and l.quantity>0 and l.remaining>0;
      if avail>=need then
       for lot in select * from public.cct_ingredient_lots l where l.ingredient_id=ingredient and l.received_on<=sold and l.unit=r->>'unit' and l.quantity>0 and l.remaining>0 order by l.received_on,l.id loop
        exit when need<=0;
        take_qty:=least(need,lot.remaining);
        amount:=round(take_qty*lot.total_cost/lot.quantity,4);
        if r->>'group'='packaging' then
         insert into public.cct_chicken_mix_packaging_allocations(order_token,item_index,order_number,sale_date,lot_id,quantity,extended_cost)
         values(p_token,ix,ord.order_number,sold,lot.id,take_qty,amount)
         on conflict(order_token,item_index,lot_id) do update set quantity=cct_chicken_mix_packaging_allocations.quantity+excluded.quantity,extended_cost=cct_chicken_mix_packaging_allocations.extended_cost+excluded.extended_cost;
        else
         execute format('insert into public.%I(order_token,item_index,order_number,sale_date,lot_id,ingredient_id,grams,unit_cost,extended_cost) values($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict(order_token,item_index,lot_id) do update set grams=%I.grams+excluded.grams,extended_cost=%I.extended_cost+excluded.extended_cost',table_name,table_name,table_name)
         using p_token,ix,ord.order_number,sold,lot.id,ingredient,take_qty,lot.total_cost/lot.quantity,amount;
        end if;
        update public.cct_ingredient_lots set remaining=remaining-take_qty where id=lot.id;
        need:=need-take_qty;
       end loop;
      end if;
     end if;
    end if;
    if need<>0 then
     errs:=errs||jsonb_build_array(format('%s: đã phân bổ %s/%s %s',r->>'name',(r->>'quantity')::numeric-need,r->>'quantity',r->>'unit'));
    end if;
   end loop;
  end if;
  update cct_internal.chicken_line_state set requirements=req,missing=errs,qty=q,sale_date=sold,updated_at=case when requirements is distinct from req or missing is distinct from errs or sale_date is distinct from sold or qty is distinct from q then now() else updated_at end where order_token=p_token and item_index=ix;
 end loop;
end $$;

create function cct_internal.chicken_order_trigger() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
begin
 if exists(select 1 from jsonb_array_elements(new.order_items) v where cct_internal.is_chicken(v))
 or exists(select 1 from cct_internal.chicken_line_state where order_token=new.order_token) then
  perform cct_internal.chicken_reconcile(new.order_token);
 end if;
 return null;
end $$;
create trigger cct_chicken_fifo_auto after insert or update of status,order_items,customer_note,pickup_date,delivery_date,fulfilment_method,order_text on public.order_commits for each row execute function cct_internal.chicken_order_trigger();

-- Chicken sauce is owned by the split-batch allocator above; leave other product rules unchanged.
do $patch$ declare d text; begin
 select pg_get_functiondef('public.cct_order_sauce_reconcile_v1(text,boolean)'::regprocedure) into d;
 d:=replace(d,'if v_has_sauce=0 then','if v_id in (select id from public.products where sku=''SU-003'') then continue;end if;'||chr(10)||'if v_has_sauce=0 then');
 execute d;
end $patch$;

create or replace function public.cct_chicken_mix_cost_report_v1(p_passcode text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare result jsonb;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 perform cct_internal.chicken_reconcile(o.order_token) from public.order_commits o
 where o.status='completed' and exists(select 1 from jsonb_array_elements(o.order_items) v where cct_internal.is_chicken(v))
 order by coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date),o.created_at,o.order_token;
 select coalesce(jsonb_agg(jsonb_build_object(
 'order_token',st.order_token,'order_number',o.order_number,'item_index',st.item_index,'qty',st.qty,'cost',round(c.amount,4),'missing',st.missing,'date',st.sale_date,'method','persisted_component_fifo',
 'requirements',st.requirements) order by st.sale_date,o.order_number,st.item_index),'[]') into result
 from cct_internal.chicken_line_state st join public.order_commits o on o.order_token=st.order_token
 cross join lateral (select coalesce(sum(x.cost),0) amount from (
 select a.extended_cost cost from public.cct_chicken_mix_fifo_allocations a where a.order_token=st.order_token and a.item_index=st.item_index
 union all select a.extended_cost from public.cct_chicken_mix_jelly_allocations a where a.order_token=st.order_token and a.item_index=st.item_index
 union all select a.extended_cost from public.cct_chicken_mix_packaging_allocations a where a.order_token=st.order_token and a.item_index=st.item_index
 union all select a.cost from public.cct_order_sauce_cogs a where a.order_token=st.order_token and a.item_index=st.item_index
 union all select a.cost from cct_internal.chicken_sauce_lots a where a.order_token=st.order_token and a.item_index=st.item_index
 ) x) c
 where o.status='completed' and cct_internal.is_chicken(o.order_items->st.item_index);
 return result;
end $$;
revoke all on all functions in schema cct_internal from public,anon,authenticated;

do $patch$ declare d text;begin
 select pg_get_functiondef('cct_internal.chicken_reconcile(text)'::regprocedure) into d;
 d:=replace(d,'ord.status<>''completed'' or it is null or not cct_internal.is_chicken(it) then',
 'ord.status<>''completed'' or it is null or not cct_internal.is_chicken(it) or coalesce(nullif(it->>''qty'','''')::numeric,1)<=0 then');
 d:=replace(d,'set requirements=''[]'',missing=''[]'',updated_at=now()','set requirements=''[]'',missing=''[]'',qty=coalesce(nullif(it->>''qty'','''')::numeric,0),updated_at=now()');
 execute d;
 select pg_get_functiondef('public.cct_chicken_mix_cost_report_v1(text)'::regprocedure) into d;
 d:=replace(d,'where o.status=''completed'' and cct_internal.is_chicken(o.order_items->st.item_index);','where o.status=''completed'' and st.qty>0 and cct_internal.is_chicken(o.order_items->st.item_index);');
 execute d;
end $patch$;
create function cct_internal.chicken_write_lock() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare needed boolean;
begin
 needed:=exists(select 1 from jsonb_array_elements(coalesce(new.order_items,'[]')) v where cct_internal.is_chicken(v));
 if tg_op='UPDATE' then
  needed:=needed or exists(select 1 from jsonb_array_elements(coalesce(old.order_items,'[]')) v where cct_internal.is_chicken(v));
 end if;
 if needed then
  -- Acquire before the existing sauce reversal trigger to keep lock order consistent.
  perform pg_advisory_xact_lock(321031,2);
  perform pg_advisory_xact_lock(1628018,2);
 end if;
 return new;
end $$;
revoke all on function cct_internal.chicken_write_lock() from public,anon,authenticated;
create trigger aaa_cct_chicken_fifo_lock before insert or update of status,order_items,customer_note,pickup_date,delivery_date,fulfilment_method,order_text on public.order_commits for each row execute function cct_internal.chicken_write_lock();