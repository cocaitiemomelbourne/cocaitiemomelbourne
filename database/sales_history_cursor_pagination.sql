create or replace function public.cct_sales_history_page_v1(p_passcode text,p_before_token text default null,p_before_created timestamptz default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare h text; result jsonb;
begin
select pass_hash into h from public.print_admin_access where id=1;
if h is null or encode(extensions.digest(('cct-print-v1-20260924'||coalesce(p_passcode,''))::text,'sha256'),'hex')<>h then raise exception 'not_authorized'; end if;
if (p_before_token is null)<>(p_before_created is null) then raise exception 'invalid_cursor'; end if;
select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.order_token desc),'[]'::jsonb) into result from (
select order_token,order_number,status,created_at,fulfilment_method,pickup_date,delivery_date,items,order_items,order_text
from public.order_commits where status='completed' and (p_before_created is null or (created_at,order_token)<(p_before_created,p_before_token))
order by created_at desc,order_token desc limit 500) x;
return result;
end $$;
revoke all on function public.cct_sales_history_page_v1(text,text,timestamptz) from public;
grant execute on function public.cct_sales_history_page_v1(text,text,timestamptz) to anon,authenticated;
notify pgrst,'reload schema';