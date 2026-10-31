begin;
do $$ declare d text;begin
 select pg_get_functiondef('public.cct_ingredient_lot_edit_v2(text,bigint,date,numeric,date,numeric)'::regprocedure) into d;
 d:=replace(d,'public.cct_ingredient_lot_edit_v2','pg_temp.lot_edit_test');
 d:=replace(d,'if not public.cct_production_auth_v1(p_passcode) then raise exception ''not_authorized'';end if;','');
 execute d;
end $$;
create temporary table before_boxes as select quantity,remaining,received_on,total_cost from public.cct_ingredient_lots where id=29;
select pg_temp.lot_edit_test('',29,l.received_on,l.total_cost,l.received_on,40) from public.cct_ingredient_lots l where l.id=29;
do $$ declare l record;begin
 select * into l from public.cct_ingredient_lots where id=29;
 if (select sum(extended_cost) from public.cct_chicken_mix_packaging_allocations where lot_id=29)<>(20-l.remaining)*2 then raise exception 'Allocated box costs not updated';end if;
 if exists(select quantity,remaining,received_on from before_boxes except select quantity,remaining,received_on from public.cct_ingredient_lots where id=29) then raise exception 'Stock changed';end if;
 begin
  perform pg_temp.lot_edit_test('',29,l.received_on,0,l.received_on,50);
  raise exception 'Stale write not rejected';
 exception when raise_exception then if sqlerrm not like 'Lô đã được cập nhật%' then raise;end if;end;
 begin
  perform pg_temp.lot_edit_test('',29,l.received_on,l.total_cost,'2026-10-31',l.total_cost);
  raise exception 'Invalid historical date accepted';
 exception when raise_exception then if sqlerrm not like 'Ngày nhận mới sau%' then raise;end if;end;
 begin
  perform public.cct_ingredient_lot_edit_v2('invalid-test-code',29,l.received_on,l.total_cost,l.received_on,50);
  raise exception 'Authentication bypass';
 exception when raise_exception then if sqlerrm<>'not_authorized' then raise;end if;end;
end $$;
select 'PASS: box recosting, unchanged quantities, optimistic concurrency, receipt-date guard, authentication' result;
rollback;