
create table cct_internal.single_addons(
 order_token text not null references public.order_commits(order_token),
 item_index integer not null,
 ingredient_id bigint not null references public.cct_ingredient_catalog(id),
 quantity_per_unit numeric not null check(quantity_per_unit>0),
 unit text not null,
 approved_note text not null check(approved_note<>''),
 primary key(order_token,item_index,ingredient_id)
);
alter table cct_internal.single_addons enable row level security;
revoke all on cct_internal.single_addons from public,anon,authenticated;
do $patch$ declare d text;begin
 select pg_get_functiondef('cct_internal.single_reconcile(text)'::regprocedure) into d;
 d:=replace(d,
 'plan:=cct_internal.single_requirements(it,ord.customer_note,st.base_recipe);',
 'select st.base_recipe||coalesce(jsonb_agg(jsonb_build_object(
 ''ingredient_id'',a.ingredient_id,''name'',c.name,''sku'',c.sku,''unit'',a.unit,
 ''group'',''addon'',''per_unit'',a.quantity_per_unit,''approved_note'',a.approved_note)),''[]''::jsonb)
 into base from cct_internal.single_addons a join public.cct_ingredient_catalog c on c.id=a.ingredient_id
 where a.order_token=p_token and a.item_index=ix
 and position(a.approved_note in cct_internal.chicken_normalize(coalesce(it->>''option_text'','''')))>0;
 plan:=cct_internal.single_requirements(it,ord.customer_note,base);');
 execute d;
 select pg_get_functiondef('cct_internal.single_requirements(jsonb,text,jsonb)'::regprocedure) into d;
 d:=replace(d,'if txt ~ ''(them|extra|add on|thay|doi)''',
 'rest:=txt;
 for v in select value from jsonb_array_elements(p_base) where value->>''group''=''addon'' and (value->>''per_unit'')::numeric>0 and coalesce(value->>''approved_note'','''')<>'''' loop
  rest:=replace(rest,v->>''approved_note'','' '');
 end loop;
 if rest ~ ''(them|extra|add on|thay|doi)''');
 execute d;
end $patch$;
