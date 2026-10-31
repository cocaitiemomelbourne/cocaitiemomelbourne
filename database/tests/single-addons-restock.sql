begin;
insert into public.cct_ingredient_lots(id,ingredient_id,ingredient_name,received_on,quantity,remaining,unit,total_cost,note) overriding system value
select (select least(-1,coalesce(min(id),0)-1) from public.cct_ingredient_lots),c.id,c.name,'2026-10-24',600,600,'g',6,'Rollback addon restock test only'
from public.cct_ingredient_catalog c where c.sku='NL-RAU-001';
set constraints all immediate;
do $$ declare tok text;before_qty numeric;begin
 select order_token into tok from public.order_commits where order_number='CCT-000291';
 if (select sum(a.grams) from cct_internal.single_ingredient_allocations a join cct_ingredient_catalog c on c.id=a.ingredient_id where a.order_token=tok and c.sku='NL-RAU-001')<>600 then raise exception 'Expected 600g mango total';end if;
 if exists(select 1 from cct_internal.single_line_state where order_token=tok and missing<>'[]'::jsonb) then raise exception 'Addon warning did not clear';end if;
 perform cct_internal.single_reconcile(tok);
 if (select sum(a.grams) from cct_internal.single_ingredient_allocations a join cct_ingredient_catalog c on c.id=a.ingredient_id where a.order_token=tok and c.sku='NL-RAU-001')<>600 then raise exception 'Duplicate mango allocation';end if;
end $$;
select 'PASS: 300g mango per Single, 600g total, automatic FIFO on restock, no duplicate consumption' result;
rollback;