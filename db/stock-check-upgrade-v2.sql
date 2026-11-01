
alter table public.cct_stock_audit add column if not exists action text not null default 'count', add column if not exists reason text, add column if not exists note text, add column if not exists details jsonb not null default '{}'::jsonb;
create index if not exists cct_stock_audit_product_history on public.cct_stock_audit(product_id,id desc);
create table if not exists public.cct_stock_settings(product_id bigint primary key references public.products(id) on delete cascade, low_threshold integer not null default 3 check(low_threshold between 0 and 1000000));
alter table public.cct_stock_settings enable row level security;
revoke all on public.cct_stock_settings from public,anon,authenticated;
create or replace function public.cct_stock_list_v2(p_passcode text) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare h text; v jsonb; begin select pass_hash into h from public.print_admin_access where id=1;
if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized'; end if;
select coalesce(jsonb_agg(to_jsonb(t) order by t.name),'[]'::jsonb) into v from
(select p.id,p.sku,p.name,p.category,p.categories,p.stock_qty,p.is_active,p.cost_only,p.updated_at,coalesce(s.low_threshold,3) as low_threshold from public.products p left join public.cct_stock_settings s on s.product_id=p.id)t;
return v; end $$;
create or replace function public.cct_stock_save_batch_v2(p_passcode text,p_changes jsonb) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare h text; x jsonb; p public.products%rowtype; n integer; result jsonb:='[]'; r text; note_value text;
begin select pass_hash into h from public.print_admin_access where id=1;
if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized'; end if;
if p_changes is null or jsonb_typeof(p_changes)<>'array' or jsonb_array_length(p_changes) not between 1 and 500 then raise exception 'invalid_changes'; end if;
if (select count(distinct a.value->>'id') from jsonb_array_elements(p_changes) as a(value))<>jsonb_array_length(p_changes) then raise exception 'duplicate_product'; end if;
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
  update public.products set stock_qty=n,updated_at=clock_timestamp() where id=p.id;
  update public.products_draft set stock_qty=n,updated_at=clock_timestamp() where id=p.id;
  insert into public.cct_stock_audit(product_id,product_name,old_qty,new_qty,action,reason,note) values(p.id,p.name,p.stock_qty,n,'count',r,nullif(note_value,''));
 end if;
 result:=result||jsonb_build_array((select to_jsonb(t) from(select id,stock_qty,updated_at from public.products where id=p.id)t));
end loop;
return result; end $$;
create or replace function public.cct_stock_threshold_save_v2(p_passcode text,p_product_id bigint,p_expected_threshold integer,p_threshold integer) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare h text; p public.products%rowtype; old_value integer; begin select pass_hash into h from public.print_admin_access where id=1;
if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized'; end if;
if p_threshold is null or p_threshold not between 0 and 1000000 then raise exception 'invalid_threshold'; end if;
select * into p from public.products where id=p_product_id for update;
if not found then raise exception 'product_not_found'; end if;
select coalesce((select low_threshold from public.cct_stock_settings where product_id=p.id),3) into old_value;
if old_value is distinct from p_expected_threshold then raise exception 'threshold_changed_reload'; end if;
if old_value<>p_threshold then
insert into public.cct_stock_settings values(p.id,p_threshold) on conflict(product_id) do update set low_threshold=excluded.low_threshold;
insert into public.cct_stock_audit(product_id,product_name,old_qty,new_qty,action,details) values(p.id,p.name,p.stock_qty,p.stock_qty,'threshold',jsonb_build_object('old_threshold',old_value,'new_threshold',p_threshold));
end if;
return jsonb_build_object('low_threshold',p_threshold); end $$;
create or replace function public.cct_stock_history_v2(p_passcode text,p_product_id bigint default null,p_before_id bigint default null,p_limit integer default 30) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare h text; v jsonb; begin select pass_hash into h from public.print_admin_access where id=1;
if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized'; end if;
select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc),'[]'::jsonb) into v from
(select a.id,a.product_id,a.product_name,a.old_qty,a.new_qty,a.action,a.reason,a.note,a.details,a.changed_at from public.cct_stock_audit a where (p_product_id is null or a.product_id=p_product_id) and (p_before_id is null or a.id<p_before_id) order by a.id desc limit least(greatest(coalesce(p_limit,30),1),100))t;
return v; end $$;
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
if p_visible is true and p.cost_only then raise exception 'cost_only_product'; end if;
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
update public.products set category=base,categories=cats,is_active=coalesce(p_visible,is_active),updated_at=clock_timestamp() where id=p.id;
update public.products_draft d set category=q.category,categories=q.categories,is_active=q.is_active,updated_at=q.updated_at from public.products q where q.id=p.id and d.id=q.id;
if p.category is distinct from base or p.categories is distinct from cats or (p_visible is not null and p_visible is distinct from p.is_active) then
insert into public.cct_stock_audit(product_id,product_name,old_qty,new_qty,action,details)
values(p.id,p.name,p.stock_qty,p.stock_qty,'menu',jsonb_build_object('old_visible',p.is_active,'new_visible',coalesce(p_visible,p.is_active),'old_preorder',coalesce(p.category='dattruoc' or 'dattruoc'=any(p.categories),false),'new_preorder',coalesce(base='dattruoc' or 'dattruoc'=any(cats),false)));
end if;
return (select to_jsonb(t) from (select id,sku,name,category,categories,stock_qty,is_active,cost_only,updated_at from public.products where id=p.id)t);
end $function$
;revoke all on function public.cct_stock_list_v2(text) from public;grant execute on function public.cct_stock_list_v2(text) to anon,authenticated;revoke all on function public.cct_stock_save_batch_v2(text,jsonb) from public;grant execute on function public.cct_stock_save_batch_v2(text,jsonb) to anon,authenticated;revoke all on function public.cct_stock_threshold_save_v2(text,bigint,integer,integer) from public;grant execute on function public.cct_stock_threshold_save_v2(text,bigint,integer,integer) to anon,authenticated;revoke all on function public.cct_stock_history_v2(text,bigint,bigint,integer) from public;grant execute on function public.cct_stock_history_v2(text,bigint,bigint,integer) to anon,authenticated;
alter table public.cct_stock_audit alter column new_qty drop not null;