do $patch$ declare d text;begin
select pg_get_functiondef('cct_internal.single_requirements(jsonb,text,jsonb)'::regprocedure) into d;
d:=replace(d,'coalesce(p_item->>''option_text'','''')||'' ''||coalesce(p_item->>''note'','''')','coalesce(p_item->>''option_text'','''')||'' ''||coalesce(p_item->>''name'','''')||'' ''||coalesce(p_item->>''note'','''')');
execute d;
end $patch$;