begin;
do $$ declare d text;begin
 select pg_get_functiondef('public.cct_ingredient_lot_edit_v3(text,bigint,date,numeric,date,numeric,numeric,numeric,text)'::regprocedure) into d;
 d:=replace(d,'public.cct_ingredient_lot_edit_v3','pg_temp.raw_edit');
 d:=replace(d,'if not public.cct_production_auth_v1(p_passcode) then raise exception ''not_authorized'';end if;','');execute d;
 select pg_get_functiondef('public.cct_retail_lot_edit_v3(text,bigint,date,numeric,integer,date,numeric,integer,text)'::regprocedure) into d;
 d:=replace(d,'public.cct_retail_lot_edit_v3','pg_temp.retail_edit');
 d:=replace(d,'if not public.cct_production_auth_v1(p_passcode) then raise exception ''not_authorized'';end if;','');execute d;
end $$;
do $$ declare l record;b record;begin
 select * into l from cct_ingredient_lots where id=29;
 perform pg_temp.raw_edit('',l.id,l.received_on,l.total_cost,l.received_on,37.50,l.quantity,25,'Test note');
 if not exists(select 1 from cct_ingredient_lots where id=l.id and quantity=25 and remaining=l.remaining+25-l.quantity and total_cost=37.50 and note='Test note') then raise exception 'Raw quantity or note incorrect';end if;
 begin
  perform pg_temp.raw_edit('',l.id,l.received_on,37.50,l.received_on,15,25,1,'Reject below used');
  raise exception 'Allowed below allocated quantity';
 exception when raise_exception then if sqlerrm not like 'Lô đã dùng%' then raise;end if;end;
 select * into b from cct_cost_batches where id=78;
 perform pg_temp.retail_edit('',b.id,b.received_on,b.unit_cost,b.quantity,b.received_on,2.50,40,'Test retail note');
 if not exists(select 1 from cct_cost_batches where id=b.id and quantity=40 and unit_cost=2.50 and note='Test retail note') then raise exception 'Retail edits failed';end if;
 begin
  perform pg_temp.retail_edit('',b.id,b.received_on,b.unit_cost,b.quantity,b.received_on,3,35,'Stale');
  raise exception 'Stale update allowed';
 exception when raise_exception then if sqlerrm not like 'Lô đã thay đổi%' then raise;end if;end;
 begin
  perform public.cct_ingredient_lot_edit_v3('invalid',l.id,l.received_on,37.50,l.received_on,30,25,20,'');
  raise exception 'Auth bypass';
 exception when raise_exception then if sqlerrm<>'not_authorized' then raise;end if;end;
end $$;
select 'PASS: ingredient quantity/remaining, retail quantity/price, notes, allocation guard, stale write and auth' result;
rollback;