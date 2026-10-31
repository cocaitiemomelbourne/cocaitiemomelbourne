
create schema if not exists cct_internal;
revoke all on schema cct_internal from public,anon,authenticated;
create or replace function cct_internal.combo_reconcile(p_token text) returns void
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare o public.order_commits%rowtype; it jsonb; ix int; sold date; q numeric; x record; l record; need numeric; take numeric; chosen bigint[]; got numeric; species int;
begin
 perform pg_advisory_xact_lock(321031,2);
 select * into o from public.order_commits where order_token=p_token;
 if not found then return; end if;
 sold:=coalesce(case when lower(o.fulfilment_method) like '%pickup%' then o.pickup_date else o.delivery_date end,o.delivery_date,o.pickup_date);
 -- Return allocations only for a changed/removed line, changed date, or reversed completion.
 for x in select a.item_index from public.cct_combo_fifo_allocations a where a.order_token=p_token group by a.item_index loop
  it:=o.order_items->x.item_index;
  q:=coalesce(nullif(it->>'qty','')::numeric,1);
  if o.status<>'completed' or sold is null or it is null or
    not (coalesce(it->>'id',it->>'product_id','')='2' or lower(coalesce(it->>'name','')) like '%sứa combo%') or
    (select sum(a.grams)<>400*q or count(distinct a.ingredient_id)<>5 or bool_or(a.sale_date<>sold) from public.cct_combo_fifo_allocations a where a.order_token=p_token and a.item_index=x.item_index) then
   for l in select lot_id,sum(grams) grams from public.cct_combo_fifo_allocations where order_token=p_token and item_index=x.item_index group by lot_id order by lot_id loop
    update public.cct_ingredient_lots set remaining=remaining+l.grams where id=l.lot_id;
   end loop;
   delete from public.cct_combo_fifo_allocations where order_token=p_token and item_index=x.item_index;
  end if;
 end loop;
 if o.status<>'completed' or sold is null then return; end if;
 -- Lock the pool in a stable order, shared by every invocation.
 perform l.id from public.cct_ingredient_lots l join public.cct_ingredient_catalog c on c.id=l.ingredient_id where c.sku like 'NL-SUA-%' order by l.id for update of l;
 for it,ix in select value,(ordinality-1)::int from jsonb_array_elements(o.order_items) with ordinality loop
  if not (coalesce(it->>'id',it->>'product_id','')='2' or lower(coalesce(it->>'name','')) like '%sứa combo%') then continue; end if;
  q:=coalesce(nullif(it->>'qty','')::numeric,1);
  if q<=0 or exists(select 1 from public.cct_combo_fifo_allocations where order_token=p_token and item_index=ix) then continue; end if;
  -- Cheapest five species; price each species using its oldest available lot.
  select array_agg(z.ingredient_id order by z.unit_cost,z.ingredient_id) into chosen from (
   select h.ingredient_id,h.unit_cost from (
    select distinct on(l.ingredient_id) l.ingredient_id,l.total_cost/l.quantity unit_cost
    from public.cct_ingredient_lots l join public.cct_ingredient_catalog c on c.id=l.ingredient_id
    where c.sku like 'NL-SUA-%' and l.received_on<=sold and l.remaining>0 and l.quantity>0 and l.unit='g'
      and (select sum(v.remaining) from public.cct_ingredient_lots v where v.ingredient_id=l.ingredient_id and v.received_on<=sold and v.unit='g' and v.quantity>0 and v.remaining>0)>=80*q
    order by l.ingredient_id,l.received_on,l.id
   ) h order by h.unit_cost,h.ingredient_id limit 5
  ) z;
  if coalesce(array_length(chosen,1),0)<>5 then continue; end if;
  foreach species in array chosen loop
   need:=80*q;
   for l in select * from public.cct_ingredient_lots where ingredient_id=species and received_on<=sold and remaining>0 and quantity>0 and unit='g' order by received_on,id loop
    exit when need<=0;
    take:=least(need,l.remaining);
    insert into public.cct_combo_fifo_allocations(order_token,item_index,order_number,sale_date,lot_id,ingredient_id,grams,unit_cost,extended_cost)
      values(p_token,ix,o.order_number,sold,l.id,species,take,l.total_cost/l.quantity,round(take*l.total_cost/l.quantity,4));
    update public.cct_ingredient_lots set remaining=remaining-take where id=l.id;
    need:=need-take;
   end loop;
   if need<>0 then raise exception 'combo_fifo_concurrent_shortage'; end if;
  end loop;
 end loop;
