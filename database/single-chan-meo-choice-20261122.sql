-- Chân Mèo uses the existing Single 250g choice definition.
-- No receipt quantities or costs are changed. Existing allocated recipes are retained.
begin;
select pg_advisory_xact_lock(321031,2);
select pg_advisory_xact_lock(1628018,2);
insert into public.cct_standard_recipe_items(product_id,ingredient_id,ingredient_name,quantity,unit,component_group,notes)
select p.id,c.id,c.name,r.quantity,r.unit,'jellyfish','CHOICE_ONE: Chọn đúng 1 loại sứa; Chân Mèo dùng định mức Single hiện hành'
from public.products p cross join public.cct_ingredient_catalog c
cross join lateral(select quantity,unit from public.cct_standard_recipe_items where product_id=p.id and component_group='jellyfish' order by id limit 1)r
where p.sku='SU-001' and c.sku='NL-SUA-010'
and not exists(select 1 from public.cct_standard_recipe_items x where x.product_id=p.id and x.ingredient_id=c.id);
update cct_internal.single_line_state s set base_recipe=s.base_recipe||jsonb_build_array(
 jsonb_build_object('ingredient_id',c.id,'name',c.name,'sku',c.sku,'unit',r.unit,'group','jellyfish','per_unit',r.quantity,'legacy_selected',false))
from public.cct_ingredient_catalog c
join public.cct_standard_recipe_items r on r.ingredient_id=c.id
join public.products p on p.id=r.product_id and p.sku='SU-001'
where c.sku='NL-SUA-010' and s.missing @> '["Chưa xác định đúng một loại sứa"]'::jsonb
and not exists(select 1 from jsonb_array_elements(s.base_recipe)v where (v->>'ingredient_id')::bigint=c.id)
and exists(select 1 from public.order_commits o where o.order_token=s.order_token and cct_internal.single_normalize(o.order_items->s.item_index->>'option_text') like '%chan meo%');
select cct_internal.single_reconcile('manual-b2188862-259f-45fc-9ac0-876862bcd0c6');
commit;
