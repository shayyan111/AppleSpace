begin;
do $test$
declare uid uuid; iid uuid:=gen_random_uuid(); aid uuid:=gen_random_uuid(); oid uuid:=gen_random_uuid(); oid2 uuid:=gen_random_uuid(); r jsonb; sid uuid;
begin
 select id into uid from public.user_profiles where role='owner' and is_active limit 1;
 if uid is null then raise exception 'Test needs owner fixture'; end if;
 perform set_config('request.jwt.claim.sub',uid::text,true);
 insert into public.inventory_items(id,stock_code,barcode_value,model,imei_1,pta_status,purchase_price,default_sale_price) values(iid,'TEST-'||iid,'TEST-'||iid,'Fulfilment test phone','999999999999998','non_pta',80,100);
 insert into public.accessories(id,name,sku,quantity,purchase_price,sale_price) values(aid,'Fulfilment test accessory','TEST-'||aid,5,5,10);
 insert into private.website_orders(id,request_id,customer_name,phone,fulfilment,total,items) values(oid,gen_random_uuid(),'Transaction test','03000000000','delivery',120,jsonb_build_array(jsonb_build_object('id',iid,'kind','iphone','title','Test phone','quantity',1,'price',100),jsonb_build_object('id',aid,'kind','accessory','title','Test accessory','quantity',2,'price',10)));
 begin perform public.store_update(jsonb_build_object('action','order_status','id',oid,'status','completed')); raise exception 'TEST invalid transition accepted'; exception when others then if sqlerrm='TEST invalid transition accepted' then raise; end if; end;
 perform public.store_update(jsonb_build_object('action','order_status','id',oid,'status','confirmed'));
 perform public.store_update(jsonb_build_object('action','order_status','id',oid,'status','dispatched','courier','Test courier','tracking_number','TEST'));
 r:=public.store_update(jsonb_build_object('action','order_status','id',oid,'status','completed'));sid:=(r->>'sale_id')::uuid;
 perform public.store_update(jsonb_build_object('action','order_status','id',oid,'status','completed'));
 if (select quantity from public.accessories where id=aid)<>3 or (select status from public.inventory_items where id=iid)<>'sold' then raise exception 'Stock mismatch'; end if;
 if (select count(*) from public.sales where website_order_id=oid)<>1 or (select count(*) from public.sale_items where sale_id=sid)<>2 then raise exception 'Duplicate/missing sale'; end if;
 if (select sale_id from public.sold_phones where original_inventory_id=iid)<>sid then raise exception 'Archive missing invoice'; end if;
 if (select sum(cost_price_snapshot) from public.sale_item_costs where sale_item_id in (select id from public.sale_items where sale_id=sid))<>90 then raise exception 'Cost snapshot mismatch'; end if;
 if (select payment_status from public.sales where id=sid)<>'unpaid' then raise exception 'Payment invented'; end if;
 if not exists(select 1 from jsonb_array_elements(public.store_order_list('completed',0)->'orders') x where x->>'id'=oid::text) then raise exception 'Done missing'; end if;
 insert into private.website_orders(id,request_id,customer_name,phone,fulfilment,total,items) values(oid2,gen_random_uuid(),'Transaction test','03000000000','pickup',100,jsonb_build_array(jsonb_build_object('id',iid,'kind','iphone','title','Test phone','quantity',1,'price',100)));
 begin perform public.store_update(jsonb_build_object('action','order_status','id',oid2,'status','confirmed')); raise exception 'TEST sold stock accepted'; exception when others then if sqlerrm='TEST sold stock accepted' then raise; end if; end;
 perform public.store_update(jsonb_build_object('action','order_status','id',oid2,'status','cancelled'));
 perform set_config('request.jwt.claim.sub','',true);
 begin perform public.store_order_list('completed',0); raise exception 'TEST unauthorized list accepted'; exception when insufficient_privilege then null; end;
 begin perform private.website_fulfil_order(jsonb_build_object('id',oid,'status','completed')); raise exception 'TEST unauthorized mutation accepted'; exception when insufficient_privilege then null; end;
end $test$;
rollback;
