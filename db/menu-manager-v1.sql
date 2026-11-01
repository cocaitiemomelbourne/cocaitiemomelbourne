
alter table public.products add column if not exists is_featured boolean not null default false;
alter table public.products_draft add column if not exists is_featured boolean not null default false;
create table if not exists public.cct_menu_requests(request_id uuid primary key,product_id bigint not null references public.products(id),created_at timestamptz not null default now());
alter table public.cct_menu_requests enable row level security;
revoke all on public.cct_menu_requests from public,anon,authenticated;
create or replace function public.cct_menu_authorize_v1(p_passcode text) returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare h text;begin select pass_hash into h from public.print_admin_access where id=1;if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized';end if; return true;end $$;
create or replace function public.cct_menu_list_v1(p_passcode text) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare h text;v jsonb;c jsonb;begin select pass_hash into h from public.print_admin_access where id=1;if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized';end if;
select coalesce(jsonb_agg(to_jsonb(p) order by p.sort_order,p.id),'[]') into v from public.products p;
select coalesce(jsonb_agg(to_jsonb(t) order by t.sort_order,t.slug),'[]') into c from public.product_categories t;
return jsonb_build_object('products',v,'categories',c);end $$;
create or replace function public.cct_menu_save_v1(p_passcode text,p_product_id bigint,p_expected_updated_at timestamptz,p_request_id uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare h text;p public.products%rowtype;v public.products%rowtype;rid bigint;new_name text;cat text;cats text[];img text;mode text;is_pre boolean;pr numeric;sortn integer;featured boolean;prefix text;seqn integer;sku_new text;created boolean:=false;
begin select pass_hash into h from public.print_admin_access where id=1;if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized';end if;
if p_request_id is null or p_data is null or jsonb_typeof(p_data)<>'object' then raise exception 'invalid_payload';end if;
perform pg_advisory_xact_lock(hashtext('cct-menu-request-'||p_request_id::text));
select product_id into rid from public.cct_menu_requests where request_id=p_request_id;
if found then return (select to_jsonb(z) from public.products z where id=rid);end if;
new_name:=btrim(coalesce(p_data->>'name',''));cat:=p_data->>'category';mode:=p_data->>'mode';img:=btrim(coalesce(p_data->>'image_url',''));
if length(new_name) not between 2 and 160 or length(coalesce(p_data->>'name_en',''))>160 or length(coalesce(p_data->>'description',''))>5000 or length(coalesce(p_data->>'description_en',''))>5000 then raise exception 'invalid_text';end if;
if coalesce(p_data->>'price','') !~ '^[0-9]{1,7}([.][0-9]{1,2})?$' then raise exception 'invalid_price';end if;
pr:=(p_data->>'price')::numeric;
if pr>1000000 or (mode='menu' and pr<=0) then raise exception 'menu_price_required';end if;
if mode is null or mode not in ('menu','private') then raise exception 'invalid_mode';end if;
if cat is null or not (exists(select 1 from public.product_categories where slug=cat and is_active) or (mode='private' and cat in ('giavi','mam','banh','private','raucusay','traicaychebien'))) then raise exception 'invalid_category';end if;
if coalesce(p_data->>'sort_order','') !~ '^[0-9]{1,6}$' then raise exception 'invalid_sort';end if;
sortn:=(p_data->>'sort_order')::integer;is_pre:=coalesce((p_data->>'preorder')::boolean,false);featured:=coalesce((p_data->>'is_featured')::boolean,false);
if img<>'' and (length(img)>2000 or img !~ '^https://[^[:space:]]+$') then raise exception 'invalid_image_url';end if;
cats:=array[cat];
if jsonb_typeof(p_data->'categories')='array' then
select coalesce(array_agg(distinct e.value),'{}') into cats from jsonb_array_elements_text(p_data->'categories') e where e.value=cat or exists(select 1 from public.product_categories where slug=e.value and is_active and slug<>'dattruoc');
if not cat=any(cats) then cats:=array_prepend(cat,cats);end if;
end if;
cats:=array_remove(cats,'dattruoc');
if is_pre or cat='dattruoc' then cats:=array_append(cats,'dattruoc');end if;
if p_product_id is null then
perform pg_advisory_xact_lock(hashtext('cct-menu-create-name'));
if exists(select 1 from public.products where lower(name)=lower(new_name)) then raise exception 'name_exists';end if;
prefix:=case cat when 'traicaysay' then 'TC' when 'banhtrang' then 'BT' when 'kho' then 'KH' when 'mam' then 'MM' when 'mientay' then 'MM' when 'sua' then 'SU' when 'haisan' then 'HS' when 'banh' then 'BA' when 'giavi' then 'GV' when 'raucusay' then 'RC' when 'traicaychebien' then 'TF' when 'khac' then 'AV' else 'BR' end;
if coalesce(p_data->>'sku_group','')<>'' then
if p_data->>'sku_group' not in ('BT','KH','MM','SU','HS','TC','BA','GV','AV','RC','TF','BR') then raise exception 'invalid_sku_group';end if;
prefix:=p_data->>'sku_group';end if;
perform pg_advisory_xact_lock(hashtext('cct_sku_'||prefix));
select coalesce(max(substring(sku from '[0-9]+$')::int),0)+1 into seqn from public.products where sku like prefix||'-%';
sku_new:=prefix||'-'||lpad(seqn::text,greatest(3,length(seqn::text)),'0');
insert into public.products(name,price,category,categories,description,name_en,description_en,image_url,is_active,cost_only,sort_order,is_featured,sku,sku_group,stock_qty)
values(new_name,pr,cat,cats,coalesce(p_data->>'description',''),nullif(btrim(p_data->>'name_en'),''),nullif(p_data->>'description_en',''),img,mode='menu',mode='private',sortn,featured,sku_new,prefix,0) returning * into p;created:=true;
-- New items begin with physical stock 0 and may receive preorders.
if mode='menu' and not is_pre then raise exception 'new_product_use_preorder';end if;
else
select * into p from public.products where id=p_product_id for update;
if not found then raise exception 'product_not_found';end if;
if p.updated_at is distinct from p_expected_updated_at then raise exception 'product_changed_reload';end if;
if mode='menu' and p.stock_qty=0 and not is_pre then raise exception 'zero_stock_use_preorder';end if;
end if;
update public.products set name=new_name,name_en=nullif(btrim(p_data->>'name_en'),''),price=pr,category=cat,categories=cats,description=coalesce(p_data->>'description',''),description_en=nullif(p_data->>'description_en',''),image_url=img,sort_order=sortn,is_active=mode='menu',cost_only=mode='private',is_featured=featured,updated_at=clock_timestamp() where id=p.id returning * into v;
insert into public.products_draft(id,name,name_en,price,category,categories,description,description_en,image_url,emoji,sort_order,is_active,stock_qty,option_groups,option_groups_en,is_featured,updated_at)
values(v.id,v.name,v.name_en,v.price,v.category,v.categories,v.description,v.description_en,v.image_url,v.emoji,v.sort_order,v.is_active,v.stock_qty,v.option_groups,v.option_groups_en,v.is_featured,v.updated_at)
on conflict(id) do update set name=excluded.name,name_en=excluded.name_en,price=excluded.price,category=excluded.category,categories=excluded.categories,description=excluded.description,description_en=excluded.description_en,image_url=excluded.image_url,sort_order=excluded.sort_order,is_active=excluded.is_active,is_featured=excluded.is_featured,updated_at=excluded.updated_at;
insert into public.cct_stock_audit(product_id,product_name,old_qty,new_qty,action,details) values(v.id,v.name,p.stock_qty,v.stock_qty,'menu_content',jsonb_build_object('created',created,'old_visible',case when created then false else p.is_active end,'new_visible',v.is_active,'old_private',p.cost_only,'new_private',v.cost_only));
insert into public.cct_menu_requests(request_id,product_id) values(p_request_id,v.id);
return to_jsonb(v);end $$;
CREATE OR REPLACE FUNCTION public.cct_stock_menu_save_v1(p_passcode text, p_product_id bigint, p_expected_updated_at timestamp with time zone, p_preorder boolean DEFAULT NULL::boolean, p_visible boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare h text; p public.products%rowtype; cats text[]; base text;
begin
select pass_hash into h from public.print_admin_access where id=1;
if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'::text),'hex') <> h then raise exception 'not_authorized'; end if;
if p_preorder is null and p_visible is null then raise exception 'no_changes'; end if;
select * into p from public.products where id=p_product_id for update;
if not found then raise exception 'product_not_found'; end if;
if p.updated_at is distinct from p_expected_updated_at then raise exception 'product_changed_reload'; end if;
if p_visible is true and coalesce(p.price,0)<=0 then raise exception 'menu_price_required'; end if;
if p_preorder is false and p.stock_qty=0 then raise exception 'zero_stock_use_preorder'; end if;
cats:=coalesce(p.categories,array[]::text[]); base:=p.category;
if p_preorder is not null then
 cats:=array_remove(cats,'dattruoc');
 if base='dattruoc' then
  base:=coalesce((select c from unnest(cats) c where c<>'dattruoc' limit 1),
   case split_part(p.sku,'-',1) when 'BT' then 'banhtrang' when 'KH' then 'kho' when 'MM' then 'mam' when 'TC' then 'traicaysay' when 'SU' then 'sua' when 'HS' then 'haisan' else 'khac' end);
 end if;
 if coalesce(array_length(cats,1),0)=0 then cats:=array[coalesce(base,'khac')]; end if;
 if p_preorder then cats:=array_append(cats,'dattruoc'); end if;
end if;
if p_visible is true and p.stock_qty=0 and p_preorder is null and not ('dattruoc'=any(cats)) then cats:=array_append(cats,'dattruoc');end if;
update public.products set category=base,categories=cats,is_active=coalesce(p_visible,is_active),cost_only=case when p_visible is not null then not p_visible else cost_only end,updated_at=clock_timestamp() where id=p.id;
update public.products_draft d set category=q.category,categories=q.categories,is_active=q.is_active,updated_at=q.updated_at from public.products q where q.id=p.id and d.id=q.id;
if p.category is distinct from base or p.categories is distinct from cats or (p_visible is not null and p_visible is distinct from p.is_active) then
insert into public.cct_stock_audit(product_id,product_name,old_qty,new_qty,action,details)
values(p.id,p.name,p.stock_qty,p.stock_qty,'menu',jsonb_build_object('old_visible',p.is_active,'new_visible',coalesce(p_visible,p.is_active),'old_preorder',coalesce(p.category='dattruoc' or 'dattruoc'=any(p.categories),false),'new_preorder',coalesce(base='dattruoc' or 'dattruoc'=any(cats),false)));
end if;
return (select to_jsonb(t) from (select id,sku,name,category,categories,stock_qty,is_active,cost_only,updated_at from public.products where id=p.id)t);
end $function$
;revoke all on function public.cct_menu_authorize_v1(text) from public;grant execute on function public.cct_menu_authorize_v1(text) to anon,authenticated;revoke all on function public.cct_menu_list_v1(text) from public;grant execute on function public.cct_menu_list_v1(text) to anon,authenticated;revoke all on function public.cct_menu_save_v1(text,bigint,timestamptz,uuid,jsonb) from public;grant execute on function public.cct_menu_save_v1(text,bigint,timestamptz,uuid,jsonb) to anon,authenticated;CREATE OR REPLACE FUNCTION public.publish_menu_from_draft()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
 IF new.publish_now = true AND old.publish_now IS DISTINCT FROM true THEN
  INSERT INTO public.products
   (id,name,name_en,price,category,categories,emoji,description,description_en,image_url,sort_order,is_active,updated_at,stock_qty,option_groups,option_groups_en,is_featured)
  SELECT id,name,name_en,price,
   CASE WHEN coalesce(array_length(categories,1),0)>0 THEN categories[1] ELSE category END,
   CASE WHEN coalesce(array_length(categories,1),0)>0 THEN categories WHEN category IS NOT NULL AND btrim(category)<>'' THEN array[category] ELSE '{}'::text[] END,
   emoji,description,description_en,image_url,sort_order,is_active,now(),stock_qty,option_groups,option_groups_en,is_featured
  FROM public.products_draft
  ON CONFLICT (id) DO UPDATE SET
   name=EXCLUDED.name,name_en=EXCLUDED.name_en,price=EXCLUDED.price,
   category=EXCLUDED.category,categories=EXCLUDED.categories,emoji=EXCLUDED.emoji,
   description=EXCLUDED.description,description_en=EXCLUDED.description_en,
   image_url=EXCLUDED.image_url,sort_order=EXCLUDED.sort_order,is_active=EXCLUDED.is_active,
   updated_at=EXCLUDED.updated_at,stock_qty=EXCLUDED.stock_qty,
   option_groups=EXCLUDED.option_groups,option_groups_en=EXCLUDED.option_groups_en,is_featured=EXCLUDED.is_featured;
  new.publish_now:=false;
  new.last_published_at:=now();
 END IF;
 RETURN new;
END;
$function$
;