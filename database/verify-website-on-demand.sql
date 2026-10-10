-- Rollback-only integration test. No accounts, products or storage metadata remain.
begin;
do $$
declare
 manager_id uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 product uuid; result jsonb; entry jsonb; original jsonb; changed jsonb; payload jsonb;
 inventory_count bigint; accessories_count bigint; purchases_count bigint;
 photos uuid[]:='{}'; photo uuid; object_path text; i integer;
begin
 select count(*) into inventory_count from public.inventory_items;
 select count(*) into accessories_count from public.accessories;
 select count(*) into purchases_count from public.purchases;
 original:=private.website_products(false);
 insert into auth.users(id,email) values(manager_id,'on-demand-'||manager_id||'@example.invalid');
 insert into private.website_managers(user_id,active) values(manager_id,true);
 perform set_config('request.jwt.claim.sub',manager_id::text,true);
 execute 'set local role authenticated';
 result:=public.store_update(jsonb_build_object('action','on_demand_save','title','On-demand rollback test','model','iPhone test','category','iphones','description','Available by enquiry only.','published',false));
 product:=(result->>'id')::uuid;
 if not exists(select 1 from jsonb_array_elements(public.store_portal()->'products') x where x->>'id'=product::text and x->>'kind'='on_demand' and x->>'status'='on_demand') then raise exception 'Manager cannot see new on-demand listing'; end if;
 execute 'reset role';
 if exists(select 1 from jsonb_array_elements(public.store_catalog()) x where x->>'id'=product::text) then raise exception 'Hidden on-demand listing exposed publicly'; end if;
 execute 'set local role authenticated';
 perform public.store_update(jsonb_build_object('action','on_demand_save','id',product,'title','Published demand test','model','iPad test','category','ipads','price',null,'price_label','Contact for price','storage','256 GB','color','Gray','published',true));
 execute 'reset role';
 select x into entry from jsonb_array_elements(public.store_catalog()) x where x->>'id'=product::text;
 if entry is null or entry->>'category'<>'ipads' or entry->>'price' is not null or entry->>'price_label'<>'Contact for price' or (entry->>'quantity')::int<>0 then raise exception 'Published quote-only catalog data incorrect'; end if;
 if entry::text ~ '"(purchase_price|profit|created_by|imei_1|imei_2|supplier_id)"' then raise exception 'Private fields exposed'; end if;
 execute 'set local role authenticated';
 perform public.store_update(jsonb_build_object('action','on_demand_save','id',product,'title','Priced demand test','model','Accessory test','category','accessories','price',15000,'published',true));
 execute 'reset role';
 select x into entry from jsonb_array_elements(public.store_catalog()) x where x->>'id'=product::text;
 if (entry->>'price')::numeric<>15000 or entry->>'category'<>'accessories' then raise exception 'Price/category update failed'; end if;
 for i in 1..9 loop
  object_path:=manager_id::text||'/rollback-demand-'||product||'-'||i||'.png';
  insert into storage.objects(bucket_id,name) values('website-products',object_path);
  execute 'set local role authenticated';
  if i<=8 then
   result:=public.store_update(jsonb_build_object('action','media_add','kind','on_demand','id',product,'path',object_path,'alt','Test product','sort_order',i));
   photos:=array_append(photos,(result->>'id')::uuid);
  else
   begin
    perform public.store_update(jsonb_build_object('action','media_add','kind','on_demand','id',product,'path',object_path));
    raise exception 'Ninth photo was allowed';
   exception when raise_exception then if sqlerrm<>'Maximum eight photos per product' then raise; end if; end;
  end if;
  execute 'reset role';
 end loop;
 execute 'set local role authenticated';
 perform public.store_update(jsonb_build_object('action','media_cover','media_id',photos[8]));
 execute 'reset role';
 select x into entry from jsonb_array_elements(public.store_catalog()) x where x->>'id'=product::text;
 if jsonb_array_length(entry->'images')<>8 or entry->'images'->0->>'id'<>photos[8]::text then raise exception 'Photo count/cover incorrect'; end if;
 execute 'set local role authenticated';
 perform public.store_update(jsonb_build_object('action','media_remove','media_id',photos[1]));
 execute 'reset role';
 payload:=jsonb_build_object('name','Rollback customer','phone','03999999999','fulfilment','pickup','request_id',gen_random_uuid(),'items',jsonb_build_array(jsonb_build_object('id',product,'kind','on_demand','quantity',1,'price',15000)));
 execute 'set local role anon';
 begin
  perform public.store_checkout(payload);
  raise exception 'On-demand product was accepted by checkout';
 exception when raise_exception then if sqlerrm<>'Invalid product type' then raise; end if; end;
 begin
  perform public.store_update(jsonb_build_object('action','on_demand_save','title','Unauthorized','model','Unauthorized','category','iphones'));
  raise exception 'Anonymous manager action accepted';
 exception when insufficient_privilege then null; end;
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 execute 'set local role authenticated';
 begin
  perform public.store_update(jsonb_build_object('action','on_demand_delete','id',product));
  raise exception 'Unauthorized account deleted listing';
 exception when insufficient_privilege then null; end;
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',manager_id::text,true);
 execute 'set local role authenticated';
 perform public.store_update(jsonb_build_object('action','on_demand_save','id',product,'title','Hide test','model','Phone test','category','iphones','published',false));
 execute 'reset role';
 if exists(select 1 from jsonb_array_elements(public.store_catalog()) x where x->>'id'=product::text) then raise exception 'Unpublished on-demand listing still public'; end if;
 execute 'set local role authenticated';
 perform public.store_update(jsonb_build_object('action','on_demand_delete','id',product));
 execute 'reset role';
 if exists(select 1 from private.website_on_demand where id=product) or exists(select 1 from private.website_media where on_demand_id=product) then raise exception 'Delete did not remove listing/media links'; end if;
 if (select count(*) from public.inventory_items)<>inventory_count or (select count(*) from public.accessories)<>accessories_count or (select count(*) from public.purchases)<>purchases_count then raise exception 'On-demand workflow changed ERP stock/purchases'; end if;
 changed:=private.website_products(false);
 if changed is distinct from original then raise exception 'Existing public inventory catalog changed'; end if;
 raise notice 'PASS: manager create/edit/publish/hide/delete, categories, optional price, eight photos, cover/remove, checkout rejection, authorization and ERP isolation';
end $$;
rollback;
