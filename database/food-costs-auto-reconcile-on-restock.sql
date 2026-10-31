
create function cct_internal.refresh_pending_food_costs() returns void
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare o record;
begin
 perform pg_advisory_xact_lock(321031,2);
 perform pg_advisory_xact_lock(1628018,2);
 -- Preserve stored allocations; each reconciler only fills gaps or reverses an edited line.
 for o in select oc.order_token,
  exists(select 1 from jsonb_array_elements(oc.order_items) v where cct_internal.is_chicken(v)) has_chicken,
  exists(select 1 from jsonb_array_elements(oc.order_items) v where coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-002') or lower(coalesce(v->>'name','')) like '%sứa combo%') has_combo
 from public.order_commits oc
 where oc.status='completed' and exists(
  select 1 from jsonb_array_elements(oc.order_items) v
  where cct_internal.is_chicken(v) or coalesce(v->>'id',v->>'product_id','') in (select id::text from public.products where sku='SU-002')
     or lower(coalesce(v->>'name','')) like '%sứa combo%')
 order by coalesce(case when lower(oc.fulfilment_method) like '%pickup%' then oc.pickup_date else oc.delivery_date end,oc.delivery_date,oc.pickup_date),oc.created_at,oc.order_token
 loop
  if o.has_chicken then perform cct_internal.chicken_reconcile(o.order_token);end if;
  if o.has_combo then perform cct_internal.combo_reconcile(o.order_token);end if;
 end loop;
end $$;
revoke all on function cct_internal.refresh_pending_food_costs() from public,anon,authenticated;

create function cct_internal.food_costs_after_restock() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
declare current_tx text:=pg_current_xact_id()::text;
begin
 -- Deferred until the complete stock entry is saved. Run once for all stock rows in that transaction.
 if current_setting('cct.food_costs_restock_tx',true) is distinct from current_tx then
  perform set_config('cct.food_costs_restock_tx',current_tx,true);
  perform cct_internal.refresh_pending_food_costs();
 end if;
 return null;
end $$;
revoke all on function cct_internal.food_costs_after_restock() from public,anon,authenticated;
create constraint trigger cct_food_costs_on_ingredient_insert after insert on public.cct_ingredient_lots
 deferrable initially deferred for each row execute function cct_internal.food_costs_after_restock();
create constraint trigger cct_food_costs_on_ingredient_restock after update on public.cct_ingredient_lots
 deferrable initially deferred for each row
 when(new.remaining>old.remaining or new.quantity is distinct from old.quantity or new.total_cost is distinct from old.total_cost or new.received_on is distinct from old.received_on or new.ingredient_id is distinct from old.ingredient_id or new.unit is distinct from old.unit)
 execute function cct_internal.food_costs_after_restock();
create constraint trigger cct_food_costs_on_sauce_insert after insert on public.cct_production_batches
 deferrable initially deferred for each row execute function cct_internal.food_costs_after_restock();
create constraint trigger cct_food_costs_on_sauce_restock after update on public.cct_production_batches
 deferrable initially deferred for each row
 when(new.quantity>old.quantity or new.used_quantity<old.used_quantity or new.total_cost is distinct from old.total_cost or new.produced_on is distinct from old.produced_on or new.recipe_id is distinct from old.recipe_id or (new.status='open' and new.status is distinct from old.status))
 execute function cct_internal.food_costs_after_restock();
