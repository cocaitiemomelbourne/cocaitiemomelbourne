CREATE OR REPLACE FUNCTION cct_internal.is_chicken(v jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
 select coalesce(v->>'sale_mode','')<>'measured' and (coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku in ('SU-003','AV-015'))
 or cct_internal.chicken_normalize(v->>'name') like 'sua tron chan ga%'
 or cct_internal.chicken_normalize(v->>'name') ~ '^chan ga (tron sua|mix sua)( |$)')
$function$
;
CREATE OR REPLACE FUNCTION cct_internal.chicken_base(p_token text, p_ix integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare v jsonb; q numeric; b jsonb; j jsonb;
begin
 select order_items->p_ix into v from public.order_commits where order_token=p_token;
 q:=coalesce(nullif(v->>'qty','')::numeric,1);
 select coalesce(jsonb_agg(jsonb_build_object('ingredient_id',t.ingredient_id,'name',t.ingredient_name,'unit',t.unit,'group',case when coalesce(v->>'id',v->>'product_id','') in(select id::text from public.products where sku='AV-015') and t.component_group not in('sauce','packaging') then 'ingredient' else t.component_group end,'per_unit',t.quantity) order by t.ingredient_id),'[]')
 into b from (
  select i.ingredient_id,min(i.ingredient_name) ingredient_name,i.unit,i.component_group,sum(i.quantity) quantity
  from public.cct_standard_recipe_items i join public.products p on p.id=i.product_id
  where p.sku=case when coalesce(v->>'id',v->>'product_id','') in(select id::text from public.products where sku='AV-015') then 'AV-015' else 'SU-003' end and i.ingredient_id is not null
  group by i.ingredient_id,i.unit,i.component_group
 ) t;
 -- Preserve verified historical species/extra grams, even when old order text was blank.
 select jsonb_agg(jsonb_build_object('ingredient_id',a.ingredient_id,'name',c.name,'unit','g','group','jellyfish','per_unit',a.grams/q) order by a.ingredient_id)
 into j from (select ingredient_id,sum(grams) grams from public.cct_chicken_mix_jelly_allocations where order_token=p_token and item_index=p_ix group by ingredient_id) a join public.cct_ingredient_catalog c on c.id=a.ingredient_id;
 return b||coalesce(j,'[]');
end $function$
;
create or replace function cct_internal.chicken_requirements(p_item jsonb,p_note text,p_base jsonb) returns jsonb language sql stable set search_path=pg_catalog,public,cct_internal as $$
select cct_internal.requirements_with_addons(p_item,case when coalesce(p_item->>'id',p_item->>'product_id','') in(select id::text from public.products where sku='AV-015') then coalesce(p_note,'')||' không sứa' else p_note end,p_base,'chicken')$$;
-- Remove legacy sauce rows on the newly supported line once, before adopting its actual recipe.
do $$ declare o record;i record;begin
 for o in select * from public.order_commits where status='completed' loop
 for i in select value v,(ordinality-1)::int ix from jsonb_array_elements(o.order_items) with ordinality where coalesce(value->>'id',value->>'product_id','') in(select id::text from public.products where sku='AV-015') loop
 if not exists(select 1 from cct_internal.chicken_line_state where order_token=o.order_token and item_index=i.ix) then
 perform pg_advisory_xact_lock(321031,2);perform pg_advisory_xact_lock(1628018,2);
 perform cct_internal.chicken_release(o.order_token,i.ix);
 end if;
 perform cct_internal.chicken_reconcile(o.order_token);
 end loop;end loop;
end $$;