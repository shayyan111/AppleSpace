-- Customer auth users have no ERP staff role. NULL must fail closed.
do $patch$ declare f regprocedure; src text; begin
 foreach f in array array['public.erp_delete_phone_purchase(uuid)'::regprocedure,'public.erp_delete_accessory(uuid)'::regprocedure,'public.erp_delete_accessory_purchase(uuid)'::regprocedure,'public.erp_update_phone_purchase(jsonb)'::regprocedure,'public.erp_update_accessory_purchase(jsonb)'::regprocedure] loop
  select pg_get_functiondef(f) into src;
  src:=replace(src,'auth.uid() is null or r not in','auth.uid() is null or r is null or r not in');
  src:=replace(src,'auth.uid() is null or v_role not in','auth.uid() is null or v_role is null or v_role not in');
  execute src;
 end loop;
end $patch$;
-- This provisioning function must remain service-only, never customer-callable.
revoke all on function public.erp_set_website_manager(uuid,boolean) from public,anon,authenticated;