end $$;
revoke all on function cct_internal.combo_reconcile(text) from public,anon,authenticated;
create or replace function cct_internal.combo_order_trigger() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
begin
 perform cct_internal.combo_reconcile(new.order_token);
 return null;
end $$;
revoke all on function cct_internal.combo_order_trigger() from public,anon,authenticated;
create trigger cct_combo_fifo_auto after insert or update of status,order_items,pickup_date,delivery_date,fulfilment_method on public.order_commits for each row execute function cct_internal.combo_order_trigger();
-- Patch the existing authenticated report: retry pending lines and validate species/weight, not lot-row count.
do $patch$
declare def text;
begin
 select pg_get_functiondef('public.cct_combo_fifo_cost_report_v2(text)'::regprocedure) into def;
 def:=replace(def,'source:=public.cct_combo5_cost_report_v1(p_passcode);',
 'perform cct_internal.combo_reconcile(o.order_token) from public.order_commits o where o.status=''completed'' order by coalesce(o.delivery_date,o.pickup_date),o.created_at,o.order_token;
 source:=public.cct_combo5_cost_report_v1(p_passcode);');
 def:=replace(def,'qty_cost is null or jsonb_array_length(coalesce(picked,''[]''::jsonb))<>5',
 'qty_cost is null or not (select count(distinct a.ingredient_id)=5 and sum(a.grams)=400*(item->>''qty'')::numeric and not exists(select 1 from public.cct_combo_fifo_allocations b where b.order_token=item->>''order_token'' and b.item_index=(item->>''item_index'')::int group by b.ingredient_id having sum(b.grams)<>80*(item->>''qty'')::numeric) from public.cct_combo_fifo_allocations a where a.order_token=item->>''order_token'' and a.item_index=(item->>''item_index'')::int)');
 execute def;
end $patch$;

do $$ declare d text; begin select pg_get_functiondef('cct_internal.combo_reconcile(text)'::regprocedure) into d; d:=replace(d,'declare o public.order_commits%rowtype;','#variable_conflict use_column'||chr(10)||'declare o public.order_commits%rowtype;'); execute d; end $$;
do $patch$ declare d text; begin
select pg_get_functiondef('public.cct_combo5_cost_report_v1(text)'::regprocedure) into d;
d:=replace(d,'select b.* into sauce_batch',
'cost_sauce:=component.quantity*qty;
if lower(coalesce(it->>''option_text'','''')) ~ ''only[[:space:]]+(sốt[[:space:]]+)?(thái|thai)'' then
 if sauce_code<>''SOT-THAI'' then continue; end if; cost_sauce:=400*qty;
elsif lower(coalesce(it->>''option_text'','''')) ~ ''only[[:space:]]+(sốt[[:space:]]+)?(mắm[[:space:]]+nhĩ|mam[[:space:]]+nhi)'' then
 if sauce_code<>''SOT-MAM-NHI'' then continue; end if; cost_sauce:=400*qty;
end if;
if exists(select 1 from public.cct_order_sauce_cogs a where a.order_token=o.order_token and a.item_index=ix and a.sauce_sku=sauce_code and a.quantity_ml=cost_sauce) then
 select extras+sum(a.cost) into extras from public.cct_order_sauce_cogs a where a.order_token=o.order_token and a.item_index=ix and a.sauce_sku=sauce_code;
 continue;
end if;
select b.* into sauce_batch');
d:=replace(d,'component.quantity*qty*case when o.order_number','cost_sauce*case when o.order_number');
execute d;
end $patch$;