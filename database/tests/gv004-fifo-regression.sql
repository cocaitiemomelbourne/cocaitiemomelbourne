begin;
do $$
declare t text;ix integer;base numeric;ml numeric;
begin
 select s.order_token,s.item_index into t,ix from cct_internal.gv004_state s limit 1;
 if t is null then raise exception 'Missing historical fixture';end if;
 select sum(used_quantity) into base from cct_production_batches;
 perform cct_internal.gv004_reconcile(t);perform cct_internal.gv004_reconcile(t);
 if (select sum(used_quantity) from cct_production_batches)<>base then raise exception 'Repeated reconciliation consumed stock';end if;
 if exists(select 1 from cct_order_sauce_cogs where order_token=t and item_index=ix) then raise exception 'Duplicate legacy cost';end if;
 update order_commits set order_items=jsonb_set(order_items,array[ix::text,'qty'],'2'::jsonb) where order_token=t;
 select sum(quantity_ml) into ml from cct_internal.gv004_allocations where order_token=t and item_index=ix;
 if ml<>400 then raise exception 'Expected 400ml for 2 portions, got %',ml;end if;
 update order_commits set status='cancelled' where order_token=t;
 if exists(select 1 from cct_internal.gv004_allocations where order_token=t) then raise exception 'Cancellation failed to restore stock';end if;
 update order_commits set status='completed' where order_token=t;
 select sum(quantity_ml) into ml from cct_internal.gv004_allocations where order_token=t and item_index=ix;
 if ml<>400 then raise exception 'Recompletion did not allocate';end if;
 if exists(select 1 from cct_production_batches where used_quantity>quantity or used_quantity<0) then raise exception 'Invalid batch balance';end if;
end $$;
rollback;
select 'PASS: adoption, idempotence, qty edit, cancellation, recompletion, valid balances; rolled back' result;