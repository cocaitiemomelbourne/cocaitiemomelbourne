begin;
create table if not exists cct_internal.order_addon_weights(code text primary key,grams numeric not null check(grams>0));
alter table cct_internal.order_addon_weights enable row level security;
revoke all on cct_internal.order_addon_weights from public,anon,authenticated;
insert into cct_internal.order_addon_weights values('jellyfish',150),('chicken',100),('egg',50) on conflict(code) do update set grams=excluded.grams;
do $$
declare n text;d text;
begin
 foreach n in array array['chicken','single'] loop
 if to_regprocedure('cct_internal.'||n||'_requirements_before_addons_v1(jsonb,text,jsonb)') is null then
 select pg_get_functiondef(to_regprocedure('cct_internal.'||n||'_requirements(jsonb,text,jsonb)')) into d;
 execute replace(d,'FUNCTION cct_internal.'||n||'_requirements(','FUNCTION cct_internal.'||n||'_requirements_before_addons_v1(');
 end if;
 end loop;
end $$;
create or replace function cct_internal.requirements_with_addons(p_item jsonb,p_note text,p_base jsonb,p_kind text) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,cct_internal as $$
declare segment text;head text;tail text;clean text:='';adds jsonb:='[]';plan jsonb;req jsonb;q numeric:=coalesce((p_item->>'qty')::numeric,1);cid bigint;cname text;g numeric;n numeric;addon_key text;
begin
 for segment in select regexp_split_to_table(coalesce(p_item->>'option_text',''),'[•]') loop
  head:=cct_internal.chicken_normalize(split_part(segment,':',1));
  tail:=cct_internal.chicken_normalize(substr(segment,position(':' in segment)+1));
  addon_key:=null;cid:=null;n:=1;
  if position(':' in segment)>0 and head ~ '^them sua phan [0-9]+ ' then
   select id,name into cid,cname from public.cct_ingredient_catalog where sku like 'NL-SUA-%' and cct_internal.chicken_normalize(name)=tail;
   if cid is not null then addon_key:='jellyfish';end if;
  elsif position(':' in segment)>0 and head ~ '^them chan ga rut xuong ' and tail ~ '^[0-9]+ phan$' then
   cid:=12;cname:='Chân gà rút xương';addon_key:='chicken';n:=split_part(tail,' ',1)::numeric;
  elsif position(':' in segment)>0 and head ~ '^them trung non ' and tail ~ '^[0-9]+ phan$' then
   cid:=14;cname:='Trứng non';addon_key:='egg';n:=split_part(tail,' ',1)::numeric;
  end if;
  if addon_key is not null and n between 1 and 99 then
   select grams into g from cct_internal.order_addon_weights where order_addon_weights.code=addon_key;
   adds:=adds||jsonb_build_array(jsonb_build_object('ingredient_id',cid,'name',cname,'unit','g','group',case when addon_key='jellyfish' then 'jellyfish' else 'ingredient' end,'per_unit',g*n,'quantity',g*n*q));
  else clean:=clean||case when clean='' then '' else ' • ' end||btrim(segment);end if;
 end loop;
 if p_kind='chicken' then plan:=cct_internal.chicken_requirements_before_addons_v1(p_item||jsonb_build_object('option_text',clean),p_note,p_base);
 else plan:=cct_internal.single_requirements_before_addons_v1(p_item||jsonb_build_object('option_text',clean),p_note,p_base);end if;
 if adds='[]'::jsonb then return plan;end if;
 select coalesce(jsonb_agg(jsonb_build_object('ingredient_id',x.cid,'name',x.nm,'unit',x.u,'group',x.grp,'per_unit',x.pu,'quantity',x.qty) order by x.cid,x.grp),'[]') into req from (
 select (v->>'ingredient_id')::bigint cid,min(v->>'name') nm,v->>'unit' u,v->>'group' grp,sum((v->>'per_unit')::numeric) pu,sum((v->>'quantity')::numeric) qty from jsonb_array_elements((plan->'requirements')||adds)v group by (v->>'ingredient_id')::bigint,v->>'unit',v->>'group'
 )x;
 return jsonb_build_object('requirements',req,'missing',plan->'missing');
end $$;
create or replace function cct_internal.chicken_requirements(p_item jsonb,p_note text,p_base jsonb) returns jsonb language sql stable set search_path=pg_catalog,public,cct_internal as $$select cct_internal.requirements_with_addons(p_item,p_note,p_base,'chicken')$$;
create or replace function cct_internal.single_requirements(p_item jsonb,p_note text,p_base jsonb) returns jsonb language sql stable set search_path=pg_catalog,public,cct_internal as $$select cct_internal.requirements_with_addons(p_item,p_note,p_base,'single')$$;
revoke all on function cct_internal.requirements_with_addons(jsonb,text,jsonb,text),cct_internal.chicken_requirements_before_addons_v1(jsonb,text,jsonb),cct_internal.single_requirements_before_addons_v1(jsonb,text,jsonb) from public,anon,authenticated;
commit;