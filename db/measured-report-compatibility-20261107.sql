-- Include measured FIFO costs in the existing report endpoint so cached dashboards also receive them.
CREATE OR REPLACE FUNCTION public.cct_confirmed_line_cost_report_v1(p_passcode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cct_internal'
AS $function$
declare outv jsonb;
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 perform cct_internal.confirmed_line_reconcile(o.order_token) from public.order_commits o where exists(select 1 from cct_internal.confirmed_line_rules r where r.order_token=o.order_token) order by coalesce(o.pickup_date,o.delivery_date),o.created_at,o.order_token;
 select coalesce(jsonb_agg(jsonb_build_object('order_token',r.order_token,'item_index',r.item_index,'display_name',r.display_name,'display_sku',r.display_sku,
 'cost',coalesce(a.amount,0),'missing',coalesce(m.errs,'[]'::jsonb),'parts',coalesce(a.parts,'[]'::jsonb))),'[]'::jsonb) into outv
 from cct_internal.confirmed_line_rules r join public.order_commits o on o.order_token=r.order_token
 cross join lateral (select coalesce(nullif(o.order_items->r.item_index->>'qty','')::numeric,0) q) q
 left join lateral(select sum(round(x.quantity*l.total_cost/nullif(l.quantity,0),4)) amount,jsonb_agg(jsonb_build_object('lot_id',l.id,'ingredient',l.ingredient_name,'quantity',x.quantity,'unit',l.unit)) parts from cct_internal.confirmed_line_allocations x join public.cct_ingredient_lots l on l.id=x.lot_id where x.order_token=r.order_token and x.item_index=r.item_index) a on true
 left join lateral(select jsonb_agg(c.name||': đã phân bổ '||coalesce(g.actual,0)||'/'||((req->>'per_unit')::numeric*q.q)||' '||c.unit||' từ lô không muộn hơn ngày bán') errs from jsonb_array_elements(r.requirements) req join public.cct_ingredient_catalog c on c.id=(req->>'ingredient_id')::bigint
 left join lateral(select sum(x.quantity) actual from cct_internal.confirmed_line_allocations x join public.cct_ingredient_lots l on l.id=x.lot_id where x.order_token=r.order_token and x.item_index=r.item_index and l.ingredient_id=c.id) g on true
 where coalesce(g.actual,0)<(req->>'per_unit')::numeric*q.q) m on true
 where o.status='completed' and q.q>0 and o.order_items->r.item_index->>'confirmed_component_rule'=r.rule_key;
 return outv||public.cct_measured_cost_report_v1(p_passcode);
end $function$
;
