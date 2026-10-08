-- Transactional checks: all fixtures, publication changes and orders roll back.
begin;
insert into public.accessories(id,name,sku,quantity,purchase_price,sale_price) values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Verification cable','VERIFY-WEBSITE-CABLE',3,500,2000);
insert into auth.users(id,email) values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','website-verification@example.invalid');
insert into private.website_managers(user_id) values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true);
set local role authenticated;
do $$
declare portal jsonb; blocked boolean:=false; n integer;
begin
 portal:=public.store_portal();
 if portal->>'owner'='true' then raise exception 'Website manager became ERP owner'; end if;
 if portal::text~'purchase_price|cost_price|profit|supplier_id|purchase_id|imei_1|imei_2' then raise exception 'Sensitive data leaked through portal'; end if;
 select count(*) into n from public.inventory_items; if n<>0 then raise exception 'Website manager can read raw inventory'; end if;
 select count(*) into n from public.accessories; if n<>0 then raise exception 'Website manager can read raw accessories'; end if;
 select count(*) into n from public.purchases; if n<>0 then raise exception 'Website manager can read purchase records'; end if;
 begin perform public.erp_read(); exception when others then blocked:=true; end;
 if not blocked then raise exception 'Website manager can read ERP snapshot'; end if;
 blocked:=false;
 begin perform public.store_update(jsonb_build_object('action','manager','email','website-verification@example.invalid','active',true)); exception when others then blocked:=true; end;
 if not blocked then raise exception 'Website manager can grant access'; end if;
end;$$;
do $$declare blocked boolean:=false; begin
 perform public.store_update(jsonb_build_object('action','listing','kind','accessory','id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','title','Verification cable','description','','price',2000,'published',true));
 if not exists(select 1 from jsonb_array_elements(public.store_catalog())x where x->>'id'='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') then raise exception 'Published accessory absent'; end if;
 perform public.store_checkout(jsonb_build_object('request_id',gen_random_uuid(),'name','Verification Customer','phone','03000000001','fulfilment','pickup','items',jsonb_build_array(jsonb_build_object('kind','accessory','id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','quantity',3,'price',2000))));
 begin perform public.store_checkout(jsonb_build_object('request_id',gen_random_uuid(),'name','Verification Customer','phone','03000000001','fulfilment','pickup','items',jsonb_build_array(jsonb_build_object('kind','accessory','id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','quantity',4,'price',2000)))); exception when others then blocked:=true; end;
 if not blocked then raise exception 'Accessory overselling allowed'; end if;
end;$$;
-- Publish one real stock item temporarily using its current ID. No real edit persists.
do $$
declare portal jsonb; p jsonb; result jsonb; repeated jsonb; request uuid:=gen_random_uuid(); blocked boolean:=false;
begin
 portal:=public.store_portal();
 select x into p from jsonb_array_elements(portal->'products')x where x->>'kind'='iphone' and x->>'status'='in_stock' limit 1;
 if p is null then raise exception 'Verification requires one in-stock phone'; end if;
 perform public.store_update(jsonb_build_object('action','listing','kind','iphone','id',p->>'id','title','Verification phone','description','Verification','price',120000,'published',true));
 if not exists(select 1 from jsonb_array_elements(public.store_catalog())x where x->>'id'=p->>'id') then raise exception 'Published phone absent'; end if;
 result:=public.store_checkout(jsonb_build_object('request_id',request,'name','Verification Customer','phone','03000000000','fulfilment','pickup','items',jsonb_build_array(jsonb_build_object('kind','iphone','id',p->>'id','quantity',1,'price',120000))));
 if (result->>'total')::numeric<>120000 then raise exception 'Order total mismatch'; end if;
 repeated:=public.store_checkout(jsonb_build_object('request_id',request,'name','Verification Customer','phone','03000000000','fulfilment','pickup','items',jsonb_build_array(jsonb_build_object('kind','iphone','id',p->>'id','quantity',1,'price',120000))));
 if result->>'id'<>repeated->>'id' then raise exception 'Retry duplicated order'; end if;
 begin perform public.store_checkout(jsonb_build_object('request_id',gen_random_uuid(),'name','Verification Customer','phone','03000000000','fulfilment','pickup','items',jsonb_build_array(jsonb_build_object('kind','iphone','id',p->>'id','quantity',2,'price',120000)))); exception when others then blocked:=true; end;
 if not blocked then raise exception 'Checkout allowed overselling'; end if;
 blocked:=false;
 begin perform public.store_checkout(jsonb_build_object('request_id',gen_random_uuid(),'name','Verification Customer','phone','03000000000','fulfilment','pickup','items',jsonb_build_array(jsonb_build_object('kind','iphone','id',p->>'id','quantity',1,'price',1)))); exception when others then blocked:=true; end;
 if not blocked then raise exception 'Checkout accepted client price manipulation'; end if;
 perform public.store_update(jsonb_build_object('action','listing','kind','iphone','id',p->>'id','price',120000,'published',false));
 if exists(select 1 from jsonb_array_elements(public.store_catalog())x where x->>'id'=p->>'id') then raise exception 'Hidden product still public'; end if;
end;$$;
reset role;
update public.accessories set quantity=0 where id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
do $$begin if exists(select 1 from jsonb_array_elements(public.store_catalog())x where x->>'id'='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') then raise exception 'Out-of-stock accessory remains public'; end if; end;$$;
-- Sold status immediately removes a published phone from both portal and shop.
select set_config('website.test_phone',(select id::text from public.inventory_items where status='in_stock' limit 1),true);
update public.inventory_items set show_on_website=true,website_price=120000 where id=current_setting('website.test_phone')::uuid;
update public.inventory_items set status='sold' where id=current_setting('website.test_phone')::uuid;
set local role authenticated;
do $$begin
 if exists(select 1 from jsonb_array_elements(public.store_catalog())x where x->>'id'=current_setting('website.test_phone')) then raise exception 'Sold product remains public'; end if;
 if exists(select 1 from jsonb_array_elements(public.store_portal()->'products')x where x->>'id'=current_setting('website.test_phone')) then raise exception 'Sold product remains in website inventory'; end if;
end;$$;
reset role;
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$declare blocked boolean:=false;begin
 perform public.store_catalog();
 begin perform public.store_portal(); exception when insufficient_privilege then blocked:=true; end;
 if not blocked then raise exception 'Anonymous visitor can use portal'; end if;
end;$$;
rollback;
