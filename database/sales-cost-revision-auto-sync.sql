-- Commit-visible revision shared by all Sale Analysis clients.
create table cct_internal.sales_cost_revision(
 singleton boolean primary key default true check(singleton),
 revision bigint not null default 1,
 changed_at timestamptz not null default clock_timestamp()
);
insert into cct_internal.sales_cost_revision(singleton) values(true);
alter table cct_internal.sales_cost_revision enable row level security;
revoke all on cct_internal.sales_cost_revision from public,anon,authenticated;
create function cct_internal.sales_cost_changed() returns trigger
language plpgsql security definer set search_path=pg_catalog,cct_internal as $$
declare tx text:=pg_current_xact_id()::text;
begin
 if tg_op='UPDATE' and to_jsonb(old)=to_jsonb(new) then return null;end if;
 if current_setting('cct.sales_revision_tx',true) is distinct from tx then
  perform set_config('cct.sales_revision_tx',tx,true);
  update cct_internal.sales_cost_revision set revision=revision+1,changed_at=clock_timestamp() where singleton;
 end if;
 return null;
end $$;
revoke all on function cct_internal.sales_cost_changed() from public,anon,authenticated;
do $$
declare t record;
begin
 for t in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where c.relkind='r' and (
 (n.nspname='public' and c.relname in (
 'cct_cost_batches','cct_ingredient_lots','cct_production_batches',
 'order_commits','cct_order_sauce_cogs','cct_order_sauce_resolution_v1',
 'cct_combo_fifo_allocations','cct_single_fifo_allocations',
 'cct_chicken_mix_fifo_allocations','cct_chicken_mix_jelly_allocations',
 'cct_chicken_mix_packaging_allocations','cct_mango_fifo_allocations',
 'cct_mango_shake_fifo_allocations'))
 or(n.nspname='cct_internal' and c.relname in ('single_ingredient_allocations',
 'single_packaging_allocations','food_packaging_allocations','single_sauce_lots','chicken_sauce_lots')))
 loop
 execute format('create constraint trigger zz_cct_sales_cost_revision after insert or update or delete on %I.%I deferrable initially deferred for each row execute function cct_internal.sales_cost_changed()',t.nspname,t.relname);
 end loop;
end $$;
create function public.cct_sales_cost_revision_v1(p_passcode text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,cct_internal as $$
begin
 if not public.cct_production_auth_v1(p_passcode) then raise exception 'not_authorized';end if;
 return (select jsonb_build_object('revision',revision::text,'changed_at',changed_at)
 from cct_internal.sales_cost_revision where singleton);
end $$;
revoke all on function public.cct_sales_cost_revision_v1(text) from public;
grant execute on function public.cct_sales_cost_revision_v1(text) to anon,authenticated;
